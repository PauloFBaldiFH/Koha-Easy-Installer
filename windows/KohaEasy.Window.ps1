# Koha Easy Installer for Windows: the Koha window (KohaEasy.ps1 Window).
# A native Windows window, so it keeps working when Koha does not: it reads
# Debian's services through wsl.exe and never needs Koha's web server.
#   * Koha's state, and each service inside Debian: MariaDB, Apache,
#     RabbitMQ, Memcached, koha-common, and whether the staff page answers
#   * Start, Stop, Restart Koha services, Restart Debian and Koha
#   * staff interface, public catalog, the control panel (terminal menus)
#   * diagnostics as one text file on the desktop (diagnostico_koha.txt)
# Opened by the Koha icon on the desktop, Koha - Status and the tray. Like
# the tray, it never starts Debian by itself: only its Start buttons do.
# Every check and action runs in a background runspace, so the window never
# freezes. Windows PowerShell 5.1. Loaded by KohaEasy.ps1 (modules imported).

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$title = T 'Koha - Status and services'
$mutex = New-Object System.Threading.Mutex($false, 'Local\KohaEasyWindow')
if (-not $mutex.WaitOne(0)) {
    # Already open: bring that window to the front instead of a second one.
    try { [void](New-Object -ComObject WScript.Shell).AppActivate($title) } catch { }
    return
}

$cfg = Get-KohaConfig
$here = $PSScriptRoot
$REFRESH_EVERY_S = 30
$colors = @{
    running  = [System.Drawing.Color]::FromArgb(30, 130, 50)
    starting = [System.Drawing.Color]::FromArgb(180, 120, 0)
    failed   = [System.Drawing.Color]::FromArgb(190, 40, 35)
    stopped  = [System.Drawing.Color]::FromArgb(110, 110, 110)
    unknown  = [System.Drawing.Color]::FromArgb(110, 110, 110)
}
$stateColor = @{
    running = 'running'; starting = 'starting'; not_responding = 'failed'
    stopped = 'stopped'; stopped_by_user = 'stopped'; not_installed = 'stopped'
}

function New-Button {
    param([string]$Text, [scriptblock]$OnClick)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.AutoSize = $true
    $b.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $b.Padding = New-Object System.Windows.Forms.Padding(6, 2, 6, 2)
    $b.add_Click($OnClick)
    return $b
}
function New-Row {
    $r = New-Object System.Windows.Forms.FlowLayoutPanel
    $r.AutoSize = $true
    $r.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $r.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
    $r.WrapContents = $false
    $r.Margin = New-Object System.Windows.Forms.Padding(0, 4, 0, 4)
    return $r
}

# ----------------------------------------------------------------------
# Layout
# ----------------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = $title
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
$form.MaximizeBox = $false
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.AutoSize = $true
$form.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
$kohaIco = Join-Path $here 'koha.ico'
if (Test-Path -LiteralPath $kohaIco) { try { $form.Icon = New-Object System.Drawing.Icon($kohaIco) } catch { } }

$root = New-Object System.Windows.Forms.TableLayoutPanel
$root.AutoSize = $true
$root.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
$root.ColumnCount = 1
$root.Padding = New-Object System.Windows.Forms.Padding(14)

# Header: the Koha logo and the state in words.
$head = New-Row
if (Test-Path -LiteralPath $kohaIco) {
    try {
        $pic = New-Object System.Windows.Forms.PictureBox
        $pic.Image = (New-Object System.Drawing.Icon($kohaIco, 32, 32)).ToBitmap()
        $pic.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::AutoSize
        $pic.Margin = New-Object System.Windows.Forms.Padding(0, 0, 10, 0)
        [void]$head.Controls.Add($pic)
    } catch { }
}
$lblState = New-Object System.Windows.Forms.Label
$lblState.AutoSize = $true
$lblState.Font = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
$lblState.Text = T 'Checking...'
$lblState.Margin = New-Object System.Windows.Forms.Padding(0, 4, 0, 0)
[void]$head.Controls.Add($lblState)
[void]$root.Controls.Add($head)

# Addresses, as links.
$links = New-Row
foreach ($l in @(@{ Text = (T 'Open the staff interface'); Url = $cfg.StaffUrl }, @{ Text = (T 'Open the public catalog'); Url = $cfg.OpacUrl })) {
    $ll = New-Object System.Windows.Forms.LinkLabel
    $ll.AutoSize = $true
    $ll.Text = '{0}: {1}' -f $l.Text, $l.Url
    $ll.Tag = $l.Url
    $ll.Margin = New-Object System.Windows.Forms.Padding(0, 0, 16, 0)
    $ll.add_LinkClicked({ param($s, $e) Start-Process ([string]$s.Tag) })
    [void]$links.Controls.Add($ll)
}
[void]$root.Controls.Add($links)

# The services.
$list = New-Object System.Windows.Forms.ListView
$list.View = [System.Windows.Forms.View]::Details
$list.FullRowSelect = $true
$list.HeaderStyle = [System.Windows.Forms.ColumnHeaderStyle]::Nonclickable
$list.MultiSelect = $false
$list.Width = 460
$list.Height = 180
$list.Margin = New-Object System.Windows.Forms.Padding(0, 8, 0, 4)
[void]$list.Columns.Add((T 'Service'), 210)
[void]$list.Columns.Add((T 'State'), 230)
[void]$root.Controls.Add($list)

$lblInfo = New-Object System.Windows.Forms.Label
$lblInfo.AutoSize = $true
$lblInfo.MaximumSize = New-Object System.Drawing.Size(460, 0)
[void]$root.Controls.Add($lblInfo)

$lblBusy = New-Object System.Windows.Forms.Label
$lblBusy.AutoSize = $true
$lblBusy.MaximumSize = New-Object System.Drawing.Size(460, 0)
$lblBusy.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$lblBusy.Margin = New-Object System.Windows.Forms.Padding(0, 6, 0, 6)
[void]$root.Controls.Add($lblBusy)

# Actions on Koha.
$row1 = New-Row
$btnStart = New-Button (T 'Start Koha') { Invoke-Action 'start' }
$btnStop = New-Button (T 'Stop Koha') {
    $q = (T 'Stop Koha?') + "`n`n" + (T 'Anyone using the catalog will be disconnected, and nightly backups will not run until Koha is started again.')
    if ([System.Windows.Forms.MessageBox]::Show($form, $q, 'Koha', 'YesNo', 'Warning') -eq 'Yes') { Invoke-Action 'stop' }
}
$btnServices = New-Button (T 'Restart Koha services') { Invoke-Action 'services' }
$btnDebian = New-Button (T 'Restart Debian and Koha') {
    $q = (T 'Restart Koha?') + "`n`n" + (T 'Anyone using the catalog will be disconnected, and nightly backups will not run until Koha is started again.')
    if ([System.Windows.Forms.MessageBox]::Show($form, $q, 'Koha', 'YesNo', 'Warning') -eq 'Yes') { Invoke-Action 'debian' }
}
$btnRefresh = New-Button (T 'Refresh') { Invoke-Action 'refresh' }
foreach ($b in $btnStart, $btnStop, $btnServices, $btnDebian, $btnRefresh) { [void]$row1.Controls.Add($b) }
[void]$root.Controls.Add($row1)

# Tools.
$row2 = New-Row
$btnReport = New-Button (T 'Export diagnostics (.txt)') { Invoke-Action 'report' }
$btnZip = New-Button (T 'Export diagnostics (.zip)') { Start-KohaHidden 'ExportDiagnostics' }
$btnPanel = New-Button (T 'Open the control panel') { Start-KohaHidden 'Panel' }
foreach ($b in $btnReport, $btnZip, $btnPanel) { [void]$row2.Controls.Add($b) }
[void]$root.Controls.Add($row2)

$form.Controls.Add($root)

# ----------------------------------------------------------------------
# Background work
# ----------------------------------------------------------------------
$iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
$iss.ImportPSModule(@((Join-Path $here 'KohaEasy.Lang.psm1'), (Join-Path $here 'KohaEasy.Core.psm1')))
$rs = [runspacefactory]::CreateRunspace($iss)
$rs.ApartmentState = 'STA'
$rs.Open()
$langDir = Join-Path $here 'lang'
if (-not (Test-Path -LiteralPath $langDir)) { $langDir = Join-Path (Split-Path -Parent $here) 'lang' }
$script:job = $null
$script:nextRefresh = [DateTime]::MinValue
$script:status = $null
$script:health = $null

$worker = {
    param($LangDir, $Action)
    Import-KeiLanguage -LangDir $LangDir
    $result = $null
    switch ($Action) {
        'start'    { $result = Start-Koha -Trigger user -Wait }
        'stop'     { $result = Stop-Koha }
        'services' { $result = Restart-KohaServices }
        'debian'   { Stop-Koha | Out-Null; $result = Start-Koha -Trigger user -Wait }
        'report'   { $result = Export-KohaDiagnosticsText }
    }
    return [pscustomobject]@{ Action = $Action; Result = $result; Status = (Get-KohaStatus); Health = (Get-KohaServiceHealth) }
}

$busyText = @{
    refresh  = (T 'Checking...')
    start    = (T 'Starting Koha... (up to 3 minutes)')
    stop     = (T 'Stopping Koha...')
    services = (T 'Restarting Koha services...')
    debian   = (T 'Restarting Debian and Koha... (up to 3 minutes)')
    report   = (T 'Collecting diagnostics... This can take a minute.')
}

function Set-Buttons {
    param([bool]$Busy)
    $on = $false
    if ($null -ne $script:health) { $on = [bool]$script:health.DebianRunning }
    $installed = ($null -eq $script:status) -or ($script:status.State -ne 'not_installed')
    $btnStart.Enabled = (-not $Busy) -and $installed -and (-not $on)
    $btnStop.Enabled = (-not $Busy) -and $on
    $btnServices.Enabled = (-not $Busy) -and $on
    $btnDebian.Enabled = (-not $Busy) -and $on
    $btnRefresh.Enabled = -not $Busy
    $btnReport.Enabled = -not $Busy
    $btnPanel.Enabled = $installed
}

function Invoke-Action {
    param([string]$Action)
    if ($null -ne $script:job) { return }
    $lblBusy.ForeColor = $colors.starting
    $lblBusy.Text = $busyText[$Action]
    Set-Buttons $true
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($worker).AddArgument($langDir).AddArgument($Action)
    $script:job = @{ PS = $ps; Handle = $ps.BeginInvoke(); Action = $Action }
}

function Update-View {
    param($Status, $Health)
    $script:status = $Status
    $script:health = $Health
    $lblState.Text = Get-KohaStateText $Status.State
    $lblState.ForeColor = $colors[$stateColor[[string]$Status.State]]
    $list.BeginUpdate()
    $list.Items.Clear()
    foreach ($r in $Health.Services) {
        $name = $r.Name
        if ($r.Unit -eq 'http') { $name = T 'Staff interface' }
        $item = New-Object System.Windows.Forms.ListViewItem ([string][char]0x25CF + '  ' + $name)
        $item.UseItemStyleForSubItems = $false
        $item.ForeColor = $colors[$r.State]
        $sub = $item.SubItems.Add((Get-KohaServiceStateText -State $r.State -Unit $r.Unit -Detail $r.Detail))
        $sub.ForeColor = $colors[$r.State]
        [void]$list.Items.Add($item)
    }
    $list.EndUpdate()
    $info = @()
    if ($Status.Autostart -eq 'manual') { $info += T 'Koha starts only when you click Koha - Start.' }
    if ($null -ne $Status.Linux) {
        if ([int64]$Status.Linux.backup.last_epoch -gt 0) {
            $when = [DateTimeOffset]::FromUnixTimeSeconds([int64]$Status.Linux.backup.last_epoch).LocalDateTime
            $info += (T 'Latest backup: {0} ({1})') -f $when.ToString('g'), (Format-KohaSize ([double]$Status.Linux.backup.last_size))
        } else {
            $info += T 'Latest backup: none yet'
        }
    }
    $info += (T 'Checked at {0}') -f (Get-Date).ToString('T')
    $lblInfo.Text = $info -join "`n"
}

function Show-Result {
    param([string]$Action, $Result)
    $ok = $colors.running
    $bad = $colors.failed
    $text = ''
    $color = $ok
    switch ($Action) {
        'start' {
            if ($Result -eq 'ready') { $text = T 'Koha is running' } else { $text = T 'Koha did not start. Open Koha - Status, or export the diagnostics from the tray menu.'; $color = $bad }
        }
        'debian' {
            if ($Result -eq 'ready') { $text = T 'Koha is running' } else { $text = T 'Koha did not start. Open Koha - Status, or export the diagnostics from the tray menu.'; $color = $bad }
        }
        'stop' { $text = T 'Koha is stopped. Use Koha - Start to turn it on again.' }
        'services' {
            switch ([string]$Result) {
                'ready'       { $text = T 'Koha services restarted.' }
                'not_running' { $text = T 'Debian is stopped. Start Koha first.'; $color = $bad }
                default       { $text = T 'Koha services restarted, but the staff interface does not answer yet. Export the diagnostics and send them to whoever supports your library.'; $color = $bad }
            }
        }
        'report' {
            $text = ((T 'Diagnostics saved on the desktop: {0}') -f $Result) + "`n" + (T 'Send this file to whoever supports your library. Passwords are not included.')
            try { Start-Process explorer.exe -ArgumentList ('/select,"{0}"' -f $Result) } catch { }
        }
    }
    $lblBusy.ForeColor = $color
    $lblBusy.Text = $text
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500
$timer.add_Tick({
        if ($null -ne $script:job) {
            if (-not $script:job.Handle.IsCompleted) { return }
            $action = $script:job.Action
            try {
                $res = @($script:job.PS.EndInvoke($script:job.Handle))
                $r = $null
                if ($res.Count -gt 0) { $r = $res[-1] }
                if ($null -ne $r) {
                    Update-View $r.Status $r.Health
                    if ($action -eq 'refresh') { $lblBusy.Text = '' } else { Show-Result $action $r.Result }
                } elseif ($script:job.PS.Streams.Error.Count -gt 0) {
                    throw $script:job.PS.Streams.Error[0].Exception
                }
            } catch {
                Write-KohaLog ('Koha window: {0} failed: {1}' -f $action, $_.Exception.Message)
                $lblBusy.ForeColor = $colors.failed
                $lblBusy.Text = $_.Exception.Message
            } finally {
                $script:job.PS.Dispose()
                $script:job = $null
                Set-Buttons $false
                $script:nextRefresh = (Get-Date).AddSeconds($REFRESH_EVERY_S)
            }
            if ($script:closeWhenDone) { $form.Close() }
            return
        }
        if ((Get-Date) -ge $script:nextRefresh -and $form.Visible -and $form.WindowState -ne 'Minimized') {
            $keep = $lblBusy.Text
            Invoke-Action 'refresh'
            # An automatic refresh keeps the last result on screen.
            if ($keep) { $lblBusy.Text = $keep }
        }
    })

$form.add_Shown({ $form.Activate(); Invoke-Action 'refresh'; $timer.Start() })
$script:closeWhenDone = $false
$form.add_FormClosing({
        param($s, $e)
        # A Start, Stop or Restart in progress finishes first, out of sight:
        # cutting it short could leave Debian's services half restarted.
        if ($null -ne $script:job -and $script:job.Action -ne 'refresh') {
            $e.Cancel = $true
            $script:closeWhenDone = $true
            $form.Hide()
        }
    })

try {
    Set-Buttons $true
    [System.Windows.Forms.Application]::Run($form)
} finally {
    $timer.Stop()
    if ($null -ne $script:job) { try { $script:job.PS.Stop() } catch { } }
    $rs.Close()
    $mutex.ReleaseMutex()
}
