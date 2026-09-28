#!/usr/bin/env bats
# Platforms (Debian/Ubuntu releases, amd64/arm64), APT sources, service start
# order, and static quality gates (syntax, ShellCheck, UTF-8, translations).

setup() {
    load lib/common
    kei_reset_env
    unset KEI_ARCH KEI_MACHINE
}

teardown() {
    kei_kill_daemons
    kei_start_mariadb
    kei_start_memcached
}

os_release() {   # os_release ID VERSION_ID [ID_LIKE]
    printf 'PRETTY_NAME="%s %s"\nID=%s\nVERSION_ID="%s"\nID_LIKE="%s"\n' "$1" "$2" "$1" "$2" "${3:-}" > "$BATS_TEST_TMPDIR/os-release"
}
platform() {     # platform ARCH MACHINE -> prints the validation lines
    export KEI_ARCH="$1" KEI_MACHINE="$2"
    panel eval "v_reset test; platform_check '$BATS_TEST_TMPDIR/os-release'; echo \"OK=\$V_OK WARN=\$V_WARN FAIL=\$V_FAIL\""
}

# --- releases x architectures ------------------------------------------------

@test "P01 supported LTS releases on amd64 and arm64 pass the platform check" {
    local rel arch
    for rel in "debian 11" "debian 12" "debian 13" "ubuntu 22.04" "ubuntu 24.04"; do
        for arch in "amd64 x86_64" "arm64 aarch64"; do
            os_release $rel
            platform $arch
            assert 'echo "$output" | grep -q "WARN=0 FAIL=0"' "$rel on $arch: $output"
            assert 'echo "$output" | grep -q "${arch%% *} (${arch##* })"' "architecture must be reported"
        done
    done
}

@test "P02 untested release or architecture is a warning, non-Debian is a failure" {
    os_release ubuntu 20.04 debian
    platform amd64 x86_64
    assert 'echo "$output" | grep -q "WARN=1 FAIL=0"' "Ubuntu 20.04: $output"
    os_release linuxmint 22 "ubuntu debian"
    platform amd64 x86_64
    assert 'echo "$output" | grep -q "WARN=1 FAIL=0"' "Mint: $output"
    os_release debian 12
    platform armhf armv7l
    assert 'echo "$output" | grep -q "WARN=1 FAIL=0"' "armhf: $output"
    os_release fedora 40 ""
    platform amd64 x86_64
    assert 'echo "$output" | grep -q "FAIL=1"' "Fedora: $output"
}

@test "P03 APT sources are pinned to the architecture reported by dpkg" {
    local arch line
    for arch in amd64 arm64; do
        export KEI_ARCH="$arch"
        panel apt_source_line /usr/share/keyrings/koha-keyring.gpg https://debian.koha-community.org/koha stable main
        line="$output"
        assert '[ "$line" = "deb [arch=$arch signed-by=/usr/share/keyrings/koha-keyring.gpg] https://debian.koha-community.org/koha stable main" ]' "got: $line"
    done
    assert '! grep -nE "arch=(amd64|arm64|x86_64|aarch64)" "$KEI_REPO/installer"' "no hard-coded architecture in the installer"
}

@test "P04 Elasticsearch switch is refused on architectures without packages" {
    mysql -e "UPDATE ${DB}.systempreferences SET value='Zebra' WHERE variable='SearchEngine';" 2>/dev/null
    kei_reset_live_catalog
    export KEI_ARCH=armhf
    panel function_toggle_search_engine
    assert '[ "$(live_engine)" = "Zebra" ]'
    assert '! grep -q "apt_install elasticsearch" "$KEI_S/calls.log" 2>/dev/null' "nothing may be installed"
    assert 'dialogs | grep -q "armhf"'
}

# --- service order -------------------------------------------------------------

@test "P05 boot order: MariaDB and Memcached before koha-common, Apache after it" {
    panel install_boot_ordering
    local d=/etc/systemd/system/koha-common.service.d/koha-easy-install.conf
    assert 'grep -q "^After=.*mariadb.service" $d && grep -q "^After=.*memcached.service" $d'
    assert 'grep -q "^Wants=.*mariadb.service" $d'
    assert 'grep -q "^ExecStartPre=-/usr/local/bin/koha-wait-services.sh" $d'
    assert 'grep -q "^After=koha-common.service" /etc/systemd/system/apache2.service.d/koha-easy-install.conf'
    assert 'bash -n /usr/local/bin/koha-wait-services.sh'
}

@test "P06 koha-wait-services.sh returns at once when MariaDB and Memcached answer" {
    panel install_boot_ordering
    run timeout 10 "$KEI_SH" /usr/local/bin/koha-wait-services.sh 5
    assert '[ "$status" -eq 0 ]'
}

@test "P07 koha-wait-services.sh waits for Memcached, but never forever" {
    panel install_boot_ordering
    kei_stop_memcached
    local t0=$SECONDS
    run timeout 20 "$KEI_SH" /usr/local/bin/koha-wait-services.sh 3
    assert '[ "$status" -eq 1 ]' "must report the missing dependency"
    assert '[ $((SECONDS - t0)) -ge 2 ] && [ $((SECONDS - t0)) -lt 15 ]' "must wait about 3 s"
    kei_start_memcached
}

@test "P08 Plack is started only after MariaDB and Memcached answer" {
    panel ensure_koha_services
    assert '[ "$status" -eq 0 ]'
    assert 'grep -q "koha-plack --start" "$KEI_S/calls.log"'
    kei_kill_daemons    # the lock leak of a Plack daemon has its own test (S05)
    kei_stop_mariadb
    : > "$KEI_S/calls.log"; rm -f "$KEI_S/run/plack"
    panel ensure_koha_services
    assert '[ "$status" -ne 0 ]' "must report failure without MariaDB"
    assert '! grep -q "koha-plack --start" "$KEI_S/calls.log"' "Plack must not start without MariaDB"
}

@test "P15 Koha's own view of the cache: a Perl client that does not load is reinstalled" {
    panel koha_cache_state
    assert '[ "$status" -eq 0 ] && [ "$output" = ok ]' "healthy cache: $output"
    touch "$KEI_S/cache-module-broken"
    # The reinstall "fixes" the module, like apt-get install --reinstall would.
    printf 'apt_install() { printf "apt_install %%s\\n" "$*" >> "$KEI_S/calls.log"; rm -f "$KEI_S/cache-module-broken"; }\n' > "$BATS_TEST_TMPDIR/extra.sh"
    : > "$KEI_S/calls.log"
    KEI_EXTRA="$BATS_TEST_TMPDIR/extra.sh" panel ensure_koha_services
    assert '[ "$status" -eq 0 ]' "$output"
    assert 'grep -q "apt_install --reinstall libcache-memcached-fast-safe-perl" "$KEI_S/calls.log"'
    assert '[ "$(grep -c "koha-plack --start" "$KEI_S/calls.log")" -ge 2 ]' "Plack must be restarted after the reinstall"
    kei_kill_daemons
}

@test "P16 a cache Koha cannot use is a failure in the validation and the repair dialog" {
    touch "$KEI_S/cache-module-broken"
    panel koha_cache_state
    assert '[ "$status" -ne 0 ] && [ "$output" = module ]' "$output"
    panel function_repair_services
    assert 'dialogs | grep -q "^ERROR.*Cache::Memcached::Fast::Safe does not load"' "the dialog must name the cause"
    rm -f "$KEI_S/cache-module-broken"
    kei_stop_memcached
    panel koha_cache_state
    assert '[ "$output" = connect ]' "$output"
    kei_start_memcached
    kei_kill_daemons
}

# --- static quality gates ---------------------------------------------------------

@test "P09 scripts parse and pass ShellCheck (warnings)" {
    local f
    for f in installer uninstall.sh tests/run.sh tests/lib/panel.sh tests/mocks/koha-mock tests/mocks/koha-script tests/mocks/systemctl tests/mocks/curl; do
        assert 'bash -n "$KEI_REPO/$f"' "$f must parse"
    done
    command -v shellcheck >/dev/null || skip "shellcheck not installed"
    # SC2034: variables read by t() through ${!name} look unused to ShellCheck.
    run shellcheck -s bash -S warning -e SC2034 "$KEI_REPO/installer" "$KEI_REPO/uninstall.sh" "$KEI_REPO/tests/run.sh"
    assert '[ "$status" -eq 0 ]' "$output"
}

@test "P10 the runtime is pure Bash: no python/perl interpreters called by the panel" {
    # Perl only runs inside Koha's environment (koha-shell / koha_exec), with Koha's libraries.
    assert '! grep -nE "(^|[^-])\b(python3?|perl)\b +(-|<<|\")" "$KEI_REPO/installer" | grep -v "koha-shell\|koha_exec\|hash_script\|sitemap"' "found interpreter calls"
    assert '! grep -nE "(^|[;&|(]|[[:space:]])python3?[[:space:]]" "$KEI_REPO/installer" | grep -v "^[0-9]*: *#"' "no Python run by the panel (package names are fine)"
}

@test "P11 files are UTF-8 and every dictionary line decodes" {
    local f
    for f in "$KEI_REPO/installer" "$KEI_REPO/uninstall.sh" "$KEI_REPO"/README*.md; do
        assert 'iconv -f UTF-8 -t UTF-8 "$f" >/dev/null' "$f must be UTF-8"
    done
    for f in "$KEI_REPO"/lang/*.cache; do
        assert '[ "$(tail -n +2 "$f" | grep -cv "^[A-Za-z0-9+/]*=*|[A-Za-z0-9+/]*=*$")" = "0" ]' "$f has malformed lines"
    done
}

@test "P12 pt-BR translations load and cover the new messages (variables filled in)" {
    export KOHA_PANEL_LANG=pt KOHA_PANEL_LANG_FULL=pt-BR
    panel eval 'echo "N=${#_TRANS_CACHE[@]}"; need_mb=900; free_mb=10; datadir=/var/lib/mysql; t "Not enough free disk space for a safe restore.\n\nNeeded: ~\${need_mb} MB\nFree  : \${free_mb} MB (\${datadir})\n\nNothing was changed."'
    assert 'echo "$output" | grep -qE "N=[0-9]{3}"' "dictionary must load: $output"
    assert 'echo "$output" | grep -q "Espaço livre em disco insuficiente"' "new messages must be translated: $output"
    assert 'echo "$output" | grep -q "~900 MB" && echo "$output" | grep -q "10 MB (/var/lib/mysql)"' "variables must be filled in: $output"
}

@test "P13 translation dictionaries cover every string (i18n_common.py, if available)" {
    command -v python3 >/dev/null || skip "python3 (contributor tool) not installed"
    cd "$KEI_REPO"
    run python3 i18n_common.py
    assert '! echo "$output" | grep -E "faltando +[1-9]|quebradas +[1-9]"' "$output"
}

@test "P14 uninstall.sh removes everything the panel now installs" {
    local f
    for f in /usr/local/bin/koha-zebra-watchdog.sh /usr/local/bin/koha-wait-services.sh apache2.service.d/koha-easy-install.conf /root/koha_patrons_template.csv; do
        assert 'grep -qF "$f" "$KEI_REPO/uninstall.sh"' "uninstall.sh must remove $f"
    done
}
