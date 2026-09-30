#!/usr/bin/env bats
# Data safety. The clean-stop guard: the mark a clean stop leaves, the boot
# that does not find it, and the repair after a power cut or a forced
# shutdown (database check, fresh backup, Zebra index brought up to date or
# rebuilt). Also the MariaDB durability settings, the log limits and the
# search index rebuild the Koha window asks for.

GUARD=/usr/local/sbin/koha-stop-guard
STATE=/var/lib/koha-easy-install

setup() {
    load lib/common
    kei_reset_env
    kei_reset_live_catalog
    rm -rf "$STATE" "$GUARD" /etc/systemd/system/koha-stop-guard.service /etc/systemd/system/koha-stop-guard-recover.service \
           "$KEI_S/result" /var/log/koha-easy-install/stop-guard.log /var/log/koha-easy-install/backup_sql.log
    mkdir -p "$KEI_S/result" "$BATS_TEST_TMPDIR/bin"
    # MariaDB really runs in the test container: whether MariaDB or Zebra
    # "still runs" at a stop is decided by this pgrep double instead.
    printf '#!/bin/sh\n[ -e %s/daemons-running ]\n' "$KEI_S" > "$BATS_TEST_TMPDIR/bin/pgrep"
    chmod +x "$BATS_TEST_TMPDIR/bin/pgrep"
    rm -f "$KEI_S/daemons-running"
    export KEI_SYSTEMD_RUNDIR="$BATS_TEST_TMPDIR/systemd-running"
    mkdir -p "$KEI_SYSTEMD_RUNDIR"
    panel install_stop_guard
    assert '[ "$status" -eq 0 ]' "$output"
}

guard() { run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" GUARD_DB_WAIT="${GUARD_DB_WAIT:-300}" "$KEI_SH" "$GUARD" "$@"; }
status_value() { sed -n "s/^$1=//p" "$STATE/recovery.status"; }

@test "G01 the guard and its two units are installed, enabled and ordered around MariaDB" {
    assert 'bash -n "$GUARD"' "generated script must parse"
    assert '[ "$(stat -c %a "$GUARD")" = "755" ]'
    local u=/etc/systemd/system/koha-stop-guard.service r=/etc/systemd/system/koha-stop-guard-recover.service
    assert 'grep -q "^Before=mariadb.service koha-common.service" "$u"' "must stop after MariaDB and Koha at shutdown"
    assert 'grep -q "^ExecStop=-$GUARD stop" "$u" && grep -q "^RemainAfterExit=yes" "$u"'
    assert 'grep -q "^After=koha-stop-guard.service mariadb.service koha-common.service" "$r"'
    assert 'grep -q "^ConditionPathExists=/run/koha-easy-install/unclean-stop" "$r"'
    assert 'grep -q "^Type=exec" "$r"' "the boot must not wait for a reindex"
    assert 'calls | grep -q "systemctl enable koha-stop-guard.service koha-stop-guard-recover.service"'
    assert 'calls | grep -q "systemctl start koha-stop-guard.service"' "started now, so it runs at the next shutdown"
    # Started while Koha already runs: the current boot counts as clean.
    assert '[ -f "$STATE/clean-stop" ]'
}

@test "G02 running the installer again rewrites nothing when nothing changed" {
    local before; before=$(stat -c %Y /etc/systemd/system/koha-stop-guard.service "$GUARD")
    : > "$KEI_S/calls.log"
    sleep 1
    panel install_stop_guard
    assert '[ "$(stat -c %Y /etc/systemd/system/koha-stop-guard.service "$GUARD")" = "$before" ]'
    assert '! calls | grep -q "systemctl enable"'
}

@test "G03 boot: first boot, clean stop, unclean stop, and a repair that never finished" {
    rm -rf "$STATE" /run/koha-easy-install
    guard boot
    assert '[ ! -e /run/koha-easy-install/unclean-stop ]' "the first boot with the guard is not a crash"
    assert '[ -f "$STATE/stop-guard.armed" ]'

    guard stop
    assert '[ "$status" -eq 0 ] && [ -f "$STATE/clean-stop" ]' "$output"
    guard boot
    assert '[ ! -e /run/koha-easy-install/unclean-stop ] && [ ! -e "$STATE/clean-stop" ]' "the mark is used once"

    guard boot
    assert '[ -e /run/koha-easy-install/unclean-stop ]' "no mark: the last stop was not clean"
    assert 'grep -q "boot: the last stop was unclean" /var/log/koha-easy-install/stop-guard.log'

    rm -f /run/koha-easy-install/unclean-stop
    : > "$STATE/clean-stop"
    : > "$STATE/recovery.pending"
    guard boot
    assert '[ -e /run/koha-easy-install/unclean-stop ]' "an unfinished repair is done again"
}

@test "G04 a stop is not marked clean while MariaDB or Zebra runs, or when MariaDB was killed" {
    rm -f "$STATE/clean-stop"
    touch "$KEI_S/daemons-running"
    guard stop
    assert '[ "$status" -ne 0 ] && [ ! -e "$STATE/clean-stop" ]'
    rm -f "$KEI_S/daemons-running"
    echo timeout > "$KEI_S/result/mariadb"
    guard stop
    assert '[ "$status" -ne 0 ] && [ ! -e "$STATE/clean-stop" ]'
    assert 'grep -q "MariaDB.s stop ended with .timeout." /var/log/koha-easy-install/stop-guard.log'
}

@test "G05 repair after an unclean stop: database checked, fresh backup, Zebra index updated" {
    panel write_backup_scripts
    : > "$KEI_S/calls.log"
    guard recover
    assert '[ "$status" -eq 0 ]' "$output"
    assert '[ "$(status_value state)" = done ] && [ "$(status_value db)" = ok ]' "$(cat "$STATE/recovery.status")"
    assert '[ "$(status_value backup)" = ok ]' "$(tail -n 3 /var/log/koha-easy-install/backup_sql.log 2>&1)"
    assert '[ "$(status_value index)" = updated ]'
    assert 'ls /var/backups/koha_sql/koha_library_*.sql.gz >/dev/null' "a new backup must exist"
    assert 'calls | grep -q "koha-rebuild-zebra -v -b -a library"'
    assert '! calls | grep -q "koha-rebuild-zebra -f"' "no full rebuild when the update works"
    assert '[ ! -e "$STATE/recovery.pending" ] && [ ! -e /run/koha-easy-install/recovery.in-progress ]'
}

@test "G06 a failed index update escalates to a full rebuild, and the failure is reported" {
    panel write_backup_scripts
    touch "$KEI_S/fail/koha-rebuild-zebra"
    : > "$KEI_S/calls.log"
    guard recover
    assert 'calls | grep -q "koha-rebuild-zebra -v -b -a library"'
    assert 'calls | grep -q "koha-rebuild-zebra -f -v -b -a library"'
    assert '[ "$(status_value index)" = failed ]'
}

@test "G07 Elasticsearch catalogs skip Zebra; a database that never answers is reported, nothing else runs" {
    kei_reset_live_catalog OLD 50 Elasticsearch
    : > "$KEI_S/calls.log"
    guard recover
    assert '[ "$(status_value index)" = elasticsearch ]'
    assert '! calls | grep -q koha-rebuild-zebra'

    kei_stop_mariadb
    GUARD_DB_WAIT=1 guard recover
    assert '[ "$(status_value db)" = unreachable ] && [ "$(status_value backup)" = skipped ] && [ "$(status_value index)" = skipped ]'
}

@test "G08 --status-json carries the last repair for the Windows notification" {
    panel write_backup_scripts
    guard recover
    panel kei_status_json
    assert 'echo "$output" | python3 -c "import json,sys; r=json.load(sys.stdin)[\"recovery\"]; assert r[\"state\"]==\"done\" and r[\"db\"]==\"ok\" and r[\"epoch\"]>0, r"' "$output"
    rm -f "$STATE/recovery.status"
    panel kei_status_json
    assert 'echo "$output" | python3 -c "import json,sys; r=json.load(sys.stdin)[\"recovery\"]; assert r[\"state\"]==\"none\" and r[\"epoch\"]==0, r"' "$output"
}

@test "G09 data-safety settings: MariaDB durability pinned, journal and panel logs capped, timers on" {
    export KEI_MARIADB_CONF_DIR="$BATS_TEST_TMPDIR/mysql/mariadb.conf.d" KEI_JOURNALD_DIR="$BATS_TEST_TMPDIR/systemd/journald.conf.d" \
           KEI_LOGROTATE_DIR="$BATS_TEST_TMPDIR/logrotate.d"
    mkdir -p "$BATS_TEST_TMPDIR/mysql" "$BATS_TEST_TMPDIR/systemd" "$KEI_LOGROTATE_DIR" "$KEI_S/units"
    touch "$KEI_S/units/logrotate.timer" "$KEI_S/units/fstrim.timer"
    : > "$KEI_S/calls.log"
    panel install_data_safety
    assert '[ "$status" -eq 0 ]' "$output"
    local cnf="$KEI_MARIADB_CONF_DIR/98-koha-durability.cnf"
    assert 'grep -qx "innodb_doublewrite = 1" "$cnf" && grep -qx "innodb_flush_log_at_trx_commit = 1" "$cnf"'
    assert 'grep -qx "innodb_file_per_table = 1" "$cnf" && grep -qx "skip-log-bin" "$cnf"'
    assert '! grep -q "^innodb_flush_method" "$cnf"' "deprecated in MariaDB 11"
    assert '[[ "98-koha-durability.cnf" < "99-koha-tuning.cnf" ]]' "must load before the tuning file"
    assert 'grep -qx "SystemMaxUse=100M" "$KEI_JOURNALD_DIR/00-koha-limits.conf" && grep -qx "MaxRetentionSec=1month" "$KEI_JOURNALD_DIR/00-koha-limits.conf"'
    assert 'grep -q "^/var/log/koha-easy-install/\*.log {" "$KEI_LOGROTATE_DIR/koha-easy-install" && grep -q "compress" "$KEI_LOGROTATE_DIR/koha-easy-install"'
    assert 'calls | grep -q "systemctl enable --now logrotate.timer" && calls | grep -q "systemctl enable --now fstrim.timer"'
    assert 'calls | grep -q "systemctl restart systemd-journald"'
    : > "$KEI_S/calls.log"
    panel install_data_safety
    assert '! calls | grep -q "restart systemd-journald"' "nothing rewritten the second time"
    panel install_boot_ordering
    assert 'grep -q "^After=.*rabbitmq-server.service" /etc/systemd/system/koha-common.service.d/koha-easy-install.conf'
}

@test "G10 validation reports MariaDB's crash-safe settings and the guard" {
    touch "$KEI_S/svc/koha-stop-guard"
    panel eval 'VALIDATION_LOG=/dev/null; v_reset test; validate_mariadb'
    assert 'echo "$output" | grep -q "crash-safe settings on"' "$output"
    assert 'echo "$output" | grep -q "Clean-stop guard: active"' "$output"
    rm -f "$KEI_S/svc/koha-stop-guard"
    panel eval 'VALIDATION_LOG=/dev/null; v_reset test; validate_mariadb'
    assert 'echo "$output" | grep -q "Clean-stop guard: not active"' "$output"
}

@test "G11 --rebuild-search-index rebuilds Zebra from scratch without questions" {
    : > "$KEI_S/calls.log"
    panel kei_rebuild_search_index
    assert '[ "$status" -eq 0 ]' "$output"
    assert 'calls | grep -q "koha-rebuild-zebra -f -v -b -a library"'
    assert '[ ! -e /run/koha-easy-install/maintenance.in-progress ]'
    touch "$KEI_S/fail/koha-rebuild-zebra"
    panel kei_rebuild_search_index
    assert '[ "$status" -eq 1 ]'
}
