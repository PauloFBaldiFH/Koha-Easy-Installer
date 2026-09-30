#!/usr/bin/env bats
# Installation screens (tui_* in the installer) and the login banner
# (write_banner): friendly lines instead of the commands' output, the log
# keeps everything, and the banner's walls stay in line in every language.

setup() {
    load lib/common
    LOG="$BATS_TEST_TMPDIR/install.log"
    printf 'TUI_LOG="%s"\n' "$LOG" > "$BATS_TEST_TMPDIR/extra.sh"
    export KEI_EXTRA="$BATS_TEST_TMPDIR/extra.sh"
}

teardown() {
    rm -f /etc/issue.kei-test /etc/motd.kei-test
}

# Display widths (one per line, sorted, unique) of the lines of $1 matching $2.
widths() {
    grep -- "$2" "$1" | while IFS= read -r l; do printf '%s' "$l" | LC_ALL=C.UTF-8 wc -L; done | sort -u
}

@test "U01 tui_run: the command's output goes to the log, the screen gets one line" {
    panel tui_run "Installing things" sh -c 'echo apt-noise; echo err-noise >&2'
    assert '[ "$status" -eq 0 ]' "$output"
    assert '[ "$(printf "%s\n" "$output" | grep -c .)" = "1" ]' "one line expected: $output"
    assert 'echo "$output" | grep -q "Installing things.*\[====================\].*Done!"' "$output"
    assert '! echo "$output" | grep -q noise' "$output"
    assert 'grep -q apt-noise "$LOG" && grep -q err-noise "$LOG"' "$(cat "$LOG")"
}

@test "U02 tui_run: a failing command is marked Failed! and its exit code is returned" {
    panel tui_run "Broken step" sh -c 'exit 7'
    assert '[ "$status" -eq 7 ]' "$output"
    assert 'echo "$output" | grep -q "Broken step.*Failed!"' "$output"
}

@test "U03 tui_run runs the command in the panel's shell (its variables are kept)" {
    panel eval 'setx() { KEPT=yes; }; tui_run "Setting" setx; echo "KEPT=$KEPT"'
    assert 'echo "$output" | grep -q "^KEPT=yes"' "$output"
}

@test "U04 tui_run in a terminal: Pac-Man runs while the command works, cursor restored" {
    run script -qc "TERM=xterm NO_COLOR=1 $KEI_SH $PANEL tui_run Waiting sleep 1" /dev/null
    assert 'echo "$output" | grep -qF "[C··"' "$output"
    assert 'echo "$output" | grep -qF "[ c··"' "the mouth opens and closes: $output"
    assert 'echo "$output" | grep -q "Done!"' "$output"
    assert '[[ "$output" == *$'"'"'\e[?25h'"'"'* ]]' "the cursor must be shown again"
}

@test "U05 tui_progress: percentage, Pac-Man head and grouped counts" {
    panel tui_progress 12500 12500 "Migrating records"
    assert 'echo "$output" | grep -q "100% \[====================\] (12,500 / 12,500)"' "$output"
    # Without a terminal, intermediate values print nothing.
    panel tui_progress 5625 12500 "Migrating records"
    assert '[ -z "$output" ]' "$output"
    run script -qc "TERM=xterm NO_COLOR=1 $KEI_SH $PANEL tui_progress 5625 12500 Records" /dev/null
    assert 'echo "$output" | grep -q "45% \[=========[Cc]··········\] (5,625 / 12,500)"' "$output"
}

@test "U06 the failure card points to the log, shows its last lines and fits 80 columns" {
    printf 'line one\n\nE: Unable to locate package koha-common\n' > "$LOG"
    panel tui_fail_card "Downloading and installing Koha"
    assert 'echo "$output" | grep -q "\"Downloading and installing Koha\""' "$output"
    assert 'echo "$output" | grep -qF "$LOG"' "$output"
    assert 'echo "$output" | grep -q "E: Unable to locate package koha-common"' "$output"
    local longest
    longest=$(printf '%s\n' "$output" | grep -vF "$LOG" | LC_ALL=C.UTF-8 wc -L)
    assert '[ "$longest" -le 80 ]' "card wider than 80 columns ($longest): $output"
}

@test "U07 tui_wrap breaks CJK sentences by characters, never inside a byte sequence" {
    panel eval 'SYS_LANG=ja; tui_wrap "インターネット接続とディスクの空き容量を確認してから、もう一度オプション 1 を実行してください。" 20'
    assert '[ "$status" -eq 0 ]'
    assert '[ "$(printf "%s\n" "$output" | LC_ALL=C.UTF-8 wc -L)" -le 20 ]' "$output"
    assert 'printf "%s" "$output" | iconv -f UTF-8 -t UTF-8 >/dev/null' "invalid UTF-8: $output"
}

@test "U08 the final screen lists the real addresses: tunnel, library network, this computer" {
    printf 'tunnel_public_hosts() { echo "palotina.koha.page palotina-admin.koha.page"; }\n' >> "$KEI_EXTRA"
    panel tui_celebrate 192.168.100.115 0
    assert 'echo "$output" | grep -q "https://palotina.koha.page"' "$output"
    assert 'echo "$output" | grep -q "https://palotina-admin.koha.page"' "$output"
    assert 'echo "$output" | grep -q "http://192.168.100.115:8080"' "$output"
    assert 'echo "$output" | grep -q "http://localhost:8080"' "$output"
    assert 'echo "$output" | grep -q "ready"' "$output"
    # WSL behind NAT: the WSL address is not reachable from other PCs.
    printf 'WIN_NET_MODE=nat\n' > "$BATS_TEST_TMPDIR/windows.conf"
    chmod 644 "$BATS_TEST_TMPDIR/windows.conf"
    KEI_WIN_CONF="$BATS_TEST_TMPDIR/windows.conf" KEI_PLATFORM_OVERRIDE=wsl2 panel tui_celebrate 172.20.1.5 2
    assert '! echo "$output" | grep -q "172.20.1.5"' "$output"
    assert 'echo "$output" | grep -q "http://localhost"' "$output"
    assert 'echo "$output" | grep -q "2 problem"' "$output"
}

@test "U09 banner: walls in line with accents and long lines, ASCII art, at most 80 columns" {
    panel banner_art "PAINEL DE CONTROLE : config.sh" "ACESSO SSH : ssh paulo@192.168.100.115" - \
        "- Usuário (Admin) : koha_library" "- Staff (Nuvem) : https://$(printf 'x%.0s' {1..90}).koha.page"
    printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/art"
    assert '[ "$(widths "$BATS_TEST_TMPDIR/art" "^  |" | wc -l)" = "1" ]' "walls out of line: $output"
    assert '[ "$(widths "$BATS_TEST_TMPDIR/art" "^  __..--" )" = "$(widths "$BATS_TEST_TMPDIR/art" "^  |")" ]' "roof and walls differ: $output"
    assert '[ "$(LC_ALL=C.UTF-8 wc -L < "$BATS_TEST_TMPDIR/art")" -le 80 ]' "$output"
    assert '! grep -q "\\\\" "$BATS_TEST_TMPDIR/art"' "no backslash (agetty escapes)"
    assert 'grep -q "KOHA LIBRARY" "$BATS_TEST_TMPDIR/art" && grep -q "Usuário (Admin) : koha_library" "$BATS_TEST_TMPDIR/art"' "$output"
}

@test "U10 write_banner: the console gets \\S and the art, SSH logins the same art" {
    cp -f /etc/issue /etc/issue.kei-test 2>/dev/null || true
    cp -f /etc/motd /etc/motd.kei-test 2>/dev/null || true
    panel write_banner 192.168.100.115 koha_library
    local issue motd
    issue=$(cat /etc/issue); motd=$(cat /etc/motd)
    [ -f /etc/issue.kei-test ] && mv -f /etc/issue.kei-test /etc/issue
    [ -f /etc/motd.kei-test ] && mv -f /etc/motd.kei-test /etc/motd
    assert '[ "$(printf "%s\n" "$issue" | head -n1)" = "\\S" ]' "$issue"
    assert '[ "$(printf "%s\n" "$issue" | tail -n +2)" = "$motd" ]' "$motd"
    assert 'echo "$motd" | grep -q "http://192.168.100.115:8080"' "$motd"
    printf '%s\n' "$motd" > "$BATS_TEST_TMPDIR/motd"
    assert '[ "$(widths "$BATS_TEST_TMPDIR/motd" "^  |" | wc -l)" = "1" ]' "$motd"
}

@test "U11 a dialog inside a tui_run task is drawn on the terminal and its answer reaches the task" {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    printf '#!/bin/sh\necho "FAKE-DIALOG"\necho "the-answer" >&2\n' > "$BATS_TEST_TMPDIR/bin/whiptail"
    chmod +x "$BATS_TEST_TMPDIR/bin/whiptail"
    # The installer's own whiptail wrapper instead of the battery's recorder.
    cat >> "$KEI_EXTRA" <<X
unset -f whiptail
PATH="$BATS_TEST_TMPDIR/bin:\$PATH"
eval "\$(sed -n '/^whiptail() {/,/^}/p' "$KEI_REPO/installer")"
ask() { echo task-noise; r=\$(whiptail --inputbox "Q" 8 40 3>&1 1>&2 2>&3); echo "got=\$r" > "$BATS_TEST_TMPDIR/answer"; }
X
    run script -qc "TERM=xterm NO_COLOR=1 $KEI_SH $PANEL tui_run Asking ask" /dev/null
    assert 'echo "$output" | grep -q FAKE-DIALOG' "the dialog must reach the terminal: $output"
    assert '! grep -q FAKE-DIALOG "$LOG"' "the dialog must not go to the log: $(cat "$LOG")"
    assert 'grep -q task-noise "$LOG"' "$(cat "$LOG")"
    assert '[ "$(cat "$BATS_TEST_TMPDIR/answer")" = "got=the-answer" ]' "$(cat "$BATS_TEST_TMPDIR/answer" 2>&1)"
    assert 'echo "$output" | grep -q "Done!"' "$output"
}
