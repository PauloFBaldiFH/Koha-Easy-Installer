#!/usr/bin/env bats
# Library tools: MARC import/undo, SQL reports pack, patron import and
# school-year turnover, data-quality check, LGPD housekeeping. The Koha
# scripts are test doubles (tests/mocks/koha-script) acting on a real
# MariaDB; the panel's own steps (lock, dry run, confirmation, PRE-* backup,
# koha-shell quoting) run for real.

setup() {
    load lib/common
    kei_reset_env
    kei_reset_live_catalog
    kei_tools_catalog
    unset KEI_SELECT_FILE KEI_DEFAULT_ANSWER
    W="$BATS_TEST_TMPDIR"
}

teardown() {
    [ -n "${HOLD:-}" ] && kill "$HOLD" 2>/dev/null
    kei_kill_daemons
}

pre_backups() { find /var/backups/koha_sql -maxdepth 1 -name "PRE-${1:-}*" 2>/dev/null | wc -l; }
line_of()     { grep -n -m1 -- "$1" "$KEI_S/calls.log" | cut -d: -f1; }
# ISO 2709 file with N minimal records (leader position 09 = "a": Unicode).
marc_file()   { local i; for ((i = 0; i < $2; i++)); do printf '00026nam a2200025 a 4500\036\035'; done > "$1"; }
bibs()        { tools_sql "SELECT COUNT(*) FROM biblio;"; }

# --- MARC import ---------------------------------------------------------

@test "L01 MARC import: staged preview, then a verified PRE-IMPORT backup, then the import" {
    marc_file "$W/books.mrc" 3
    export KEI_SELECT_FILE="$W/books.mrc"
    inputs "UTF-8" "keep"
    answer yes
    panel lt_marc_import
    assert '[ "$status" -eq 0 ]' "$output"
    assert 'grep -q "^stage_file.pl --file /tmp/koha_tools\.[^ ]*/books.mrc --format ISO2709 --encoding UTF-8 --add-items --comment koha-easy-installer [0-9-]* books.mrc --match 1 --no-replace \[pre=0\]" "$KEI_S/calls.log"' "$(calls)"
    assert 'grep -q "^commit_file.pl --batch-number 1 \[pre=1\]" "$KEI_S/calls.log"' "the import must come after the safety backup: $(calls)"
    assert '[ "$(line_of stage_file.pl)" -lt "$(line_of commit_file.pl)" ]'
    local pre; pre=$(ls /var/backups/koha_sql/PRE-IMPORT_*.sql.gz)
    assert 'gzip -t "$pre" && zcat "$pre" | tail -n1 | grep -q "Dump completed"' "PRE-IMPORT backup must be complete"
    assert '[ "$(bibs)" = "203" ]'
    assert '[ "$(tools_sql "SELECT import_status FROM import_batches WHERE import_batch_id = 1;")" = "imported" ]'
    assert 'dialogs | grep -q "^OK ✔ Batch 1 imported"'
    assert '[ -z "$(ls -d /tmp/koha_tools.* 2>/dev/null)" ]' "the work folder must be removed on exit"
}

@test "L02 MARC import declined after the preview: nothing imported, no backup" {
    marc_file "$W/books.mrc" 2
    export KEI_SELECT_FILE="$W/books.mrc"
    inputs "UTF-8" "new"
    answer no
    panel lt_marc_import
    assert 'grep -q "^stage_file.pl" "$KEI_S/calls.log"'
    assert '! grep -q "^stage_file.pl.*--match" "$KEI_S/calls.log"' "mode 'new' must not match records"
    assert '! grep -q "^commit_file.pl" "$KEI_S/calls.log"'
    assert '[ "$(pre_backups)" = "0" ] && [ "$(bibs)" = "200" ]'
    assert 'dialogs | grep -q "Nothing was added to the catalog"'
}

@test "L03 MARC import refuses empty and non-MARC files before calling Koha" {
    local f
    : > "$W/empty.mrc"
    echo "hello" > "$W/text.mrc"
    echo "<collection></collection>" > "$W/none.xml"
    for f in empty.mrc text.mrc none.xml; do
        export KEI_SELECT_FILE="$W/$f"
        panel lt_marc_import
    done
    assert '! grep -q "stage_file.pl" "$KEI_S/calls.log" 2>/dev/null' "$(calls)"
    assert '[ "$(dialogs | grep -c "^ERROR")" = "3" ]' "$(dialogs)"
    assert '[ "$(bibs)" = "200" ]'
}

@test "L04 MARC undo: counts first, PRE-UNDO-IMPORT backup, then commit_file.pl --revert" {
    marc_file "$W/books.mrc" 4
    export KEI_SELECT_FILE="$W/books.mrc"
    inputs "UTF-8" "new"; answer yes
    panel lt_marc_import
    assert '[ "$(bibs)" = "204" ]'
    : > "$KEI_S/calls.log"
    inputs "1"; answer yes
    panel lt_marc_undo
    assert 'dialogs | grep -q "PROMPT \[Undo a MARC import\] Batch 1: 4 record(s) and 4 item(s)"' "$(dialogs)"
    assert 'grep -q "^commit_file.pl --revert --batch-number 1 \[pre=2\]" "$KEI_S/calls.log"' "$(calls)"
    assert '[ "$(pre_backups UNDO-IMPORT)" = "1" ]'
    assert '[ "$(bibs)" = "200" ]'
    assert '[ "$(tools_sql "SELECT import_status FROM import_batches WHERE import_batch_id = 1;")" = "reverted" ]'
}

@test "L05 write tools are refused while a backup or restore holds the lock" {
    marc_file "$W/books.mrc" 2
    export KEI_SELECT_FILE="$W/books.mrc"
    flock -o /var/lock/koha_backup.lock sleep 30 3>&- &
    HOLD=$!; sleep 0.5
    panel lt_marc_import
    inputs "1"
    panel lt_reports
    inputs "ST" "FM" "all" "*"
    panel lt_patron_category
    assert '! grep -qE "stage_file|update_patrons" "$KEI_S/calls.log" 2>/dev/null' "$(calls)"
    assert '[ "$(dialogs | grep -c "already running")" = "3" ]' "$(dialogs)"
    assert '[ "$(tools_sql "SELECT COUNT(*) FROM saved_sql;")" = "1" ]'
}

@test "L06 no write happens when the safety backup cannot be made" {
    marc_file "$W/books.mrc" 2
    export KEI_SELECT_FILE="$W/books.mrc"
    rm -rf /var/backups/koha_sql; mkdir -p /var/backups; : > /var/backups/koha_sql   # a file where the folder should be
    inputs "UTF-8" "keep"; answer yes
    panel lt_marc_import
    rm -f /var/backups/koha_sql
    assert 'grep -q "^stage_file.pl" "$KEI_S/calls.log"' "the preview still runs"
    assert '! grep -q "^commit_file.pl" "$KEI_S/calls.log"' "nothing may be imported without the backup"
    assert 'dialogs | grep -q "Safety backup failed"'
    assert '[ "$(bibs)" = "200" ]'
}

@test "L07 koha_tool passes every argument intact through koha-shell and refuses single quotes" {
    printf '#!/bin/bash\nprintf "<%%s>\\n" "$@"\n' > /usr/share/koha/bin/kei_echo.pl
    chmod 755 /usr/share/koha/bin/kei_echo.pl
    panel eval 'tools_workdir; l=$(tools_log echo); koha_tool "$l" kei_echo.pl "a b" "\$HOME" "\`id\`" "q\"uote" "back\\slash" "a;b|c&d"; cat "$l"'
    rm -f /usr/share/koha/bin/kei_echo.pl
    assert 'echo "$output" | grep -qxF "<a b>"' "$output"
    assert 'echo "$output" | grep -qxF "<\$HOME>" && echo "$output" | grep -qxF "<\`id\`>"' "$output"
    assert 'echo "$output" | grep -qxF "<q\"uote>" && echo "$output" | grep -qxF "<back\\slash>" && echo "$output" | grep -qxF "<a;b|c&d>"' "$output"
    panel eval 'tools_workdir; l=$(tools_log echo); koha_tool "$l" stage_file.pl "it'"'"'s"; echo "rc=$?"'
    assert 'echo "$output" | grep -q "rc=2"' "$output"
    assert '! grep -q "^stage_file.pl" "$KEI_S/calls.log" 2>/dev/null'
}

# --- SQL reports pack ------------------------------------------------------

@test "L08 reports pack: tagged read-only reports, idempotent, removal keeps other reports" {
    inputs "1"; answer yes
    panel lt_reports
    assert '[ "$status" -eq 0 ]' "$output"
    local n ids
    n=$(tools_sql "SELECT COUNT(*) FROM saved_sql WHERE notes LIKE '%[koha-easy-installer:%';")
    assert '[ "$n" = "8" ]' "8 reports expected, got $n: $(dialogs)"
    assert '[ "$(pre_backups REPORTS)" = "1" ]'
    assert '[ "$(tools_sql "SELECT COUNT(*) FROM saved_sql WHERE notes LIKE '"'"'%[koha-easy-installer:%'"'"' AND savedsql NOT LIKE '"'"'SELECT %'"'"';")" = "0" ]' "only SELECT statements"
    assert '[ "$(tools_sql "SELECT DISTINCT borrowernumber FROM saved_sql WHERE report_group IS NOT NULL;")" = "$(tools_sql "SELECT borrowernumber FROM borrowers WHERE cardnumber = '"'"'E4'"'"';")" ]' "owner = the superlibrarian"
    # Every saved query runs on the catalog.
    local q
    while IFS= read -r q; do
        assert 'mysql koha_library -e "$q" >/dev/null' "report does not run: $q"
    done < <(tools_sql "SELECT savedsql FROM saved_sql WHERE notes LIKE '%[koha-easy-installer:%';")
    ids=$(tools_sql "SELECT GROUP_CONCAT(id ORDER BY id) FROM saved_sql;")
    inputs "1"; answer yes
    panel lt_reports
    assert '[ "$(tools_sql "SELECT GROUP_CONCAT(id ORDER BY id) FROM saved_sql;")" = "$ids" ]' "installing again must update the same reports"
    assert 'grep -q "update" "$KEI_S/textbox.last"'
    inputs "2"; answer yes
    panel lt_reports
    assert '[ "$(tools_sql "SELECT report_name FROM saved_sql;")" = "My own report" ]' "only the pack may be removed"
}

@test "L09 reports pack declined after the preview: nothing saved, no backup" {
    inputs "1"; answer no
    panel lt_reports
    assert '[ "$(tools_sql "SELECT COUNT(*) FROM saved_sql;")" = "1" ] && [ "$(pre_backups)" = "0" ]'
    assert 'grep -q "Most borrowed titles" "$KEI_S/textbox.last"' "the preview lists the reports"
}

# --- patrons ------------------------------------------------------------------

@test "L10 patron import: dry run first, then PRE-PATRONS backup and --confirm" {
    printf 'cardnumber,surname,firstname,branchcode\nN1,Nova,Ana,\nN2,Neto,Bruno,MPL\nC1,Existing,Ana,\n' > "$W/patrons.csv"
    export KEI_SELECT_FILE="$W/patrons.csv"
    inputs "CPL" "ST"
    answer no yes          # do not update existing patrons; import
    panel lt_patron_import
    assert 'grep -q "^import_patrons.pl --file /tmp/koha_tools\.[^ ]*/patrons.csv --matchpoint cardnumber --default branchcode=CPL --default categorycode=ST -v -v \[pre=0\]" "$KEI_S/calls.log"' "$(calls)"
    assert 'grep -q "^import_patrons.pl .* -v -v --confirm \[pre=1\]" "$KEI_S/calls.log"' "$(calls)"
    assert 'dialogs | grep -q "New patrons      : 2"' "$(dialogs)"
    assert '[ "$(tools_sql "SELECT CONCAT(branchcode, categorycode) FROM borrowers WHERE cardnumber = '"'"'N1'"'"';")" = "CPLST" ]'
    assert '[ "$(tools_sql "SELECT branchcode FROM borrowers WHERE cardnumber = '"'"'N2'"'"';")" = "MPL" ]'
    assert '[ "$(tools_sql "SELECT surname FROM borrowers WHERE cardnumber = '"'"'C1'"'"';")" = "OLD" ]' "existing patrons stay as they are"
    assert '[ -f /root/koha_patrons_template.csv ]'
}

@test "L11 patron import refuses non-UTF-8, semicolon and header-less files" {
    printf 'cardnumber,surname\nX1,Jo\xe3o\n' > "$W/latin1.csv"
    printf 'cardnumber;surname\nX1;Joao\n' > "$W/semicolon.csv"
    printf 'X1,Joao\nX2,Maria\n' > "$W/noheader.csv"
    local f
    for f in latin1 semicolon noheader; do
        export KEI_SELECT_FILE="$W/$f.csv"
        panel lt_patron_import
    done
    assert '! grep -q "import_patrons" "$KEI_S/calls.log" 2>/dev/null'
    assert 'dialogs | grep -q "not UTF-8" && dialogs | grep -q "semicolons" && dialogs | grep -q "must name the columns"' "$(dialogs)"
}

@test "L12 school-year turnover: dry run lists the patrons, --confirm only after the backup" {
    inputs "ST" "FM" "age" "*"
    answer yes
    panel lt_patron_category
    assert 'grep -q "^update_patrons_category.pl --from ST --to FM -v --too_old \[pre=0\]" "$KEI_S/calls.log"' "$(calls)"
    assert 'grep -q "^update_patrons_category.pl --from ST --to FM -v --too_old --confirm \[pre=1\]" "$KEI_S/calls.log"' "$(calls)"
    assert 'grep -q "WOULD HAVE Updated Bia Souza" "$KEI_S/textbox.last"'
    assert '[ "$(tools_sql "SELECT COUNT(*) FROM borrowers WHERE categorycode = '"'"'FM'"'"';")" = "2" ]' "only the two adults move"
    assert 'dialogs | grep -q "Patrons moved from ST to FM: 2"'
}

@test "L13 school-year turnover: same category, bad date and empty selection change nothing" {
    inputs "ST" "ST"
    panel lt_patron_category
    inputs "ST" "FM" "date" "2024-13-45"
    panel lt_patron_category
    inputs "ST" "FM" "date" "2000-01-01" "*"
    panel lt_patron_category
    assert '[ "$(grep -c "^update_patrons_category.pl" "$KEI_S/calls.log")" = "1" ]' "only the valid request reaches Koha: $(calls)"
    assert 'grep -q -- "--regbefore 2000-01-01 \[pre=0\]" "$KEI_S/calls.log"'
    assert 'dialogs | grep -q "No patron matches"'
    assert '[ "$(tools_sql "SELECT COUNT(*) FROM borrowers WHERE categorycode = '"'"'ST'"'"';")" = "3" ] && [ "$(pre_backups)" = "0" ]'
}

# --- data quality ---------------------------------------------------------------

@test "L14 data-quality check is read-only and its report goes to a log" {
    panel lt_data_quality
    assert 'dialogs | grep -q "No inconsistencies found"' "$(dialogs)"
    tools_sql "UPDATE items SET homebranch = NULL WHERE itemnumber = 7;"
    panel lt_data_quality
    assert 'grep -q "itemnumber=7" "$KEI_S/textbox.last"'
    assert '[ "$(ls /var/log/koha-easy-install/tools/data-quality-*.log | wc -l)" -ge 1 ]'
    assert '[ "$(pre_backups)" = "0" ]' "a read-only check makes no backup"
}

# --- privacy (LGPD) -------------------------------------------------------------

@test "L15 anonymise: counts like Koha, then PRE-PRIVACY backup, then batch_anonymise.pl" {
    inputs "365"
    answer yes
    panel lt_privacy_anonymise
    assert 'dialogs | grep -q "Loans: 3"' "3 old loans (the patron who keeps his history and the recent loan are left out): $(dialogs)"
    assert 'dialogs | grep -q "Holds: 2"'
    assert 'grep -q "^batch_anonymise.pl --days 365 -v \[pre=1\]" "$KEI_S/calls.log"' "$(calls)"
    assert '[ "$(tools_sql "SELECT COUNT(*) FROM old_issues WHERE borrowernumber IS NULL;")" = "3" ]'
    assert 'dialogs | grep -q "Anonymised: 3 loan(s) and 2 hold(s)"'
}

@test "L16 anonymise: too few days is refused, declining changes nothing" {
    inputs "7"
    panel lt_privacy_anonymise
    inputs "365"; answer no
    panel lt_privacy_anonymise
    assert '! grep -q "batch_anonymise" "$KEI_S/calls.log" 2>/dev/null'
    assert '[ "$(tools_sql "SELECT COUNT(*) FROM old_issues WHERE borrowernumber IS NULL;")" = "0" ] && [ "$(pre_backups)" = "0" ]'
}

@test "L17 delete old patrons: dry run, typed count confirmation, PRE-PRIVACY backup" {
    inputs "2020-01-01" "*" "5"      # wrong number typed
    panel lt_privacy_delete
    assert '! grep -q "delete_patrons.pl.*--confirm" "$KEI_S/calls.log"' "$(calls)"
    assert 'dialogs | grep -q "did not match"'
    inputs "2020-01-01" "*" "2"
    panel lt_privacy_delete
    assert 'grep -q "^delete_patrons.pl --expired_before 2020-01-01 --not_borrowed_since 2020-01-01 -v \[pre=0\]" "$KEI_S/calls.log"' "$(calls)"
    assert 'grep -q "^delete_patrons.pl .* -v --confirm \[pre=1\]" "$KEI_S/calls.log"' "$(calls)"
    assert '[ "$(tools_sql "SELECT GROUP_CONCAT(cardnumber ORDER BY cardnumber) FROM borrowers WHERE dateexpiry < '"'"'2020-01-01'"'"';")" = "E3,E4" ]' "the patron with a loan and the staff member stay"
    assert 'dialogs | grep -q "Patrons deleted: 2"'
}

@test "L18 tool logs are private and listed newest first" {
    inputs "ST" "FM" "all" "*"; answer no
    panel lt_patron_category
    assert '[ "$(stat -c %a /var/log/koha-easy-install/tools)" = "700" ]'
    assert '[ "$(stat -c %a /var/log/koha-easy-install/tools/patron-category-*.log)" = "600" ]'
    panel lt_view_logs
    assert 'grep -q "WOULD HAVE Updated" "$KEI_S/textbox.last"'
}
