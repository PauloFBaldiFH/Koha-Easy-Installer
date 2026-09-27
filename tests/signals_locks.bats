#!/usr/bin/env bats
# Interruptions (Ctrl+C, SSH connection lost, kill) during a restore, and the
# locks shared by the panel and the nightly cron backups.

setup() {
    load lib/common
    kei_reset_env
    kei_reset_live_catalog
    kei_backup_fixtures
    # A backup whose import takes a few seconds, so it can be interrupted.
    [ -s "$FIX/slow.sql" ] || sed '/^-- Dump completed/i SELECT SLEEP(4);' "$FIX/new.sql" > "$FIX/slow.sql"
    unset KEI_EXTRA KEI_DEFAULT_ANSWER
    export KEI_SELECT_FILE="$FIX/slow.sql"
}

teardown() {
    [ -n "${BG:-}" ] && kill -9 -- "-$BG" 2>/dev/null
    [ -n "${HOLD:-}" ] && kill "$HOLD" 2>/dev/null
    kei_kill_daemons
}

lock_is_free()       { flock -n /var/lock/koha_backup.lock true; }
panel_lock_is_free() { flock -n /var/run/koha_panel.lock true; }

# Starts the restore in its own session (like a terminal), so a signal can
# be sent to its whole process group as the terminal would.
start_restore_bg() {
    setsid "$KEI_SH" "$PANEL" function_restore_database > "$BATS_TEST_TMPDIR/out" 2>&1 &
    BG=$!
}
wait_for() {   # wait_for "condition" [seconds]
    local i
    for i in $(seq 1 $(( ${2:-60} * 4 ))); do eval "$1" && return 0; sleep 0.25; done
    return 1
}
wait_bg() {
    local i
    for i in $(seq 1 480); do kill -0 "$BG" 2>/dev/null || break; sleep 0.25; done
    RC=0; wait "$BG" 2>/dev/null || RC=$?
    BG=""
}
in_live_import() { grep -q "koha-plack --stop" "$KEI_S/calls.log" 2>/dev/null; }

@test "S01 Ctrl+C (SIGINT to the process group) during the live import: restore finishes consistently" {
    start_restore_bg
    assert 'wait_for in_live_import' "restore must reach the live import"
    sleep 1.5
    kill -INT -- "-$BG"
    wait_bg
    assert '[ "$(live_marker)" = "NEW" ] && [ "$(live_biblios)" = "300" ]' "catalog must be complete (got '$(live_marker)' / '$(live_biblios)')"
    assert '[ -e "$KEI_S/run/plack" ]' "Plack must be running again"
    assert 'lock_is_free'
}

@test "S02 SSH connection lost (SIGHUP to the process group) during the live import" {
    start_restore_bg
    assert 'wait_for in_live_import'
    sleep 1.5
    kill -HUP -- "-$BG"
    wait_bg
    assert '[ "$(live_marker)" = "NEW" ] && [ "$(live_biblios)" = "300" ]' "catalog must be complete (got '$(live_marker)')"
    assert '[ -e "$KEI_S/run/plack" ]' "Plack must be running again"
}

@test "S03 SIGTERM to the panel during the live import: services are not left stopped" {
    start_restore_bg
    assert 'wait_for in_live_import'
    sleep 1.5
    kill -TERM "$BG"
    wait_bg
    assert '[ "$(live_marker)" = "NEW" ] && [ "$(live_biblios)" = "300" ]' "catalog must be complete (got '$(live_marker)')"
    assert '[ -e "$KEI_S/run/plack" ]' "Plack must be running again"
}

@test "S04 Ctrl+C during the trial import: production untouched, trial database removed" {
    start_restore_bg
    assert 'wait_for "mysql -e \"USE koha_restore_check\" 2>/dev/null"' "trial import must start"
    sleep 1
    kill -INT -- "-$BG"
    wait_bg
    assert_catalog_untouched
    assert '! mysql -e "USE koha_restore_check" 2>/dev/null' "the trial database must not be left behind"
    assert 'lock_is_free'
}

@test "S05 daemons started by the panel do not keep the panel lock after it exits" {
    panel ensure_koha_services
    assert 'grep -q "koha-plack --start" "$KEI_S/calls.log"' "Plack must have been started"
    assert 'panel_lock_is_free' "a Plack daemon holding the panel lock would block the next 'sudo config.sh'"
}

@test "S06 daemons restarted during a restore do not keep the backup lock" {
    export KEI_SELECT_FILE="$FIX/new.sql.gz"
    panel function_restore_database
    assert '[ "$(live_marker)" = "NEW" ]'
    assert 'lock_is_free' "a daemon holding the backup lock would make every nightly backup skip"
    assert 'panel_lock_is_free'
}

@test "S07 a second panel session is refused while one is open" {
    flock -o /var/run/koha_panel.lock sleep 30 &
    HOLD=$!; sleep 0.5
    panel true
    assert '[ "$status" -ne 0 ]' "second session must be refused"
    assert 'echo "$output" | grep -qi "already running"'
}

@test "S08 restore is refused while a nightly backup holds the backup lock" {
    flock -o /var/lock/koha_backup.lock sleep 30 &
    HOLD=$!; sleep 0.5
    export KEI_SELECT_FILE="$FIX/new.sql.gz"
    panel function_restore_database
    assert_catalog_untouched
    assert 'dialogs | grep -qi "already running"'
}

@test "S09 the nightly SQL backup skips while the panel restores (shared lock)" {
    panel write_backup_scripts
    setsid "$KEI_SH" "$PANEL" eval 'backup_lock_acquire && sleep 5' >/dev/null 2>&1 &
    BG=$!
    sleep 1
    run "$KEI_SH" /root/backup_sql.sh
    assert '[ -z "$(ls /var/backups/koha_sql/*.sql.gz 2>/dev/null)" ]' "no backup may be taken during a restore"
    assert 'grep -q "skipped" /var/log/koha-easy-install/backup_sql.log'
}
