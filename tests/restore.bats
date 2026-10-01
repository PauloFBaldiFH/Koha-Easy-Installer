#!/usr/bin/env bats
# Database restore (menu 3): bad backups, database failures, disk problems
# and failures in the middle of the import. The live catalog starts as "OLD"
# (200 records); a good backup holds "NEW" (300 records).

setup() {
    load lib/common
    kei_reset_env
    kei_reset_live_catalog
    kei_backup_fixtures
    unset KEI_SELECT_FILE KEI_EXTRA KEI_DEFAULT_ANSWER
}

teardown() {
    kei_kill_daemons
    mountpoint -q /var/backups/koha_sql 2>/dev/null && umount /var/backups/koha_sql
    rm -f /root/.my.cnf
    mysql -e "DROP USER IF EXISTS 'kei_limited'@'localhost';" 2>/dev/null || true
    if [ "$(mysql -Nse 'SELECT @@skip_name_resolve' 2>/dev/null)" = "1" ]; then kei_stop_mariadb; fi
    kei_start_mariadb
}

restore() {
    export KEI_SELECT_FILE="$1"
    panel function_restore_database
}

lock_is_free() { flock -n /var/lock/koha_backup.lock true; }

# A mysqldump file cut at the start of table $2 (plain SQL, no end line).
cut_before_table() {
    awk -v t="$2" 'index($0, "-- Table structure for table `" t "`") { exit } { print }' "$FIX/new.sql" > "$1"
}

# --- valid backups -----------------------------------------------------

@test "R01 valid .sql.gz: catalog replaced, validated safety copy kept, services back" {
    restore "$FIX/new.sql.gz"
    assert '[ "$(live_marker)" = "NEW" ]' "catalog must be NEW after restore"
    assert '[ "$(live_biblios)" = "300" ]'
    local rescue
    rescue=$(ls /var/backups/koha_sql/PRE-RESTORE_*.sql.gz 2>/dev/null | head -n1)
    assert '[ -n "$rescue" ]' "a PRE-RESTORE safety copy must exist"
    assert 'gzip -t "$rescue"'
    assert 'zcat "$rescue" | tail -n1 | grep -q "^-- Dump completed"' "safety copy must be a complete mysqldump"
    assert 'zcat "$rescue" | grep -q "OLD title 1 "' "safety copy must hold the OLD catalog"
    assert '[ -e "$KEI_S/run/plack" ] && [ -e "$KEI_S/run/zebra" ] && [ -e "$KEI_S/run/worker" ]' "Plack, Zebra and workers must be running"
    assert 'lock_is_free'
    assert '! mysql -e "USE koha_restore_check" 2>/dev/null' "trial database must be dropped"
}

@test "R02 valid plain .sql backup restores" {
    restore "$FIX/new.sql"
    assert '[ "$(live_marker)" = "NEW" ]'
}

@test "R03 zero-byte .sql.gz is rejected before anything is touched" {
    : > "$BATS_TEST_TMPDIR/empty.sql.gz"
    restore "$BATS_TEST_TMPDIR/empty.sql.gz"
    assert_catalog_untouched
    assert 'dialogs | grep -q "^ERROR"' "an error must be shown"
}

@test "R04 zero-byte .sql is rejected before anything is touched" {
    : > "$BATS_TEST_TMPDIR/empty.sql"
    restore "$BATS_TEST_TMPDIR/empty.sql"
    assert_catalog_untouched
    assert 'dialogs | grep -q "^ERROR"'
}

@test "R05 malformed .sql.gz (not gzip at all) is rejected" {
    head -c 50000 /dev/urandom > "$BATS_TEST_TMPDIR/garbage.sql.gz"
    restore "$BATS_TEST_TMPDIR/garbage.sql.gz"
    assert_catalog_untouched
    assert 'dialogs | grep -qi "gzip"'
}

@test "R06 truncated .sql.gz (download cut short) is rejected" {
    local size; size=$(stat -c %s "$FIX/new.sql.gz")
    head -c $((size / 2)) "$FIX/new.sql.gz" > "$BATS_TEST_TMPDIR/cut.sql.gz"
    restore "$BATS_TEST_TMPDIR/cut.sql.gz"
    assert_catalog_untouched
}

@test "R07 .sql cut in the middle of a statement fails the trial import" {
    local size; size=$(stat -c %s "$FIX/new.sql")
    head -c $((size * 2 / 3)) "$FIX/new.sql" > "$BATS_TEST_TMPDIR/cut.sql"
    restore "$BATS_TEST_TMPDIR/cut.sql"
    assert_catalog_untouched
}

@test "R08 .sql cut between statements (58 tables, no systempreferences) never replaces the catalog" {
    cut_before_table "$BATS_TEST_TMPDIR/partial.sql" systempreferences
    export KEI_DEFAULT_ANSWER=yes     # operator says "yes" to every question
    restore "$BATS_TEST_TMPDIR/partial.sql"
    assert_catalog_untouched
}

@test "R09 a 60-table dump that is not a Koha database is refused" {
    mysql -e "DROP DATABASE IF EXISTS kei_other; CREATE DATABASE kei_other;"
    for i in $(seq 1 60); do echo "CREATE TABLE wp_t$i (id int PRIMARY KEY, v text); INSERT INTO wp_t$i VALUES (1, REPEAT('x', 300));"; done | mysql kei_other
    kei_dump kei_other "$BATS_TEST_TMPDIR/other.sql.gz"
    mysql -e "DROP DATABASE kei_other;"
    export KEI_DEFAULT_ANSWER=yes
    restore "$BATS_TEST_TMPDIR/other.sql.gz"
    assert_catalog_untouched
}

# --- database availability, credentials, privileges ---------------------

@test "R10 MariaDB down (and cannot start): clear error, nothing touched" {
    kei_stop_mariadb
    restore "$FIX/new.sql.gz"
    kei_start_mariadb
    assert_catalog_untouched
    assert 'dialogs | grep -qi "MariaDB"' "the error must name MariaDB"
}

@test "R11 administrator login refused (wrong credentials): clear error, nothing touched" {
    printf '[client]\nuser=kei_nobody\npassword=wrong\n' > /root/.my.cnf
    restore "$FIX/new.sql.gz"
    rm -f /root/.my.cnf
    assert_catalog_untouched
    assert 'dialogs | grep -qi "refused\|denied"' "the error must say the login was refused"
}

@test "R12 administrator without DDL privileges: nothing touched" {
    mysql -e "CREATE USER IF NOT EXISTS 'kei_limited'@'localhost' IDENTIFIED BY 'x'; GRANT SELECT ON *.* TO 'kei_limited'@'localhost';"
    printf '[client]\nuser=kei_limited\npassword=x\n' > /root/.my.cnf
    restore "$FIX/new.sql.gz"
    rm -f /root/.my.cnf
    assert_catalog_untouched
}

# --- disk space and backup folder ----------------------------------------

@test "R13 safety copy cannot be written (backup disk full): restore refused" {
    mkdir -p /var/backups/koha_sql
    mount -t tmpfs -o size=16k tmpfs /var/backups/koha_sql
    export KEI_DEFAULT_ANSWER=yes     # even when the operator insists
    restore "$FIX/new.sql.gz"
    assert_catalog_untouched
    assert '[ -z "$(ls /var/backups/koha_sql/PRE-RESTORE_* 2>/dev/null)" ]' "no partial safety copy may be left"
    assert 'lock_is_free'
}

@test "R14 backup folder not writable (path is a file): restore refused" {
    mkdir -p /var/backups && rm -rf /var/backups/koha_sql && : > /var/backups/koha_sql
    export KEI_DEFAULT_ANSWER=yes
    restore "$FIX/new.sql.gz"
    rm -f /var/backups/koha_sql
    assert_catalog_untouched
}

@test "R15 not enough free space for the database: refused before the trial import" {
    printf 'get_free_space_mb() { echo 5; }\n' > "$BATS_TEST_TMPDIR/extra.sh"
    export KEI_EXTRA="$BATS_TEST_TMPDIR/extra.sh"
    restore "$FIX/new.sql.gz"
    assert_catalog_untouched
    assert '! mysql -e "USE koha_restore_check" 2>/dev/null'
    assert 'dialogs | grep -qi "disk space"' "the error must mention disk space"
}

# --- failures after the old catalog was dropped ------------------------------

inject_live_import_failure() {
    cat > "$BATS_TEST_TMPDIR/extra.sh" <<'EOF'
eval "kei_orig_$(declare -f import_sql_file)"
import_sql_file() {
    if [ "$2" = "koha_library" ] && [ ! -e /run/kei-mock/injected ]; then
        touch /run/kei-mock/injected
        printf 'ERROR 1030 (HY000): Got error 28 "No space left on device" (injected)\n' >> "$3"
        return 1
    fi
    kei_orig_import_sql_file "$@"
}
EOF
    rm -f "$KEI_S/injected"
    export KEI_EXTRA="$BATS_TEST_TMPDIR/extra.sh"
}

@test "R16 live import fails: previous catalog rolled back, services and indexer back" {
    inject_live_import_failure
    restore "$FIX/new.sql.gz"
    assert '[ "$(live_marker)" = "OLD" ] && [ "$(live_biblios)" = "200" ]' "OLD catalog must be rolled back (got '$(live_marker)')"
    assert 'dialogs | grep -q "previous catalog was restored"'
    assert '[ -e "$KEI_S/run/plack" ] && [ -e "$KEI_S/run/zebra" ]' "Plack and Zebra must be running again"
    assert '[ -e "$KEI_S/run/indexer" ]' "Zebra indexer daemon must be running again"
    assert 'lock_is_free'
}

@test "R17 schema upgrade fails: previous catalog rolled back" {
    touch "$KEI_S/fail/koha-upgrade-schema"
    restore "$FIX/new.sql.gz"
    assert '[ "$(live_marker)" = "OLD" ]' "OLD catalog must be rolled back after a failed schema upgrade (got '$(live_marker)')"
    assert '[ -e "$KEI_S/run/plack" ]'
}

@test "R18 MariaDB dies during the import: safety copy intact and reported, no hang" {
    cat > "$BATS_TEST_TMPDIR/extra.sh" <<'EOF'
eval "kei_orig_$(declare -f import_sql_file)"
import_sql_file() {
    if [ "$2" = "koha_library" ] && [ ! -e /run/kei-mock/injected ]; then
        touch /run/kei-mock/injected
        mysqladmin shutdown >/dev/null 2>&1; sleep 1
    fi
    kei_orig_import_sql_file "$@"
}
EOF
    rm -f "$KEI_S/injected"
    export KEI_EXTRA="$BATS_TEST_TMPDIR/extra.sh"
    export KEI_SELECT_FILE="$FIX/new.sql.gz"
    run timeout 300 "$KEI_SH" "$PANEL" function_restore_database
    assert '[ "$status" -ne 124 ]' "the panel must not hang"
    kei_start_mariadb
    local rescue
    rescue=$(ls /var/backups/koha_sql/PRE-RESTORE_*.sql.gz 2>/dev/null | head -n1)
    assert '[ -n "$rescue" ] && gzip -t "$rescue"' "safety copy must survive the crash"
    assert 'dialogs | grep -qF "$rescue"' "the error must tell where the safety copy is"
    mysql -e "DROP DATABASE IF EXISTS koha_library; CREATE DATABASE koha_library;"
    zcat "$rescue" | mysql koha_library
    assert '[ "$(live_marker)" = "OLD" ]' "the safety copy must bring the OLD catalog back"
    assert 'lock_is_free'
}

@test "R19 dump made with --databases (CREATE DATABASE/USE) goes into koha_library only" {
    kei_make_catalog kei_src NEW 300
    kei_dump kei_src "$BATS_TEST_TMPDIR/dbs.sql.gz" --databases
    mysql -e "DROP DATABASE kei_src;"
    restore "$BATS_TEST_TMPDIR/dbs.sql.gz"
    assert '[ "$(live_marker)" = "NEW" ]'
    assert '! mysql -e "USE kei_src" 2>/dev/null' "the dump must not recreate its original database"
}

@test "R20 Zebra server with the stock <elasticsearch> block stays on Zebra after restore" {
    touch "$KEI_S/pkgs/koha-elasticsearch" "$KEI_S/pkgs/elasticsearch"
    restore "$FIX/new.sql.gz"
    assert '[ "$(live_engine)" = "Zebra" ]' "SearchEngine must stay Zebra (got '$(live_engine)')"
    assert '[ ! -e /etc/cron.d/koha_es_watchdog ]' "no Elasticsearch watchdog on a Zebra server"
}

@test "R21 the Koha database user can log in after the restore (socket and 127.0.0.1)" {
    # With skip-name-resolve (common on tuned servers) a TCP login from
    # 127.0.0.1 no longer matches user@localhost.
    kei_stop_mariadb
    kei_start_mariadb --skip-name-resolve
    mysql -e "DROP USER IF EXISTS 'koha_library'@'localhost'; DROP USER IF EXISTS 'koha_library'@'127.0.0.1';"
    sed -i 's|<hostname>localhost</hostname>|<hostname>127.0.0.1</hostname>|' /etc/koha/sites/library/koha-conf.xml
    restore "$FIX/new.sql.gz"
    assert '[ "$(live_marker)" = "NEW" ]'
    assert 'MYSQL_PWD=KeiTest-Pass_42 mysql --no-defaults -h 127.0.0.1 --protocol=TCP -u koha_library -e "SELECT 1 FROM koha_library.biblio LIMIT 1" >/dev/null' "TCP login as Koha does must work"
    assert 'MYSQL_PWD=KeiTest-Pass_42 mysql --no-defaults -u koha_library -e "SELECT 1 FROM koha_library.biblio LIMIT 1" >/dev/null' "socket login must work"
}

@test "R22 the restore shows one line per step; the commands' output goes to restore.log" {
    rm -f /var/log/koha-easy-install/restore.log
    restore "$FIX/new.sql.gz"
    assert '[ "$(live_marker)" = "NEW" ]'
    local step
    for step in "Testing the backup" "Saving a safety backup" "Importing the catalog" \
                "Upgrading the database schema" "Reindexing the catalog" "Restarting Koha services"; do
        assert 'echo "$output" | grep -q "${step}.*Done!"' "missing '$step': $output"
    done
    assert '! echo "$output" | grep -q "^>>>"' "$output"
    assert '[ -s /var/log/koha-easy-install/restore.log ]'
}
