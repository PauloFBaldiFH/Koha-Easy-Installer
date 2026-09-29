# Koha Easy Installer for Windows: shared logic for the shortcuts, the
# scheduled tasks and the tray (blueprint, part 2).
#   * state.json: what the librarian asked for (desired running/stopped,
#     automatic start) and what was already notified.
#   * Start / Stop / Restart and the automatic start at sign-in (2.5.1).
#   * Status, read from "config.sh --status-json" inside the distro.
#   * Windows notifications for service events and nightly backups.
#   * Diagnostics exported to one .zip for support.
#   * Watchdog for the free space around the distro's virtual disk (ext4.vhdx).
# Windows PowerShell 5.1 compatible (no ??, ternary or &&). UTF-8 with BOM.

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'KohaEasy.Lang.psm1')

$script:Cfg = @{
    Root        = 'C:\KohaEasy'
    Distro      = 'koha'
    OldDistros  = @('KohaEasy')
    TaskPath    = '\KohaEasy\'
    KeepTask    = 'Keep Koha running'
    SignInTask  = 'Start Koha at sign-in'
    NetTask     = 'Koha network'
    FirewallRule = 'Koha (web, local network)'
    WebPorts    = @(80, 8080)
    PanelPath   = '/usr/local/bin/koha-panel'
    StaffUrl    = 'http://localhost:8080/'
    OpacUrl     = 'http://localhost/'
    StartWaitS  = 180
    DiskWarnGB  = 10
    DiskCritGB  = 5
    StaleBackupH = 36
    ToastAppId  = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
}
if ($env:KOHAEASY_ROOT) { $script:Cfg.Root = $env:KOHAEASY_ROOT }

# Set by the tray: notifications fall back to its balloon tips when Windows
# toasts are unavailable.
$script:TrayIcon = $null

function Get-KohaConfig { return $script:Cfg }
function Set-KohaTrayIcon { param($Icon) $script:TrayIcon = $Icon }
function Set-KohaConfig {
    param([hashtable]$Values)
    foreach ($k in $Values.Keys) { $script:Cfg[$k] = $Values[$k] }
}

# ----------------------------------------------------------------------
# Paths, log and state.json
# ----------------------------------------------------------------------
function Get-KohaPath {
    param([ValidateSet('Root', 'Bin', 'Logs', 'Backups', 'State', 'Wsl', 'Lang')][string]$Name)
    $r = $script:Cfg.Root
    switch ($Name) {
        'Root'    { return $r }
        'Bin'     { return [System.IO.Path]::Combine($r, 'bin') }
        'Logs'    { return [System.IO.Path]::Combine($r, 'logs') }
        'Backups' { return [System.IO.Path]::Combine($r, 'Backups') }
        'State'   { return [System.IO.Path]::Combine($r, 'state.json') }
        'Wsl'     { return [System.IO.Path]::Combine($r, 'wsl') }
        'Lang'    { return [System.IO.Path]::Combine($r, 'bin', 'lang') }
    }
}

function Write-KohaLog {
    param([string]$Message, [string]$Name = 'koha')
    try {
        $dir = Get-KohaPath Logs
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $file = Join-Path $dir ('{0}-{1}.log' -f $Name, (Get-Date -Format 'yyyyMMdd'))
        $line = '{0} | {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        Add-Content -LiteralPath $file -Value $line -Encoding UTF8
    } catch { }
}

$script:StateDefaults = [ordered]@{
    desired              = 'running'
    autostart            = 'logon'
    startedAt            = 0
    lastState            = ''
    firstSeen            = 0
    lastBackupLogEpoch   = 0
    lastStaleBackupWarn  = 0
    lastDiskLevel        = 'ok'
    lastDiskWarn         = 0
    notifyBackupOk       = $true
    handshakePending     = $false
}

# state.json as an ordered hashtable, with defaults for missing keys. A
# damaged file is kept aside (state.json.bad) instead of breaking Start/Stop.
function Get-KohaState {
    $state = [ordered]@{}
    foreach ($k in $script:StateDefaults.Keys) { $state[$k] = $script:StateDefaults[$k] }
    $file = Get-KohaPath State
    if (Test-Path -LiteralPath $file) {
        try {
            $json = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $json.PSObject.Properties) { $state[$p.Name] = $p.Value }
        } catch {
            Write-KohaLog "state.json unreadable, kept as state.json.bad: $($_.Exception.Message)"
            Copy-Item -LiteralPath $file -Destination ($file + '.bad') -Force -ErrorAction SilentlyContinue
        }
    }
    if (@('running', 'stopped') -notcontains $state.desired) { $state.desired = 'running' }
    if (@('logon', 'manual') -notcontains $state.autostart) { $state.autostart = 'logon' }
    return $state
}

# Merges $Changes into state.json. Written to a temporary file and moved, so
# a shortcut and the tray writing at the same time never leave half a file.
function Set-KohaState {
    param([Parameter(Mandatory = $true)][hashtable]$Changes)
    $state = Get-KohaState
    foreach ($k in $Changes.Keys) { $state[$k] = $Changes[$k] }
    $file = Get-KohaPath State
    $dir = Split-Path -Parent $file
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = $file + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tmp, ($state | ConvertTo-Json -Depth 5), $utf8)
    Move-Item -LiteralPath $tmp -Destination $file -Force
    return $state
}

function Get-UnixTime { return [int64][Math]::Floor(([DateTimeOffset]::UtcNow).ToUnixTimeSeconds()) }

# ----------------------------------------------------------------------
# WSL
# ----------------------------------------------------------------------
# UTF-8 for this console, both ways, and for text piped into wsl.exe. The
# encoding carries no BOM: [Text.Encoding]::UTF8 in Windows PowerShell 5.1
# would put one in front of every script sent to Debian through stdin.
function Set-KohaUtf8Console {
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    try { & "$env:SystemRoot\System32\chcp.com" 65001 | Out-Null } catch { }
    try { [Console]::OutputEncoding = $utf8 } catch { }
    try { [Console]::InputEncoding = $utf8 } catch { }
    $global:OutputEncoding = $utf8
}

# Windows Terminal (wt.exe), when installed. It draws emoji; the classic
# console has no emoji font and shows them as boxes. KOHAEASY_NO_WT=1 keeps
# everything in the classic console.
function Get-KohaTerminalPath {
    if ($env:KOHAEASY_NO_WT -eq '1') { return $null }
    $c = Get-Command 'wt.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return [string]$c.Source }
    return $null
}

# Runs wsl.exe with UTF-8 output. Returns ExitCode and Output (one string).
function Invoke-KohaWsl {
    param([Parameter(Mandatory = $true)][string[]]$Arguments, [string]$InputText)
    $env:WSL_UTF8 = '1'
    $prev = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
        if ($PSBoundParameters.ContainsKey('InputText')) {
            $out = $InputText | & wsl.exe @Arguments 2>&1
        } else {
            $out = & wsl.exe @Arguments 2>&1
        }
        $code = $LASTEXITCODE
    } finally {
        [Console]::OutputEncoding = $prev
    }
    $text = (@($out) | ForEach-Object { [string]$_ }) -join "`n"
    return [pscustomobject]@{ ExitCode = $code; Output = $text.Replace([string][char]0, '') }
}

# Command inside the distro, as root.
function Invoke-KohaLinux {
    param([Parameter(Mandatory = $true)][string[]]$Command, [string]$InputText)
    $wslArgs = @('-d', $script:Cfg.Distro, '-u', 'root', '--') + $Command
    if ($PSBoundParameters.ContainsKey('InputText')) { return Invoke-KohaWsl -Arguments $wslArgs -InputText $InputText }
    return Invoke-KohaWsl -Arguments $wslArgs
}

# Runs a shell script as root inside the distro. The script crosses into
# Linux through stdin (tee) and runs from a file, so only plain words go on
# wsl.exe's command line: Windows PowerShell 5.1 does not escape the double
# quotes inside a native command's arguments, and "sh -c <script>" arrived
# in Linux cut into pieces. $InputText, when given, is the script's stdin.
function Invoke-KohaLinuxScript {
    param([Parameter(Mandatory = $true)][string]$Script, [string]$InputText)
    $file = '/run/kohaeasy-{0}.sh' -f ([guid]::NewGuid().ToString('N'))
    # "exit $?" ends the script before the CR LF that Windows adds after
    # piped text, which sh would otherwise run as a command.
    $body = ($Script -replace "`r", '') + "`nexit `$?`n"
    $w = Invoke-KohaLinux -Command @('tee', $file) -InputText $body
    if ($w.ExitCode -ne 0) { return $w }
    try {
        if ($PSBoundParameters.ContainsKey('InputText')) { return (Invoke-KohaLinux -Command @('sh', $file) -InputText $InputText) }
        return (Invoke-KohaLinux -Command @('sh', $file))
    } finally {
        Invoke-KohaLinux -Command @('rm', '-f', $file) | Out-Null
    }
}

# Names of the running distros. Never starts one (a status check must not
# turn on a Koha the librarian stopped).
function Get-KohaRunningDistros {
    $r = Invoke-KohaWsl -Arguments @('--list', '--running', '--quiet')
    if ($r.ExitCode -ne 0) { return @() }
    return @($r.Output -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-KohaInstalledDistros {
    $r = Invoke-KohaWsl -Arguments @('--list', '--quiet')
    if ($r.ExitCode -ne 0) { return @() }
    return @($r.Output -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Test-KohaDistroRunning { return (@(Get-KohaRunningDistros) -contains $script:Cfg.Distro) }
function Test-KohaDistroInstalled { return (@(Get-KohaInstalledDistros) -contains $script:Cfg.Distro) }

# ----------------------------------------------------------------------
# Handshake file (/etc/koha-easy-install/windows.conf)
# ----------------------------------------------------------------------
# Keeps only the characters the panel's parser accepts for each key.
function ConvertTo-KohaConfValue {
    param([string]$Value, [int]$Max = 64)
    $v = ([string]$Value) -replace '[^A-Za-z0-9._:/ -]', ''
    $v = $v -replace '\.\.+', '.'
    if ($v.Length -gt $Max) { $v = $v.Substring(0, $Max) }
    return $v.Trim()
}

# Network mode of WSL: mirrored when .wslconfig asks for it on a build that
# supports it (Windows 11 22H2, build 22621+), NAT otherwise.
function Get-KohaNetMode {
    param([int]$Build = [Environment]::OSVersion.Version.Build)
    if (-not $env:USERPROFILE) { return 'nat' }
    $cfg = Join-Path $env:USERPROFILE '.wslconfig'
    if ($Build -ge 22621 -and (Test-Path -LiteralPath $cfg)) {
        if ((Get-Content -LiteralPath $cfg -Raw) -match '(?im)^\s*networkingMode\s*=\s*mirrored\s*$') { return 'mirrored' }
    }
    return 'nat'
}

function Get-KohaLanIp {
    try {
        $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Sort-Object RouteMetric | Select-Object -First 1
        $ip = Get-NetIPAddress -InterfaceIndex $route.ifIndex -AddressFamily IPv4 -ErrorAction Stop | Select-Object -First 1
        return [string]$ip.IPAddress
    } catch { return '' }
}

function New-KohaHandshake {
    param([System.Collections.IDictionary]$State = (Get-KohaState))
    $os = [Environment]::OSVersion.Version
    $edition = ''
    try { $edition = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).EditionID } catch { }
    $memGb = 0
    try { $memGb = [int][Math]::Round((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory / 1GB) } catch { }
    $backup = Get-KohaPath Backups
    $wslBackup = ''
    if ($backup -match '^([A-Za-z]):[\\/](.*)$') { $wslBackup = '/mnt/' + $Matches[1].ToLowerInvariant() + '/' + ($Matches[2] -replace '[\\/]', '/') }
    $lines = @(
        '# Written by KohaEasy.ps1. Read by the panel (read_windows_conf), never executed.'
        'KEI_WIN_VERSION=' + (ConvertTo-KohaConfValue $script:KohaEasyVersion)
        'WIN_BUILD=' + $os.Build
        'WIN_EDITION=' + (ConvertTo-KohaConfValue $edition)
        'WIN_NET_MODE=' + (Get-KohaNetMode -Build $os.Build)
        'WIN_LAN_IP=' + (ConvertTo-KohaConfValue (Get-KohaLanIp))
        'WIN_HOSTNAME=' + (ConvertTo-KohaConfValue $env:COMPUTERNAME 63)
        'WIN_USER=' + (ConvertTo-KohaConfValue $env:USERNAME)
        'WIN_BACKUP_DIR=' + (ConvertTo-KohaConfValue $wslBackup 200)
        'WIN_MEM_GB=' + $memGb
        'WIN_UPDATED_AT=' + (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
        'WIN_AUTOSTART=' + $State.autostart
    )
    # An empty value would be logged as invalid by the panel: leave the key out.
    return (@($lines | Where-Object { $_ -notmatch '^[A-Z_]+=$' }) -join "`n") + "`n"
}

# Writes the handshake through stdin: root-owned, 0644, replaced atomically,
# as read_windows_conf requires. Needs the distro running: when it is not,
# the write waits for the next Start (handshakePending).
function Update-KohaHandshake {
    if (-not (Test-KohaDistroRunning)) {
        Set-KohaState @{ handshakePending = $true } | Out-Null
        return $false
    }
    $script = 'umask 022; d=/etc/koha-easy-install; mkdir -p "$d" && t=$(mktemp "$d/.windows.conf.XXXXXX") && cat > "$t" && chown root:root "$t" && chmod 644 "$t" && mv -f "$t" "$d/windows.conf"'
    $r = Invoke-KohaLinuxScript -Script $script -InputText (New-KohaHandshake)
    if ($r.ExitCode -ne 0) {
        Write-KohaLog "handshake not written: $($r.Output)"
        return $false
    }
    Set-KohaState @{ handshakePending = $false } | Out-Null
    return $true
}

# ----------------------------------------------------------------------
# Status
# ----------------------------------------------------------------------
# Koha's own view of itself (config.sh --status-json), or $null.
function Get-KohaLinuxStatus {
    $r = Invoke-KohaLinux -Command @($script:Cfg.PanelPath, '--status-json')
    if ($r.ExitCode -ne 0) { return $null }
    $line = @($r.Output -split "`n" | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -Last 1)
    if ($line.Count -eq 0) { return $null }
    try { return ($line[0] | ConvertFrom-Json) } catch { return $null }
}

# One-word state for the tray and the Status shortcut:
#   running | starting | not_responding | stopped_by_user | stopped | not_installed
function Resolve-KohaState {
    param($Installed, $Running, $Linux, [System.Collections.IDictionary]$State, [int64]$Now = (Get-UnixTime))
    if (-not $Installed) { return 'not_installed' }
    if (-not $Running) {
        if ($State.desired -eq 'stopped') { return 'stopped_by_user' }
        return 'stopped'
    }
    $recent = ($State.startedAt -gt 0) -and (($Now - [int64]$State.startedAt) -lt $script:Cfg.StartWaitS)
    if ($null -ne $Linux -and $Linux.state -eq 'ok') { return 'running' }
    if ($null -ne $Linux -and $Linux.state -eq 'not_installed') { return 'not_installed' }
    if ($recent) { return 'starting' }
    return 'not_responding'
}

function Get-KohaStatus {
    $state = Get-KohaState
    $installed = Test-KohaDistroInstalled
    $running = $false
    $linux = $null
    if ($installed) { $running = Test-KohaDistroRunning }
    if ($running) { $linux = Get-KohaLinuxStatus }
    return [pscustomobject]@{
        State     = (Resolve-KohaState -Installed $installed -Running $running -Linux $linux -State $state)
        Desired   = $state.desired
        Autostart = $state.autostart
        Linux     = $linux
        CheckedAt = (Get-UnixTime)
    }
}

function Get-KohaStateText {
    param([string]$State)
    switch ($State) {
        'running'         { return (T 'Koha is running') }
        'starting'        { return (T 'Koha is starting...') }
        'not_responding'  { return (T 'Koha is not responding') }
        'stopped_by_user' { return (T 'Koha is stopped (you stopped it)') }
        'stopped'         { return (T 'Koha is stopped') }
        default           { return (T 'Koha is not installed') }
    }
}

# ----------------------------------------------------------------------
# Notifications
# ----------------------------------------------------------------------
# Windows toast (WinRT, Windows PowerShell 5.1). Falls back to the tray's
# balloon tip, and always goes to logs\notifications-*.log.
function Show-KohaNotification {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Text,
        [ValidateSet('info', 'warning', 'error')][string]$Level = 'info'
    )
    Write-KohaLog ("[{0}] {1}: {2}" -f $Level, $Title, $Text) 'notifications'
    try {
        $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $scenario = ''
        if ($Level -eq 'error') { $scenario = ' scenario="reminder"' }
        $xml.LoadXml(('<toast{0}><visual><binding template="ToastGeneric"><text>{1}</text><text>{2}</text></binding></visual></toast>' -f
                $scenario, [Security.SecurityElement]::Escape($Title), [Security.SecurityElement]::Escape($Text)))
        $toast = New-Object Windows.UI.Notifications.ToastNotification $xml
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($script:Cfg.ToastAppId).Show($toast)
        return 'toast'
    } catch {
        if ($null -ne $script:TrayIcon) {
            $icon = [System.Windows.Forms.ToolTipIcon]::Info
            if ($Level -eq 'warning') { $icon = [System.Windows.Forms.ToolTipIcon]::Warning }
            if ($Level -eq 'error') { $icon = [System.Windows.Forms.ToolTipIcon]::Error }
            $script:TrayIcon.ShowBalloonTip(10000, $Title, $Text, $icon)
            return 'balloon'
        }
        return 'log'
    }
}

function Format-KohaSize {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    return ('{0:N0} KB' -f ($Bytes / 1KB))
}

# What to tell the librarian after a status check, and the state.json
# changes that remember it. Pure function: the tray shows the result.
#   $Previous  last state word shown ('' on the first check)
#   $Status    Get-KohaStatus result
#   $Disk      Get-KohaDiskHealth result or $null
function Get-KohaNotifications {
    param([string]$Previous, $Status, $Disk, [System.Collections.IDictionary]$State, [int64]$Now = (Get-UnixTime))
    $out = New-Object System.Collections.ArrayList
    $changes = @{ lastState = $Status.State }
    $cur = $Status.State
    $wanted = ($State.desired -eq 'running')

    # Service events (only while the librarian wants Koha on).
    if ($wanted -and $Previous -and $Previous -ne $cur) {
        if ($cur -eq 'not_responding') {
            [void]$out.Add(@{ Level = 'error'; Title = (T 'Koha is not responding'); Text = (T 'The library system stopped answering. Use Restart Koha in the tray menu; if it happens again, export the diagnostics for support.') })
        } elseif ($cur -eq 'stopped' -and @('running', 'starting') -contains $Previous) {
            [void]$out.Add(@{ Level = 'error'; Title = (T 'Koha stopped unexpectedly'); Text = (T 'Koha was turned off without Stop Koha. It will be started again automatically.') })
        } elseif ($cur -eq 'running' -and @('not_responding', 'stopped') -contains $Previous) {
            [void]$out.Add(@{ Level = 'info'; Title = (T 'Koha is working again'); Text = (T 'The staff interface and the catalog are answering again.') })
        }
    }

    # Nightly backup: one notification per new line of backup_sql.log.
    if ($null -ne $Status.Linux -and $null -ne $Status.Linux.backup) {
        $b = $Status.Linux.backup
        if ([int64]$b.log_epoch -gt [int64]$State.lastBackupLogEpoch) {
            $changes.lastBackupLogEpoch = [int64]$b.log_epoch
            if ($State.lastBackupLogEpoch -gt 0 -or ($Now - [int64]$b.log_epoch) -lt 86400) {
                if ($b.last_result -eq 'ok' -and $State.notifyBackupOk) {
                    [void]$out.Add(@{ Level = 'info'; Title = (T 'Backup completed'); Text = ((T 'The nightly backup of the catalog was saved ({0}).') -f (Format-KohaSize ([double]$b.last_size))) })
                } elseif ($b.last_result -eq 'failed') {
                    [void]$out.Add(@{ Level = 'error'; Title = (T 'Backup FAILED'); Text = (T 'The nightly backup of the catalog failed. Open the tray menu and export the diagnostics for support.') })
                }
            }
        }
        # No good backup for too long (in manual mode Koha may be off at 23:00).
        # Counted from the first time Koha was seen, so a new install is not warned.
        $limit = $script:Cfg.StaleBackupH * 3600
        $first = [int64]$State.firstSeen
        if ($first -le 0) { $first = $Now; $changes.firstSeen = $Now }
        $age = $Now - [int64]$b.last_epoch
        if ($Status.Linux.koha_installed -and $age -gt $limit -and ($Now - $first) -gt $limit -and ($Now - [int64]$State.lastStaleBackupWarn) -gt 86400) {
            $changes.lastStaleBackupWarn = $Now
            $text = T 'There is no recent backup of the catalog. Use Control panel > Manual backup, or keep Koha on at 23:00.'
            if ($State.autostart -eq 'manual') {
                $text = T 'There is no recent backup of the catalog. Koha starts only when you click Koha - Start, and the nightly backup runs at 23:00 only while Koha is on.'
            }
            [void]$out.Add(@{ Level = 'warning'; Title = (T 'No recent backup'); Text = $text })
        }
    }

    # Disk space: on every level change, and a critical level again every 6 hours.
    if ($null -ne $Disk) {
        $changes.lastDiskLevel = $Disk.Level
        $again = ($Disk.Level -eq 'critical') -and (($Now - [int64]$State.lastDiskWarn) -gt 21600)
        if ($Disk.Level -ne 'ok' -and ($Disk.Level -ne $State.lastDiskLevel -or $again)) {
            $changes.lastDiskWarn = $Now
            $title = T 'Disk space is low'
            if ($Disk.Level -eq 'critical') { $title = T 'Disk space is critically low' }
            [void]$out.Add(@{ Level = $(if ($Disk.Level -eq 'critical') { 'error' } else { 'warning' }); Title = $title; Text = $Disk.Message })
        }
    }
    return [pscustomobject]@{ Notifications = @($out); Changes = $changes }
}

# ----------------------------------------------------------------------
# Virtual disk watchdog
# ----------------------------------------------------------------------
# WSL's registration of a distro (HKCU\...\Lxss\{guid}): PSPath, Name,
# BasePath (its folder) and, on recent WSL, ShortcutPath and
# TerminalProfilePath. $null when WSL does not know the name.
function Get-KohaLxssEntry {
    param([string]$Name = $script:Cfg.Distro)
    $lxss = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    if (-not (Test-Path $lxss)) { return $null }
    foreach ($k in Get-ChildItem $lxss -ErrorAction SilentlyContinue) {
        $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
        if ($null -eq $p -or -not $p.PSObject.Properties['DistributionName'] -or $p.DistributionName -ne $Name) { continue }
        $e = [ordered]@{ PSPath = $k.PSPath; Name = [string]$p.DistributionName; BasePath = ''; ShortcutPath = ''; TerminalProfilePath = '' }
        foreach ($v in 'BasePath', 'ShortcutPath', 'TerminalProfilePath') {
            if ($p.PSObject.Properties[$v]) { $e[$v] = ([string]$p.$v) -replace '^\\\\\?\\', '' }
        }
        return [pscustomobject]$e
    }
    return $null
}

# Folder of the distro (BasePath in HKCU\...\Lxss) and its ext4.vhdx.
function Get-KohaVhdxPath {
    $e = Get-KohaLxssEntry
    if ($null -eq $e -or -not $e.BasePath) { return $null }
    $file = Join-Path $e.BasePath 'ext4.vhdx'
    if (Test-Path -LiteralPath $file) { return $file }
    return $null
}

# Level from the numbers alone (pure, tested):
#   HostFree/HostTotal  the Windows drive that holds ext4.vhdx
#   VhdxSize            the file today (it grows, it does not shrink by itself)
#   LinuxUsed/LinuxTotal  "df /" inside the distro, 0 when unknown
function Measure-KohaDiskLevel {
    param([double]$HostFree, [double]$HostTotal, [double]$VhdxSize, [double]$LinuxUsed, [double]$LinuxTotal)
    $level = 'ok'
    $msgs = New-Object System.Collections.ArrayList
    $warn = $script:Cfg.DiskWarnGB * 1GB
    $crit = $script:Cfg.DiskCritGB * 1GB
    if ($HostTotal -gt 0) {
        if ($HostFree -lt $crit) {
            $level = 'critical'
        } elseif ($HostFree -lt $warn) {
            $level = 'warning'
        }
        if ($level -ne 'ok') {
            [void]$msgs.Add(((T 'Only {0} free on the Windows drive that holds Koha. When it is full, Koha and its backups stop working.') -f (Format-KohaSize $HostFree)))
        }
    }
    if ($LinuxTotal -gt 0) {
        $pct = $LinuxUsed / $LinuxTotal
        if ($pct -ge 0.95) { $level = 'critical' } elseif ($pct -ge 0.90 -and $level -eq 'ok') { $level = 'warning' }
        if ($pct -ge 0.90) { [void]$msgs.Add(((T 'The Koha disk is {0}% full.') -f [int]($pct * 100))) }
    }
    $reclaim = 0
    if ($VhdxSize -gt 0 -and $LinuxTotal -gt 0) {
        $reclaim = [Math]::Max([double]0, $VhdxSize - $LinuxUsed)
        if ($reclaim -gt 10GB -and $reclaim -gt ($VhdxSize * 0.3) -and $level -ne 'ok') {
            [void]$msgs.Add(((T 'About {0} can be given back to Windows: tray menu > Check disk space > Compact.') -f (Format-KohaSize $reclaim)))
        }
    }
    return [pscustomobject]@{ Level = $level; Message = ($msgs -join ' '); Reclaimable = $reclaim }
}

function Get-KohaDiskHealth {
    param($Linux)
    $vhdx = Get-KohaVhdxPath
    $size = 0
    $drive = (Get-KohaPath Root).Substring(0, 2)
    if ($vhdx) {
        $size = (Get-Item -LiteralPath $vhdx).Length
        $drive = $vhdx.Substring(0, 2)
    }
    $free = 0; $total = 0
    try {
        $di = New-Object System.IO.DriveInfo($drive)
        $free = $di.AvailableFreeSpace; $total = $di.TotalSize
    } catch { }
    $lUsed = 0; $lTotal = 0
    if ($null -ne $Linux -and $null -ne $Linux.disk) {
        $lTotal = [double]$Linux.disk.total
        $lUsed = $lTotal - [double]$Linux.disk.free
    }
    $m = Measure-KohaDiskLevel -HostFree $free -HostTotal $total -VhdxSize $size -LinuxUsed $lUsed -LinuxTotal $lTotal
    return [pscustomobject]@{
        Level = $m.Level; Message = $m.Message; Reclaimable = $m.Reclaimable
        Vhdx = $vhdx; VhdxSize = $size; Drive = $drive; HostFree = $free; HostTotal = $total
        LinuxUsed = $lUsed; LinuxTotal = $lTotal
    }
}

function Test-KohaAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Gives the unused space of ext4.vhdx back to Windows: fstrim inside Linux,
# "wsl --shutdown" (the disk must be detached; this also stops any other WSL
# distro), diskpart "compact vdisk", then Koha is started again if it was
# meant to run. Needs administrator rights (diskpart). [verify] on real WSL.
function Invoke-KohaDiskCompact {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()
    $vhdx = Get-KohaVhdxPath
    if (-not $vhdx) { throw (T 'The Koha virtual disk (ext4.vhdx) was not found.') }
    if (-not (Test-KohaAdmin)) { throw (T 'Compacting the disk needs administrator rights.') }
    $state = Get-KohaState
    $before = (Get-Item -LiteralPath $vhdx).Length
    if (-not $PSCmdlet.ShouldProcess($vhdx, 'compact')) { return }
    if (Test-KohaDistroRunning) { Invoke-KohaLinux -Command @('fstrim', '-av') | Out-Null }
    Stop-KohaKeepAlive
    Invoke-KohaWsl -Arguments @('--shutdown') | Out-Null
    $script = @(
        ('select vdisk file="{0}"' -f $vhdx)
        'attach vdisk readonly'
        'compact vdisk'
        'detach vdisk'
    ) -join "`r`n"
    $tmp = Join-Path $env:TEMP ('kohaeasy-compact-{0}.txt' -f [guid]::NewGuid().ToString('N'))
    Set-Content -LiteralPath $tmp -Value $script -Encoding ASCII
    try {
        $out = Invoke-KohaDiskpart -ScriptFile $tmp
        Write-KohaLog "compact: $out"
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
    if ($state.desired -eq 'running') { Start-KohaKeepAlive }
    $after = (Get-Item -LiteralPath $vhdx).Length
    return [pscustomobject]@{ Before = $before; After = $after; Freed = [Math]::Max([double]0, [double]($before - $after)) }
}

function Invoke-KohaDiskpart {
    param([string]$ScriptFile)
    return ((& diskpart.exe /s $ScriptFile 2>&1) -join "`n")
}

# ----------------------------------------------------------------------
# Start, Stop and automatic start (blueprint 2.5.1)
# ----------------------------------------------------------------------
# Two tasks of the user (no administrator rights, no stored password):
#   "Keep Koha running"      action Run: holds the distro open; triggers on
#                            unlock and on resume only repair a Koha meant to run.
#   "Start Koha at sign-in"  action Start -Trigger logon; enabled only in
#                            "logon" mode.
function Get-KohaScriptPath { return [System.IO.Path]::Combine((Get-KohaPath Bin), 'KohaEasy.ps1') }

function New-KohaAction {
    param([string]$Arguments)
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arg = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" {1}' -f (Get-KohaScriptPath), $Arguments
    return New-ScheduledTaskAction -Execute $ps -Argument $arg
}

function Register-KohaTasks {
    param([ValidateSet('logon', 'manual')][string]$Autostart = (Get-KohaState).autostart)
    $user = '{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $keepSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -Hidden
    $ns = 'Root/Microsoft/Windows/TaskScheduler'
    $unlock = New-CimInstance -CimClass (Get-CimClass -Namespace $ns -ClassName MSFT_TaskSessionStateChangeTrigger) -ClientOnly -Property @{ StateChange = 8; UserId = $user }
    $resume = New-CimInstance -CimClass (Get-CimClass -Namespace $ns -ClassName MSFT_TaskEventTrigger) -ClientOnly -Property @{
        Subscription = '<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[Provider[@Name=''Microsoft-Windows-Power-Troubleshooter''] and EventID=1]]</Select></Query></QueryList>'
    }
    Register-ScheduledTask -TaskPath $script:Cfg.TaskPath -TaskName $script:Cfg.KeepTask -Action (New-KohaAction 'Run') `
        -Trigger @($unlock, $resume) -Principal $principal -Settings $keepSettings -Force | Out-Null

    $signSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -Hidden
    $logon = New-ScheduledTaskTrigger -AtLogOn -User $user
    Register-ScheduledTask -TaskPath $script:Cfg.TaskPath -TaskName $script:Cfg.SignInTask -Action (New-KohaAction 'Start -Trigger logon') `
        -Trigger $logon -Principal $principal -Settings $signSettings -Force | Out-Null
    Set-KohaAutostart -Mode $Autostart | Out-Null
}

function Set-KohaSignInTask {
    param([bool]$Enabled)
    if ($Enabled) {
        Enable-ScheduledTask -TaskPath $script:Cfg.TaskPath -TaskName $script:Cfg.SignInTask | Out-Null
    } else {
        Disable-ScheduledTask -TaskPath $script:Cfg.TaskPath -TaskName $script:Cfg.SignInTask | Out-Null
    }
}
function Start-KohaKeepAlive { Start-ScheduledTask -TaskPath $script:Cfg.TaskPath -TaskName $script:Cfg.KeepTask }
function Stop-KohaKeepAlive {
    Stop-ScheduledTask -TaskPath $script:Cfg.TaskPath -TaskName $script:Cfg.KeepTask -ErrorAction SilentlyContinue
}

# "Start Koha automatically when I sign in to Windows": Yes (logon) / No (manual).
# Changes only the sign-in task and the saved choice; never stops a running Koha.
function Set-KohaAutostart {
    param([Parameter(Mandatory = $true)][ValidateSet('logon', 'manual')][string]$Mode)
    Set-KohaSignInTask -Enabled ($Mode -eq 'logon')
    Set-KohaState @{ autostart = $Mode } | Out-Null
    Update-KohaHandshake | Out-Null
    Write-KohaLog "autostart set to $Mode"
    return $Mode
}

# Waits until the staff interface answers (any HTTP status below 500).
function Wait-KohaHttp {
    param([int]$Seconds = $script:Cfg.StartWaitS, [scriptblock]$OnTick)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-WebRequest -Uri $script:Cfg.StaffUrl -UseBasicParsing -TimeoutSec 5 -MaximumRedirection 0 -ErrorAction Stop
            if ([int]$r.StatusCode -lt 500) { return $true }
        } catch {
            $resp = $null
            if ($_.Exception.PSObject.Properties['Response']) { $resp = $_.Exception.Response }
            if ($null -ne $resp -and [int]$resp.StatusCode -lt 500) { return $true }
        }
        if ($OnTick) { & $OnTick }
        Start-Sleep -Seconds 3
    }
    return $false
}

# KohaEasy.ps1 Start [-Trigger user|logon]
#   user   the Koha - Start shortcut or the tray: always starts
#   logon  the sign-in task: starts only in "logon" mode
function Start-Koha {
    param([ValidateSet('user', 'logon')][string]$Trigger = 'user', [switch]$Wait)
    $state = Get-KohaState
    if ($Trigger -eq 'logon' -and $state.autostart -ne 'logon') {
        Write-KohaLog 'sign-in: automatic start is off, nothing started'
        return 'skipped'
    }
    Set-KohaState @{ desired = 'running'; startedAt = (Get-UnixTime) } | Out-Null
    Start-KohaKeepAlive
    Write-KohaLog "start requested ($Trigger)"
    if (-not $Wait) { return 'started' }
    if (Wait-KohaHttp) { return 'ready' }
    return 'timeout'
}

# KohaEasy.ps1 Stop: desired=stopped first, so the keep-alive task's
# restart-on-failure does not bring Koha back a minute later.
function Stop-Koha {
    Set-KohaState @{ desired = 'stopped'; startedAt = 0 } | Out-Null
    Stop-KohaKeepAlive
    Invoke-KohaWsl -Arguments @('--terminate', $script:Cfg.Distro) | Out-Null
    Write-KohaLog 'stopped by the user'
    return 'stopped'
}

# The keep-alive task's action. Exits at once when Koha is meant to be off
# (Stop pressed, or an unlock/resume trigger while it was off). Otherwise it
# refreshes the handshake, starts the holder that keeps the distro alive and
# waits on it; a holder that dies ends the task with an error, and the task
# setting restarts it one minute later.
function Invoke-KohaRun {
    param([scriptblock]$Holder)
    $state = Get-KohaState
    if ($state.desired -ne 'running') {
        Write-KohaLog 'keep-alive: Koha is meant to be stopped, exiting'
        return 0
    }
    if (-not $Holder) {
        $Holder = {
            $p = Start-Process -FilePath 'wsl.exe' -ArgumentList @('-d', $script:Cfg.Distro, '-u', 'root', '--exec', '/bin/sleep', 'infinity') -WindowStyle Hidden -PassThru
            return $p
        }
    }
    $proc = & $Holder
    Start-Sleep -Seconds 2
    Update-KohaHandshake | Out-Null
    Start-KohaNetworkTask | Out-Null
    if (-not (Wait-KohaHttp)) {
        Write-KohaLog 'keep-alive: the staff interface did not answer in time' 'health'
        Show-KohaNotification -Title (T 'Koha did not start') -Text (T 'Koha did not start. Open Koha - Status, or export the diagnostics from the tray menu.') -Level error | Out-Null
    }
    $proc.WaitForExit()
    if ((Get-KohaState).desired -ne 'running') { return 0 }
    Write-KohaLog "keep-alive: the WSL holder ended (exit $($proc.ExitCode)); the task will restart it"
    return 1
}

# ----------------------------------------------------------------------
# Other PCs of the library network (ports 80 and 8080)
# ----------------------------------------------------------------------
# Apache inside Debian listens on every address. What Windows adds, once,
# with administrator rights (KohaEasy.ps1 SetupNetwork):
#   * a firewall rule for TCP 80 and 8080 from the local network only;
#   * mirrored networking (Windows 11): the same ports opened in the Hyper-V
#     firewall that WSL uses;
#   * NAT networking (Windows 10): a task "Koha network" that runs with the
#     user's highest rights and points netsh portproxy at Debian's address,
#     which changes at every start of WSL. Invoke-KohaRun starts it.
$script:WslVmCreatorId = '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'

# Debian's IPv4 address in WSL's NAT network, or '' (never starts the distro).
function Get-KohaWslIp {
    if (-not (Test-KohaDistroRunning)) { return '' }
    $r = Invoke-KohaLinux -Command @('hostname', '-I')
    if ($r.ExitCode -ne 0) { return '' }
    foreach ($ip in ($r.Output -split '\s+')) {
        if (Test-KohaIPv4 $ip) { return $ip }
    }
    return ''
}

function Test-KohaIPv4 {
    param([string]$Address)
    if ($Address -notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$') { return $false }
    foreach ($i in 1..4) { if ([int]$Matches[$i] -gt 255) { return $false } }
    return $true
}

# Pure: the netsh commands that point ports 80 and 8080 of every Windows
# address at Debian (delete first, so a changed address never stacks up).
function Get-KohaPortProxyCommands {
    param([Parameter(Mandatory = $true)][string]$WslIp, [int[]]$Ports = $script:Cfg.WebPorts)
    $cmds = New-Object System.Collections.ArrayList
    foreach ($port in $Ports) {
        [void]$cmds.Add(@('interface', 'portproxy', 'delete', 'v4tov4', ('listenport={0}' -f $port), 'listenaddress=0.0.0.0'))
        [void]$cmds.Add(@('interface', 'portproxy', 'add', 'v4tov4', ('listenport={0}' -f $port), 'listenaddress=0.0.0.0', ('connectport={0}' -f $port), ('connectaddress={0}' -f $WslIp)))
    }
    return @($cmds)
}

# KohaEasy.ps1 UpdatePortProxy: the action of the "Koha network" task.
function Update-KohaPortProxy {
    param([string]$WslIp)
    if ((Get-KohaNetMode) -ne 'nat') { return 'mirrored' }
    if (-not $WslIp) { $WslIp = Get-KohaWslIp }
    if (-not (Test-KohaIPv4 $WslIp)) {
        Write-KohaLog 'network: Debian has no address yet, port forwarding not changed' 'network'
        return 'no-address'
    }
    foreach ($c in Get-KohaPortProxyCommands -WslIp $WslIp) {
        $out = & netsh.exe @c 2>&1
        if ($LASTEXITCODE -ne 0 -and $c[2] -eq 'add') {
            Write-KohaLog ('network: netsh {0} failed: {1}' -f ($c -join ' '), (@($out) -join ' ')) 'network'
            return 'failed'
        }
    }
    Write-KohaLog ('network: ports {0} forwarded to {1}' -f ($script:Cfg.WebPorts -join ', '), $WslIp) 'network'
    return 'forwarded'
}

# KohaEasy.ps1 SetupNetwork (administrator): firewall rules and, under NAT,
# the "Koha network" task. Safe to run again.
function Set-KohaLanAccess {
    param([string]$Mode = (Get-KohaNetMode))
    $name = $script:Cfg.FirewallRule
    Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName $name -Group 'Koha' -Direction Inbound -Action Allow -Protocol TCP `
        -LocalPort $script:Cfg.WebPorts -RemoteAddress LocalSubnet -Profile Any | Out-Null
    if ($Mode -eq 'mirrored') {
        try {
            Get-NetFirewallHyperVRule -Name 'KohaWeb' -ErrorAction SilentlyContinue | Remove-NetFirewallHyperVRule -ErrorAction SilentlyContinue
            New-NetFirewallHyperVRule -Name 'KohaWeb' -DisplayName $name -Direction Inbound -VMCreatorId $script:WslVmCreatorId `
                -Protocol TCP -LocalPorts $script:Cfg.WebPorts -Action Allow | Out-Null
        } catch {
            Write-KohaLog ('network: Hyper-V firewall rule not added: ' + $_.Exception.Message) 'network'
        }
    } else {
        $user = '{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -Hidden
        Register-ScheduledTask -TaskPath $script:Cfg.TaskPath -TaskName $script:Cfg.NetTask -Action (New-KohaAction 'UpdatePortProxy') `
            -Principal $principal -Settings $settings -Force | Out-Null
    }
    Write-KohaLog ('network: local network access set up ({0})' -f $Mode) 'network'
    return $Mode
}

# After each start under NAT: the task refreshes the forwarding with the
# rights it was given once. Nothing to do in mirrored mode or without it.
function Start-KohaNetworkTask {
    if ((Get-KohaNetMode) -ne 'nat') { return $false }
    try {
        $t = Get-ScheduledTask -TaskPath $script:Cfg.TaskPath -TaskName $script:Cfg.NetTask -ErrorAction SilentlyContinue
        if ($null -eq $t) { return $false }
        Start-ScheduledTask -TaskPath $script:Cfg.TaskPath -TaskName $script:Cfg.NetTask -ErrorAction Stop
        return $true
    } catch {
        Write-KohaLog ('network: task not started: ' + $_.Exception.Message) 'network'
        return $false
    }
}

# Addresses the other PCs use, from this PC's local IPv4 address.
function Get-KohaLanUrls {
    $ip = Get-KohaLanIp
    if (-not $ip) { return $null }
    return [pscustomobject]@{ Opac = ('http://{0}/' -f $ip); Staff = ('http://{0}:8080/' -f $ip) }
}

# ----------------------------------------------------------------------
# Control panel window and a quick check
# ----------------------------------------------------------------------
# Opens the Koha control panel in its own console window, as root, and
# starts Koha as well (the panel alone would keep Debian up only while it is
# open). The window gets UTF-8 and the symbol mode through WSLENV.
function Open-KohaPanel {
    param([switch]$NoStart)
    if (-not $NoStart) { Start-Koha -Trigger user | Out-Null }
    $wsl = [System.IO.Path]::Combine([string]$env:SystemRoot, 'System32', 'wsl.exe')
    $launch = Get-KohaPanelLaunch -Wsl $wsl -Terminal (Get-KohaTerminalPath)
    Start-Process -FilePath $launch.File -ArgumentList $launch.Arguments | Out-Null
    Write-KohaLog 'control panel opened'
}

# Pure: how the control panel window opens. In Windows Terminal the panel
# shows emoji; in the classic console, plain symbols. The choice travels as
# "env KEI_PLAIN_GLYPHS=..." on the command line, because a Windows Terminal
# that is already open does not see this process's environment.
function Get-KohaPanelLaunch {
    param([string]$Wsl, [string]$Terminal)
    $plain = '1'
    if ($Terminal) { $plain = '0' }
    $cmd = '-d {0} -u root --cd /root -- env KEI_PLAIN_GLYPHS={1} {2}' -f $script:Cfg.Distro, $plain, $script:Cfg.PanelPath
    if ($Terminal) { return [pscustomobject]@{ File = $Terminal; Arguments = ('-w new --title Koha "{0}" {1}' -f $Wsl, $cmd) } }
    return [pscustomobject]@{ File = $Wsl; Arguments = $cmd }
}

# What is running, in a few lines a librarian can paste into a message:
# Debian's services, the koha-common package, whether Apache answers inside
# Debian, and the keep-alive task. Starts nothing that was not running.
$script:QuickCheckScript = @'
printf 'systemd: %s\n' "$(systemctl is-system-running 2>/dev/null)"
for s in mariadb apache2 memcached rabbitmq-server koha-common; do
  printf '%s: %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null)"
done
printf 'koha-common package: %s\n' "$(dpkg-query -W -f='${db:Status-Abbrev}${Version}' koha-common 2>/dev/null || echo missing)"
printf 'koha instance: %s\n' "$(ls /etc/koha/sites 2>/dev/null | tr '\n' ' ')"
printf 'installation finished: %s\n' "$([ -f /root/koha_credentials.txt ] && echo yes || echo no)"
printf 'staff page inside Debian: %s\n' "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8080/ 2>/dev/null)"
printf 'listening: %s\n' "$(ss -lnt 2>/dev/null | awk 'NR>1 {print $4}' | grep -E ':(80|8080|3306|11211|16613)$' | tr '\n' ' ')"
'@

function Get-KohaQuickCheck {
    $lines = New-Object System.Collections.ArrayList
    $running = Test-KohaDistroRunning
    [void]$lines.Add(('Debian ({0}) running: {1}' -f $script:Cfg.Distro, $running))
    try {
        $info = Get-ScheduledTaskInfo -TaskPath $script:Cfg.TaskPath -TaskName $script:Cfg.KeepTask -ErrorAction Stop
        $task = Get-ScheduledTask -TaskPath $script:Cfg.TaskPath -TaskName $script:Cfg.KeepTask -ErrorAction Stop
        [void]$lines.Add(('Keep Koha running task: {0}, last result 0x{1:X}, last run {2}' -f $task.State, [int64]$info.LastTaskResult, $info.LastRunTime))
    } catch {
        [void]$lines.Add('Keep Koha running task: not found')
    }
    if ($running) {
        $r = Invoke-KohaLinuxScript -Script $script:QuickCheckScript
        foreach ($l in ([string]$r.Output -split "`n")) { if ($l.Trim()) { [void]$lines.Add($l.TrimEnd()) } }
    }
    return @($lines)
}

# ----------------------------------------------------------------------
# Diagnostics
# ----------------------------------------------------------------------
# Same rules as kei_redact in the installer.
function Protect-KohaText {
    param([AllowEmptyString()][string]$Text)
    $r = '[REDACTED]'
    $t = $Text
    $t = [regex]::Replace($t, '(?i)(<(pass|password|user_pass|encryption_key|api_key)>)[^<]*(</[a-z_]+>)', ('$1' + $r + '$3'))
    $t = [regex]::Replace($t, '(?i)([a-z_-]*(pass(word)?|passwd|pwd|secret|token|api[_-]?key)[a-z_-]*["'']?\s*[:=]\s*["'']?)[^"''\s,;&}]+', ('$1' + $r))
    $t = [regex]::Replace($t, '(?i)((proxy-)?authorization:\s*[a-z]+)\s+\S+', ('$1 ' + $r))
    $t = [regex]::Replace($t, '(?i)(bearer|basic)\s+[A-Za-z0-9._~+/=-]{8,}', ('$1 ' + $r))
    $t = [regex]::Replace($t, '://[^/@\s:]+:[^/@\s]+@', ('://' + $r + '@'))
    $t = [regex]::Replace($t, 'ya29\.[A-Za-z0-9._-]+', $r)
    $t = [regex]::Replace($t, '1//[A-Za-z0-9._-]{20,}', $r)
    return $t
}

function Save-KohaText {
    param([string]$Path, [string]$Text)
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, (Protect-KohaText $Text), $utf8)
}

function Invoke-KohaCapture {
    param([scriptblock]$Block)
    try { return ((& $Block 2>&1 | Out-String -Width 200)) } catch { return ('ERROR: ' + $_.Exception.Message) }
}

# Collects the Windows side, asks Linux for its own bundle
# (config.sh --export-diagnostics) and zips both into $Destination.
# A stopped Koha is started for the export and stopped again afterwards.
function Export-KohaDiagnostics {
    param([string]$Destination = [Environment]::GetFolderPath('Desktop'))
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $work = Join-Path $env:TEMP ('KohaEasy-diagnostics-' + $stamp)
    $win = Join-Path $work 'windows'
    New-Item -ItemType Directory -Path $win -Force | Out-Null
    $state = Get-KohaState

    Save-KohaText (Join-Path $win 'wsl.txt') ((Invoke-KohaWsl -Arguments @('--version')).Output + "`n`n" +
        (Invoke-KohaWsl -Arguments @('--status')).Output + "`n`n" + (Invoke-KohaWsl -Arguments @('--list', '--verbose')).Output)
    Save-KohaText (Join-Path $win 'computer.txt') (Invoke-KohaCapture {
            Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber, OSArchitecture, TotalVisibleMemorySize, FreePhysicalMemory, LastBootUpTime | Format-List
            Get-CimInstance Win32_ComputerSystem | Select-Object Manufacturer, Model, HypervisorPresent, NumberOfLogicalProcessors | Format-List
            Get-CimInstance Win32_Processor | Select-Object Name, VirtualizationFirmwareEnabled | Format-List
            Get-PSDrive -PSProvider FileSystem | Format-Table Name, Used, Free -AutoSize
        })
    if ($env:USERPROFILE) {
        $wslconfig = Join-Path $env:USERPROFILE '.wslconfig'
        if (Test-Path -LiteralPath $wslconfig) { Save-KohaText (Join-Path $win 'wslconfig.txt') (Get-Content -LiteralPath $wslconfig -Raw) }
    }
    Save-KohaText (Join-Path $win 'state.json') ($state | ConvertTo-Json -Depth 5)
    Save-KohaText (Join-Path $win 'tasks.txt') (Invoke-KohaCapture {
            Get-ScheduledTask -TaskPath $script:Cfg.TaskPath | ForEach-Object {
                $_ | Select-Object TaskName, State | Format-List
                $_ | Get-ScheduledTaskInfo | Select-Object LastRunTime, LastTaskResult, NextRunTime, NumberOfMissedRuns | Format-List
            }
        })
    $wasRunning = Test-KohaDistroRunning
    $linux = $null
    if ($wasRunning) { $linux = Get-KohaLinuxStatus }
    Save-KohaText (Join-Path $win 'disk.txt') (Invoke-KohaCapture { Get-KohaDiskHealth -Linux $linux | Format-List })
    Save-KohaText (Join-Path $win 'events.txt') (Invoke-KohaCapture {
            Get-WinEvent -FilterHashtable @{ LogName = 'Application', 'System'; Level = 1, 2, 3; StartTime = (Get-Date).AddDays(-3) } -MaxEvents 2000 -ErrorAction SilentlyContinue |
                Where-Object { $_.ProviderName -match 'wsl|Lxss|Hyper-V|vmcompute|Kernel-Power|Power-Troubleshooter|disk|Ntfs' } |
                Select-Object -First 300 | Format-List TimeCreated, ProviderName, Id, LevelDisplayName, Message
        })
    $logs = Get-KohaPath Logs
    if (Test-Path -LiteralPath $logs) {
        $dst = Join-Path $win 'logs'
        New-Item -ItemType Directory -Path $dst -Force | Out-Null
        Get-ChildItem -LiteralPath $logs -Filter '*.log' | Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-7) } | ForEach-Object {
            Save-KohaText (Join-Path $dst $_.Name) ((Get-Content -LiteralPath $_.FullName -Tail 2000) -join "`n")
        }
    }

    Save-KohaText (Join-Path $win 'quick-check.txt') ((Get-KohaQuickCheck) -join "`n")

    # Linux side, written straight into the work folder.
    $note = ''
    if (Test-KohaDistroInstalled) {
        $lp = (Invoke-KohaLinux -Command @('wslpath', '-a', '-u', $work)).Output.Trim()
        $r = Invoke-KohaLinux -Command @($script:Cfg.PanelPath, '--export-diagnostics', $lp)
        if ($r.ExitCode -eq 0) {
            $dir = ($r.Output -split "`n" | Where-Object { $_ -like '/*' } | Select-Object -Last 1)
            if ($dir) {
                $name = Split-Path -Leaf $dir
                if (Test-Path -LiteralPath (Join-Path $work $name)) { Rename-Item -LiteralPath (Join-Path $work $name) -NewName 'linux' }
            }
        } else {
            $note = 'Linux diagnostics failed: ' + $r.Output
        }
        if (-not $wasRunning -and $state.desired -ne 'running') { Invoke-KohaWsl -Arguments @('--terminate', $script:Cfg.Distro) | Out-Null }
    } else {
        $note = ('The {0} distro is not installed.' -f $script:Cfg.Distro)
    }
    if ($note) { Save-KohaText (Join-Path $work 'NOTE.txt') $note }

    if (-not (Test-Path -LiteralPath $Destination)) { New-Item -ItemType Directory -Path $Destination -Force | Out-Null }
    $zip = Join-Path $Destination ('Koha-diagnostics-{0}-{1}.zip' -f $env:COMPUTERNAME, $stamp)
    Compress-Archive -Path (Join-Path $work '*') -DestinationPath $zip -Force
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    Write-KohaLog "diagnostics exported: $zip"
    return $zip
}

# ----------------------------------------------------------------------
# Shortcuts (Start menu folder "Koha" and desktop), all with koha.ico
# ----------------------------------------------------------------------
function Get-KohaIconPath { return [System.IO.Path]::Combine((Get-KohaPath Bin), 'koha.ico') }

# What to create (pure, tested). Kind "url" is an Internet shortcut (.url),
# "lnk" a program shortcut. Commands run KohaEasy.ps1 in Windows PowerShell 5.1.
function Get-KohaShortcutList {
    $ps = [System.IO.Path]::Combine([string]$env:SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
    $ps1 = Get-KohaScriptPath
    $cmd = { param($a, $style) '-NoProfile -WindowStyle {0} -ExecutionPolicy Bypass -File "{1}" {2}' -f $style, $ps1, $a }
    $wsl = [System.IO.Path]::Combine([string]$env:SystemRoot, 'System32', 'wsl.exe')
    $list = @(
        # The one desktop icon: the Koha control panel (Koha is started too, so
        # it keeps running after the panel is closed).
        @{ Name = 'Koha'; Kind = 'lnk'; Target = $ps; Arguments = (& $cmd 'Panel' 'Hidden'); Desktop = $true; StartMenu = $false }
        @{ Name = (T 'Koha - Staff interface'); Kind = 'url'; Target = $script:Cfg.StaffUrl }
        @{ Name = (T 'Koha - Public catalog'); Kind = 'url'; Target = $script:Cfg.OpacUrl }
        @{ Name = (T 'Koha - Control panel'); Kind = 'lnk'; Target = $ps; Arguments = (& $cmd 'Panel' 'Hidden') }
        @{ Name = (T 'Koha - Backups folder'); Kind = 'lnk'; Target = [System.IO.Path]::Combine([string]$env:SystemRoot, 'explorer.exe'); Arguments = ('"{0}"' -f (Get-KohaPath Backups)) }
        @{ Name = (T 'Koha - Start'); Kind = 'lnk'; Target = $ps; Arguments = (& $cmd 'Start' 'Hidden') }
        @{ Name = (T 'Koha - Stop'); Kind = 'lnk'; Target = $ps; Arguments = (& $cmd 'Stop' 'Hidden') }
        @{ Name = (T 'Koha - Restart'); Kind = 'lnk'; Target = $ps; Arguments = (& $cmd 'Restart' 'Hidden') }
        @{ Name = (T 'Koha - Status'); Kind = 'lnk'; Target = $ps; Arguments = (& $cmd 'Status' 'Hidden') }
        @{ Name = (T 'Koha - Export diagnostics'); Kind = 'lnk'; Target = $ps; Arguments = (& $cmd 'ExportDiagnostics' 'Hidden') }
        @{ Name = (T 'Koha - Status icon'); Kind = 'lnk'; Target = $ps; Arguments = (& $cmd 'Tray' 'Hidden') }
    )
    foreach ($s in $list) { $s.Icon = Get-KohaIconPath }
    return $list
}

# Characters Windows refuses in file names.
function ConvertTo-KohaFileName { param([string]$Name) return ($Name -replace '[\\/:*?"<>|]', '-').Trim() }

function Save-KohaUrlShortcut {
    param([string]$Path, [string]$Url, [string]$Icon)
    $text = "[InternetShortcut]`r`nURL=$Url`r`nIconFile=$Icon`r`nIconIndex=0`r`n"
    [System.IO.File]::WriteAllText($Path, $text, [System.Text.Encoding]::ASCII)
}

function Save-KohaLnkShortcut {
    param([string]$Path, [string]$Target, [string]$Arguments, [string]$Icon)
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($Path)
    $lnk.TargetPath = $Target
    $lnk.Arguments = $Arguments
    $lnk.WorkingDirectory = Get-KohaPath Root
    $lnk.IconLocation = $Icon + ',0'
    $lnk.Save()
}

# Creates (or refreshes) every shortcut with the Koha icon. The icon is copied
# next to KohaEasy.ps1 first, so shortcuts keep it if the ZIP folder is deleted.
function New-KohaShortcuts {
    param(
        [string]$StartMenu = [System.IO.Path]::Combine([Environment]::GetFolderPath('Programs'), 'Koha'),
        [string]$Desktop = [Environment]::GetFolderPath('Desktop'),
        [string]$IconSource = [System.IO.Path]::Combine($PSScriptRoot, 'koha.ico')
    )
    $icon = Get-KohaIconPath
    if ((Test-Path -LiteralPath $IconSource) -and ($IconSource -ne $icon)) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $icon) -Force | Out-Null
        Copy-Item -LiteralPath $IconSource -Destination $icon -Force
    }
    New-Item -ItemType Directory -Path $StartMenu -Force | Out-Null
    $made = New-Object System.Collections.ArrayList
    foreach ($s in Get-KohaShortcutList) {
        $dirs = @()
        if (-not $s.ContainsKey('StartMenu') -or $s.StartMenu) { $dirs += $StartMenu }
        if ($s.ContainsKey('Desktop') -and $s.Desktop -and $Desktop) { $dirs += $Desktop }
        foreach ($d in $dirs) {
            $file = [System.IO.Path]::Combine($d, (ConvertTo-KohaFileName $s.Name) + '.' + $s.Kind)
            if ($s.Kind -eq 'url') {
                Save-KohaUrlShortcut -Path $file -Url $s.Target -Icon $s.Icon
            } else {
                Save-KohaLnkShortcut -Path $file -Target $s.Target -Arguments $s.Arguments -Icon $s.Icon
            }
            [void]$made.Add($file)
        }
    }
    Write-KohaLog ('shortcuts created: {0}' -f $made.Count)
    return @($made)
}

# The distro's own entries, made by WSL itself, show Debian's logo: its
# Start menu shortcut and the Windows Terminal profile it wrote. Both get
# koha.ico (and so does shortcut.ico, the file WSL points them at). When WSL
# wrote no terminal profile (older WSL), a Windows Terminal fragment adds a
# "Koha (Debian)" profile with the icon.
function Set-KohaDistroIcon {
    param(
        [string]$Icon = (Get-KohaIconPath),
        [string]$FragmentDir = [System.IO.Path]::Combine([string]$env:LOCALAPPDATA, 'Microsoft', 'Windows Terminal', 'Fragments', 'KohaEasy')
    )
    $done = New-Object System.Collections.ArrayList
    $e = Get-KohaLxssEntry
    if (-not (Test-Path -LiteralPath $Icon) -or $null -eq $e) { return @() }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    if ($e.BasePath -and (Test-Path -LiteralPath $e.BasePath)) {
        try { Copy-Item -LiteralPath $Icon -Destination (Join-Path $e.BasePath 'shortcut.ico') -Force; [void]$done.Add('shortcut.ico') } catch { }
    }
    if ($e.ShortcutPath -and (Test-Path -LiteralPath $e.ShortcutPath)) {
        try {
            $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($e.ShortcutPath)
            $lnk.IconLocation = $Icon + ',0'
            $lnk.Save()
            [void]$done.Add('start-menu')
        } catch { Write-KohaLog ('icon: Start menu shortcut not changed: ' + $_.Exception.Message) }
    }
    $hasProfile = $false
    if ($e.TerminalProfilePath -and (Test-Path -LiteralPath $e.TerminalProfilePath)) {
        try {
            $json = [System.IO.File]::ReadAllText($e.TerminalProfilePath) | ConvertFrom-Json
            foreach ($p in @($json.profiles)) {
                if ($p.PSObject.Properties['icon']) { $p.icon = $Icon } else { $p | Add-Member -NotePropertyName icon -NotePropertyValue $Icon }
            }
            [System.IO.File]::WriteAllText($e.TerminalProfilePath, ($json | ConvertTo-Json -Depth 10), $utf8)
            $hasProfile = $true
            [void]$done.Add('terminal')
        } catch { Write-KohaLog ('icon: terminal profile not changed: ' + $_.Exception.Message) }
    }
    if (-not $hasProfile -and $FragmentDir) {
        try {
            New-Item -ItemType Directory -Path $FragmentDir -Force | Out-Null
            $frag = [ordered]@{ profiles = @([ordered]@{
                        name = 'Koha (Debian)'; commandline = ('wsl.exe -d {0}' -f $script:Cfg.Distro)
                        icon = $Icon; startingDirectory = '~' }) }
            [System.IO.File]::WriteAllText((Join-Path $FragmentDir 'koha.json'), ($frag | ConvertTo-Json -Depth 5), $utf8)
            [void]$done.Add('terminal-fragment')
        } catch { Write-KohaLog ('icon: terminal fragment not written: ' + $_.Exception.Message) }
    }
    Write-KohaLog ('icon: koha.ico set on {0}' -f ($done -join ', '))
    return @($done)
}

# ----------------------------------------------------------------------
# Tray at sign-in (HKCU Run: no administrator rights)
# ----------------------------------------------------------------------
function Set-KohaTrayAtSignIn {
    param([bool]$Enabled = $true)
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    if ($Enabled) {
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $cmd = '"{0}" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}" Tray' -f $ps, (Get-KohaScriptPath)
        New-ItemProperty -Path $key -Name 'KohaEasyTray' -Value $cmd -PropertyType String -Force | Out-Null
    } else {
        Remove-ItemProperty -Path $key -Name 'KohaEasyTray' -ErrorAction SilentlyContinue
    }
}

$script:KohaEasyVersion = '0.1.0'

Export-ModuleMember -Function * -Variable KohaEasyVersion
