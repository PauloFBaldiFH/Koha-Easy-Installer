#!/usr/bin/env bats
# Library tools 15: the Cutter Calculator. The library's Cutter-Sanborn table
# read in the layout of the three-figure table ("  127     Abbot, J.", a
# made-up sample: the real tables are copyrighted and never enter the
# repository), cutter_calculator.pl run as a CGI with the Koha doubles of
# tests/mocks/perl5 (the items of the collection in $KS/items.tsv, the
# records in $KS/biblio), and the panel: the calculator, the table loaded
# from the menu, the page and its buttons installed and removed.

setup() {
    load lib/common
    kei_reset_env
    kei_reset_live_catalog
    kei_tools_catalog
    kei_modules_catalog
    unset KEI_SELECT_FILE KEI_DEFAULT_ANSWER KEI_EXTRA KOHA_INTRA_CGI
    W="$BATS_TEST_TMPDIR"
    PM=/usr/local/lib/site_perl
    KS=/run/kei-mock/koha
    TABLE=/etc/koha-easy-install/tables/cutter.tsv
    rm -rf "$KS" "$PM/KohaEasy/Cataloguing" /etc/koha-easy-install/tables
    mkdir -p "$KS/biblio" "$W/lib/KohaEasy/Cataloguing"
    "$KEI_SH" "$PANEL" mr_pm_rules > "$W/lib/KohaEasy/Cataloguing/Rules.pm"
}

teardown() { kei_kill_daemons; }

pre_backups() { find /var/backups/koha_sql -maxdepth 1 -name "PRE-${1:-}*" 2>/dev/null | wc -l; }
extra()       { printf '%s\n' "$@" > "$W/extra.sh"; export KEI_EXTRA="$W/extra.sh"; }
userjs()      { mysql -N -B --raw -e "SELECT value FROM systempreferences WHERE variable = 'IntranetUserJS';" "$DB"; }

# A made-up table in the layout of the three-figure table: number, spaces,
# entry; the leading spaces vary, Windows line ends, initials after a comma.
cutter_rows() {
    printf '%s\r\n' "111     Aa" "  112     Ab" "  127     Abbot, J." "  128     Abbot, M" "  131     Abbott" \
        "  847     Ass" "  848     Assi" "  849     Ast" \
        "18     Ea" "  19     Ec" "  21     Ed" \
        "111     La" "  588     Lem" "  589     Lent" "  591     Leo" \
        "1     Qa" "  2     Qe" "  3     Qu"
}

load_table() {
    mkdir -p /etc/koha-easy-install/tables
    cutter_rows > "$W/cutter.txt"
    "$KEI_SH" "$PANEL" cat_table_import cutter "$W/cutter.txt" "$TABLE" > /dev/null
}

page() {
    "$KEI_SH" "$PANEL" cutter_page_script > "$W/cutter_calculator.pl"
    printf '%s\n' $'1\t869.3 A848d\tDom Casmurro\tAssis, Machado de' $'2\t869.3 A848m ex.2\tMemórias <b>póstumas</b>\tAlves, Outro' \
        $'3\tR 869.3 A847a\tAlguma coisa\tAstro, Ana' $'4\t869.3 A8481\tOutro livro\tAssim, Rui' > "$KS/items.tsv"
    cat > "$KS/biblio/7.xml" <<'XML'
<record><datafield tag="082" ind1="0" ind2="4"><subfield code="a">869.3</subfield></datafield><datafield tag="100" ind1="1" ind2=" "><subfield code="a">Eco, Umberto,</subfield></datafield><datafield tag="245" ind1="1" ind2="2"><subfield code="a">O nome da rosa &amp; outros /</subfield></datafield></record>
XML
}
cgi() { run env PERL5LIB="$KEI_REPO/tests/mocks/perl5:$W/lib" "$KEI_REPO/tests/lib/cgi-run" "$W/cutter_calculator.pl" GET "$@"; }
json() { cgi format=json "$@"; output=$(sed -n '/^{/,$p' <<< "$output"); }
jget() { perl -MJSON::PP -0 -e 'my $j = decode_json(<STDIN>); for my $k (split /\./, $ARGV[0]) { $j = ref $j eq "ARRAY" ? $j->[$k] : $j->{$k} } print ref $j eq "JSON::PP::Boolean" ? 0 + $j : ref $j ? "" : $j // ""' "$1" <<< "$output"; }

# --- the table and the notation -------------------------------------------------------

@test "K01 the three-figure table is read as printed: varying spaces, CRLF, initials after a comma" {
    mkdir -p /etc/koha-easy-install/tables
    cutter_rows > "$W/cutter.txt"
    panel cat_table_import cutter "$W/cutter.txt" "$TABLE"
    assert 'grep -q "^Entries: 18$" <<< "$output" && grep -q "^Lines not understood: 0$" <<< "$output" && grep -q "@@problems 0" <<< "$output"' "$output"
    assert 'grep -qP "^a\tabbot j\t127\tAbbot, J\.$" "$TABLE" && grep -qP "^a\tabbot m\t128\tAbbot, M$" "$TABLE" && grep -qP "^a\tabbott\t131\tAbbott$" "$TABLE"' "$(cat "$TABLE")"
    # The comma still separates the entry from the number when it is next to it.
    printf 'Sampaio M.,184\nRau,183\n' > "$W/pha.txt"
    panel cat_table_import pha "$W/pha.txt" "$W/pha.tsv"
    assert 'grep -qP "^s\tsampaio m\t184\tSampaio M\.$" "$W/pha.tsv" && grep -qP "^r\trau\t183\tRau$" "$W/pha.tsv"' "$(cat "$W/pha.tsv")"
    local c
    while IFS='|' read -r name title want; do
        panel cat_notation cutter "$name" "$title"
        assert '[ "$(cut -f1 <<< "$output")" = "$want" ]' "$name / $title: got $(cut -f1 <<< "$output"), want $want"
    done <<'EOF'
Assis, Machado de|Dom Casmurro|A848d
Abbot, John|The life|A127L
Abbot, Mary|Poems|A128p
Abbott, Ann|Poems|A131p
Eco, Umberto|O nome da rosa|E19n
Queiroz, Rachel de|O quinze|Q3q
Lentino, Noêmia|Classificação|L589c
EOF
}

# --- cutter_calculator.pl ------------------------------------------------------------

@test "K02 page: staff login, the notation as JSON, a name read as Surname, Forename, numbers used in the class" {
    load_table
    page
    json name="Machado de Assis" title="Dom Casmurro" class=869.3
    assert 'grep -qx "checkauth intranet catalogue=1" "$KS/calls.log"' "$(cat "$KS/calls.log")"
    assert '[ "$(jget notation)" = "A848d" ] && [ "$(jget read_as)" = "Assis, Machado de" ] && [ "$(jget entry)" = "Assi" ] && [ "$(jget call_number)" = "869.3 A848d" ]' "$output"
    assert '[ "$(jget used.0.call_number)" = "869.3 A848d" ] && [ "$(jget used.1.call_number)" = "869.3 A848m ex.2" ] && [ -z "$(jget used.2.call_number)" ]' "A8481 is another number: $output"
    assert '[ "$(jget alternatives.0.number)" = "A847" ] && [ "$(jget alternatives.0.free)" = "0" ] && [ "$(jget alternatives.1.number)" = "A849" ] && [ "$(jget alternatives.1.free)" = "1" ]' "R 869.3 A847a uses A847 in the class: $output"
    json name="Alves, Rui" title="Memórias" class=869.3 bn=2
    assert '[ "$(jget notation)" = "A131m" ] && [ -z "$(jget read_as)" ] && [ -z "$(jget alternatives)" ]' "$output"
    json name="Assis, M" title=Dom class=869.3 bn=2
    assert '[ "$(jget used.0.call_number)" = "869.3 A848d" ] && [ -z "$(jget used.1.call_number)" ]' "the record being edited is not a collision: $output"
    json name="Instituto Brasileiro" title="Anuário" mode=corporate
    assert '[ "$(jget error)" = "no_entry" ] && [ -z "$(jget notation)" ]' "no entry for the letter I in the sample: $output"
    json title="Quinze dias" mode=title
    assert '[ "$(jget notation)" = "Q3" ]' "anonymous work: first word of the title, no mark: $output"
    json name="123 Editora"
    assert '[ "$(jget error)" = "no_letter" ]' "$output"
}

@test "K03 page: the item editor reads the record, the form and the result are escaped, the field is kept" {
    load_table
    page
    json bn=7
    assert '[ "$(jget notation)" = "E19n" ] && [ "$(jget title)" = "O nome da rosa & outros" ] && [ "$(jget ind2)" = "2" ] && [ "$(jget class)" = "869.3" ]' "100, 245 with ind2 and 082 of the record: $output"
    cgi name="Assis, M" title=Dom class=869.3 target=tag_090_subfield_b_123
    assert 'grep -q "<div class=\"big\">A848d</div>" <<< "$output" && grep -q "class=\"apply\" data-n=\"A848d\" data-c=\"869.3\"" <<< "$output" && grep -q "\"target\":\"tag_090_subfield_b_123\"" <<< "$output"' "$output"
    assert 'grep -q "Memórias &lt;b&gt;póstumas&lt;/b&gt;" <<< "$output" && ! grep -q "<b>póstumas" <<< "$output"' "titles of the catalogue escaped"
    cgi "name=<script>alert(1)</script>" "title=\"><i>" "target=x\"><script>" format=part
    assert '! grep -q "<script>alert" <<< "$output" && ! grep -q "class=\"apply\"" <<< "$output"' "a bad target gives no Use button: $output"
    cgi "name=<script>alert(1)</script>" "title=\"><i>"
    assert 'grep -q "value=\"&lt;script&gt;alert(1)&lt;/script&gt;\"" <<< "$output" && grep -q "value=\"&quot;&gt;&lt;i&gt;\"" <<< "$output" && grep -q "Cutter-Sanborn table of the library: 18 entries" <<< "$output"' "$output"
    rm -f "$TABLE"
    cgi name="Assis, M"
    assert 'grep -q "The Cutter-Sanborn table has not been loaded yet" <<< "$output"' "$output"
}

# --- panel -------------------------------------------------------------------------

@test "K04 panel: the table is loaded from the menu and the calculator shows the numbers used in the class" {
    cutter_rows > "$W/minha-tabela.txt"
    export KEI_SELECT_FILE="$W/minha-tabela.txt"
    answer yes
    panel lt_cat_load cutter
    assert '[ "$(wc -l < "$TABLE")" = "18" ] && dialogs | grep -q "^OK .*18 entries"' "no menu of tables: $(dialogs | tail -3)"
    inputs "Lentino, Noêmia" "Classificação" "025.4"
    panel lt_cutter_calc
    local r="$KEI_S/textbox.last"
    assert 'grep -q "Cutter-Sanborn: L589c" "$r" && grep -q "025.4 L589o .*Lent, Carlos" "$r"' "$(cat "$r")"
    assert 'grep -q "L588  (free to use)" "$r"' "$(cat "$r")"
    rm -f "$TABLE"
    panel lt_cutter_calc
    assert 'dialogs | grep -q "Load the Cutter-Sanborn table of your library first"' "$(dialogs | tail -1)"
}

@test "K05 panel: the page is compiled, installed with the rules module and its buttons, updated in place and removed cleanly" {
    export KOHA_INTRA_CGI="$W/cgi"
    mkdir -p "$W/cgi/cataloguing" "$W/cgi/tools"
    answer yes
    panel lt_cutter_install
    local page="$W/cgi/cataloguing/cutter_calculator.pl"
    assert '[ "$(stat -c "%a %U" "$page")" = "755 root" ] && [ "$(stat -c "%a %U" "$PM/KohaEasy/Cataloguing/Rules.pm")" = "644 root" ]' "$(ls -l "$page" 2>&1) $(dialogs | tail -2)"
    assert 'grep -q "koha-shell library -c \"/usr/bin/perl\" \"-I\" \".*\" \"-c\" \".*cutter_calculator.pl\"" "$KEI_S/calls.log"' "compiled as the instance user first: $(calls)"
    assert 'grep -q "our \$TABLE = '"'"'/etc/koha-easy-install/tables/cutter.tsv'"'"'" "$page" && dialogs | grep -q "The page asks for the table until it is loaded"' "$(dialogs | tail -1)"
    local js; js=$(userjs)
    assert '[[ "$js" == "/* the library'"'"'s own code */"* ]] && [ "$(pre_backups CUTTER)" = "1" ]' "the library code is kept: $js"
    assert 'grep -qF "input[id^='"'"'tag_090_subfield_b'"'"']" <<< "$js" && grep -qF "input[id^='"'"'tag_952_subfield_o'"'"']" <<< "$js" && grep -q "fa fa-calculator" <<< "$js" && grep -q "next(\".kei-cdd\")" <<< "$js"' "$js"
    answer yes
    panel lt_cutter_install
    js=$(userjs)
    assert '[ "$(grep -c "cutter begin" <<< "$js")" = "1" ] && grep -q "^koha-plack --restart library" "$KEI_S/calls.log" && [ "$(pre_backups CUTTER)" = "1" ]' "the same block is not written again"
    # Replace a MARC record shares the rules module: it stays while that page is installed.
    touch "$W/cgi/tools/marc_replace.pl"
    answer yes
    panel lt_cutter_remove
    js=$(userjs)
    assert '[ ! -e "$page" ] && ! grep -q "cutter begin" <<< "$js" && [ -e "$PM/KohaEasy/Cataloguing/Rules.pm" ]' "$js"
    rm -f "$W/cgi/tools/marc_replace.pl"
    answer no
    panel lt_cutter_install
    answer yes
    panel lt_cutter_remove
    assert '[ ! -e "$page" ] && [ ! -e "$PM/KohaEasy/Cataloguing/Rules.pm" ]' "$(ls -R "$PM/KohaEasy" 2>&1)"
}

@test "K06 panel: a page that does not compile is never installed; the menu is Library tools 15" {
    export KOHA_INTRA_CGI="$W/cgi"
    mkdir -p "$W/cgi/cataloguing"
    extra 'cutter_page_script() { printf "use strict;\nthis is not perl(\n"; }'
    answer yes
    panel lt_cutter_install
    assert 'dialogs | grep -q "does not compile" && [ ! -e "$W/cgi/cataloguing/cutter_calculator.pl" ] && [ "$(pre_backups)" = "0" ]' "$(dialogs | tail -2)"
    local item='"15" "$(t "✂  Cutter Calculator")"'
    assert 'grep -qF "$item" "$KEI_REPO/installer" && grep -qF "15) function_cutter ;;" "$KEI_REPO/installer"'
}
