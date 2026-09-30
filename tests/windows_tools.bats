#!/usr/bin/env bats
# Read-only commands used by the Windows tools (tray, notifications,
# "Export diagnostics"): config.sh --status-json and --export-diagnostics.

setup() {
    load lib/common
    kei_reset_env
    printf 'kei_http_code() { cat "%s/http-code" 2>/dev/null || echo 000; }\n' "$KEI_S" > "$BATS_TEST_TMPDIR/extra.sh"
    export KEI_EXTRA="$BATS_TEST_TMPDIR/extra.sh"
    rm -f "$KEI_S/http-code" "$LOGS/backup_sql.log"
}

teardown() {
    rm -rf /var/log/apache2/error.log /tmp/koha_tmp_kei_test
    rm -f "$KEI_S/http-code" "$LOGS/backup_sql.log"
    kei_kill_daemons
}

LOGS=/var/log/koha-easy-install

json() {   # json EXPR: evaluates a Python expression on the JSON in $output (j)
    printf '%s' "$output" | python3 -c 'import json,sys; j=json.load(sys.stdin); print('"$1"')'
}

@test "D01 --status-json: one JSON object, overall state from services and the staff page" {
    echo 200 > "$KEI_S/http-code"
    panel kei_status_json
    assert '[ "$status" -eq 0 ]' "$output"
    assert '[ "$(json "j[\"state\"]")" = "degraded" ]' "koha-common is stopped: $output"
    assert '[ "$(json "j[\"services\"][\"mariadb\"]")" = "active" ]' "$output"
    assert '[ "$(json "j[\"http\"][\"staff\"]")" = "200" ]' "$output"

    touch "$KEI_S/svc/koha-common"
    panel kei_status_json
    assert '[ "$(json "j[\"state\"]")" = "ok" ]' "$output"
    echo 000 > "$KEI_S/http-code"
    panel kei_status_json
    assert '[ "$(json "j[\"state\"]")" = "degraded" ]' "services up but the staff page does not answer: $output"

    rm -f "$KEI_S/svc/apache2" "$KEI_S/svc/mariadb" "$KEI_S/svc/koha-common"
    panel kei_status_json
    assert '[ "$(json "j[\"state\"]")" = "stopped" ]' "$output"

    printf 'WIN_AUTOSTART=manual\nWIN_NET_MODE=nat\n' > "$BATS_TEST_TMPDIR/windows.conf"
    chmod 644 "$BATS_TEST_TMPDIR/windows.conf"
    KEI_WIN_CONF="$BATS_TEST_TMPDIR/windows.conf" KEI_PLATFORM_OVERRIDE=wsl2 panel kei_status_json
    assert '[ "$(json "j[\"platform\"]+\" \"+j[\"wsl_net\"]+\" \"+j[\"autostart\"]")" = "wsl2 nat manual" ]' "$output"
}

@test "D02 --status-json: newest nightly backup and the result the backup script logged" {
    panel kei_status_json
    assert '[ "$(json "j[\"backup\"][\"last_result\"]")" = "none" ]' "$output"

    mkdir -p /var/backups/koha_sql "$LOGS"
    head -c 20480 /dev/urandom > /var/backups/koha_sql/koha_library_2026-09-27_23h00.sql.gz
    touch -d '2026-09-27 23:00' /var/backups/koha_sql/koha_library_2026-09-27_23h00.sql.gz
    head -c 30000 /dev/urandom > /var/backups/koha_sql/koha_library_2026-09-28_23h00.sql.gz
    printf '2026-09-28 23:00:05 | OK: /var/backups/koha_sql/koha_library_2026-09-28_23h00.sql.gz (30000 bytes)\n' > "$LOGS/backup_sql.log"
    panel kei_status_json
    assert '[ "$(json "j[\"backup\"][\"last_result\"]")" = "ok" ]' "$output"
    assert '[ "$(json "j[\"backup\"][\"last_file\"]")" = "koha_library_2026-09-28_23h00.sql.gz" ]' "$output"
    assert '[ "$(json "j[\"backup\"][\"last_size\"]")" = "30000" ]' "$output"
    assert '[ "$(json "j[\"backup\"][\"log_epoch\"]")" = "$(date -d "2026-09-28 23:00:05" +%s)" ]' "$output"

    printf '2026-09-29 23:00:02 | FAILED to generate /var/backups/koha_sql/x.sql.gz\n' >> "$LOGS/backup_sql.log"
    panel kei_status_json
    assert '[ "$(json "j[\"backup\"][\"last_result\"]")" = "failed" ]' "$output"
}

@test "D03 JSON strings survive quotes, backslashes and control characters" {
    panel eval 'printf "[%s]" "$(json_str "$(printf "a\"b\\\\c\nd\te\001f é")")"'
    assert '[ "$status" -eq 0 ]' "$output"
    assert '[ "$(json "j[0]")" = "$(printf "a\"b\\\\c\nd\te\001f é")" ]' "$output"
}

@test "D04 read-only commands run next to an open panel and leave its files alone" {
    touch /tmp/koha_tmp_kei_test
    flock /var/run/koha_panel.lock sleep 20 &
    local holder=$! i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        flock -n /var/run/koha_panel.lock true || break
        sleep 0.2
    done
    run bash "$KEI_REPO/installer" --status-json
    assert '[ "$status" -eq 0 ]' "$output"
    assert '[ -n "$(json "j[\"state\"]")" ]' "$output"
    assert '[ -e /tmp/koha_tmp_kei_test ]' "the temporary files of the open panel are kept"

    run bash "$KEI_REPO/installer" < /dev/null
    assert '[ "$status" -eq 1 ] && echo "$output" | grep -q "already running"' "the menu itself still takes the lock: $output"
    pkill -P "$holder" 2>/dev/null || true
    kill "$holder" 2>/dev/null || true
}

@test "D05 redaction: passwords, tokens and keys removed, ordinary lines kept" {
    cat > "$BATS_TEST_TMPDIR/in.txt" << 'EOF'
<pass>KeiTest-Pass_42</pass>
[error] DBI connect failed: password=hunter2 user=koha
{"access_token":"ya29.a0AfB_byC","refresh_token":"1//0gAbCdEfGhIjKlMnOpQrStUv"}
Authorization: Bearer abcdefghijklmnop
remote https://backup:S3cr3t@example.org/dav/
api_key: XYZ123456
DB_PASS='quoted secret'
Timezone: America/Sao_Paulo
apache2-prefork started; token_type=Bearer
EOF
    panel eval 'kei_redact < "$BATS_TEST_TMPDIR/in.txt"'
    assert '[ "$status" -eq 0 ]' "$output"
    local secret
    for secret in KeiTest-Pass_42 hunter2 ya29 1//0gAb abcdefghijklmnop S3cr3t XYZ123456 "quoted secret"; do
        assert '! echo "$output" | grep -qF -- "$secret"' "left in the text: $secret
$output"
    done
    assert 'echo "$output" | grep -qx "Timezone: America/Sao_Paulo"' "$output"
    assert 'echo "$output" | grep -q "^apache2-prefork started"' "$output"
    assert 'echo "$output" | grep -q "user=koha"' "$output"
}

@test "D06 --export-diagnostics: logs and status in a private folder, no configuration or secret" {
    mkdir -p /var/log/apache2 "$LOGS"
    printf '[error] AH00000: login failed for password=KeiTest-Pass_42\n[error] AH00001: something else\n' > /var/log/apache2/error.log
    printf '2026-09-28 23:00:05 | OK: /var/backups/koha_sql/a.sql.gz (30000 bytes)\n' > "$LOGS/backup_sql.log"
    mkdir -p "$BATS_TEST_TMPDIR/out"

    run bash "$KEI_REPO/installer" --export-diagnostics "$BATS_TEST_TMPDIR/out"
    assert '[ "$status" -eq 0 ]' "$output"
    local d="$output"
    assert '[ -d "$d" ] && [ "$(stat -c %a "$d")" = "700" ]' "$d"
    local f
    for f in status.json system.txt services.txt README.txt logs/apache2_error.log logs/koha-easy-install_backup_sql.log; do
        assert '[ -s "$d/$f" ]' "missing $f: $(find "$d" -type f)"
    done
    assert 'python3 -m json.tool "$d/status.json" >/dev/null'
    assert 'grep -q "something else" "$d/logs/apache2_error.log"'
    assert '! grep -rqF "KeiTest-Pass_42" "$d"' "the Koha database password leaked: $(grep -rF KeiTest-Pass_42 "$d")"
    assert '[ -z "$(find "$d" -name "*.xml" -o -name "rclone.conf" -o -name "vision.conf" -o -name "*credentials*")" ]'

    run bash "$KEI_REPO/installer" --export-diagnostics "$BATS_TEST_TMPDIR/nope"
    assert '[ "$status" -eq 2 ] && echo "$output" | grep -q usage' "$output"
}

@test "D07 the handshake written by the Windows scripts is accepted by the panel's parser" {
    command -v pwsh >/dev/null || skip "PowerShell (pwsh) not installed"
    export KEI_PS_ROOT="$BATS_TEST_TMPDIR/KohaEasy" KEI_REPO
    local before
    before=$(cat "$LOGS"/painel-*.log 2>/dev/null | grep -c "windows.conf")
    run pwsh -NoProfile -Command '
        $env:KOHAEASY_ROOT = $env:KEI_PS_ROOT; $env:COMPUTERNAME = "BIBLIOTECA-PC"; $env:USERNAME = "Ana Souza"
        Import-Module "$env:KEI_REPO/windows/KohaEasy.Core.psm1"
        $st = Set-KohaState @{ autostart = "manual" }
        Set-KohaConfig @{ Root = "C:\KohaEasy" }
        [IO.File]::WriteAllText("$env:KEI_PS_ROOT/windows.conf", (New-KohaHandshake -State $st).Replace("`n", "`r`n"), (New-Object Text.UTF8Encoding($true)))'
    assert '[ "$status" -eq 0 ]' "$output"
    chmod 644 "$KEI_PS_ROOT/windows.conf"
    panel eval 'read_windows_conf "$KEI_PS_ROOT/windows.conf"; echo "rc=$? auto=$WIN_AUTOSTART host=$WIN_HOSTNAME user=$WIN_USER net=$WIN_NET_MODE backup=$WIN_BACKUP_DIR"'
    assert 'echo "$output" | grep -qx "rc=0 auto=manual host=BIBLIOTECA-PC user=Ana Souza net=nat backup=/mnt/c/KohaEasy/Backups"' "$output"
    assert '[ "$(cat "$LOGS"/painel-*.log 2>/dev/null | grep -c "windows.conf")" = "$before" ]' "every line accepted: $(grep windows.conf "$LOGS"/painel-*.log | tail -n 5)"
}

@test "D08 PowerShell side (Pester): Start/Stop, notifications, diagnostics, disk watchdog" {
    command -v pwsh >/dev/null || skip "PowerShell (pwsh) not installed"
    export KEI_REPO
    pwsh -NoProfile -Command 'if (-not (Get-Module -ListAvailable Pester | Where-Object { $_.Version.Major -ge 5 })) { exit 1 }' || skip "Pester 5 not installed"
    run pwsh -NoProfile -Command '$c = New-PesterConfiguration; $c.Run.Path = "$env:KEI_REPO/tests/windows"; $c.Run.Exit = $true; $c.Output.Verbosity = "Normal"; Invoke-Pester -Configuration $c'
    assert '[ "$status" -eq 0 ]' "$output"
}
