#!/usr/bin/env bats
# Brazil: localization & migration (Library tools > 10). Real yaz-marcdump,
# MARC::Record, xsltproc, MariaDB and Memcached; the Koha scripts are the
# test doubles of tests/mocks/koha-script and koha-mysql / koha-preferences
# of tests/mocks/koha-mock.

setup() {
    load lib/common
    kei_reset_env
    kei_reset_live_catalog
    kei_tools_catalog
    kei_br_catalog
    unset KEI_SELECT_FILE KEI_DEFAULT_ANSWER KEI_EXTRA
    W="$BATS_TEST_TMPDIR"
    rm -f /etc/koha-easy-install/ficha.state
}

teardown() {
    [ -n "${HOLD:-}" ] && kill "$HOLD" 2>/dev/null
    kei_kill_daemons
}

pre_backups() { find /var/backups/koha_sql -maxdepth 1 -name "PRE-${1:-}*" 2>/dev/null | wc -l; }
extra()       { printf '%s\n' "$@" > "$W/extra.sh"; export KEI_EXTRA="$W/extra.sh"; }
marc_dump()   { yaz-marcdump "$1" 2>/dev/null; }

# A Biblivre-like export: accession numbers (tombo) in 949 $a, call number
# in 090, Latin-1 text, leader/09 blank. Record 3 already has a 952.
biblivre_xml() {
    cat > "$W/biblivre.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<collection xmlns="http://www.loc.gov/MARC21/slim">
<record><leader>00000nam  2200000 a 4500</leader><controlfield tag="001">1</controlfield>
  <datafield tag="082" ind1="0" ind2="4"><subfield code="a">869.3</subfield></datafield>
  <datafield tag="090" ind1=" " ind2=" "><subfield code="a">869.3</subfield><subfield code="b">A848d</subfield></datafield>
  <datafield tag="100" ind1="1" ind2=" "><subfield code="a">Assis, Machado de,</subfield><subfield code="d">1839-1908.</subfield></datafield>
  <datafield tag="245" ind1="1" ind2="0"><subfield code="a">Dom Casmurro /</subfield><subfield code="c">Machado de Assis.</subfield></datafield>
  <datafield tag="260" ind1=" " ind2=" "><subfield code="a">São Paulo :</subfield><subfield code="b">Ática,</subfield><subfield code="c">1997.</subfield></datafield>
  <datafield tag="949" ind1=" " ind2=" "><subfield code="a">000123</subfield></datafield>
  <datafield tag="949" ind1=" " ind2=" "><subfield code="a">000124</subfield></datafield>
</record>
<record><leader>00000nam  2200000 a 4500</leader><controlfield tag="001">2</controlfield>
  <datafield tag="245" ind1="0" ind2="0"><subfield code="a">Iracema :</subfield><subfield code="b">lenda do Ceará /</subfield><subfield code="c">José de Alencar.</subfield></datafield>
  <datafield tag="949" ind1=" " ind2=" "><subfield code="b">sem tombo</subfield></datafield>
</record>
<record><leader>00000nam  2200000 a 4500</leader><controlfield tag="001">3</controlfield>
  <datafield tag="245" ind1="0" ind2="0"><subfield code="a">Já catalogado no Koha</subfield></datafield>
  <datafield tag="952" ind1=" " ind2=" "><subfield code="a">X</subfield><subfield code="p">999</subfield></datafield>
</record>
</collection>
XML
}

# --- 3. CPF and calendar (pure functions) ----------------------------------

@test "BR01 CPF modulo-11 validator: official check digits, formatting, identical digits" {
    local v
    for v in 529.982.247-25 52998224725 111.444.777-35 123.456.789-09 000.000.001-91 390.533.447-05; do
        panel cpf_valid "$v"
        assert '[ "$status" -eq 0 ]' "$v must be valid"
    done
    for v in 000.000.000-00 111.111.111-11 222.222.222-22 999.999.999-99 \
             529.982.247-24 529.982.247-15 123.456.789-00 \
             5299822472 529982247250 12345678 a29.982.247-25 "529 982 247 25" ""; do
        panel cpf_valid "$v"
        assert '[ "$status" -ne 0 ]' "'$v' must be refused"
    done
}

@test "BR02 movable holidays from Easter (Meeus/Jones/Butcher): Carnival, Good Friday, Corpus Christi" {
    local y
    for y in "2000 2000-04-23" "2008 2008-03-23" "2011 2011-04-24" "2019 2019-04-21" "2024 2024-03-31" "2025 2025-04-20" "2026 2026-04-05" "2038 2038-04-25"; do
        panel br_easter "${y% *}"
        assert '[ "$output" = "${y#* }" ]' "Easter ${y% *}: got $output"
    done
    panel br_holidays 2025
    assert 'echo "$output" | grep -qx "2025-03-03|Carnaval (segunda-feira)|P"' "$output"
    assert 'echo "$output" | grep -qx "2025-03-04|Carnaval (terça-feira)|P"'
    assert 'echo "$output" | grep -qx "2025-04-18|Sexta-feira Santa|N"'
    assert 'echo "$output" | grep -qx "2025-06-19|Corpus Christi|P"'
    assert '[ "$(echo "$output" | grep -c "|N$")" = "10" ] && [ "$(echo "$output" | wc -l)" = "13" ]' "10 national + 3 optional in 2025"
    assert '[ "$(echo "$output" | cut -d"|" -f1)" = "$(echo "$output" | cut -d"|" -f1 | sort)" ]' "sorted by date"
    panel br_holidays 2024
    assert 'echo "$output" | grep -q "^2024-02-13|Carnaval (terça-feira)" && echo "$output" | grep -q "^2024-03-29|Sexta-feira Santa" && echo "$output" | grep -q "^2024-05-30|Corpus Christi"' "$output"
    panel br_holidays 2023
    assert '! echo "$output" | grep -q "Consciência Negra"' "national only from 2024 (Lei 14.759/2023)"
}

# --- 1. Legacy migration -------------------------------------------------------

@test "BR03 Biblivre: Latin-1 export becomes UTF-8, 949 tombo goes to 952, then Koha's staged import" {
    biblivre_xml
    kei_marc "$W/acervo.mrc" ISO-8859-1 "$W/biblivre.xml"
    assert '! iconv -f UTF-8 -t UTF-8 "$W/acervo.mrc" >/dev/null 2>&1' "the fixture must be Latin-1"
    export KEI_SELECT_FILE="$W/acervo.mrc"
    inputs "biblivre" "ISO-8859-1" "CPL" "LIVRO" "new"
    answer yes yes      # convert, then import
    panel lt_br_migrate_marc
    assert '[ "$status" -eq 0 ]' "$output"
    local f="$KEI_S/last-staged.mrc"
    assert '[ -s "$f" ] && iconv -f UTF-8 -t UTF-8 "$f" >/dev/null' "the staged file must be UTF-8"
    assert '[ "$(head -c 10 "$f" | tail -c 1)" = "a" ]' "leader/09 must say Unicode"
    assert 'marc_dump "$f" | grep -q "São Paulo : \$b Ática"' "accents kept: $(marc_dump "$f" | grep ^260)"
    assert 'marc_dump "$f" | grep -qx "952    \$a CPL \$b CPL \$y LIVRO \$o 869.3 A848d \$p 000123"' "$(marc_dump "$f" | grep ^952)"
    assert 'marc_dump "$f" | grep -qx "952    \$a CPL \$b CPL \$y LIVRO \$o 869.3 A848d \$p 000124"'
    assert '[ "$(marc_dump "$f" | grep -n "000123" | cut -d: -f1)" -lt "$(marc_dump "$f" | grep -n "000124" | cut -d: -f1)" ]' "items keep their order"
    assert '! marc_dump "$f" | grep -q "^949"' "legacy item fields removed once moved"
    assert 'marc_dump "$f" | grep -qx "952    \$a X \$p 999"' "an existing 952 is left alone"
    assert 'grep -q "koha-shell library -c \"/usr/bin/perl\" \".*remap952.pl\".*--dry-run" "$KEI_S/calls.log"' "the preview runs MARC::Record through koha-shell: $(calls)"
    assert 'grep -q "^stage_file.pl .*--format ISO2709 --encoding UTF-8 .*\[pre=0\]" "$KEI_S/calls.log"' "$(calls)"
    assert 'grep -q "^commit_file.pl --batch-number 1 \[pre=1\]" "$KEI_S/calls.log"' "import only after the PRE-IMPORT backup"
    assert 'grep -q "Items without barcode: 1" "$KEI_S/textboxes.log"' "the preview reports items without barcode"
    assert '[ "$(tools_sql "SELECT COUNT(*) FROM biblio;")" = "203" ]'
    assert '[ -z "$(ls -A /tmp/koha_tools.* 2>/dev/null)" ]' "converted files are removed"
}

@test "BR04 migration declined after the preview: no staging, nothing imported" {
    biblivre_xml
    kei_marc "$W/acervo.mrc" UTF-8 "$W/biblivre.xml"
    export KEI_SELECT_FILE="$W/acervo.mrc"
    inputs "biblivre" "UTF-8" "CPL" "LIVRO" "keep"
    answer no
    panel lt_br_migrate_marc
    assert 'grep -q "remap952.pl.*--dry-run" "$KEI_S/calls.log"'
    assert '! grep -q "remap952.pl.*--out" "$KEI_S/calls.log" && ! grep -q "^stage_file.pl" "$KEI_S/calls.log"' "$(calls)"
    assert '[ "$(pre_backups)" = "0" ] && [ "$(tools_sql "SELECT COUNT(*) FROM biblio;")" = "200" ]'
}

@test "BR05 SophiA, Pergamum and custom maps move their item fields to 952" {
    cat > "$W/vendors.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<collection xmlns="http://www.loc.gov/MARC21/slim">
<record><leader>00000nam  2200000 a 4500</leader>
  <datafield tag="245" ind1="0" ind2="0"><subfield code="a">Vidas secas</subfield></datafield>
  <datafield tag="852" ind1=" " ind2=" "><subfield code="h">869.3</subfield><subfield code="i">R194v</subfield><subfield code="p">P-001</subfield><subfield code="t">2</subfield></datafield>
  <datafield tag="990" ind1=" " ind2=" "><subfield code="a">S-001</subfield><subfield code="b">B869.3 R194</subfield></datafield>
  <datafield tag="949" ind1=" " ind2=" "><subfield code="c">C-001</subfield><subfield code="d">869.3</subfield><subfield code="e">R194v</subfield></datafield>
</record>
</collection>
XML
    kei_marc "$W/v.mrc" UTF-8 "$W/vendors.xml"
    local p
    for p in "pergamum|\$o 869.3 R194v \$p P-001 \$t 2" "sophia|\$o B869.3 R194 \$p S-001" "949 p=c,o=d+e|\$o 869.3 R194v \$p C-001"; do
        panel eval "br_preset '${p%%|*}' || exit 9; br_write_remapper '$W/r.pl'; perl '$W/r.pl' --in '$W/v.mrc' --out '$W/o.mrc' --item-tag \"\$BR_ITEM_TAG\" --map \"\$BR_MAP\" --callnumber \"\$BR_CN\" --branch MPL --itype REV >/dev/null && yaz-marcdump '$W/o.mrc'"
        assert '[ "$status" -eq 0 ]' "${p%%|*}: $output"
        assert 'echo "$output" | grep -qF "952    \$a MPL \$b MPL \$y REV ${p#*|}"' "${p%%|*}: $output"
    done
    panel br_preset "952 p=a"
    assert '[ "$status" -ne 0 ]' "952 itself cannot be the source"
    panel br_preset "949 p=a;rm"
    assert '[ "$status" -ne 0 ]' "malformed maps are refused"
}

@test "BR06 missing yaz-marcdump: offered install, and nothing happens without it" {
    biblivre_xml
    kei_marc "$W/acervo.mrc" UTF-8 "$W/biblivre.xml"
    export KEI_SELECT_FILE="$W/acervo.mrc"
    extra 'YAZ_MARCDUMP=/nonexistent/yaz-marcdump'
    inputs "biblivre" "UTF-8" "CPL" "LIVRO" "new"
    answer yes
    panel lt_br_migrate_marc
    assert 'grep -q "^apt_install yaz" "$KEI_S/calls.log"' "the yaz package must be offered: $(calls)"
    assert 'dialogs | grep -q "could not be installed"'
    assert '! grep -q "remap952\|stage_file" "$KEI_S/calls.log"'
    : > "$KEI_S/calls.log"
    inputs "biblivre" "UTF-8" "CPL" "LIVRO" "new"
    answer no
    panel lt_br_migrate_marc
    assert '! grep -q "apt_install\|remap952\|stage_file" "$KEI_S/calls.log" 2>/dev/null' "refusing the install stops here"
}

# Windows-1252 spreadsheet with Portuguese headers, semicolons, quoted
# fields, formatted CPFs, one invalid and one duplicate CPF, one line
# without a name.
legacy_csv() {
    printf 'Nome;CPF;E-mail;Data de Nascimento;Sexo;Cidade\r\n"Ana Maria Souza";529.982.247-25;ana@x.br;05/03/2001;Feminino;S\xe3o Paulo\r\nJo\xe3o Lima;111.444.777-35;;12/12/1999;M;"Palotina; PR"\r\nPedro Errado;123.456.789-00;;;;\r\nAna Dup;52998224725;;;;\r\n;390.533.447-05;;;;\r\n' > "$W/leitores.csv"
}

@test "BR07 legacy patrons: Windows-1252 spreadsheet converted, CPFs checked, then Koha's dry run" {
    legacy_csv
    export KEI_SELECT_FILE="$W/leitores.csv"
    inputs "CPL" "PT"
    answer yes no yes    # convert; do not update existing; import
    panel lt_br_patrons
    assert '[ "$status" -eq 0 ]' "$output"
    assert 'grep -q "Patrons ready: 2" "$KEI_S/textboxes.log" && grep -q "Rejected: 3" "$KEI_S/textboxes.log"' "$(cat "$KEI_S/textboxes.log")"
    assert 'grep -q "line 4: invalid CPF 123.456.789-00" "$KEI_S/textboxes.log"'
    assert 'grep -q "line 5: duplicate CPF (line 2)" "$KEI_S/textboxes.log" && grep -q "line 6: no name" "$KEI_S/textboxes.log"'
    assert 'grep -q "the CPF is used as the card number" "$KEI_S/textboxes.log"'
    assert 'grep -q "^import_patrons.pl .*--matchpoint cardnumber --default branchcode=CPL --default categorycode=PT -v -v \[pre=0\]" "$KEI_S/calls.log"' "$(calls)"
    assert 'grep -q "^import_patrons.pl .*--confirm \[pre=1\]" "$KEI_S/calls.log"'
    assert '[ "$(tools_sql "SELECT CONCAT(firstname, \"|\", surname) FROM borrowers WHERE cardnumber = \"52998224725\";")" = "Ana|Maria Souza" ]'
    assert '[ "$(tools_sql "SELECT surname FROM borrowers WHERE cardnumber = \"11144477735\";")" = "Lima" ]'
    assert '[ "$(tools_sql "SELECT COUNT(*) FROM borrowers WHERE cardnumber = \"12345678900\";")" = "0" ]' "invalid CPFs are not imported"
}

@test "BR08 legacy patrons with a card number column and CPF attribute, under mawk too" {
    printf 'MATRÍCULA,Nome Completo,Endereço,Nº CPF,Validade\n2024001,Bia Rocha,"Rua A, 10",390.533.447-05,31/12/2026\n2024002,Caio Reis,,123.456.789-00,\n' > "$W/alunos.csv"
    tools_sql "INSERT INTO borrower_attribute_types VALUES ('CPF', 'CPF');"
    local awk_impl
    for awk_impl in default mawk; do
        if [ "$awk_impl" = "mawk" ]; then command -v mawk >/dev/null || continue; extra 'awk() { mawk "$@"; }'; fi
        rm -f "$KEI_S/textboxes.log"
        export KEI_SELECT_FILE="$W/alunos.csv"
        answer no
        panel lt_br_patrons
        assert 'grep -qE "MATRÍCULA +-> cardnumber" "$KEI_S/textboxes.log" && grep -qE "Nº CPF +-> cpf" "$KEI_S/textboxes.log"' "$awk_impl: $(cat "$KEI_S/textboxes.log")"
        assert 'grep -q "Patrons ready: 1" "$KEI_S/textboxes.log" && grep -q "invalid CPF 123.456.789-00" "$KEI_S/textboxes.log"' "$awk_impl"
        assert '! grep -q "not stored" "$KEI_S/textboxes.log"' "the CPF goes to the CPF attribute"
        unset KEI_EXTRA
    done
    # Converted file handed to Koha: card number from MATRÍCULA, CPF attribute, ISO dates.
    inputs "CPL" "ST"; answer yes no yes
    panel lt_br_patrons
    assert 'grep -q "^import_patrons.pl .*--confirm \[pre=1\]" "$KEI_S/calls.log"'
    assert '[ "$(tools_sql "SELECT surname FROM borrowers WHERE cardnumber = \"2024001\";")" = "Rocha" ]'
}

@test "BR09 CPF report is read-only: invalid, shared and non-CPF values" {
    inputs "sort1"
    panel lt_br_cpf_audit
    local r="$KEI_S/textbox.last"
    assert 'grep -q "Invalid CPF: 123.456.789-00" "$r" && grep -q "Invalid CPF: 5299822472" "$r"' "$(cat "$r")"
    assert 'grep -q "CPF shared by two patrons: 52998224725" "$r"'
    assert 'grep -q "Checked: 4   valid: 2   invalid: 2   shared: 1   other values (not a CPF): 1" "$r"' "$(cat "$r")"
    assert '[ "$(pre_backups)" = "0" ] && ! grep -q "koha-mysql" "$KEI_S/calls.log" 2>/dev/null' "read-only"
}

# --- 2. Printing and cataloguing --------------------------------------------------

@test "BR10 Pimaco templates: chosen sheets and layouts through koha-mysql, idempotent, removable" {
    inputs "1" "6180 6287"
    answer yes
    panel lt_br_labels
    assert '[ "$status" -eq 0 ]' "$output"
    assert 'grep -q "^koha-mysql library" "$KEI_S/calls.log"' "SQL runs with Koha's account: $(calls)"
    assert '[ "$(pre_backups LABELS)" = "1" ]'
    assert '[ "$(tools_sql "SELECT CONCAT_WS(\"|\", label_width, label_height, cols, \`rows\`, units, page_width) FROM creator_templates WHERE template_code = \"KEI-PIMACO-6180\";")" = "66.68|25.4|3|10|MM|215.9" ]' "$(tools_sql "SELECT * FROM creator_templates")"
    assert '[ "$(tools_sql "SELECT CONCAT_WS(\"|\", label_width, label_height, cols, \`rows\`) FROM creator_templates WHERE template_code = \"KEI-PIMACO-6287\";")" = "44.45|12.7|4|20" ]'
    assert '[ "$(tools_sql "SELECT COUNT(*) FROM creator_templates WHERE template_code LIKE \"KEI-PIMACO-%\";")" = "2" ]' "only the chosen sheets"
    assert '[ "$(tools_sql "SELECT GROUP_CONCAT(layout_name ORDER BY layout_name) FROM creator_layouts WHERE layout_name LIKE \"KEI %\";")" = "KEI Codigo de barras,KEI Lombada,KEI Titulo e codigo" ]'
    inputs "1" "6180 6287 A4256"
    answer yes
    panel lt_br_labels
    assert '[ "$(tools_sql "SELECT COUNT(*) FROM creator_templates WHERE template_code LIKE \"KEI-PIMACO-%\";")" = "3" ] && [ "$(tools_sql "SELECT COUNT(*) FROM creator_layouts WHERE layout_name LIKE \"KEI %\";")" = "3" ]' "no duplicates on a second run"
    inputs "2"; answer yes
    panel lt_br_labels
    assert '[ "$(tools_sql "SELECT GROUP_CONCAT(template_code) FROM creator_templates;")" = "MINHA" ] && [ "$(tools_sql "SELECT GROUP_CONCAT(layout_name) FROM creator_layouts;")" = "Meu layout" ]' "only the panel's templates are removed"
}

@test "BR11 label templates are refused while a backup holds the lock, and need the safety backup" {
    flock -o /var/lock/koha_backup.lock sleep 30 3>&- &
    HOLD=$!; sleep 0.5
    inputs "1" "6180"
    panel lt_br_labels
    kill "$HOLD"; HOLD=""; sleep 0.3
    assert 'dialogs | grep -q "already running" && ! grep -q "koha-mysql" "$KEI_S/calls.log" 2>/dev/null'
    rm -rf /var/backups/koha_sql; mkdir -p /var/backups; : > /var/backups/koha_sql
    inputs "1" "6180"; answer yes
    panel lt_br_labels
    rm -f /var/backups/koha_sql
    assert 'dialogs | grep -q "Safety backup failed" && ! grep -q "koha-mysql" "$KEI_S/calls.log"'
    assert '[ "$(tools_sql "SELECT COUNT(*) FROM creator_templates;")" = "1" ]'
}

# Stub default detail stylesheets (Koha's real ones are checked with
# xsltproc when the card changes; see tests/README.md).
ficha_env() {
    local d
    for d in opac/en opac/pt-BR intra/en; do mkdir -p "$W/tmpl/$d/xslt"; done
    for d in opac/en opac/pt-BR; do
        printf '<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform" xmlns:marc="http://www.loc.gov/MARC21/slim"><xsl:output method="html"/><xsl:template match="/"><xsl:apply-templates/></xsl:template><xsl:template match="marc:record"><div id="default-%s">DEFAULT VIEW</div></xsl:template></xsl:stylesheet>\n' "${d##*/}" > "$W/tmpl/$d/xslt/MARC21slim2OPACDetail.xsl"
    done
    cp "$W/tmpl/opac/en/xslt/MARC21slim2OPACDetail.xsl" "$W/tmpl/intra/en/xslt/MARC21slim2intranetDetail.xsl"
    extra "KOHA_OPAC_TMPL='$W/tmpl/opac'" "KOHA_INTRA_TMPL='$W/tmpl/intra'" "FICHA_DIR='$W/ficha'"
}

@test "BR12 catalogue card: stylesheets per language, preferences set through koha-preferences, then restored" {
    ficha_env
    inputs "on"; answer yes
    panel lt_br_ficha
    assert '[ "$status" -eq 0 ]' "$output"
    assert '[ -f "$W/ficha/en/opac-detail.xsl" ] && [ -f "$W/ficha/pt-BR/opac-detail.xsl" ] && [ -f "$W/ficha/pt-BR/staff-detail.xsl" ]' "$(ls -R "$W/ficha" 2>&1)"
    assert 'grep -q "href=\"$W/tmpl/opac/pt-BR/xslt/MARC21slim2OPACDetail.xsl\"" "$W/ficha/pt-BR/opac-detail.xsl"' "the OPAC card imports the view of its own language"
    assert 'grep -q "href=\"$W/tmpl/intra/en/xslt/MARC21slim2intranetDetail.xsl\"" "$W/ficha/pt-BR/staff-detail.xsl"' "a language missing on one side falls back to English"
    assert 'grep -q "^koha-preferences set OPACXSLTDetailsDisplay $W/ficha/{langcode}/opac-detail.xsl" "$KEI_S/calls.log"' "$(calls)"
    assert '[ "$(tools_sql "SELECT value FROM systempreferences WHERE variable = \"XSLTDetailsDisplay\";")" = "$W/ficha/{langcode}/staff-detail.xsl" ]'
    assert 'grep -qx "OPACXSLTDetailsDisplay=default" /etc/koha-easy-install/ficha.state && grep -qx "XSLTDetailsDisplay=default" /etc/koha-easy-install/ficha.state'
    assert '[ "$(pre_backups FICHA)" = "1" ]'
    # The card itself (AACR2 layout) below the default view.
    biblio_xml='<record xmlns="http://www.loc.gov/MARC21/slim"><leader>00000nam a2200000 a 4500</leader>
      <datafield tag="020" ind1=" " ind2=" "><subfield code="a">8508040350</subfield></datafield>
      <datafield tag="082" ind1="0" ind2="4"><subfield code="a">869.3</subfield></datafield>
      <datafield tag="090" ind1=" " ind2=" "><subfield code="a">869.3</subfield><subfield code="b">A848d</subfield></datafield>
      <datafield tag="100" ind1="1" ind2=" "><subfield code="a">Assis, Machado de,</subfield><subfield code="d">1839-1908</subfield></datafield>
      <datafield tag="245" ind1="1" ind2="0"><subfield code="a">Dom Casmurro /</subfield><subfield code="c">Machado de Assis.</subfield></datafield>
      <datafield tag="250" ind1=" " ind2=" "><subfield code="a">3. ed.</subfield></datafield>
      <datafield tag="260" ind1=" " ind2=" "><subfield code="a">São Paulo :</subfield><subfield code="b">Ática,</subfield><subfield code="c">1997.</subfield></datafield>
      <datafield tag="300" ind1=" " ind2=" "><subfield code="a">208 p. ;</subfield><subfield code="c">21 cm.</subfield></datafield>
      <datafield tag="490" ind1="0" ind2=" "><subfield code="a">Bom livro ;</subfield><subfield code="v">12</subfield></datafield>
      <datafield tag="650" ind1=" " ind2="4"><subfield code="a">Romance brasileiro</subfield><subfield code="y">Século XIX.</subfield></datafield>
      <datafield tag="700" ind1="1" ind2=" "><subfield code="a">Silva, João,</subfield><subfield code="e">org.</subfield></datafield>
    </record>'
    printf '%s\n' "$biblio_xml" > "$W/rec.xml"
    run xsltproc "$W/ficha/pt-BR/opac-detail.xsl" "$W/rec.xml"
    assert '[ "$status" -eq 0 ] && echo "$output" | grep -q "default-pt-BR"' "Koha's view comes first: $output"
    local card
    card=$(echo "$output" | sed -n '/class="kei-ficha"/,/kei-ficha-print/p' | sed 's/<[^>]*>/\n/g; s/^ *//' | grep -v '^$')
    assert 'echo "$card" | grep -qx "869.3" && echo "$card" | grep -qx "A848d"' "call number column: $card"
    assert 'echo "$card" | grep -qx "Assis, Machado de, 1839-1908."' "$card"
    assert 'echo "$card" | grep -qx "Dom Casmurro / Machado de Assis. – 3. ed. – São Paulo : Ática, 1997."' "$card"
    assert 'echo "$card" | grep -qx "208 p. ; 21 cm. – (Bom livro ; 12)"' "$card"
    assert 'echo "$card" | grep -qx "ISBN 8508040350"'
    assert 'echo "$card" | grep -qx "1. Romance brasileiro – Século XIX. I. Silva, João. II. Título."' "$card"
    assert 'echo "$card" | grep -qx "CDD 869.3"'
    assert 'echo "$output" | grep -q "class=\"kei-entrada\"" && echo "$output" | grep -q "text-indent: -2.2em"' "hanging indentation"
    # Off: the previous values come back.
    inputs "off"; answer yes
    panel lt_br_ficha
    assert '[ "$(tools_sql "SELECT value FROM systempreferences WHERE variable = \"OPACXSLTDetailsDisplay\";")" = "default" ]'
    assert '[ ! -e /etc/koha-easy-install/ficha.state ]'
}

@test "BR13 catalogue card refresh: new languages get a stylesheet, nothing when the card is off" {
    ficha_env
    panel ficha_refresh
    assert '[ ! -e "$W/ficha" ]' "ficha_refresh must not do anything while the card is off"
    printf 'OPACXSLTDetailsDisplay=default\nXSLTDetailsDisplay=default\n' > /etc/koha-easy-install/ficha.state
    mkdir -p "$W/tmpl/opac/es-ES/xslt" && cp "$W/tmpl/opac/en/xslt/MARC21slim2OPACDetail.xsl" "$W/tmpl/opac/es-ES/xslt/"
    panel ficha_refresh
    rm -f /etc/koha-easy-install/ficha.state
    assert '[ -f "$W/ficha/es-ES/opac-detail.xsl" ] && [ -f "$W/ficha/es-ES/staff-detail.xsl" ]' "$(ls -R "$W/ficha" 2>&1)"
}

# --- 3. Calendar ----------------------------------------------------------------

# Probes Memcached in a subshell (fd 3 belongs to bats).
memcached_set() { ( exec 5<>/dev/tcp/127.0.0.1/11211; printf 'set kei_probe 0 0 1\r\nx\r\n' >&5; read -r -t 2 _ <&5 ); }
memcached_has() { ( exec 5<>/dev/tcp/127.0.0.1/11211; printf 'get kei_probe\r\n' >&5; read -r -t 2 r <&5; [[ "$r" == VALUE* ]] ); }

@test "BR14 holidays: national, movable and local days for every library, no duplicates" {
    memcached_set
    assert 'memcached_has'
    inputs "add" "2025" "*" "20/01 São Sebastião"
    answer yes
    panel lt_br_holidays
    assert '[ "$status" -eq 0 ]' "$output"
    assert 'grep -q "^koha-mysql library" "$KEI_S/calls.log" && [ "$(pre_backups CALENDAR)" = "1" ]' "$(calls)"
    local q="SELECT COUNT(*) FROM special_holidays WHERE year = 2025 AND isexception = 0"
    assert '[ "$(tools_sql "$q AND branchcode = \"MPL\";")" = "14" ]' "13 national/optional days + 1 local"
    assert '[ "$(tools_sql "$q AND branchcode = \"CPL\";")" = "14" ]' "CPL already had Natal: $(tools_sql "SELECT day, month, title FROM special_holidays WHERE branchcode = 'CPL'")"
    assert '[ "$(tools_sql "SELECT COUNT(*) FROM special_holidays WHERE branchcode = \"CPL\" AND day = 25 AND month = 12;")" = "1" ]' "a day already in the calendar is not added twice"
    assert '[ "$(tools_sql "SELECT title FROM special_holidays WHERE branchcode = \"MPL\" AND day = 4 AND month = 3;")" = "Carnaval (terça-feira)" ]'
    assert '[ "$(tools_sql "SELECT title FROM special_holidays WHERE branchcode = \"MPL\" AND day = 19 AND month = 6;")" = "Corpus Christi" ]'
    assert '[ "$(tools_sql "SELECT title FROM special_holidays WHERE branchcode = \"MPL\" AND day = 20 AND month = 1;")" = "São Sebastião" ]'
    assert '! memcached_has' "Koha's cached calendar must be dropped"
    inputs "add" "2025" "*" ""
    answer yes
    panel lt_br_holidays
    assert '[ "$(tools_sql "SELECT COUNT(*) FROM special_holidays;")" = "28" ]' "a second run adds nothing"
    inputs "remove" "2025" "MPL"
    answer yes
    panel lt_br_holidays
    assert '[ "$(tools_sql "SELECT COUNT(*) FROM special_holidays WHERE branchcode = \"MPL\";")" = "0" ] && [ "$(tools_sql "SELECT COUNT(*) FROM special_holidays WHERE branchcode = \"CPL\";")" = "14" ]'
    inputs "remove" "2025" "CPL"; answer yes
    panel lt_br_holidays
    assert '[ "$(tools_sql "SELECT title FROM special_holidays;")" = "Natal" ]' "days added by hand stay"
}

@test "BR15 holidays: bad input is refused, and Koha's newer calendar table is used when present" {
    inputs "add" "25"
    panel lt_br_holidays
    inputs "add" "2025" "CPL" "32/13 Nada"
    panel lt_br_holidays
    assert '[ "$(dialogs | grep -c "^ERROR")" = "2" ] && ! grep -q "koha-mysql" "$KEI_S/calls.log" 2>/dev/null' "$(dialogs)"
    tools_sql "DROP TABLE special_holidays; CREATE TABLE library_single_closures (library_single_closure_id int(11) NOT NULL AUTO_INCREMENT PRIMARY KEY, library_id varchar(10) NOT NULL, date date NOT NULL, title varchar(50) NOT NULL DEFAULT '', description mediumtext NOT NULL, UNIQUE KEY library_id_date (library_id, date));"
    inputs "add" "2026" "CPL" ""; answer yes
    panel lt_br_holidays
    assert '[ "$(tools_sql "SELECT COUNT(*) FROM library_single_closures WHERE library_id = \"CPL\";")" = "13" ]' "$output"
    assert '[ "$(tools_sql "SELECT title FROM library_single_closures WHERE date = \"2026-02-17\";")" = "Carnaval (terça-feira)" ]'
}

@test "BR16 opt-in only: the installation and the panel start never apply a Brazilian preset" {
    local body
    body=$(sed -n '/^function_install_koha() {/,/^}/p' "$KEI_REPO/installer")
    assert '[ -n "$body" ] && ! echo "$body" | grep -qE "lt_br_|br_|ficha_|cpf_|function_brazil"' "the installation must not call the Brazil tools"
    assert '! sed -n "/^(return 0 2>\/dev\/null) \&\& return 0/,\$p" "$KEI_REPO/installer" | grep -qE "lt_br_|br_holidays|br_patrons|_lt_br"' "the startup only refreshes an already enabled card"
    assert 'grep -qE "^ +10\) function_brazil_tools ;;" "$KEI_REPO/installer"' "reachable only from Library tools > 10"
}
