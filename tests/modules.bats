#!/usr/bin/env bats
# Library tools 11-13 and the Biblioteca Fácil preset: WhatsApp / Telegram
# messaging (the SMS::Send driver of the panel, run by the real SMS::Send
# against tests/mocks/http-mock), cataloguing aids (author tables and CDD,
# real MariaDB), collection spreadsheets (real MARC::Record and
# yaz-marcdump) and marc_replace.pl (run as a CGI with the Koha doubles of
# tests/mocks/perl5).

setup() {
    load lib/common
    kei_reset_env
    kei_reset_live_catalog
    kei_tools_catalog
    kei_br_catalog
    kei_modules_catalog
    unset KEI_SELECT_FILE KEI_DEFAULT_ANSWER KEI_EXTRA KOHA_INTRA_CGI
    W="$BATS_TEST_TMPDIR"
    CONF=/etc/koha/sites/library/kei-messaging.conf
    PM=/usr/local/lib/site_perl
}

teardown() { kei_kill_daemons; }

pre_backups() { find /var/backups/koha_sql -maxdepth 1 -name "PRE-${1:-}*" 2>/dev/null | wc -l; }
extra()       { printf '%s\n' "$@" > "$W/extra.sh"; export KEI_EXTRA="$W/extra.sh"; }
marc_dump()   { yaz-marcdump "$1" 2>/dev/null; }
pref()        { tools_sql "SELECT value FROM systempreferences WHERE variable = '$1';"; }
# Perl as the Koha instance would run it (settings found through KOHA_CONF).
kperl()       { KOHA_CONF=/etc/koha/sites/library/koha-conf.xml perl -I "$PM" "$@"; }

# WhatsApp through Evolution API on the HTTP double, numbers of Paraná (44).
whatsapp_on() {
    kei_http_mock_start
    inputs setup evolution "http://127.0.0.1:18080" biblioteca "segredo-123456"
    panel lt_msg_whatsapp
    inputs 55 44
    panel lt_msg_country
}

# --- Messaging -----------------------------------------------------------------

@test "M01 phone sanitizer: country and area code, trunk and carrier prefixes, 9th mobile digit, DDD check" {
    local v
    while IFS='|' read -r num cc area want kind; do
        panel phone_normalize "$num" "$cc" "$area"
        assert '[ "$output" = "$(printf "%s\t%s" "$want" "$kind")" ]' "$num (+$cc $area): got '$output', want '$want $kind'"
    done <<'EOF'
(44) 99876-5432|55|44|+5544998765432|fixed
44 9876-5432|55|44|+5544998765432|fixed
9876-5432|55|44|+5544998765432|fixed
+55 44 98765-4321|55|44|+5544987654321|ok
55 44 98765-4321|55||+5544987654321|fixed
0 44 98765-4321|55||+5544987654321|fixed
0 15 44 9876-5432|55||+5544998765432|fixed
(44) 3524-1234|55||+554435241234|landline
+351 912 345 678|55|44|+351912345678|ok
912 345 678|351||+351912345678|fixed
00351912345678|55||+351912345678|fixed
555 123 4567|1||+15551234567|fixed
EOF
    for v in "98765-4321|55|" "(10) 98765-4321|55|44" "(44) 1524-1234|55|44" "44 8765 432|55|" "abc|55|44" "(44) 89876-5432|55|44"; do
        panel phone_normalize "${v%%|*}" "$(cut -d'|' -f2 <<< "$v")" "$(cut -d'|' -f3 <<< "$v")"
        assert '[ "$status" -ne 0 ] && [ "$output" = "$(printf "\tinvalid")" ]' "'$v' must be invalid: $output"
    done
    panel phone_ddd_valid 44;  assert '[ "$status" -eq 0 ]'
    panel phone_ddd_valid 20;  assert '[ "$status" -ne 0 ]' "DDD 20 does not exist"
}

@test "M02 WhatsApp (Evolution API): settings for Koha only, test message through SMS::Send with the corrected number" {
    whatsapp_on
    assert '[ -f "$CONF" ] && [ "$(stat -c %a "$CONF")" = "640" ]' "the settings hold the token: $(ls -l "$CONF")"
    assert 'grep -qx "whatsapp=on" "$CONF" && grep -qx "wa_url=http://127.0.0.1:18080" "$CONF" && grep -qx "wa_instance=biblioteca" "$CONF" && grep -qx "country=55" "$CONF" && grep -qx "area=44" "$CONF"' "$(cat "$CONF")"
    assert '[ -f "$PM/SMS/Send/KohaEasy/Gateway.pm" ] && [ -f "$PM/KohaEasy/Messaging.pm" ] && [ -x /usr/local/lib/koha-easy-installer/kei-telegram-link ]'
    assert '[ "$(pref SMSSendDriver)" = "Email" ] && [ "$(pre_backups)" = "0" ]' "setting a channel up does not touch Koha"
    inputs "(44) 9876-5432"
    panel lt_msg_test
    assert 'dialogs | grep -q "^OK .*whatsapp"' "$(dialogs | tail -3)"
    assert 'grep -q "koha-shell library -c.*msg-test.pl" "$KEI_S/calls.log"' "sent as the instance user: $(calls | tail -3)"
    assert 'http_log | grep -q "\"path\": \"/message/sendText/biblioteca\"" && http_log | grep -q "\"apikey\": \"segredo-123456\""' "$(http_log)"
    assert 'http_log | grep -q "\"number\": \"5544998765432\""' "9th digit and country code added: $(http_log)"
    assert 'http_log | grep -q "Test message from the library system"'
}

@test "M03 gateway errors and invalid numbers are reported; nothing is sent to a bad number" {
    whatsapp_on
    touch "$KEI_S/http-fail"
    inputs "44 99876-5432"
    panel lt_msg_test
    assert 'dialogs | grep -q "^ERROR .*not sent"' "$(dialogs | tail -2)"
    assert 'grep -q "Reason: WhatsApp: HTTP 500" "$KEI_S/textbox.last"' "$(cat "$KEI_S/textbox.last")"
    rm -f "$KEI_S/http-fail" "$KEI_S/http.log"
    inputs "(10) 1234-5678"
    panel lt_msg_test
    assert 'dialogs | grep -q "Invalid phone number"' && assert '[ ! -s "$KEI_S/http.log" ]' "nothing sent: $(http_log)"
    inputs setup evolution "ftp://gateway"
    panel lt_msg_whatsapp
    assert 'dialogs | grep -q "Invalid address" && grep -qx "wa_url=http://127.0.0.1:18080" "$CONF"' "a bad address changes nothing"
}

@test "M04 Telegram: token checked with getMe, patrons link their own number, notices go to the linked chat" {
    kei_http_mock_start
    panel msg_conf_set tg_api "http://127.0.0.1:18080"
    inputs setup "123456:BADBADBADBADBADBADBADBADBADBADBADBAD"
    panel lt_msg_telegram
    assert 'dialogs | grep -q "^ERROR .*did not accept the token"' "$(dialogs | tail -2)"
    assert '! grep -qx "telegram=on" "$CONF" && [ ! -f /etc/cron.d/koha_messaging ]' "a refused token keeps Telegram off"
    inputs setup "123456:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef1234"
    panel lt_msg_telegram
    assert 'grep -qx "telegram=on" "$CONF" && grep -qx "tg_bot=biblioteca_teste_bot" "$CONF"' "$(cat "$CONF")"
    assert 'grep -q "koha-shell library -c \"/usr/bin/perl /usr/local/lib/koha-easy-installer/kei-telegram-link\"" /etc/cron.d/koha_messaging' "$(cat /etc/cron.d/koha_messaging 2>&1)"
    assert '! grep -q process_message_queue /etc/cron.d/koha_messaging' "no notice queue before the notices are turned on"
    cat > "$KEI_S/tg-updates.json" <<'JSON'
[{"update_id": 1, "message": {"chat": {"id": 555, "type": "private"}, "from": {"id": 555}, "text": "/start"}},
 {"update_id": 2, "message": {"chat": {"id": 555, "type": "private"}, "from": {"id": 555}, "contact": {"phone_number": "5544998765432", "user_id": 555}}},
 {"update_id": 3, "message": {"chat": {"id": 777, "type": "private"}, "from": {"id": 777}, "contact": {"phone_number": "5544988887777", "user_id": 999}}},
 {"update_id": 4, "message": {"chat": {"id": -100, "type": "group"}, "from": {"id": 1}, "text": "/start"}}]
JSON
    run kperl /usr/local/lib/koha-easy-installer/kei-telegram-link
    assert '[ "$status" -eq 0 ]' "$output"
    assert 'grep -qx "+5544998765432 555" /var/lib/koha/library/kei-messaging/telegram.map && [ "$(wc -l < /var/lib/koha/library/kei-messaging/telegram.map)" = "1" ]' "only the own contact is linked: $(cat /var/lib/koha/library/kei-messaging/telegram.map)"
    assert 'http_log | grep "sendMessage" | grep "\"chat_id\": 555" | grep -q "\"request_contact\": true"' "Start answers with the share button: $(http_log)"
    assert 'http_log | grep "\"chat_id\": 777" | grep -q "your own phone number"'
    assert '! http_log | grep -q "\"chat_id\": -100"' "groups are ignored"
    assert '[ "$(cat /var/lib/koha/library/kei-messaging/telegram.offset)" = "5" ]'
    local sent; sent=$(http_log | grep -c sendMessage)
    run kperl /usr/local/lib/koha-easy-installer/kei-telegram-link
    assert '[ "$(http_log | grep -c sendMessage)" = "$sent" ] && http_log | tail -1 | grep -q "\"offset\": 5"' "updates are read once"
    inputs "(44) 99876-5432"
    panel lt_msg_test
    assert 'dialogs | grep -q "^OK .*telegram" && http_log | tail -1 | grep -q "\"chat_id\": 555"' "$(http_log | tail -1)"
    printf '[{"update_id": 5, "message": {"chat": {"id": 555, "type": "private"}, "from": {"id": 555}, "text": "/stop"}}]' > "$KEI_S/tg-updates.json"
    run kperl /usr/local/lib/koha-easy-installer/kei-telegram-link
    assert '[ ! -s /var/lib/koha/library/kei-messaging/telegram.map ]' "/stop unlinks"
}

@test "M05 Koha notices on and off: SMSSendDriver saved and restored, verified backups, two-minute queue" {
    panel lt_msg_notices
    assert 'dialogs | grep -q "Turn on WhatsApp or Telegram first" && [ "$(pref SMSSendDriver)" = "Email" ]'
    whatsapp_on
    answer no
    panel lt_msg_notices
    assert '[ "$(pref SMSSendDriver)" = "Email" ] && [ "$(pre_backups)" = "0" ]' "declined: nothing changes"
    answer yes
    panel lt_msg_notices
    assert '[ "$(pref SMSSendDriver)" = "KohaEasy::Gateway" ]' "$(dialogs | tail -3)"
    assert '[ "$(pre_backups MESSAGING)" = "1" ] && grep -qx "prev_driver=Email" /etc/koha-easy-install/messaging.state'
    assert 'grep -q "koha-shell library -c \"/usr/share/koha/bin/cronjobs/process_message_queue.pl -t sms\"" /etc/cron.d/koha_messaging' "$(cat /etc/cron.d/koha_messaging)"
    assert 'grep -q "^koha-preferences set SMSSendDriver KohaEasy::Gateway \[pre=1\]" "$KEI_S/calls.log"' "changed only after the backup: $(calls)"
    answer yes
    panel lt_msg_notices
    assert '[ "$(pref SMSSendDriver)" = "Email" ] && [ ! -f /etc/koha-easy-install/messaging.state ] && [ ! -f /etc/cron.d/koha_messaging ]' "$(pref SMSSendDriver)"
    assert '[ "$(pre_backups MESSAGING)" = "2" ]'
}

@test "M06 what Koha needs: report, then short SMS notices only where there is none" {
    answer yes
    panel lt_msg_check
    assert 'grep -q "\[✔\] CHECKOUT" "$KEI_S/textbox.last" && grep -q "\[ \] ODUE" "$KEI_S/textbox.last" && grep -q "\[✔\] HOLD" "$KEI_S/textbox.last"' "$(cat "$KEI_S/textbox.last")"
    assert 'grep -q "SMSSendDriver = Email" "$KEI_S/textbox.last" && grep -q "Patrons with an SMS number: 4" "$KEI_S/textbox.last" && grep -q "chose SMS in their messaging preferences: 2" "$KEI_S/textbox.last"'
    assert '[ "$(tools_sql "SELECT COUNT(*) FROM letter WHERE message_transport_type = \"sms\";")" = "6" ] && [ "$(pre_backups NOTICES)" = "1" ]' "$(tools_sql "SELECT code FROM letter WHERE message_transport_type = 'sms';")"
    assert '[ "$(tools_sql "SELECT content FROM letter WHERE code = \"CHECKOUT\" AND message_transport_type = \"sms\";")" = "The following items have been checked out: [% biblio.title %]" ]' "existing notices are kept"
    local odue; odue=$(tools_sql "SELECT content FROM letter WHERE code = 'ODUE' AND message_transport_type = 'sms';")
    assert '[[ "$odue" == "[%- USE KohaDates -%]"* ]] && [[ "$odue" == *"[% FOREACH overdue IN overdues %]- [% overdue.item.biblio.title %] ([% overdue.date_due | \$KohaDates %])"* ]]' "$odue"
    assert '[ "$(tools_sql "SELECT name FROM letter WHERE code = \"ODUE\" AND message_transport_type = \"sms\";")" = "Overdue notice" ]' "the name of the email version is reused"
    assert '[[ "$(tools_sql "SELECT content FROM letter WHERE code = \"CHECKIN\" AND message_transport_type = \"sms\";")" == "[% branch.branchname %]: [% biblio.title %] was returned."* ]]'
    panel lt_msg_check
    assert '[ "$(pre_backups NOTICES)" = "1" ] && ! dialogs | tail -2 | grep -q "PROMPT"' "nothing left to create"
}

@test "M07 patrons' SMS numbers: report with the driver rules, corrections written only on confirmation" {
    panel msg_conf_set country 55 area 44
    answer yes
    panel lt_msg_phones
    assert 'grep -q "Complete and correct: 1" "$KEI_S/textbox.last" && grep -q "Can be corrected: 1" "$KEI_S/textbox.last" && grep -q "Landlines.*: 1" "$KEI_S/textbox.last" && grep -q "Invalid (fix them by hand): 1" "$KEI_S/textbox.last"' "$(cat "$KEI_S/textbox.last")"
    assert 'grep -q "S1 .*(44) 9876-5432 .*-> +5544998765432" "$KEI_S/textbox.last" && grep -q "S3 .*-> ?" "$KEI_S/textbox.last"'
    assert '[ "$(tools_sql "SELECT smsalertnumber FROM borrowers WHERE cardnumber = \"S1\";")" = "+5544998765432" ]'
    assert '[ "$(tools_sql "SELECT smsalertnumber FROM borrowers WHERE cardnumber = \"S3\";")" = "(10) 1234-5678" ] && [ "$(tools_sql "SELECT smsalertnumber FROM borrowers WHERE cardnumber = \"E1\";")" = "0 15 44 3524-1234" ]' "invalid numbers and landlines are left as they are"
    assert '[ "$(pre_backups PHONES)" = "1" ] && [ ! -d "$PM/KohaEasy" ]' "the report works without installing the module"
}

@test "M08 the driver as Koha calls it: regional numbers, Unicode text, failures die with the reason" {
    whatsapp_on
    run kperl -MSMS::Send -e 'use utf8; my $s = SMS::Send->new("KohaEasy::Gateway", _login => "", _password => ""); print $s->send_sms(to => "(44) 9876-5432", text => "Olá, a devolução é amanhã") ? "sent\n" : "no\n"'
    assert '[ "$output" = "sent" ]' "$output"
    assert 'http_log | tail -1 | grep -q "\"text\": \"Olá, a devolução é amanhã\"" && http_log | tail -1 | grep -q "\"number\": \"5544998765432\""' "$(http_log | tail -1)"
    touch "$KEI_S/http-fail"
    run kperl -MSMS::Send -e 'my $ok = eval { SMS::Send->new("KohaEasy::Gateway")->send_sms(to => "44998765432", text => "x") }; print $ok ? "sent\n" : "failed: $@"'
    assert '[[ "$output" == "failed: WhatsApp: HTTP 500"* ]]' "$output"
}

@test "M09 removing the module restores SMSSendDriver and deletes the driver, settings, links and schedule" {
    whatsapp_on
    answer yes
    panel lt_msg_notices
    assert '[ "$(pref SMSSendDriver)" = "KohaEasy::Gateway" ]'
    answer yes yes
    panel lt_msg_remove
    assert '[ "$(pref SMSSendDriver)" = "Email" ]' "$(pref SMSSendDriver)"
    assert '[ ! -e "$CONF" ] && [ ! -e "$PM/SMS/Send/KohaEasy/Gateway.pm" ] && [ ! -e "$PM/KohaEasy/Messaging.pm" ] && [ ! -e /etc/cron.d/koha_messaging ] && [ ! -d /var/lib/koha/library/kei-messaging ]'
}

# --- Cataloguing aids -----------------------------------------------------------

# Synthetic rows in the layout of the PHA book (left letter, number, right
# letter), made around the examples of its explanation chapter.
pha_rows() {
    cat <<'EOF'
L 1 M
Laf 166 Macd
Lag 167 Mace
Len 588 Macj
Lent 589 Mack
Leo 59 Macl
Lib 671 Macr
Libr 672 Macs
R 1 S
Rat 183 Sampaio
Rau 184 Sampaio M.
Rav 185 Sampaio P.
T 1 A
Tap 175 Ale
Tar 176 Alf
D;1
Dub;876
Duc;877
O 1 U
Od 23 Ud
Oe 24 Ue
EOF
}

@test "C01 loading a table: rows of the book, Windows-1252, order and repeated entries checked before anything is kept" {
    { pha_rows; printf 'Lz 2 Mz\nLent 590 Mack\nÁgua 17 Árvore\n'; } | iconv -f UTF-8 -t WINDOWS-1252 > "$W/pha.txt"
    export KEI_SELECT_FILE="$W/pha.txt"
    inputs pha
    answer no
    panel lt_cat_load
    assert 'grep -q "^Entries: 43$" "$KEI_S/textbox.last" && grep -q "Numbers out of order.*: 3$" "$KEI_S/textbox.last" && grep -q "Repeated entries.*: 2$" "$KEI_S/textbox.last"' "$(cat "$KEI_S/textbox.last")"
    assert 'grep -q "line 22: Lz 2 < Libr 672" "$KEI_S/textbox.last" && grep -q "line 24: Árvore 17 < Alf 176" "$KEI_S/textbox.last" && grep -q "line 23: Lent (Lent 589)" "$KEI_S/textbox.last"' "the suspect lines are shown (Windows-1252 read)"
    assert '[ ! -e /etc/koha-easy-install/tables/pha.tsv ]' "declined: nothing kept"
    pha_rows > "$W/pha.txt"
    inputs pha
    answer yes
    panel lt_cat_load
    assert '[ "$(wc -l < /etc/koha-easy-install/tables/pha.tsv)" = "39" ] && dialogs | grep -q "^OK .*39 entries"' "$(dialogs | tail -2)"
    assert 'grep -qP "^s\tsampaio m\t184\tSampaio M\.$" /etc/koha-easy-install/tables/pha.tsv'
    assert '[ "$(pre_backups)" = "0" ]' "a table is not a database change"
}

# Heading|title|mode|notation (the rules of the PHA explanation).
notation_cases() {
    cat <<'EOF'
Lentino, Noêmia|Classificação decimal||L589c
Libonato, José|Lendas do sul||L671L
Sampaio, Francisco|O mar||S183m
Sampaio, Mário|Poemas||S184p
Sampaio, Paulo|Poemas||S185p
Tapajós, Vicente|História do Brasil||T175h
Alencar, José de|O tronco do ipê||A175t
La Fonte, Antonio|Fábulas||L166f
Du Bartas, Guillaume|La semaine||D876s
O'Donnel, Léopold|The life||O23L
McDown, John|Echoes||M166e
M'Knight, Ann|An hour||M589h
Rath|Arte||R183a
Sampaio|Poemas||S183p
Lent|Xadrez||L589x
|Mil e uma noites|title|M672
EOF
}

@test "C02 author notation follows the rules of the PHA explanation" {
    mkdir -p /etc/koha-easy-install/tables
    pha_rows > "$W/pha.txt"
    panel cat_table_import pha "$W/pha.txt" /etc/koha-easy-install/tables/pha.tsv
    local c
    while IFS='|' read -r name title mode want; do
        panel cat_notation pha "$name" "$title" "" "${mode:-person}"
        assert '[ "$(cut -f1 <<< "$output")" = "$want" ]' "$name / $title: got $(cut -f1 <<< "$output"), want $want"
    done < <(notation_cases)
    panel cat_notation pha "Lentino, Noêmia" "Classificação decimal"
    assert '[ "$(cut -f2-5 <<< "$output")" = "$(printf "Lent\t589\t588\t59")" ]' "entry, number and neighbours: $output"
    panel cat_notation pha "123 Editora" "Livro"
    assert '[ "$status" -ne 0 ]' "a name must start with a letter"
}

@test "C03 notation of a catalogue record: 100, 245 ind2 and 082 read from MARCXML; numbers used by other authors in the class" {
    mkdir -p /etc/koha-easy-install/tables
    pha_rows > "$W/pha.txt"
    panel cat_table_import pha "$W/pha.txt" /etc/koha-easy-install/tables/pha.tsv
    inputs 201
    panel lt_cat_record
    local r="$KEI_S/textbox.last"
    assert 'grep -q "PHA table.*: L589c" "$r" && grep -q "Heading: Lentino, Noêmia$" "$r"' "$(cat "$r")"
    assert 'grep -qx "      025.4" "$r" && grep -qx "      L589c" "$r"' "call number with the class of 082"
    assert 'grep -q "025.4 L589o .*Lent, Carlos" "$r"' "another author already uses L589 in 025.4"
    assert '! grep -q "L5891a" "$r" && ! grep -q "869.3 L589x" "$r" && ! grep -q "LENTINO" "$r"' "longer numbers, other classes and the record itself are not collisions"
    assert 'grep -q "L588  (free)" "$r" && grep -q "L59  (free)" "$r"' "neighbouring numbers: $(cat "$r")"
    inputs 999999
    panel lt_cat_record
    assert 'dialogs | grep -q "Record not found"'
}

@test "C04 CDD: main classes built in, the library's schedule by number or word, and how the catalogue uses it" {
    inputs "869.3"
    panel lt_cat_cdd
    assert 'grep -q "800 .*Literature" "$KEI_S/textbox.last" && grep -q "869.3 .*1$" "$KEI_S/textbox.last"' "$(cat "$KEI_S/textbox.last")"
    printf '800\tLiteratura (teste)\n860;Literaturas ibéricas (teste)\n869 Literatura em português (teste)\n869.3\tFicção (teste)\nxyz\n' > "$W/cdd.txt"
    export KEI_SELECT_FILE="$W/cdd.txt"
    inputs cdd
    answer yes
    panel lt_cat_load
    assert '[ "$(wc -l < /etc/koha-easy-install/tables/cdd.tsv)" = "4" ]' "$(cat "$KEI_S/textbox.last")"
    inputs "869.3"
    panel lt_cat_cdd
    local r="$KEI_S/textbox.last"
    assert 'grep -q "^  800 .*Literature" "$r" && grep -q "^  860 .*Literaturas ibéricas" "$r" && grep -q "^  869 .*Literatura em português" "$r" && grep -q "^  869.3 .*Ficção" "$r"' "$(cat "$r")"
    inputs "FICCAO"
    panel lt_cat_cdd
    assert 'grep -q "869.3 .*Ficção (teste)" "$KEI_S/textbox.last"' "search without accents or case: $(cat "$KEI_S/textbox.last")"
    inputs "title 1 "
    panel lt_cat_cdd
    assert 'grep -q "^  000\.[0-9]* " "$KEI_S/textbox.last"' "classes used by titles with the word: $(cat "$KEI_S/textbox.last")"
    inputs cdd
    answer yes
    panel lt_cat_remove
    assert '[ ! -e /etc/koha-easy-install/tables/cdd.tsv ]'
}

@test "C05 the cataloguing aids never write to the catalogue" {
    local before after
    before=$(mysqldump --skip-dump-date "$DB" | md5sum)
    mkdir -p /etc/koha-easy-install/tables
    pha_rows > "$W/pha.txt"
    panel cat_table_import pha "$W/pha.txt" /etc/koha-easy-install/tables/pha.tsv
    inputs "Lentino, Noêmia" "Classificação" "025.4"
    panel lt_cat_notation
    inputs 201
    panel lt_cat_record
    inputs "poesia"
    panel lt_cat_cdd
    after=$(mysqldump --skip-dump-date "$DB" | md5sum)
    assert '[ "$before" = "$after" ] && [ "$(pre_backups)" = "0" ]'
    inputs "Lentino" "x" "025.4; DROP TABLE items"
    panel lt_cat_notation
    assert 'dialogs | grep -q "Invalid class number"'
}

# --- Collection spreadsheets (Biblioteca Fácil) -----------------------------------

biblioteca_facil_csv() {
    cat <<'EOF' | iconv -f UTF-8 -t WINDOWS-1252 > "$W/acervo.csv"
Tombo;Título;Subtítulo;Autor;Editora;Local;Ano;Edição;ISBN;CDD;Cutter;Assunto;Exemplar;Tipo;Data de aquisição;Valor;Observação da escola
0001;O cortiço;;Azevedo, Aluísio;Ática;São Paulo;1997;2;978-85-08-00001-3;869.3;A994c;"Romance brasileiro; Naturalismo";1;Livro;05/03/2020;R$ 25,90;x
0002;O cortiço;;Azevedo, Aluísio;Ática;São Paulo;1997;2;978-85-08-00001-3;869.3;A994c;"Romance brasileiro; Naturalismo";2;Livro;05/03/2020;;
0003;Revista Ciência Hoje;n. 300;;SBPC;Rio de Janeiro;2013;;;505;;Ciência;;revista;;;
0001;Duplicado;;Autor, Teste;;;;;;;;;;;;;
;;;Sem título;;;;;;;;;;;;;
EOF
}

@test "F01 Biblioteca Fácil: Windows-1252 spreadsheet becomes UTF-8 MARC with one record per title and its items in 952" {
    biblioteca_facil_csv
    export KEI_SELECT_FILE="$W/acervo.csv"
    inputs CPL LIVRO new
    answer yes yes
    panel lt_br_migrate_sheet
    assert '[ "$status" -eq 0 ]' "$output"
    local f="$KEI_S/last-staged.mrc" p="$KEI_S/textboxes.log"
    assert 'grep -q "Título *-> title" "$p" && grep -q "Tombo *-> barcode" "$p" && grep -q "Observação da escola *-> -" "$p" && grep -q "Encoding: Windows-1252" "$p"' "$(cat "$p")"
    assert 'grep -q "Records: 3" "$p" && grep -q "Items created: 4" "$p" && grep -q "Rows without title: 1" "$p" && grep -q "Repeated barcodes (kept on the first row only): 1" "$p"'
    assert '[ -s "$f" ] && iconv -f UTF-8 -t UTF-8 "$f" >/dev/null && [ "$(head -c 10 "$f" | tail -c 1)" = "a" ]' "UTF-8 with leader/09 a"
    assert '[ "$(marc_dump "$f" | grep -c "^245")" = "3" ]' "$(marc_dump "$f")"
    assert 'marc_dump "$f" | grep -qx "245 12 \$a O cortiço"' "nonfiling article: $(marc_dump "$f" | grep ^245)"
    assert 'marc_dump "$f" | grep -qx "260    \$a São Paulo : \$b Ática, \$c 1997" && marc_dump "$f" | grep -qx "250    \$a 2. ed."'
    assert 'marc_dump "$f" | grep -qx "952    \$a CPL \$b CPL \$y LIVRO \$o 869.3 A994c \$p 0001 \$t 1 \$d 2020-03-05 \$g 25.90"' "$(marc_dump "$f" | grep ^952)"
    assert 'marc_dump "$f" | grep -qx "952    \$a CPL \$b CPL \$y LIVRO \$o 869.3 A994c \$p 0002 \$t 2 \$d 2020-03-05"'
    assert 'marc_dump "$f" | grep -qx "952    \$a CPL \$b CPL \$y REV \$o 505 \$p 0003"' "item type from its description"
    assert 'marc_dump "$f" | grep -qx "020    \$a 9788508000013" && marc_dump "$f" | grep -qx "090    \$a 869.3 \$b A994c" && marc_dump "$f" | grep -qx "650  4 \$a Naturalismo"'
    assert 'marc_dump "$f" | grep -A12 "Duplicado" | grep -q "^952    \$a CPL \$b CPL \$y LIVRO$"' "the repeated tombo is dropped, the item kept"
    assert 'grep -q "koha-shell library -c \"/usr/bin/perl\" \".*sheet2marc.pl\".*--dry-run" "$KEI_S/calls.log" && grep -q "^commit_file.pl --batch-number 1 \[pre=1\]" "$KEI_S/calls.log"' "$(calls)"
}

@test "F02 spreadsheet without a title column, or declined after the preview: nothing staged" {
    printf 'Tombo;Autor\n1;Fulano\n' > "$W/semtitulo.csv"
    export KEI_SELECT_FILE="$W/semtitulo.csv"
    inputs CPL LIVRO new
    panel lt_br_migrate_sheet
    assert 'dialogs | grep -q "needs a title column"' "$(dialogs | tail -2)"
    biblioteca_facil_csv
    export KEI_SELECT_FILE="$W/acervo.csv"
    inputs CPL LIVRO keep
    answer no
    panel lt_br_migrate_sheet
    assert 'grep -q "sheet2marc.pl.*--dry-run" "$KEI_S/calls.log" && ! grep -q "sheet2marc.pl.*--out" "$KEI_S/calls.log" && ! grep -q "^stage_file.pl" "$KEI_S/calls.log"' "$(calls)"
    assert '[ "$(pre_backups)" = "0" ] && [ "$(tools_sql "SELECT COUNT(*) FROM biblio;")" = "202" ]'
}

# --- Biblioteca Fácil database (.bkp and data folder) -----------------------------

# Synthetic backup (tests/lib/bf_backup.py): the program's 15 DBISAM tables
# with made-up patrons, copies, loans and holds, compressed like the real one.
bf_backup() { python3 "$KEI_REPO/tests/lib/bf_backup.py" "$@"; }
# Columns and tables of Koha that the loans and holds are written to.
bf_circ_schema() {
    tools_sql "ALTER TABLE items ADD COLUMN itemnotes_nonpublic longtext, ADD COLUMN onloan date;
      CREATE TABLE reserves (reserve_id int(11) NOT NULL AUTO_INCREMENT PRIMARY KEY, borrowernumber int(11) NOT NULL, reservedate date,
        biblionumber int(11) NOT NULL, branchcode varchar(10), priority smallint(6) NOT NULL DEFAULT 1, expirationdate date)
        DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;"
}

@test "F03 Biblioteca Fácil database: the backup's tables become MARC 21 records, patrons and a preview, never the operators' passwords" {
    bf_backup "$W/biblioteca.bkp"
    bf_circ_schema
    tools_sql "INSERT INTO borrower_attribute_types VALUES ('CPF', 'CPF');"
    export KEI_SELECT_FILE="$W/biblioteca.bkp"
    inputs CPL LIVRO PT new
    answer yes yes no yes
    panel lt_br_migrate_bfdb
    assert '[ "$status" -eq 0 ]' "$output"
    local f="$KEI_S/last-staged.mrc" p="$KEI_S/textboxes.log"
    assert 'grep -q "Tables read: 15 of 15" "$p" && grep -q "Backup: Backup do dia 30/09/2026 08:15:18 (2026-09-30 08:15)" "$p"' "$(cat "$p")"
    assert 'grep -q "T09  collection (one row per copy)  105 row(s), 1 deleted, 1 removed in the program" "$p" && grep -q "T04_LEIT: 1 record(s) failed the checksum" "$p"'
    assert 'grep -q "^Records: 103$" "$p" && grep -q "^Items created: 104$" "$p" && grep -q "BF<number> (tombo missing or repeated): 1" "$p"'
    assert 'grep -q "^Patrons ready: 3$" "$p" && grep -q "Invalid CPF (not kept): 1    Repeated CPF (kept on the first only): 1" "$p"'
    assert 'grep -q "^Open loans: 1$" "$p" && grep -q "^Returned loans: 1$" "$p" && grep -q "^Holds still valid: 2$" "$p" && grep -q "Item types: LIVRO -> LIVRO, Revista -> REV" "$p"'
    assert 'grep -q "loan period 7 days; up to 3 items per patron" "$p"'
    assert '! grep -rq "segredo123" "$p" /var/log/koha-easy-install 2>/dev/null' "the operators' passwords never reach a screen or a log"
    assert '[ "$(marc_dump "$f" | grep -c "^245")" = "103" ]' "$(marc_dump "$f" | head -40)"
    assert 'marc_dump "$f" | grep -qx "245 12 \$a O cortiço" && marc_dump "$f" | grep -qx "100 1  \$a Azevedo, Aluísio"'
    assert 'marc_dump "$f" | grep -qx "505 0  \$a Capítulo I (p. 9) -- Capítulo II (p. 21)" && marc_dump "$f" | grep -qx "655  4 \$a ROMANCE"'
    assert 'marc_dump "$f" | grep -qx "952    \$a CPL \$b CPL \$y LIVRO \$o 869.3 A994c \$p 1001 \$t 1 \$c EST1 \$d 2020-03-05 \$x Biblioteca Fácil: acervo 1"' "$(marc_dump "$f" | grep ^952 | head -3)"
    assert 'marc_dump "$f" | grep -qx "952    \$a CPL \$b CPL \$y LIVRO \$p 1002 \$t 2 \$c EST1 \$d 2020-03-05 \$x Biblioteca Fácil: acervo 2" || marc_dump "$f" | grep -q "\$p 1002 .*acervo 2"'
    assert 'marc_dump "$f" | grep -qx "952    \$a CPL \$b CPL \$y LIVRO \$p BF5 \$0 1 \$x Biblioteca Fácil: acervo 5"' "repeated tombo, withdrawn: $(marc_dump "$f" | grep 'acervo 5')"
    assert 'marc_dump "$f" | grep -qx "700 0  \$a Coautora Teste" && marc_dump "$f" | grep -qx "041 0  \$a eng" && ! marc_dump "$f" | grep -q "Autor Apagado\|Livro apagado\|Registro excluído"'
    assert 'marc_dump "$f" | grep -qx "952    \$a CPL \$b CPL \$y REV \$p 1003 \$7 1 \$x Biblioteca Fácil: acervo 3"' "not for loan, item type from its description"
    assert '[ "$(tools_sql "SELECT GROUP_CONCAT(cardnumber ORDER BY cardnumber) FROM borrowers WHERE categorycode = \"PT\" AND cardnumber IN (\"1\",\"2\",\"4\",\"3\",\"5\");")" = "1,2,4" ]' "$(tools_sql "SELECT cardnumber, surname, categorycode FROM borrowers;")"
    assert 'grep -q "^commit_file.pl --batch-number 1 \[pre=1\]" "$KEI_S/calls.log" && grep -q "^import_patrons.pl .*--matchpoint cardnumber .*--confirm \[pre=2\]" "$KEI_S/calls.log"' "$(calls)"
    assert 'dialogs | grep -q "No loan or hold to add"' "the mock import has no Biblioteca Fácil items: $(dialogs | tail -3)"
    assert '[ "$(pre_backups CIRCULATION)" = "0" ] && [ -z "$(ls -A /tmp/koha_tools.* 2>/dev/null)" ]' "no circulation change; the work copies (patron data) are gone"
}

@test "F04 Biblioteca Fácil loans and holds: linked by card number and barcode, one transaction, ids above old_issues" {
    bf_backup "$W/biblioteca.bkp"
    bf_circ_schema
    "$KEI_SH" "$PANEL" bf_write_dbreader "$W/bfdb2koha.pl"
    perl "$W/bfdb2koha.pl" --in "$W/biblioteca.bkp" --branch CPL --itype LIVRO --today 2026-09-30 --circ "$W/circ.sql" --circ-check "$W/check.sql" > /dev/null
    tools_sql "INSERT INTO borrowers (cardnumber, surname, branchcode, categorycode) VALUES ('1', 'Silva', 'CPL', 'PT'), ('2', 'Pereira', 'CPL', 'PT'), ('4', 'Duplicado', 'CPL', 'PT');
      INSERT INTO biblio (title, datecreated) VALUES ('O cortiço', CURDATE()); SET @b1 = LAST_INSERT_ID();
      INSERT INTO biblio (title, datecreated) VALUES ('A menina', CURDATE()); SET @b2 = LAST_INSERT_ID();
      INSERT INTO items (biblionumber, barcode, homebranch, itemnotes_nonpublic) VALUES (@b1, '1001', 'CPL', 'Biblioteca Fácil: acervo 1'),
        (@b1, '1002', 'CPL', 'Biblioteca Fácil: acervo 2'), (@b2, 'BF5', 'CPL', 'Biblioteca Fácil: acervo 5');
      INSERT INTO old_issues (issue_id, borrowernumber, itemnumber) VALUES (500, 1, 1);
      INSERT INTO reserves (borrowernumber, reservedate, biblionumber, priority) VALUES (1, '2026-01-01', @b1, 1);"
    answer yes
    panel tools_locked _lt_br_bfdb_circ "$W/circ.sql" "$W/check.sql"
    assert '[ "$status" -eq 0 ]' "$output $(tail -30 /var/log/koha-easy-install/tools/bf-circulation-*.log)"
    assert 'grep -q "^Loans linked: 2 of 2" "$KEI_S/textboxes.log" && grep -q "^Holds linked: 2 of 2" "$KEI_S/textboxes.log"' "$(cat "$KEI_S/textboxes.log")"
    assert 'dialogs | grep -q "^OK .*Returned loans: 1.*Open loans: 1.*Holds: 2" || dialogs | grep -A0 "^OK" | grep -q "Loans and holds added"' "$(dialogs | tail -3)"
    local open
    open=$(tools_sql "SELECT CONCAT(c.issue_id, '|', b.cardnumber, '|', i.barcode, '|', DATE(c.issuedate), '|', c.date_due, '|', i.onloan, '|', i.issues) FROM issues c JOIN borrowers b USING (borrowernumber) JOIN items i USING (itemnumber) WHERE i.barcode = '1001';")
    assert '[ "$open" = "502|1|1001|2026-09-20|2026-09-27 23:59:00|2026-09-27|1" ]' "open loan: $open"
    assert '[ "$(tools_sql "SELECT CONCAT(o.issue_id, \"|\", b.cardnumber, \"|\", i.barcode, \"|\", DATE(o.returndate)) FROM old_issues o JOIN borrowers b USING (borrowernumber) JOIN items i USING (itemnumber) WHERE o.issue_id > 500;")" = "501|2|1002|2025-03-07" ]'
    assert '[ "$(tools_sql "SELECT AUTO_INCREMENT FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = \"issues\";")" -ge 503 ]' "the next check-out never reuses an old_issues id"
    assert '[ "$(tools_sql "SELECT GROUP_CONCAT(CONCAT(b.cardnumber, \":\", r.priority, \":\", r.expirationdate) ORDER BY r.reserve_id) FROM reserves r JOIN borrowers b USING (borrowernumber) WHERE r.reserve_id > 1;")" = "4:2:2099-12-31,1:1:2099-12-31" ]' "$(tools_sql "SELECT * FROM reserves;")"
    assert '[ "$(pre_backups CIRCULATION)" = "1" ]'
    # Run again: the same loans and holds are not added twice.
    panel tools_locked _lt_br_bfdb_circ "$W/circ.sql" "$W/check.sql"
    assert 'grep -q "^Loans already in Koha (skipped): 2" "$KEI_S/textboxes.log" && grep -q "^Holds already in Koha (skipped): 2" "$KEI_S/textboxes.log" && dialogs | grep -q "No loan or hold to add"' "$(dialogs | tail -3)"
    assert '[ "$(tools_sql "SELECT COUNT(*) FROM issues WHERE issue_id > 500;")" = "1" ] && [ "$(tools_sql "SELECT COUNT(*) FROM old_issues WHERE issue_id > 500;")" = "1" ] && [ "$(tools_sql "SELECT COUNT(*) FROM reserves;")" = "3" ] && [ "$(pre_backups CIRCULATION)" = "1" ]' "$(tools_sql "SELECT * FROM reserves;")"
}

@test "F05 Biblioteca Fácil: data folder read like the backup; a file that is not a backup, or a declined preview, changes nothing" {
    bf_backup --folder "$W/Dados"
    bf_circ_schema
    export KEI_SELECT_FILE="$W/Dados/T09_ACER.dat"
    inputs CPL LIVRO PT new
    answer no
    panel lt_br_migrate_bfdb
    assert 'grep -q "^Records: 103$" "$KEI_S/textboxes.log" && grep -q "^Patrons ready: 3$" "$KEI_S/textboxes.log"' "$(cat "$KEI_S/textboxes.log")"
    head -c 4000 /dev/urandom > "$W/estragado.bkp"
    export KEI_SELECT_FILE="$W/estragado.bkp"
    inputs CPL LIVRO PT new
    panel lt_br_migrate_bfdb
    assert 'dialogs | grep -q "not a Biblioteca Fácil backup"' "$(dialogs | tail -3)"
    bf_backup "$W/biblioteca.bkp"
    head -c 6000 "$W/biblioteca.bkp" > "$W/cortado.bkp"
    export KEI_SELECT_FILE="$W/cortado.bkp"
    inputs CPL LIVRO PT new
    panel lt_br_migrate_bfdb
    assert '[ "$(dialogs | grep -c "not a Biblioteca Fácil backup")" = "2" ]' "a cut backup is refused: $(dialogs | tail -3)"
    assert '! grep -q "bfdb2koha.pl.*--marc" "$KEI_S/calls.log" && ! grep -q "^stage_file.pl\|^import_patrons.pl" "$KEI_S/calls.log"' "$(calls)"
    assert '[ "$(pre_backups)" = "0" ] && [ "$(tools_sql "SELECT COUNT(*) FROM biblio;")" = "202" ]'
}

# --- marc_replace.pl ---------------------------------------------------------------

KS=/run/kei-mock/koha
mr_setup() {
    mkdir -p "$KS/biblio" /var/lib/koha/library/kei-marc-replace
    "$KEI_SH" "$PANEL" marc_replace_script > "$W/marc_replace.pl"
    cat > "$KS/biblio/7.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<record xmlns="http://www.loc.gov/MARC21/slim"><leader>00200nam a2200100 a 4500</leader><controlfield tag="001">7</controlfield>
<datafield tag="245" ind1="0" ind2="0"><subfield code="a">Título provisório</subfield></datafield></record>
XML
    echo 3 > "$KS/biblio/7.items"; echo FA > "$KS/biblio/7.fw"
    cp "$KS/biblio/7.xml" "$W/old7.xml"
}
cgi() { run env PERL5LIB="$KEI_REPO/tests/mocks/perl5" "$KEI_REPO/tests/lib/cgi-run" "$W/marc_replace.pl" "$@"; }
field() { grep -o "name=\"$1\" value=\"[^\"]*\"" <<< "$output" | sed 's/.*value="//; s/"$//'; }
BN_TEXT=$'000    00942nam a2200265 a 4500\n001    9085\n100 1_ |a Assis, Machado de,|d 1839-1908.\n245 10 |a Dom Casmurro /|c Machado de Assis.\n260 __ |a São Paulo :|b Ática,|c 1997.\n650  4 |a Romance brasileiro.\n952 __ |a CPL |p 999'

@test "R01 marc_replace.pl: staff login with edit_catalogue, CSRF token and cud- operation in the form, Koha item types escaped" {
    mr_setup
    cgi GET biblionumber=7
    assert 'grep -qx "checkauth intranet editcatalogue=edit_catalogue" "$KS/calls.log"' "$(cat "$KS/calls.log")"
    assert '[ "$(field csrf_token)" = "tok-SESSID1" ] && [ "$(field op)" = "cud-preview" ] && [ "$(field biblionumber)" = "7" ]' "$output"
    assert 'grep -q "Revista &lt;b&gt; (REV)" <<< "$output" && ! grep -q "Revista <b>" <<< "$output"' "item types from Koha, escaped"
    assert 'grep -q "Content-Type: text/html; charset=utf-8" <<< "$output"'
}

@test "R02 preview of pasted Biblioteca Nacional text: item fields left out, item type set, nothing replaced yet" {
    mr_setup
    cgi POST op=cud-preview csrf_token=tok-SESSID1 biblionumber=7 "marctext=$BN_TEXT" itemtype=LIVRO
    assert 'grep -q "Item fields found in the file and left out: 1" <<< "$output" && grep -q "Items of the record (kept as they are): 3" <<< "$output"' "$output"
    assert 'grep -q "650  4 _aRomance brasileiro." <<< "$output" && grep -q "942    _cLIVRO" <<< "$output" && grep -q "_aSão Paulo :" <<< "$output"' "indicators, 942 and accents"
    assert '! grep -q "^952" <<< "$(sed -n "/<pre>/,/<\/pre>/p" <<< "$output")"'
    assert '[ "$(field op)" = "cud-replace" ] && [ -n "$(field record)" ] && [ "${#output}" -gt 0 ] && [ "$(field digest)" = "$(sha1sum < "$W/old7.xml" | cut -d" " -f1)" ]' "digest of the record now in the catalogue"
    assert '! grep -q ModBiblio "$KS/calls.log" && [ -z "$(ls /var/lib/koha/library/kei-marc-replace)" ]' "nothing replaced by the preview"
}

@test "R03 replacement: one transaction, record locked and compared, previous version saved, items never touched" {
    mr_setup
    cgi POST op=cud-preview csrf_token=tok-SESSID1 biblionumber=7 "marctext=$BN_TEXT"
    local rec dig
    rec=$(field record); dig=$(field digest)
    : > "$KS/calls.log"
    cgi POST op=cud-replace csrf_token=tok-SESSID1 biblionumber=7 "record=$rec" "digest=$dig"
    assert 'grep -q "Record replaced. (7)" <<< "$output"' "$output"
    assert '[ "$(sed -n 2,5p "$KS/calls.log" | tr "\n" "|")" = "txn-begin|select-metadata 7 FOR-UPDATE|ModBiblio 7 fw=FA tags=001,100,245,260,650|txn-commit|" ]' "$(cat "$KS/calls.log")"
    local saved; saved=$(ls /var/lib/koha/library/kei-marc-replace/7-*.xml)
    assert 'cmp -s "$saved" "$W/old7.xml" && [ "$(stat -c %a "$saved")" = "640" ]' "the previous version is saved as it was"
    assert 'grep -q "Dom Casmurro" "$KS/biblio/7.xml" && ! grep -q "tag=\"952\"" "$KS/biblio/7.xml"'
    local v; v=$(basename "$saved" .xml); v=${v#7-}
    assert 'grep -q "op=download&amp;biblionumber=7&amp;version=$v" <<< "$output"'
    cgi GET op=download biblionumber=7 "version=$v"
    assert 'grep -q "attachment; filename=\"biblio-7-$v.xml\"" <<< "$output" && grep -q "Título provisório" <<< "$output"' "$output"
    cgi GET op=download biblionumber=7 "version=../../../etc/passwd"
    assert 'grep -q "404" <<< "$output" && ! grep -q "root:" <<< "$output"' "only saved versions can be downloaded"
}

@test "R04 refused: wrong token, stale preview, unknown record, missing input; no write in any case" {
    mr_setup
    cgi POST op=cud-preview csrf_token=tok-SESSID1 biblionumber=7 "marctext=$BN_TEXT"
    local rec dig
    rec=$(field record); dig=$(field digest)
    cgi POST op=cud-replace csrf_token=tok-OTHER biblionumber=7 "record=$rec" "digest=$dig"
    assert 'grep -q "Invalid or expired security token" <<< "$output"'
    echo '<record xmlns="http://www.loc.gov/MARC21/slim"><leader>00100nam a2200100 a 4500</leader><datafield tag="245" ind1="0" ind2="0"><subfield code="a">Changed by a colleague</subfield></datafield></record>' > "$KS/biblio/7.xml"
    cgi POST op=cud-replace csrf_token=tok-SESSID1 biblionumber=7 "record=$rec" "digest=$dig"
    assert 'grep -q "The record was changed after the preview" <<< "$output" && grep -q "txn-rollback" "$KS/calls.log"' "$output"
    cgi POST op=cud-preview csrf_token=tok-SESSID1 biblionumber=8 "marctext=$BN_TEXT"
    assert 'grep -q "There is no record with this biblionumber" <<< "$output"'
    cgi POST op=cud-preview csrf_token=tok-SESSID1 biblionumber=7
    assert 'grep -q "Paste the text of the record or choose" <<< "$output"'
    assert '! grep -q ModBiblio "$KS/calls.log" && grep -q "Changed by a colleague" "$KS/biblio/7.xml" && [ -z "$(ls /var/lib/koha/library/kei-marc-replace)" ]'
}

@test "R05 input formats: Latin-1 .mrc through MarcToUTF8Record, MARCXML, MarcEdit text; several records or bad lines refused, text escaped" {
    mr_setup
    cat > "$W/one.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<record xmlns="http://www.loc.gov/MARC21/slim"><leader>00000nam  2200000 a 4500</leader><datafield tag="245" ind1="1" ind2="0"><subfield code="a">Memórias póstumas</subfield></datafield><datafield tag="952" ind1=" " ind2=" "><subfield code="p">1</subfield></datafield></record>
XML
    kei_marc "$W/latin1.mrc" ISO-8859-1 "$W/one.xml"
    cgi POST op=cud-preview csrf_token=tok-SESSID1 biblionumber=7 "marcfile=@$W/latin1.mrc"
    assert 'grep -q "_aMemórias póstumas" <<< "$output" && grep -q "Characters read as: ISO-8859-1" <<< "$output" && grep -q "left out: 1" <<< "$output"' "$output"
    assert 'grep -q "MarcToUTF8Record MARC21" "$KS/calls.log"' "Koha converts the characters"
    cgi POST op=cud-preview csrf_token=tok-SESSID1 biblionumber=7 "marcfile=@$W/one.xml"
    assert 'grep -q "_aMemórias póstumas" <<< "$output" && grep -q "UTF-8 (MARCXML)" <<< "$output"'
    cat "$W/latin1.mrc" "$W/latin1.mrc" > "$W/two.mrc"
    cgi POST op=cud-preview csrf_token=tok-SESSID1 biblionumber=7 "marcfile=@$W/two.mrc"
    assert 'grep -q "The file has more than one record" <<< "$output"'
    cgi POST op=cud-preview csrf_token=tok-SESSID1 biblionumber=7 $'marctext==LDR  00000nam\\\\2200000\\a\\4500\n=245  14$aThe {dollar}100 book$cAnon.\n=650  \\4$aTest'
    assert 'grep -q "245 14 _aThe \$100 book" <<< "$output" && grep -q "650  4 _aTest" <<< "$output"' "MarcEdit: $output"
    cgi POST op=cud-preview csrf_token=tok-SESSID1 biblionumber=7 $'marctext=245 10 |a Ok\nthis is <script>alert(1)</script>\n300 garbage'
    assert 'grep -q "were not understood: 2, 3" <<< "$output" && ! grep -q "<script>" <<< "$output"' "$output"
}

@test "R06 ModBiblio failure: the transaction is rolled back and the record stays as it was" {
    mr_setup
    cgi POST op=cud-preview csrf_token=tok-SESSID1 biblionumber=7 "marctext=$BN_TEXT"
    local rec dig
    rec=$(field record); dig=$(field digest)
    touch "$KS/modbiblio.fail"
    cgi POST op=cud-replace csrf_token=tok-SESSID1 biblionumber=7 "record=$rec" "digest=$dig"
    assert 'grep -q "Koha could not replace the record" <<< "$output" && grep -q "txn-rollback" "$KS/calls.log"' "$output"
    assert 'cmp -s "$KS/biblio/7.xml" "$W/old7.xml"'
}

@test "R07 panel: the page and its AI cataloguing modules are compiled with Koha's modules, installed read-only, linked in the Edit menu and removed cleanly" {
    export KOHA_INTRA_CGI="$W/cgi"
    mkdir -p "$W/cgi/tools"
    local js_before; js_before=$(mysql -N -B --raw -e "SELECT value FROM systempreferences WHERE variable = 'IntranetUserJS';" "$DB" | md5sum)
    answer yes
    panel lt_mr_install
    local page="$W/cgi/tools/marc_replace.pl"
    assert '[ -f "$page" ] && [ "$(stat -c "%a %U" "$page")" = "755 root" ]' "$(ls -l "$page" 2>&1) $(dialogs | tail -2)"
    assert 'grep -q "koha-shell library -c \"/usr/bin/perl\" \"-c\" \".*marc_replace.pl\"" "$KEI_S/calls.log"' "compiled as the instance user first: $(calls)"
    assert '[ -d /var/lib/koha/library/kei-marc-replace ] && [ "$(pre_backups MARC-REPLACE)" = "1" ]'
    assert '[ "$(stat -c "%a %U" "$PM/KohaEasy/Cataloguing/Vision.pm")" = "644 root" ] && [ -f "$PM/KohaEasy/Cataloguing/Rules.pm" ]' "AI cataloguing modules installed"
    assert 'grep -q "koha-shell library -c \"/usr/bin/perl\" \"-c\" \".*Vision.pm\"" "$KEI_S/calls.log" && grep -q "koha-shell library -c \"/usr/bin/perl\" \"-c\" \".*Rules.pm\"" "$KEI_S/calls.log"' "modules compiled first"
    assert 'perl -I "$PM" -MKohaEasy::Cataloguing::Vision -MKohaEasy::Cataloguing::Rules -e 1' "the modules load"
    local js; js=$(mysql -N -B --raw -e "SELECT value FROM systempreferences WHERE variable = 'IntranetUserJS';" "$DB")
    assert '[[ "$js" == "/* the library'"'"'s own code */"$'"'"'\n'"'"'"\$(document).ready(function () { var re = /a\\b/; });"* ]]' "the library code is kept as it was: $js"
    assert 'grep -q "tools/marc_replace.pl?biblionumber=" <<< "$js" && grep -q "Replace the record (MARC file)" <<< "$js"'
    assert 'grep -qF "cataloguing\/cataloging-home\.pl" <<< "$js" && grep -q "\"/cgi-bin/koha/tools/marc_replace.pl\", \"fa-exchange\", \"Replace a MARC record\"" <<< "$js" && grep -q "marc_replace.pl?op=vision\", \"fa-camera\", \"AI cataloguing\"" <<< "$js"' "shortcuts in the tools of the cataloguing home page"
    answer yes
    panel lt_mr_install
    js=$(mysql -N -B --raw -e "SELECT value FROM systempreferences WHERE variable = 'IntranetUserJS';" "$DB")
    assert '[ "$(grep -c "marc_replace begin" <<< "$js")" = "1" ] && grep -q "^koha-plack --restart library" "$KEI_S/calls.log" && [ "$(pre_backups MARC-REPLACE)" = "1" ]' "the same block is not written again"
    # A block of an older version (without the shortcuts) is replaced by the new one.
    mysql -e "UPDATE systempreferences SET value = REPLACE(value, 'cataloging-home', 'old-home') WHERE variable = 'IntranetUserJS';" "$DB"
    answer yes
    panel lt_mr_install
    js=$(mysql -N -B --raw -e "SELECT value FROM systempreferences WHERE variable = 'IntranetUserJS';" "$DB")
    assert '[ "$(grep -c "marc_replace begin" <<< "$js")" = "1" ] && grep -q "cataloging-home" <<< "$js" && ! grep -q "old-home" <<< "$js"' "old block updated: $js"
    answer yes
    panel lt_mr_remove
    assert '[ ! -e "$page" ] && [ -d /var/lib/koha/library/kei-marc-replace ] && [ ! -e "$PM/KohaEasy/Cataloguing" ]'
    assert '[ "$(mysql -N -B --raw -e "SELECT value FROM systempreferences WHERE variable = '"'"'IntranetUserJS'"'"';" "$DB" | md5sum)" = "$js_before" ]' "IntranetUserJS back to the original"
}

@test "R08 panel: a page that does not compile is never installed" {
    export KOHA_INTRA_CGI="$W/cgi"
    mkdir -p "$W/cgi/tools"
    extra 'marc_replace_script() { printf "use strict;\nthis is not perl(\n"; }'
    answer no
    panel lt_mr_install
    assert 'dialogs | grep -q "does not compile" && [ ! -e "$W/cgi/tools/marc_replace.pl" ] && [ "$(pre_backups)" = "0" ]' "$(dialogs | tail -2)"
}

# --- marc_replace.pl: AI cataloguing ------------------------------------------------

VD=/var/lib/koha/library/kei-marc-replace
# The page and its two modules (in $W/lib, as the site Perl folder), the PHA
# table of the cataloguing aids and a vision model on the HTTP double.
vision_setup() {
    mr_setup
    mkdir -p "$W/lib/KohaEasy/Cataloguing" /etc/koha-easy-install/tables
    "$KEI_SH" "$PANEL" mr_pm_vision > "$W/lib/KohaEasy/Cataloguing/Vision.pm"
    "$KEI_SH" "$PANEL" mr_pm_rules > "$W/lib/KohaEasy/Cataloguing/Rules.pm"
    pha_rows > "$W/pha.txt"
    panel cat_table_import pha "$W/pha.txt" /etc/koha-easy-install/tables/pha.tsv
    kei_http_mock_start
    printf 'provider=compatible\nurl=http://127.0.0.1:18080/v1\nmodel=vision-test\ntoken=sk-local-123\norg_code=BR-XxBIB\n' > "$VD/vision.conf"
    perl -MGD -e '$i = GD::Image->new(2400, 1600, 1); $i->filledRectangle(0, 0, 2399, 1599, $i->colorAllocate(200, 50, 50)); open F, ">", shift; binmode F; print F $i->jpeg(80)' "$W/titlepage.jpg"
    cat > "$KEI_S/vision-reply.txt" <<'JSON'
Here is the record:
```json
{"title": "Dom Casmurro", "subtitle": "romance", "responsibility": "Machado de Assis ; ilustrações de <b>Ana</b> Silva",
 "authors": [{"name": "Machado de Assis", "role": "author"}, {"name": "Ana Silva", "role": "illustrator"}],
 "corporate": null, "edition": "2. ed", "place": "São Paulo", "publisher": "Ática", "year": "1997",
 "isbn": ["978-85-359-0277-8", "85-08-00000-1"], "pages": "256", "series": "N/A", "language": "por",
 "subjects": ["Romance brasileiro"], "cip": {"present": true, "ddc": "869.3", "subjects": ["1. Ficção brasileira. I. Título."], "cutter": "A848d"},
 "ddc": "B869.35", "notes": "<script>alert(1)</script>"}
```
JSON
}
vcgi() { run env PERL5LIB="$KEI_REPO/tests/mocks/perl5:$W/lib" "$KEI_REPO/tests/lib/cgi-run" "$W/marc_replace.pl" "$@"; }
draft_text() { python3 -c 'import html, re, sys; print(html.unescape(re.search(r"<textarea[^>]*>(.*?)</textarea>", sys.stdin.read(), re.S).group(1)), end="")' <<< "$output"; }
# Photos -> draft -> preview; leaves the preview in $output.
vision_preview() {
    vcgi POST op=cud-vision csrf_token=tok-SESSID1 "img_title=@$W/titlepage.jpg" itemtype=LIVRO frameworkcode=FA
    local text ext
    text=$(draft_text)$'\n952 __ |a CPL |p 123'; ext=$(field extraction)
    vcgi POST op=cud-vision-preview csrf_token=tok-SESSID1 "marctext=$text" itemtype=LIVRO frameworkcode=FA "extraction=$ext"
}

@test "V01 AI cataloguing tab: CSRF form for the photos, frameworks and item types of Koha escaped; without the modules or the settings it says so" {
    vision_setup
    vcgi GET op=vision
    assert '[ "$(field csrf_token)" = "tok-SESSID1" ] && [ "$(field op)" = "cud-vision" ]' "$output"
    assert 'grep -q "name=\"img_cover\"" <<< "$output" && grep -q "name=\"img_title\"" <<< "$output" && grep -q "name=\"img_verso\"" <<< "$output"'
    assert 'grep -q "Seriados &lt;i&gt; (SER)" <<< "$output" && grep -q "Revista &lt;b&gt; (REV)" <<< "$output"' "frameworks and item types escaped"
    assert 'grep -q "class=\"on\">AI cataloguing" <<< "$output" && ! grep -q "not configured yet" <<< "$output"'
    rm -f "$VD/vision.conf"
    vcgi GET op=vision
    assert 'grep -q "The AI model is not configured yet" <<< "$output"'
    cgi GET op=vision
    assert 'grep -q "The AI cataloguing modules are not installed" <<< "$output" && ! grep -q "img_cover" <<< "$output"' "page without the modules"
    cgi GET biblionumber=7
    assert '[ "$(field op)" = "cud-preview" ] && grep -q "Replace a record" <<< "$output"' "the replacement is unchanged"
}

@test "V02 photos to the model: JSON read, national rules applied (PHA notation, CDD of the CIP, AACR2), draft escaped, nothing saved" {
    vision_setup
    vcgi POST op=cud-vision csrf_token=tok-SESSID1 "img_title=@$W/titlepage.jpg" itemtype=LIVRO frameworkcode=FA
    local req; req=$(grep chat/completions "$KEI_S/http.log")
    assert 'grep -q "\"authorization\": \"Bearer sk-local-123\"" <<< "$req" && grep -q "\"model\": \"vision-test\"" <<< "$req" && grep -q "photo 1 = title page" <<< "$req"' "$req"
    local text; text=$(draft_text)
    assert 'grep -qx "100 1_ |a Assis, Machado de." <<< "$text"' "name inverted: $text"
    assert 'grep -qx "245 10 |a Dom Casmurro :|b romance /|c Machado de Assis ; ilustrações de <b>Ana</b> Silva." <<< "$text"' "ISBD punctuation"
    assert 'grep -qx "260 __ |a São Paulo :|b Ática,|c 1997." <<< "$text" && grep -qx "250 __ |a 2. ed." <<< "$text" && grep -qx "300 __ |a 256 p." <<< "$text"'
    assert 'grep -qx "082 04 |a 869.3|2 23" <<< "$text" && grep -qx "090 __ |a 869.3|b A176d" <<< "$text"' "CDD of the CIP, PHA notation of the table (the panel gives $(panel cat_notation pha "Assis, Machado de" "Dom Casmurro"; cut -f1 <<< "$output"))"
    assert 'grep -qx "020 __ |a 9788535902778" <<< "$text" && grep -qx "020 __ |z 8508000001" <<< "$text"' "valid ISBN in a, wrong check digit in z"
    assert 'grep -qx "650 _4 |a Ficção brasileira." <<< "$text" && grep -qx "700 1_ |a Silva, Ana,|e il." <<< "$text" && grep -qx "040 __ |a BR-XxBIB|b por|c BR-XxBIB" <<< "$text"'
    assert '! grep -q "^490" <<< "$text"' "placeholders such as N/A are dropped"
    assert '! grep -q "<script>" <<< "$output" && ! grep -q "<b>Ana" <<< "$output" && grep -q "&lt;script&gt;" <<< "$output"' "model text escaped"
    assert 'grep -q "from the CIP block of the book" <<< "$output" && grep -q "wrong check digit" <<< "$output" && grep -q "<img src=\"data:image/jpeg;base64," <<< "$output"'
    assert '[ "$(field op)" = "cud-vision-preview" ] && [ "$(field frameworkcode)" = "FA" ] && [ -n "$(field extraction)" ]'
    assert '! grep -q "AddBiblio\|ModBiblio" "$KS/calls.log" && [ ! -e "$VD/vision" ]' "nothing saved by the draft"
    printf 'not a photo' > "$W/bad.jpg"
    vcgi POST op=cud-vision csrf_token=tok-SESSID1 "img_cover=@$W/bad.jpg"
    assert 'grep -q "Photos must be JPEG, PNG or WebP" <<< "$output"'
    vcgi POST op=cud-vision csrf_token=tok-SESSID1
    assert 'grep -q "Choose at least one photo" <<< "$output"'
    touch "$KEI_S/vision-fail"
    vcgi POST op=cud-vision csrf_token=tok-SESSID1 "img_title=@$W/titlepage.jpg"
    assert 'grep -q "The AI model could not be used: the server refused the request: HTTP 500: model crashed" <<< "$output"' "$output"
    rm -f "$KEI_S/vision-fail"; printf 'Sorry, I cannot read it.' > "$KEI_S/vision-reply.txt"
    vcgi POST op=cud-vision csrf_token=tok-SESSID1 "img_title=@$W/titlepage.jpg"
    assert 'grep -q "was not the expected data: Sorry, I cannot read it." <<< "$output"'
}

@test "V03 mandatory preview, then one atomic insertion: lock, ISBN check, AddBiblio and the copy in one transaction; a second send adds nothing" {
    vision_setup
    vision_preview
    assert 'grep -q "Item fields found in the file and left out: 1" <<< "$output" && grep -q "942    _2ddc" <<< "$output" && grep -q "_cLIVRO" <<< "$output"' "$output"
    assert '[ "$(field op)" = "cud-vision-add" ] && [ -n "$(field record)" ] && [[ "$(field nonce)" =~ ^[0-9a-f]{40}$ ]] && ! grep -q allow_dup <<< "$output"'
    assert '! grep -q AddBiblio "$KS/calls.log"' "the preview adds nothing"
    local rec nonce ext
    rec=$(field record); nonce=$(field nonce); ext=$(field extraction)
    : > "$KS/calls.log"
    vcgi POST op=cud-vision-add csrf_token=tok-SESSID1 "record=$rec" frameworkcode=FA "nonce=$nonce" "extraction=$ext"
    assert 'grep -q "Record added. (8)" <<< "$output" && grep -q "additem.pl?biblionumber=8" <<< "$output"' "$output"
    assert '[ "$(tr "\n" "|" < "$KS/calls.log")" = "checkauth intranet editcatalogue=edit_catalogue|get-lock kei_marc_replace_vision|txn-begin|select-isbn 9788535902778|select-isbn 8508000001|AddBiblio 8 fw=FA tags=008,020,020,040,082,090,100,245,250,260,300,650,700,942|txn-commit|release-lock kei_marc_replace_vision|" ]' "$(cat "$KS/calls.log")"
    assert '! grep -q "tag=\"952\"" "$KS/biblio/8.xml" && grep -q "Dom Casmurro" "$KS/biblio/8.xml"'
    assert 'cmp -s "$KS/biblio/8.xml" $VD/vision/8-*.xml && grep -q "\"model\":\"vision-test\"" $VD/vision/8-*.json && [ "$(stat -c %a $VD/vision/8-*.xml)" = "640" ]' "copy of the record and of the model's answer"
    assert '! grep -rq "sk-local-123" $VD/vision' "the token is not in the copies"
    vcgi POST op=cud-vision-add csrf_token=tok-SESSID1 "record=$rec" frameworkcode=FA "nonce=$nonce" "extraction=$ext"
    assert 'grep -q "This form was already sent" <<< "$output" && [ ! -e "$KS/biblio/9.xml" ] && [ "$(grep -c AddBiblio "$KS/calls.log")" = "1" ]' "$output"
}

@test "V04 refused without any write: wrong token, same ISBN already in the catalogue, lock busy, AddBiblio failing" {
    vision_setup
    vision_preview
    local rec; rec=$(field record)
    vcgi POST op=cud-vision-add csrf_token=tok-OTHER "record=$rec" "nonce=$(field nonce)"
    assert 'grep -q "Invalid or expired security token" <<< "$output" && [ ! -e "$KS/biblio/8.xml" ]'
    touch "$KS/lock.busy"
    vcgi POST op=cud-vision-add csrf_token=tok-SESSID1 "record=$rec" "nonce=$(printf a%.0s {1..40})"
    assert 'grep -q "Another record is being added right now" <<< "$output" && ! grep -q txn-begin "$KS/calls.log"'
    rm -f "$KS/lock.busy"; touch "$KS/addbiblio.fail"
    vcgi POST op=cud-vision-add csrf_token=tok-SESSID1 "record=$rec" "nonce=$(printf b%.0s {1..40})"
    assert 'grep -q "Koha could not add the record" <<< "$output" && grep -q txn-rollback "$KS/calls.log" && [ -z "$(ls $VD/vision)" ]' "$output"
    rm -f "$KS/addbiblio.fail"
    vcgi POST op=cud-vision-add csrf_token=tok-SESSID1 "record=$rec" "nonce=$(printf c%.0s {1..40})"
    assert 'grep -q "Record added. (8)" <<< "$output"'
    vision_preview
    assert 'grep -q "Records with the same ISBN already in the catalogue" <<< "$output" && grep -q "detail.pl?biblionumber=8" <<< "$output" && grep -q "name=\"allow_dup\"" <<< "$output"' "$output"
    rec=$(field record)
    vcgi POST op=cud-vision-add csrf_token=tok-SESSID1 "record=$rec" "nonce=$(field nonce)"
    assert 'grep -q "A record with the same ISBN is already in the catalogue" <<< "$output" && [ ! -e "$KS/biblio/9.xml" ]'
    vcgi POST op=cud-vision-add csrf_token=tok-SESSID1 "record=$rec" "nonce=$(printf d%.0s {1..40})" allow_dup=1
    assert 'grep -q "Record added. (9)" <<< "$output"'
}

@test "V05 a biblionumber sends the draft to the replacement, with its own preview, lock and saved version" {
    vision_setup
    vcgi POST op=cud-vision csrf_token=tok-SESSID1 "img_title=@$W/titlepage.jpg" biblionumber=7
    assert '[ "$(field op)" = "cud-preview" ] && [ "$(field biblionumber)" = "7" ]' "$output"
    local text; text=$(draft_text)
    vcgi POST op=cud-preview csrf_token=tok-SESSID1 biblionumber=7 "marctext=$text"
    assert 'grep -q "Items of the record (kept as they are): 3" <<< "$output" && [ "$(field op)" = "cud-replace" ]' "$output"
    local asked; asked=$(grep -c chat/completions "$KEI_S/http.log")
    vcgi POST op=cud-vision csrf_token=tok-SESSID1 "img_title=@$W/titlepage.jpg" biblionumber=99
    assert 'grep -q "There is no record with this biblionumber" <<< "$output" && [ "$(grep -c chat/completions "$KEI_S/http.log")" = "$asked" ]' "the model is not asked"
}

@test "V06 AI settings: only with the system preferences permission; the token is never shown, kept, removed or refused over plain http" {
    vision_setup
    vcgi GET op=vision-settings
    assert 'grep -q "name=\"provider\"" <<< "$output" && grep -q "A token is saved" <<< "$output" && ! grep -q "sk-local-123" <<< "$output"' "$output"
    assert 'grep -qx "haspermission librarian parameters=manage_sysprefs" <(grep haspermission "$KS/calls.log" | tail -1)'
    vcgi POST op=cud-vision-settings csrf_token=tok-SESSID1 provider=compatible url=http://127.0.0.1:18080/v1 model=vision-test token= timeout=60 max_px=1200 lang=por table=pha ddc_edition=22 country=bl org_code=
    assert 'grep -q "Settings saved" <<< "$output" && grep -qx "token=sk-local-123" "$VD/vision.conf" && grep -qx "ddc_edition=22" "$VD/vision.conf" && [ "$(stat -c %a "$VD/vision.conf")" = "600" ]' "$output"
    vcgi POST op=cud-vision-test csrf_token=tok-SESSID1 provider=compatible url=http://127.0.0.1:18080/v1 model=vision-test token=
    assert 'grep -q "Connection OK: OK http://127.0.0.1:18080/v1/models (2 models); vision-test: found" <<< "$output"' "$output"
    vcgi POST op=cud-vision-settings csrf_token=tok-SESSID1 provider=openai url=http://ai.example.com/v1 model=x token=sk-new
    assert 'grep -q "cannot be sent without encryption" <<< "$output" && grep -qx "token=sk-local-123" "$VD/vision.conf"' "not saved"
    vcgi POST op=cud-vision-settings csrf_token=tok-SESSID1 provider=ollama url=http://127.0.0.1:18080 model=qwen2.5vl:7b token= token_clear=1
    assert 'grep -qx "token=" "$VD/vision.conf" && grep -qx "provider=ollama" "$VD/vision.conf"'
    vcgi POST op=cud-vision csrf_token=tok-SESSID1 "img_title=@$W/titlepage.jpg"
    assert 'grep -q "^{\"path\": \"/api/chat\", \"authorization\": null" <<< "$(tail -n1 "$KEI_S/http.log")" && grep -qx "100 1_ |a Assis, Machado de." <<< "$(draft_text)"' "local Ollama without a token"
    vcgi POST op=cud-vision-settings csrf_token=tok-OTHER provider=openai token=sk-evil
    assert 'grep -q "Invalid or expired security token" <<< "$output" && grep -qx "provider=ollama" "$VD/vision.conf"'
    touch "$KS/noconfig"
    vcgi GET op=vision-settings
    assert 'grep -q "Only staff allowed to change the system preferences" <<< "$output" && ! grep -q "name=\"provider\"" <<< "$output"'
    vcgi POST op=cud-vision-settings csrf_token=tok-SESSID1 provider=openai token=sk-evil
    assert 'grep -q "You are not allowed to change these settings" <<< "$output" && grep -qx "provider=ollama" "$VD/vision.conf"'
}

@test "V08 prompts: default MARC 21 instructions with an example record, customisable and restorable; the note for one book is sent once and never kept" {
    vision_setup
    vcgi GET op=vision-settings
    assert 'grep -q "all the rules of MARC 21" <<< "$output" && grep -q "245 10 |a Dom Casmurro / |c Machado de Assis." <<< "$output" && grep -q "name=\"instructions_default\"" <<< "$output"' "default instructions shown: $output"
    vcgi GET op=vision
    assert 'grep -q "<textarea id=\"note\" name=\"note\"[^>]*></textarea>" <<< "$output"' "empty note field"
    vcgi POST op=cud-vision csrf_token=tok-SESSID1 "img_title=@$W/titlepage.jpg" "note=Livro de <b>1897</b>, o ilustrador é o autor"
    local req; req=$(grep chat/completions "$KEI_S/http.log" | tail -n1)
    assert 'grep -q "all the rules of MARC 21" <<< "$req" && grep -q "Language of cataloguing: Portuguese" <<< "$req" && grep -q "650 _4 |a Romance brasileiro." <<< "$req"' "default instructions, language and example record: $req"
    assert 'grep -q "for this book only (they take precedence over the general ones above):\\\\nLivro de <b>1897</b>, o ilustrador é o autor" <<< "$req" && grep -q "ANSWER FORMAT. The images show one printed book" <<< "$req"' "note of the book, then the fixed format: $req"
    assert '! grep -q "1897" <<< "$output" && ! grep -rq "1897" "$VD"' "the note does not follow the draft and is not kept"
    local text; text=$(draft_text)
    vcgi POST op=cud-vision-preview csrf_token=tok-SESSID1 "marctext=$text" "extraction=$(field extraction)"
    vcgi POST op=cud-vision-add csrf_token=tok-SESSID1 "record=$(field record)" "nonce=$(field nonce)" "extraction=$(field extraction)"
    assert 'grep -q "Record added" <<< "$output" && ! grep -rq "1897" "$VD"' "$output"
    vcgi GET op=vision
    assert 'grep -q "<textarea id=\"note\" name=\"note\"[^>]*></textarea>" <<< "$output"' "the next book starts with an empty note"
    vcgi POST op=cud-vision csrf_token=tok-SESSID1
    assert 'grep -q "Choose at least one photo" <<< "$output" && grep -q "<textarea id=\"note\" name=\"note\"[^>]*></textarea>" <<< "$output"'
    vcgi POST op=cud-vision csrf_token=tok-SESSID1 "note=keep me <i>"
    assert 'grep -q ">keep me &lt;i&gt;</textarea>" <<< "$output"' "kept (escaped) when the photos are missing"
    vcgi POST op=cud-vision-settings csrf_token=tok-SESSID1 provider=compatible url=http://127.0.0.1:18080/v1 model=vision-test lang=spa \
        $'instructions=Catalogue for a school library in {language}.\nUse CDD 22 and <short> subjects.'
    assert 'grep -q "Settings saved" <<< "$output" && [ "$(stat -c %a "$VD/vision-prompt.txt")" = "640" ] && grep -q "school library in {language}" "$VD/vision-prompt.txt"' "$output"
    assert 'grep -q "&lt;short&gt; subjects.</textarea>" <<< "$output" && ! grep -q "<short>" <<< "$output"' "saved text shown back, escaped"
    vcgi POST op=cud-vision csrf_token=tok-SESSID1 "img_title=@$W/titlepage.jpg"
    req=$(grep chat/completions "$KEI_S/http.log" | tail -n1)
    assert 'grep -q "Catalogue for a school library in Spanish." <<< "$req" && ! grep -q "all the rules of MARC 21" <<< "$req" && ! grep -q "for this book only" <<< "$req" && grep -q "ANSWER FORMAT" <<< "$req"' "custom instructions, no note, fixed format kept: $req"
    vcgi POST op=cud-vision-settings csrf_token=tok-SESSID1 provider=compatible url=http://127.0.0.1:18080/v1 model=vision-test "instructions=anything" instructions_default=1
    assert '[ ! -e "$VD/vision-prompt.txt" ] && grep -q "all the rules of MARC 21" <<< "$output"' "default restored"
    touch "$KS/noconfig"
    vcgi POST op=cud-vision-settings csrf_token=tok-SESSID1 provider=compatible "instructions=evil"
    assert '[ ! -e "$VD/vision-prompt.txt" ]' "only with the permission"
}

@test "V07 the author notation of the page is the notation of the panel (same table, same rules)" {
    mkdir -p /etc/koha-easy-install/tables "$W/lib/KohaEasy/Cataloguing"
    "$KEI_SH" "$PANEL" mr_pm_rules > "$W/lib/KohaEasy/Cataloguing/Rules.pm"
    pha_rows > "$W/pha.txt"
    panel cat_table_import pha "$W/pha.txt" /etc/koha-easy-install/tables/pha.tsv
    local name title mode want got
    while IFS='|' read -r name title mode want; do
        got=$(perl -I "$W/lib" -MKohaEasy::Cataloguing::Rules -CA -e 'my $r = KohaEasy::Cataloguing::Rules::notation(@ARGV); print $r->{notation} // "error $r->{error}"' \
            /etc/koha-easy-install/tables/pha.tsv "$name" "$title" "" "${mode:-person}")
        assert '[ "$got" = "$want" ]' "$name / $title: got $got, want $want"
    done < <(notation_cases)
    got=$(perl -I "$W/lib" -MKohaEasy::Cataloguing::Rules -CSA -e 'print join "|", map { KohaEasy::Cataloguing::Rules::invert_name($_) } @ARGV' "Machado de Assis" "José de Andrade Filho" "Assis, Machado de" "Érico Veríssimo" "Platão")
    assert '[ "$got" = "Assis, Machado de|Andrade Filho, José de|Assis, Machado de|Veríssimo, Érico|Platão" ]' "$got"
}

# --- Opt-in ------------------------------------------------------------------------

@test "X01 opt-in: loading the panel installs nothing; the modules only act from their menus" {
    panel true
    assert '[ ! -e /usr/local/lib/site_perl/KohaEasy ] && [ ! -e /etc/cron.d/koha_messaging ] && [ ! -e /etc/koha-easy-install/tables ] && [ "$(pref SMSSendDriver)" = "Email" ]'
    local f callers
    for f in msg_install_files _lt_msg_notices_set _lt_msg_letters _lt_msg_phones_fix cat_table_import _lt_br_migrate_sheet_run _lt_mr_install _lt_mr_remove; do
        callers=$(grep -nE "(^|[^_a-z])${f}( |$|\))" "$KEI_REPO/installer" | grep -vE "^[0-9]+:${f}\(\) \{" | grep -vE "^[0-9]+:\s*#" | cut -d: -f1)
        assert '[ -n "$callers" ]' "$f is used"
        local l
        for l in $callers; do
            assert 'awk -v l="$l" "NR <= l && /^[a-z_]+\\(\\) \\{/ { fn = \$1 } NR == l { print fn }" "$KEI_REPO/installer" | grep -qE "^(lt_|_lt_|function_|msg_|cat_)"' "$f at line $l must be reached from a menu"
        done
    done
}
