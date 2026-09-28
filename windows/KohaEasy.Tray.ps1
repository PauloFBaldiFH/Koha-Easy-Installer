# Koha Easy Installer for Windows: notification-area icon.
# Started at sign-in (HKCU Run, KohaEasy.ps1 Tray) whatever the automatic
# start mode, so a stopped Koha still has its Start button. It never starts
# the distro by itself: the status is read only while Koha is already running.
#   * icon colour: green running, yellow starting, red not responding, grey stopped
#   * menu: open staff interface / catalog, Start, Stop, Restart, Status,
#     Export diagnostics, Check disk space, Backups folder, automatic start
#   * notifications: service events, nightly backups, disk space
# Checks run in a background runspace so the menu never freezes.
# Windows PowerShell 5.1. Loaded by KohaEasy.ps1 (modules already imported).

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$mutex = New-Object System.Threading.Mutex($false, 'Local\KohaEasyTray')
if (-not $mutex.WaitOne(0)) { return }

$cfg = Get-KohaConfig
$here = $PSScriptRoot
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$STATUS_EVERY_S = 60
$DISK_EVERY_S = 1800

# The Koha icon (koha.ico) with a status dot in the lower right corner; a
# plain dot when the icon file is missing.
$kohaIco = Join-Path $here 'koha.ico'
function New-DotIcon {
    param([System.Drawing.Color]$Color)
    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), 1.5
    if (Test-Path -LiteralPath $kohaIco) {
        $base = New-Object System.Drawing.Icon($kohaIco, 16, 16)
        $g.DrawIcon($base, (New-Object System.Drawing.Rectangle 0, 0, 16, 16))
        $base.Dispose()
        $g.FillEllipse((New-Object System.Drawing.SolidBrush $Color), 8, 8, 7, 7)
        $g.DrawEllipse($pen, 8, 8, 7, 7)
    } else {
        $g.FillEllipse((New-Object System.Drawing.SolidBrush $Color), 1, 1, 14, 14)
    }
    $g.Dispose()
    return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}
$icons = @{
    running         = New-DotIcon ([System.Drawing.Color]::FromArgb(46, 160, 67))
    starting        = New-DotIcon ([System.Drawing.Color]::FromArgb(230, 170, 20))
    not_responding  = New-DotIcon ([System.Drawing.Color]::FromArgb(210, 50, 45))
    stopped         = New-DotIcon ([System.Drawing.Color]::FromArgb(140, 140, 140))
    stopped_by_user = New-DotIcon ([System.Drawing.Color]::FromArgb(140, 140, 140))
    not_installed   = New-DotIcon ([System.Drawing.Color]::FromArgb(140, 140, 140))
}

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = $icons.stopped
$tray.Text = 'Koha'
$tray.Visible = $true
Set-KohaTrayIcon $tray

# Actions that take time run in their own process: the menu stays responsive.
function Invoke-KohaCommand {
    param([string]$Arguments, [switch]$Elevated)
    $a = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" {1}' -f (Join-Path $here 'KohaEasy.ps1'), $Arguments
    if ($Elevated) { Start-Process $psExe -ArgumentList $a -Verb RunAs } else { Start-Process $psExe -ArgumentList $a -WindowStyle Hidden }
}

$menu = New-Object System.Windows.Forms.ContextMenuStrip
function Add-Item {
    param([string]$Text, [scriptblock]$OnClick)
    $item = New-Object System.Windows.Forms.ToolStripMenuItem $Text
    if ($OnClick) { $item.add_Click($OnClick) }
    [void]$menu.Items.Add($item)
    return $item
}
function Add-Separator { [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) }

$header = Add-Item (Get-KohaStateText 'stopped') $null
$header.Enabled = $false
Add-Separator
$miStaff = Add-Item (T 'Open the staff interface') { Start-Process $cfg.StaffUrl }
$miOpac = Add-Item (T 'Open the public catalog') { Start-Process $cfg.OpacUrl }
Add-Separator
$miStart = Add-Item (T 'Start Koha') { Invoke-KohaCommand 'Start'; Request-Check 5 }
$miStop = Add-Item (T 'Stop Koha') { Invoke-KohaCommand 'Stop'; Request-Check 5 }
$miRestart = Add-Item (T 'Restart Koha') { Invoke-KohaCommand 'Restart'; Request-Check 5 }
Add-Item (T 'Status') { Invoke-KohaCommand 'Status' } | Out-Null
Add-Separator
Add-Item (T 'Export diagnostics (.zip)') { Invoke-KohaCommand 'ExportDiagnostics' } | Out-Null
Add-Item (T 'Check disk space') { Invoke-KohaCommand 'CheckDisk' } | Out-Null
Add-Item (T 'Open the backups folder') {
    $b = Get-KohaPath Backups
    if (-not (Test-Path -LiteralPath $b)) { New-Item -ItemType Directory -Path $b -Force | Out-Null }
    Start-Process explorer.exe -ArgumentList ('"{0}"' -f $b)
} | Out-Null
Add-Separator
$miAuto = Add-Item (T 'Start Koha when I sign in to Windows') {
    $mode = 'logon'
    if ((Get-KohaState).autostart -eq 'logon') { $mode = 'manual' }
    Invoke-KohaCommand ('SetAutostart -Mode ' + $mode)
    $miAuto.Checked = ($mode -eq 'logon')
}
$miBackupOk = Add-Item (T 'Notify me when the nightly backup succeeds') {
    $on = -not [bool](Get-KohaState).notifyBackupOk
    Set-KohaState @{ notifyBackupOk = $on } | Out-Null
    $miBackupOk.Checked = $on
}
Add-Separator
Add-Item (T 'Close this icon') { $tray.Visible = $false; [System.Windows.Forms.Application]::Exit() } | Out-Null
$tray.ContextMenuStrip = $menu
$tray.add_DoubleClick({ Invoke-KohaCommand 'Status' })

# ----------------------------------------------------------------------
# Background checks
# ----------------------------------------------------------------------
$iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
$iss.ImportPSModule(@((Join-Path $here 'KohaEasy.Lang.psm1'), (Join-Path $here 'KohaEasy.Core.psm1')))
$pool = [runspacefactory]::CreateRunspace($iss)
$pool.ApartmentState = 'STA'
$pool.Open()
$langDir = Join-Path $here 'lang'
$job = $null
$nextStatus = [DateTime]::MinValue
$nextDisk = [DateTime]::MinValue

function Request-Check { param([int]$InSeconds = 0) $script:nextStatus = (Get-Date).AddSeconds($InSeconds) }

function Start-Check {
    param([bool]$WithDisk)
    $ps = [powershell]::Create()
    $ps.Runspace = $pool
    [void]$ps.AddScript({
            param($LangDir, $WithDisk)
            Import-KeiLanguage -LangDir $LangDir
            $status = Get-KohaStatus
            $disk = $null
            if ($WithDisk) { $disk = Get-KohaDiskHealth -Linux $status.Linux }
            return [pscustomobject]@{ Status = $status; Disk = $disk }
        }).AddArgument($langDir).AddArgument($WithDisk)
    return @{ PS = $ps; Handle = $ps.BeginInvoke() }
}

function Update-Menu {
    param($Status)
    $s = $Status.State
    $tray.Icon = $icons[$s]
    $text = Get-KohaStateText $s
    $header.Text = $text
    $tray.Text = $text.Substring(0, [Math]::Min(63, $text.Length))
    $on = @('running', 'starting', 'not_responding') -contains $s
    $miStart.Enabled = (-not $on) -and $s -ne 'not_installed'
    $miStop.Enabled = $on
    $miRestart.Enabled = $on
    $miStaff.Enabled = ($s -eq 'running')
    $miOpac.Enabled = ($s -eq 'running')
    $st = Get-KohaState
    $miAuto.Checked = ($st.autostart -eq 'logon')
    $miBackupOk.Checked = [bool]$st.notifyBackupOk
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 3000
$timer.add_Tick({
        if ($null -ne $script:job) {
            if (-not $script:job.Handle.IsCompleted) { return }
            try {
                $res = @($script:job.PS.EndInvoke($script:job.Handle))
                if ($res.Count -gt 0 -and $null -ne $res[0]) {
                    $r = $res[0]
                    $state = Get-KohaState
                    Update-Menu $r.Status
                    $n = Get-KohaNotifications -Previous ([string]$state.lastState) -Status $r.Status -Disk $r.Disk -State $state
                    foreach ($x in $n.Notifications) { Show-KohaNotification -Title $x.Title -Text $x.Text -Level $x.Level | Out-Null }
                    if ($null -eq $r.Disk) { $n.Changes.Remove('lastDiskLevel') }
                    Set-KohaState $n.Changes | Out-Null
                }
            } catch {
                Write-KohaLog ('tray check failed: ' + $_.Exception.Message)
            } finally {
                $script:job.PS.Dispose()
                $script:job = $null
            }
        }
        $now = Get-Date
        if ($now -ge $script:nextStatus) {
            $withDisk = ($now -ge $script:nextDisk)
            if ($withDisk) { $script:nextDisk = $now.AddSeconds($DISK_EVERY_S) }
            $script:nextStatus = $now.AddSeconds($STATUS_EVERY_S)
            $script:job = Start-Check $withDisk
        }
    })
$timer.Start()

try {
    [System.Windows.Forms.Application]::Run()
} finally {
    $timer.Stop()
    $tray.Visible = $false
    $tray.Dispose()
    $pool.Close()
    $mutex.ReleaseMutex()
}
