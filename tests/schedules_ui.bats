#!/usr/bin/env bats
# Scheduled tasks (nightly cleanup really deleting, e-mail notices handed to
# koha-common through koha-email-enable) and the dialog layer (dark theme,
# geometry, status markers, main menu).

setup() {
    load lib/common
    kei_reset_env
    unset KEI_DEFAULT_ANSWER
}

teardown() {
    kei_kill_daemons
}

# The koha_tasks file written by panels up to 1.1.0.
legacy_tasks() {
    cat > /etc/cron.d/koha_tasks <<'EOF'
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=""
0 23 * * * root /bin/bash /root/backup_sql.sh >/dev/null 2>&1
15 2 * * * root /usr/local/bin/library-custom.sh >/dev/null 2>&1
30 1 * * * root /usr/sbin/koha-shell library -c "/usr/share/koha/bin/cronjobs/cleanup_database.pl --sessions --sessdays 2 --zebraqueue 10" >/dev/null 2>&1

# BEGIN KOHA EMAIL NOTICES
0 8 * * * root /usr/sbin/koha-shell library -c "/usr/share/koha/bin/cronjobs/overdue_notices.pl -v -t" >/dev/null 2>&1
5 8 * * * root /usr/sbin/koha-shell library -c "/usr/share/koha/bin/cronjobs/process_message_queue.pl -v" >/dev/null 2>&1
# END KOHA EMAIL NOTICES
EOF
}
email_on() { [ -e /var/lib/koha/library/email.enabled ]; }

# --- scheduled tasks -----------------------------------------------------------

@test "C01 new schedule: the 01:30 cleanup runs with --confirm and no e-mail jobs are duplicated" {
    panel write_cron_tasks
    local f=/etc/cron.d/koha_tasks
    assert 'grep -q "^30 1 \* \* \* root .*cleanup_database.pl --confirm --sessions --sessdays 2 --zebraqueue 10" $f' "$(cat $f)"
    assert '! grep -qE "overdue_notices|process_message_queue|BEGIN KOHA EMAIL" $f'
    assert 'grep -q "^PATH=" $f && [ "$(stat -c %a $f)" = "644" ]'
    assert 'grep -q "systemctl restart cron" "$KEI_S/calls.log"'
}

@test "C02 koha_email_enable uses koha-email-enable once and reports failures" {
    panel koha_email_enable
    assert '[ "$status" -eq 0 ] && email_on'
    panel koha_email_enable
    assert '[ "$(grep -c "^koha-email-enable library" "$KEI_S/calls.log")" = "1" ]' "already enabled: no second call"
    rm -f /var/lib/koha/library/email.enabled
    touch "$KEI_S/fail/koha-email-enable"
    panel koha_email_enable
    assert '[ "$status" -ne 0 ] && ! email_on'
}

@test "C03 old schedules are upgraded: --confirm added, e-mail block removed only once e-mail is enabled" {
    legacy_tasks
    touch "$KEI_S/fail/koha-email-enable"
    panel upgrade_cron_tasks
    local f=/etc/cron.d/koha_tasks
    assert 'grep -q "cleanup_database.pl --confirm --sessions" $f' "$(cat $f)"
    assert 'grep -q "overdue_notices" $f' "the old e-mail jobs stay while koha-email-enable fails"
    rm -f "$KEI_S/fail/koha-email-enable"
    : > "$KEI_S/calls.log"
    panel upgrade_cron_tasks
    assert '! grep -qE "overdue_notices|process_message_queue|KOHA EMAIL" $f' "$(cat $f)"
    assert 'email_on'
    assert 'grep -q "library-custom.sh" $f && grep -q "backup_sql.sh" $f' "other lines must be kept"
    assert '[ "$(grep -c -- "--confirm" $f)" = "1" ]'
    assert 'grep -q "systemctl restart cron" "$KEI_S/calls.log"'
    : > "$KEI_S/calls.log"
    panel upgrade_cron_tasks
    assert '! grep -q "systemctl restart cron" "$KEI_S/calls.log"' "nothing to do the second time"
}

@test "C04 regenerating the schedule never drops e-mail notices" {
    legacy_tasks
    touch "$KEI_S/fail/koha-email-enable"
    panel write_cron_tasks
    assert 'grep -q "overdue_notices" /etc/cron.d/koha_tasks' "koha-email-enable failed: the old jobs keep sending"
    rm -f "$KEI_S/fail/koha-email-enable"
    panel write_cron_tasks
    assert '! grep -q "overdue_notices" /etc/cron.d/koha_tasks && email_on'
}

@test "C05 e-mail setup enables koha-common's own e-mail jobs" {
    legacy_tasks
    panel function_configure_emails
    assert 'email_on && ! grep -q "overdue_notices" /etc/cron.d/koha_tasks'
    assert 'dialogs | grep -q "koha-email-enable"' "$(dialogs)"
    rm -f /var/lib/koha/library/email.enabled
    touch "$KEI_S/fail/koha-email-enable"
    : > "$KEI_S/dialogs.log"
    panel function_configure_emails
    assert 'dialogs | grep -q "^ERROR"' "$(dialogs)"
}

# --- dialogs -----------------------------------------------------------------------

# layout LINES COLUMNS WHIPTAIL_ARGS...: the arguments ui_layout gives
# whiptail, one per line (setsid: no terminal, so $LINES/$COLUMNS count).
layout() {
    local lines="$1" cols="$2"
    shift 2
    printf '%s\0' "$@" > "$BATS_TEST_TMPDIR/args"
    run setsid -w env LINES="$lines" COLUMNS="$cols" KEI_ARGS="$BATS_TEST_TMPDIR/args" "$KEI_SH" "$PANEL" \
        eval 'mapfile -d "" A < "$KEI_ARGS"; ui_layout "${A[@]}"; printf "%s\n" "${UI_ARGS[@]}"'
}

@test "U01 one geometry: fixed width, height from the text, padded title" {
    layout 40 120 --title "Backup" --msgbox "One line" 30 100
    assert '[ "$output" = "$(printf "%s\n" --title " Backup " --msgbox "One line" 7 74)" ]' "$output"
    layout 40 120 --title "Q" --yesno "a\nb\nc" 5 50
    assert 'echo "$output" | tail -n2 | tr "\n" " " | grep -qx "9 74 "' "$output"
    layout 40 120 --inputbox "Name:" 0 0 "x"
    assert 'echo "$output" | sed -n 3,4p | tr "\n" " " | grep -qx "8 74 "' "$output"
}

@test "U02 small terminals: the box shrinks, gets a scroll bar, menus scroll" {
    local long; long=$(printf 'word %.0s' $(seq 1 400))
    layout 20 60 --title "T" --msgbox "$long" 10 74
    assert 'echo "$output" | grep -qx -- "--scrolltext"' "$output"
    assert 'echo "$output" | tail -n2 | tr "\n" " " | grep -qx "18 58 "' "$output"
    local items=() i
    for i in $(seq 1 30); do items+=("$i" "item $i"); done
    layout 24 80 --menu "Pick:" 0 0 0 "${items[@]}"
    assert 'echo "$output" | sed -n 3,5p | tr "\n" " " | grep -qx "22 74 14 "' "list height must fit the screen: $output"
}

@test "U03 dark theme goes to whiptail only, never to the shell or other programs" {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    printf '#!/bin/bash\necho "COLORS=[$NEWT_COLORS]"\nprintf "ARG=%%s\\n" "$@"\n' > "$BATS_TEST_TMPDIR/bin/whiptail"
    chmod 755 "$BATS_TEST_TMPDIR/bin/whiptail"
    # The real wrapper (the test doubles replace it) and a fake whiptail first in PATH.
    local wrapper='PATH="$FAKEBIN:$PATH"; source <(sed -n "/^whiptail() {/,/^}/p" "$KEI_REPO/installer")'
    run env FAKEBIN="$BATS_TEST_TMPDIR/bin" "$KEI_SH" "$PANEL" eval "$wrapper; whiptail --title T --msgbox hi 5 5; env | grep -c ^NEWT_COLORS= || true"
    assert 'echo "$output" | grep -q "^COLORS=\[.*window=[a-z0-9]*,[a-z0-9]*"' "$output"
    assert 'echo "$output" | grep -q "^ARG=Koha Easy Installer & Manager v"' "back title: $output"
    assert 'echo "$output" | tail -n1 | grep -qx 0' "NEWT_COLORS must not be exported: $output"
    run env NO_COLOR=1 FAKEBIN="$BATS_TEST_TMPDIR/bin" "$KEI_SH" "$PANEL" eval "$wrapper; whiptail --msgbox hi 5 5"
    assert 'echo "$output" | grep -q "actlistbox=black,lightgray"' "NO_COLOR: monochrome: $output"
    assert '! grep -n "^export NEWT_COLORS\|^ *export NEWT_COLORS" "$KEI_REPO/installer"'
}

@test "U04 validation reports use the status markers" {
    panel eval 'v_reset test; { v_ok "fine"; v_warn "careful"; v_fail "broken"; v_info "note"; } >/dev/null; tail -n4 "$VALIDATION_LOG"'
    assert '[ "$output" = "$(printf "✔ fine\n⚠ careful\n✖ broken\n● note")" ]' "$output"
    assert 'grep -q "fail_tag=\"✖ \"" "$KEI_REPO/installer"' "the pre-installation summary must read the same marker"
}

@test "U05 main menu: 17 options, Library tools is option 10" {
    local n
    n=$(sed -n '/^    MAIN_OPT=\$(whiptail/,/3>&1 1>&2 2>&3)/p' "$KEI_REPO/installer" | grep -cE '^ +"[0-9]+" +"\$m[0-9]+"')
    assert '[ "$n" = "17" ]' "got $n"
    assert 'grep -qE "^ +10\) function_library_tools ;;" "$KEI_REPO/installer"'
    assert 'grep -qE "^ +17\) clear; exit 0 ;;" "$KEI_REPO/installer"'
    assert 'grep -q "via option 16 in the panel" "$KEI_REPO/installer"' "the reboot hint must follow the new numbering"
}
