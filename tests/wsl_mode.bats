#!/usr/bin/env bats
# Windows (WSL) mode: platform detection, the capability layer (host_can),
# the Windows handshake file (windows.conf) and the host tasks the panel
# leaves to Windows (swap, NTP, timezone, UFW, Fail2ban, avahi, reboot).

setup() {
    load lib/common
    kei_reset_env
    FAKE="$BATS_TEST_TMPDIR/proc"
    mkdir -p "$FAKE/sys/kernel" "$FAKE/sys/fs/binfmt_misc"
    export KEI_WIN_CONF="$BATS_TEST_TMPDIR/windows.conf"
    export KEI_SYSTEMD_RUNDIR="$BATS_TEST_TMPDIR/systemd-running"
}

teardown() {
    kei_kill_daemons
    kei_start_mariadb
    kei_start_memcached
}

# fake_kernel RELEASE [interop]: a /proc tree for detect_platform.
fake_kernel() {
    printf '%s\n' "$1" > "$FAKE/sys/kernel/osrelease"
    rm -f "$FAKE/sys/fs/binfmt_misc/WSLInterop"*
    [ "${2:-}" = "interop" ] && touch "$FAKE/sys/fs/binfmt_misc/WSLInterop"
    return 0
}
detected() {     # prints "<platform> <network>" as seen by the panel at load time
    KEI_PLATFORM_OVERRIDE=auto KEI_PROC="$FAKE" panel eval 'echo "$KEI_PLATFORM $KEI_WSL_NET"'
}
wsl() { KEI_PLATFORM_OVERRIDE=wsl2 panel "$@"; }
win_conf() {     # win_conf LINE... -> root-owned 0644 handshake file
    printf '%s\n' "$@" > "$KEI_WIN_CONF"
    chown root:root "$KEI_WIN_CONF"
    chmod 644 "$KEI_WIN_CONF"
}
os_release() {
    printf 'PRETTY_NAME="Debian 12"\nID=debian\nVERSION_ID="12"\n' > "$BATS_TEST_TMPDIR/os-release"
}

# --- detection -----------------------------------------------------------------

@test "W01 WSL 2, WSL 1 and plain Linux kernels are told apart" {
    fake_kernel 5.15.167.4-microsoft-standard-WSL2
    detected
    assert '[ "${output%% *}" = "wsl2" ]' "WSL 2 kernel: $output"

    fake_kernel 6.6.36.3-microsoft-standard-WSL2+
    detected
    assert '[ "${output%% *}" = "wsl2" ]' "WSL 2 kernel with local build suffix: $output"

    fake_kernel 6.8.0-custom interop
    detected
    assert '[ "${output%% *}" = "wsl2" ]' "custom kernel with the WSLInterop handler: $output"

    fake_kernel 4.4.0-19041-Microsoft
    detected
    assert '[ "${output%% *}" = "wsl1" ]' "WSL 1 kernel: $output"

    fake_kernel 6.1.0-25-amd64
    detected
    assert '[ "$output" = "linux " ]' "Debian kernel: $output"
}

@test "W02 network mode: windows.conf first, default gateway as the fallback" {
    fake_kernel 5.15.167.4-microsoft-standard-WSL2
    win_conf 'WIN_NET_MODE=mirrored'
    detected
    assert '[ "$output" = "wsl2 mirrored" ]' "$output"
    win_conf 'WIN_NET_MODE=nat'
    detected
    assert '[ "$output" = "wsl2 nat" ]' "$output"

    local gw want
    for gw in "172.24.80.1 nat" "172.16.0.1 nat" "172.31.255.1 nat" "192.168.0.1 mirrored" \
              "10.0.0.1 mirrored" "172.32.0.1 mirrored" "172.15.0.1 mirrored" " unknown"; do
        want="${gw##* }"
        panel _wsl_net_from_gateway "${gw% *}"
        assert '[ "$output" = "$want" ]' "gateway '${gw% *}': got '$output', want '$want'"
    done
}

# --- handshake file -------------------------------------------------------------

@test "W03 windows.conf: whitelisted keys only, never executed" {
    rm -f /tmp/kei-pwned
    printf '\xEF\xBB\xBFKEI_WIN_VERSION=1.0.0\r\n' > "$KEI_WIN_CONF"
    cat >> "$KEI_WIN_CONF" <<'EOF'
# written by KohaEasy.ps1
WIN_BUILD=22631
WIN_NET_MODE=mirrored
WIN_LAN_IP=192.168.0.25
WIN_HOSTNAME=BIBLIOTECA-PC
WIN_USER=maria silva
WIN_BACKUP_DIR=/mnt/c/KohaEasy/Backups
WIN_MEM_GB=4
WIN_AUTOSTART=manual
WIN_EDITION=$(touch /tmp/kei-pwned)
WIN_UPDATED_AT=`touch /tmp/kei-pwned`
WIN_USER2=x; touch /tmp/kei-pwned
PATH=/tmp
KEI_PLATFORM=linux
 WIN_BUILD=1
EOF
    chmod 644 "$KEI_WIN_CONF"
    wsl eval 'for k in $KEI_WIN_KEYS; do printf "%s=%s\n" "$k" "${!k}"; done; echo "PATH=$PATH"; echo "PLATFORM=$KEI_PLATFORM"'
    assert 'echo "$output" | grep -qx "KEI_WIN_VERSION=1.0.0"' "BOM and CRLF are stripped: $output"
    assert 'echo "$output" | grep -qx "WIN_BUILD=22631"' "$output"
    assert 'echo "$output" | grep -qx "WIN_NET_MODE=mirrored"'
    assert 'echo "$output" | grep -qx "WIN_LAN_IP=192.168.0.25"'
    assert 'echo "$output" | grep -qx "WIN_HOSTNAME=BIBLIOTECA-PC"'
    assert 'echo "$output" | grep -qx "WIN_USER=maria silva"'
    assert 'echo "$output" | grep -qx "WIN_BACKUP_DIR=/mnt/c/KohaEasy/Backups"'
    assert 'echo "$output" | grep -qx "WIN_MEM_GB=4"'
    assert 'echo "$output" | grep -qx "WIN_AUTOSTART=manual"' "start mode chosen on Windows: $output"
    assert 'echo "$output" | grep -qx "WIN_EDITION="' "command substitution must not be taken"
    assert 'echo "$output" | grep -qx "WIN_UPDATED_AT="' "backticks must not be taken"
    assert '! echo "$output" | grep -q "^PATH=/tmp$"' "only whitelisted keys may be set"
    assert 'echo "$output" | grep -qx "PLATFORM=wsl2"' "the file cannot change the platform"
    assert '[ ! -e /tmp/kei-pwned ]' "nothing in the file may run"
}

@test "W04 windows.conf: invalid values dropped, unsafe files refused" {
    win_conf 'WIN_NET_MODE=bridged' 'WIN_BUILD=22631a' 'WIN_LAN_IP=192.168.0' \
             'WIN_HOSTNAME=-bad' 'WIN_BACKUP_DIR=/mnt/c/../../etc' 'WIN_USER=../root' 'WIN_AUTOSTART=always' 'WIN_MEM_GB=4'
    wsl eval 'echo "$WIN_NET_MODE|$WIN_BUILD|$WIN_LAN_IP|$WIN_HOSTNAME|$WIN_BACKUP_DIR|$WIN_USER|$WIN_AUTOSTART|$WIN_MEM_GB"'
    assert '[ "$output" = "|||||||4" ]' "only the valid value is kept: $output"

    win_conf 'WIN_BUILD=22631'
    chmod 666 "$KEI_WIN_CONF"
    wsl eval 'read_windows_conf "$KEI_WIN_CONF"; echo "rc=$? build=$WIN_BUILD"'
    assert '[ "$output" = "rc=1 build=" ]' "a world-writable file is refused: $output"

    chmod 644 "$KEI_WIN_CONF"
    chown nobody "$KEI_WIN_CONF"
    wsl eval 'read_windows_conf "$KEI_WIN_CONF"; echo "rc=$? build=$WIN_BUILD"'
    assert '[ "$output" = "rc=1 build=" ]' "a file not owned by root is refused: $output"

    chown root "$KEI_WIN_CONF"
    ln -sfn "$KEI_WIN_CONF" "$BATS_TEST_TMPDIR/link.conf"
    wsl eval 'read_windows_conf "$BATS_TEST_TMPDIR/link.conf"; echo "rc=$? build=$WIN_BUILD"'
    assert '[ "$output" = "rc=1 build=" ]' "a symlink is refused: $output"

    rm -f "$KEI_WIN_CONF"
    wsl eval 'read_windows_conf "$KEI_WIN_CONF"; echo "rc=$?"; host_can swap || echo "still wsl"'
    assert '[ "$output" = "$(printf "rc=1\nstill wsl")" ]' "a missing file is not an error for the panel: $output"
}

# --- capabilities ---------------------------------------------------------------

@test "W05 host_can: everything on Linux, nothing host-level under WSL but the timezone" {
    local cap
    win_conf 'WIN_NET_MODE=nat'
    wsl host_can timezone
    assert '[ "$status" -eq 0 ]' "the zone inside Debian is the panel's to set"
    for cap in swap ntp firewall fail2ban mdns reboot lan_direct; do
        panel host_can "$cap"
        assert '[ "$status" -eq 0 ]' "linux may manage $cap"
        wsl host_can "$cap"
        assert '[ "$status" -eq 1 ]' "WSL (NAT) must leave $cap to Windows"
    done
    win_conf 'WIN_NET_MODE=mirrored'
    wsl host_can lan_direct
    assert '[ "$status" -eq 0 ]' "mirrored networking lets other PCs connect"
    wsl host_can swap
    assert '[ "$status" -eq 1 ]'
    panel host_can swapp
    assert '[ "$status" -eq 2 ]' "a misspelt capability is an error, not a yes"
}

# --- install steps --------------------------------------------------------------

@test "W06 WSL install: no swapfile, no NTP, no UFW, Fail2ban or avahi" {
    cp /etc/fstab "$BATS_TEST_TMPDIR/fstab.before" 2>/dev/null || touch "$BATS_TEST_TMPDIR/fstab.before"
    wsl eval 'install_clock_sync; install_swap; configure_firewall; configure_fail2ban'
    assert '[ "$status" -eq 0 ]' "$output"
    assert '[ ! -e /swapfile ]' "no swapfile under WSL"
    assert 'cmp -s /etc/fstab "$BATS_TEST_TMPDIR/fstab.before" || [ ! -e /etc/fstab ]' "fstab untouched"
    assert '! calls | grep -qE "timesyncd|fail2ban|ufw"' "$(calls)"
    assert 'echo "$output" | grep -q "SWAP managed by Windows"' "$output"
    assert 'echo "$output" | grep -q "Clock kept by Windows"' "$output"

    wsl essential_packages
    assert '! echo "$output" | grep -qxE "ufw|fail2ban|avahi-daemon"' "$output"
    assert 'echo "$output" | grep -qx memcached' "Koha's own packages stay: $output"
    panel essential_packages
    assert 'echo "$output" | grep -qx ufw && echo "$output" | grep -qx fail2ban && echo "$output" | grep -qx avahi-daemon' \
        "Linux keeps the host tools: $output"
    assert 'grep -qF "host_can ntp && { timedatectl set-ntp true" "$KEI_REPO/installer"' "NTP at panel start is guarded"
    assert 'grep -q "host_can mdns && systemctl enable --now avahi-daemon" "$KEI_REPO/installer"'
}

@test "W07 WSL: the timezone is asked in Debian, and a zone other than Windows' outlives WSL restarts" {
    export KEI_WSL_CONF="$BATS_TEST_TMPDIR/wsl.conf"
    printf '# Written by Koha Easy Installer for Windows.\n[boot]\nsystemd=true\n\n[user]\ndefault=maria\n' > "$KEI_WSL_CONF"
    cat > "$BATS_TEST_TMPDIR/tz.sh" <<'EOS'
get_current_timezone() { cat "$KEI_S/tz" 2>/dev/null || printf 'America/Sao_Paulo'; }
timedatectl() { echo "timedatectl $*" >> "$KEI_S/calls.log"; [ "$1" = set-timezone ] && printf '%s' "$2" > "$KEI_S/tz"; return 0; }
choose_timezone() { echo "choose_timezone" >> "$KEI_S/calls.log"; printf '%s' "${KEI_PICK:-$(get_current_timezone)}"; }
EOS
    export KEI_EXTRA="$BATS_TEST_TMPDIR/tz.sh"
    rm -f "$KEI_S/tz"

    # The zone Windows passed on is kept: wsl.conf is not touched.
    wsl function_configure_clock
    assert 'calls | grep -q choose_timezone' "the panel asks under WSL: $(calls)"
    assert '! grep -q "\[time\]" "$KEI_WSL_CONF"' "$(cat "$KEI_WSL_CONF")"

    # Another zone: WSL must stop copying Windows' zone at every start.
    KEI_PICK=America/Manaus wsl function_configure_clock
    assert 'calls | grep -q "timedatectl set-timezone America/Manaus"' "$(calls)"
    assert 'grep -qx "useWindowsTimezone=false" "$KEI_WSL_CONF"' "$(cat "$KEI_WSL_CONF")"
    assert 'grep -qx "default=maria" "$KEI_WSL_CONF" && grep -qx "systemd=true" "$KEI_WSL_CONF"' "the rest of wsl.conf stays"
    assert '[ "$(stat -c %a "$KEI_WSL_CONF")" = 644 ]'

    # Once more: still one [time] section, one key.
    rm -f "$KEI_S/tz"
    KEI_PICK=America/Cuiaba wsl function_configure_clock
    assert '[ "$(grep -c "^\[time\]" "$KEI_WSL_CONF")" = 1 ] && [ "$(grep -c "^useWindowsTimezone" "$KEI_WSL_CONF")" = 1 ]' "$(cat "$KEI_WSL_CONF")"

    # Plain Linux never writes a wsl.conf.
    rm -f "$KEI_WSL_CONF" "$KEI_S/tz"
    KEI_PICK=America/Manaus panel function_configure_clock
    assert '[ ! -e "$KEI_WSL_CONF" ]'
    rm -f "$KEI_S/tz"
}

@test "W12 ini_set_value: sets one key, keeps every other line, adds the section when missing" {
    local f="$BATS_TEST_TMPDIR/x.conf"
    printf '# top\n[boot]\nsystemd=true\n\n[Time]\n  useWindowsTimezone = true\nother=1\n' > "$f"
    panel ini_set_value "$f" time useWindowsTimezone false
    assert '[ "$status" -eq 0 ]' "$output"
    assert '[ "$(cat "$f")" = "$(printf "# top\n[boot]\nsystemd=true\n\n[Time]\nuseWindowsTimezone=false\nother=1")" ]' "$(cat "$f")"
    panel ini_set_value "$f" interop appendWindowsPath false
    assert 'tail -n 3 "$f" | tr "\n" "|" | grep -qx "|\[interop\]|appendWindowsPath=false|"' "$(cat "$f")"
    rm -f "$f"
    panel ini_set_value "$f" time useWindowsTimezone false
    assert '[ "$(cat "$f")" = "$(printf "[time]\nuseWindowsTimezone=false")" ]' "$(cat "$f")"
}

@test "W13 Apache listens on every address on 80 and 8080, single-address lines widened once" {
    local f="$BATS_TEST_TMPDIR/ports.conf"
    export KEI_APACHE_PORTS="$f"
    printf 'Listen 127.0.0.1:80\n\n<IfModule ssl_module>\n\tListen 443\n</IfModule>\n' > "$f"
    panel apache_listen_all
    assert '[ "$(grep -E "^[[:space:]]*Listen" "$f" | tr "\n" "|")" = "Listen 80|Listen 8080|	Listen 443|" ]' "$(cat "$f")"
    panel apache_listen_all
    assert '[ "$(grep -c "^Listen 8080$" "$f")" = 1 ] && [ "$(grep -c "^Listen 80$" "$f")" = 1 ]' "run twice: $(cat "$f")"
    printf '# empty\n' > "$f"
    panel apache_listen_all
    assert 'grep -qx "Listen 80" "$f" && grep -qx "Listen 8080" "$f"' "$(cat "$f")"
    printf 'Listen 192.168.0.5:80\nListen 127.0.0.1:80\nListen [::1]:8080\nListen 0.0.0.0:8080\n' > "$f"
    panel apache_listen_all
    assert '[ "$(tr "\n" "|" < "$f")" = "Listen 80|Listen 8080|" ]' "one Listen per port: $(cat "$f")"
    assert 'grep -q "^    apache_listen_all$" "$KEI_REPO/installer"' "the install step uses it"
}

@test "W14 UTF-8 screens, and plain symbols in the classic Windows console" {
    # No locale at all (as under wsl.exe): the panel switches itself to UTF-8.
    run env -u LANG -u LC_ALL -u LC_CTYPE LANGUAGE= KEI_PLATFORM_OVERRIDE=wsl2 "$KEI_SH" "$PANEL" eval 'locale charmap; echo "plain=$KEI_PLAIN_GLYPHS"'
    assert 'echo "$output" | grep -qx "UTF-8"' "$output"

    # WSL outside Windows Terminal: plain symbols; inside it (WT_SESSION): emoji.
    run env -u WT_SESSION KEI_PLAIN_GLYPHS= KEI_PLATFORM_OVERRIDE=wsl2 "$KEI_SH" "$PANEL" eval 'echo "plain=$KEI_PLAIN_GLYPHS"'
    assert 'echo "$output" | grep -qx "plain=1"' "$output"
    run env WT_SESSION=abc KEI_PLAIN_GLYPHS= KEI_PLATFORM_OVERRIDE=wsl2 "$KEI_SH" "$PANEL" eval 'echo "plain=$KEI_PLAIN_GLYPHS"'
    assert 'echo "$output" | grep -qx "plain=0"' "$output"
    run env -u WT_SESSION KEI_PLAIN_GLYPHS=0 KEI_PLATFORM_OVERRIDE=wsl2 "$KEI_SH" "$PANEL" eval 'echo "plain=$KEI_PLAIN_GLYPHS"'
    assert 'echo "$output" | grep -qx "plain=0"' "the Windows installer's choice wins: $output"
    run env -u WT_SESSION KEI_PLAIN_GLYPHS= KEI_PLATFORM_OVERRIDE=linux "$KEI_SH" "$PANEL" eval 'echo "plain=$KEI_PLAIN_GLYPHS"'
    assert 'echo "$output" | grep -qx "plain=0"' "Linux keeps its symbols: $output"

    # The conversion: icons dropped with their spaces, marks turned into ASCII.
    panel eval 'kei_plain_text "⚙  Install Koha server"; echo "[$REPLY]"; kei_plain_text "✔ ok ● run ⚠ x → y ⇄ z ★ Free ⚙️ set"; echo "[$REPLY]"; kei_plain_text "Ação já é"; echo "[$REPLY]"'
    assert 'echo "$output" | grep -qxF "[Install Koha server]"' "$output"
    assert 'echo "$output" | grep -qxF "[+ ok * run ! x -> y <-> z Free set]"' "$output"
    assert 'echo "$output" | grep -qxF "[Ação já é]"' "accents stay: $output"

    # t() and every dialog argument, a --textbox file through a converted copy.
    printf '✔ good\n✖ bad\n' > "$BATS_TEST_TMPDIR/report.txt"
    KEI_PLAIN_GLYPHS=1 panel eval 'echo "[$(t "✖  Exit")]"; UI_ARGS=(--title "⚠ Warn" --textbox "'"$BATS_TEST_TMPDIR"'/report.txt" 10 40); kei_plain_args; printf "%s|" "${UI_ARGS[@]}"; echo; cat "${UI_ARGS[3]}"'
    assert 'echo "$output" | grep -qxF "[x  Exit]"' "$output"
    assert 'echo "$output" | grep -qF -- "--title|! Warn|--textbox|/tmp/koha_tmp_glyphs."' "$output"
    assert 'echo "$output" | grep -qx "+ good" && echo "$output" | grep -qx "x bad"' "$output"
    assert 'grep -q "✔ good" "$BATS_TEST_TMPDIR/report.txt"' "the original file is untouched"
    rm -f /tmp/koha_tmp_glyphs.*
}

# --- reboot ----------------------------------------------------------------------

@test "W08 WSL: option 16 restarts Koha's services and never reboots" {
    answer yes
    wsl function_reboot_server
    assert '! calls | grep -qE "systemctl (reboot|poweroff)|shutdown"' "$(calls)"
    local order
    order=$(calls | grep -oE "systemctl restart (mariadb|koha-common|apache2)" | awk '{print $3}' | uniq | tr '\n' ' ')
    assert '[ "$order" = "mariadb koha-common apache2 " ]' "restart order: $order"
    assert 'dialogs | grep -q "PROMPT \[Restart Koha services\]"' "$(dialogs)"

    : > "$KEI_S/calls.log"
    wsl reboot_now
    assert '[ "$status" -eq 1 ]'
    assert '! calls | grep -q reboot' "$(calls)"
    assert 'dialogs | grep -q "does not reboot the computer"'

    : > "$KEI_S/calls.log"
    answer no
    panel function_reboot_server
    assert '! calls | grep -q "restart mariadb"' "Linux keeps the reboot prompt: $(calls)"
    assert 'dialogs | grep -q "PROMPT \[Reboot\]"' "$(dialogs)"
    assert 'grep -q "host_can reboot || m16=" "$KEI_REPO/installer"' "menu label follows the platform"
}

# --- systemd and validation -------------------------------------------------------

@test "W09 WSL without systemd as PID 1: only About and Exit are left" {
    rm -rf "$KEI_SYSTEMD_RUNDIR"
    wsl require_systemd
    assert '[ "$status" -eq 1 ]'
    assert 'dialogs | grep -q "systemd=true"' "$(dialogs)"

    : > "$KEI_S/dialogs.log"
    KEI_PLATFORM_OVERRIDE=wsl1 panel require_systemd
    assert '[ "$status" -eq 1 ]'
    assert 'dialogs | grep -q "wsl --set-version"' "$(dialogs)"

    mkdir -p "$KEI_SYSTEMD_RUNDIR"
    wsl require_systemd
    assert '[ "$status" -eq 0 ]'
    rm -rf "$KEI_SYSTEMD_RUNDIR"
    panel require_systemd
    assert '[ "$status" -eq 0 ]' "Linux servers are checked by the pre-installation instead"

    assert 'grep -qE "^        15\|17\) ;;" "$KEI_REPO/installer" && grep -q "require_systemd || continue" "$KEI_REPO/installer"' \
        "the main menu is guarded"
}

@test "W10 validation reports: platform line, systemd, firewall managed by Windows" {
    os_release
    local check='v_reset test; platform_check "$BATS_TEST_TMPDIR/os-release"; validate_ufw; tail -n5 "$VALIDATION_LOG"; echo "OK=$V_OK WARN=$V_WARN FAIL=$V_FAIL"'
    win_conf 'WIN_BUILD=22631' 'WIN_NET_MODE=mirrored'
    mkdir -p "$KEI_SYSTEMD_RUNDIR"
    wsl eval "$check"
    assert 'echo "$output" | grep -q "Windows (WSL 2), build 22631, network: mirrored"' "$output"
    assert 'echo "$output" | grep -q "running as PID 1"'
    assert 'echo "$output" | grep -q "Windows Defender Firewall"'
    assert 'echo "$output" | grep -q "WARN=0 FAIL=0"' "$output"

    rm -rf "$KEI_SYSTEMD_RUNDIR"
    wsl eval "$check"
    assert 'echo "$output" | grep -q "FAIL=1"' "no systemd must fail the pre-installation: $output"

    KEI_PLATFORM_OVERRIDE=wsl1 panel eval "$check"
    assert 'echo "$output" | grep -q "WSL 1"' "$output"
    assert 'echo "$output" | grep -q "FAIL=1"'

    panel eval 'v_reset test; platform_check "$BATS_TEST_TMPDIR/os-release"; echo "OK=$V_OK WARN=$V_WARN FAIL=$V_FAIL"'
    assert '! echo "$output" | grep -q "WSL"' "no Windows line on Linux: $output"
}

@test "W11 WSL: RabbitMQ's STOMP leaves the port range Windows reserves, and Koha follows it" {
    command -v perl >/dev/null || skip "perl needed to hold a port"
    export KEI_RABBITMQ_DIR="$BATS_TEST_TMPDIR/rabbitmq"
    wsl eval 'prepare_wsl_broker; echo "rc=$? port=$(koha_stomp_port)"'
    assert 'echo "$output" | grep -q "rc=0 port=16613"' "$output"
    assert 'grep -qx "stomp.listeners.tcp.1 = 127.0.0.1:16613" "$KEI_RABBITMQ_DIR/rabbitmq.conf"' "$(cat "$KEI_RABBITMQ_DIR/rabbitmq.conf")"
    assert 'grep -q "rabbitmq_stomp" "$KEI_RABBITMQ_DIR/enabled_plugins"' "the listener key is only valid with the plugin enabled"

    # Run again: the port chosen is kept and nothing is duplicated.
    wsl eval 'prepare_wsl_broker; echo "port=$(koha_stomp_port)"'
    assert 'echo "$output" | grep -q "port=16613"' "$output"
    assert '[ "$(grep -c "^stomp.listeners" "$KEI_RABBITMQ_DIR/rabbitmq.conf")" = "1" ]'

    # Something already listens on 16613: the next port is used.
    rm -rf "$KEI_RABBITMQ_DIR"
    perl -MIO::Socket::INET -e '$s = IO::Socket::INET->new(LocalAddr => "127.0.0.1", LocalPort => 16613, Proto => "tcp", Listen => 1, ReuseAddr => 1) or exit 1; sleep 30' &
    local holder=$!
    sleep 1
    wsl eval 'prepare_wsl_broker; echo "port=$(koha_stomp_port)"'
    kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true
    assert 'echo "$output" | grep -q "port=26613"' "$output"

    # Plain Linux: RabbitMQ keeps its own defaults (61613).
    rm -rf "$KEI_RABBITMQ_DIR"
    panel eval 'prepare_wsl_broker; echo "rc=$? port=$(koha_stomp_port)"'
    assert 'echo "$output" | grep -q "rc=0 port=61613"' "$output"
    assert '[ ! -e "$KEI_RABBITMQ_DIR" ]' "nothing written on Linux"
}
