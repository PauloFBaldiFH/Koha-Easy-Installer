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

@test "W05 host_can: everything on Linux, nothing host-level under WSL" {
    local cap
    win_conf 'WIN_NET_MODE=nat'
    for cap in swap ntp timezone firewall fail2ban mdns reboot lan_direct; do
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
    assert 'grep -q "^host_can ntp && { timedatectl set-ntp true" "$KEI_REPO/installer"' "NTP at panel start is guarded"
    assert 'grep -q "host_can mdns && systemctl enable --now avahi-daemon" "$KEI_REPO/installer"'
}

@test "W07 WSL timezone follows Windows unless it reads UTC" {
    printf 'get_current_timezone() { printf "%%s" "$KEI_TZ"; }\napply_timezone() { echo "apply_timezone $1" >> "$KEI_S/calls.log"; }\n' \
        > "$BATS_TEST_TMPDIR/tz.sh"
    export KEI_EXTRA="$BATS_TEST_TMPDIR/tz.sh"
    KEI_TZ=America/Sao_Paulo wsl timezone_follows_host
    assert '[ "$status" -eq 0 ]'
    KEI_TZ=Etc/UTC wsl timezone_follows_host
    assert '[ "$status" -eq 1 ]' "UTC under WSL still asks"
    KEI_TZ=America/Sao_Paulo panel timezone_follows_host
    assert '[ "$status" -eq 1 ]' "Linux always asks"

    KEI_TZ=America/Sao_Paulo wsl function_configure_clock
    assert 'dialogs | grep -q "INFO \[Clock and timezone\].*America/Sao_Paulo"' "$(dialogs)"
    assert '! calls | grep -qE "apply_timezone|timesyncd"' "$(calls)"
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
