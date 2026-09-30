# Koha Easy Installer for Windows: the Koha window (KohaEasy.ps1 Window).
# A native Windows window, so it keeps working when Koha does not: it reads
# Debian's services through wsl.exe and never needs Koha's web server.
# Dark, in cards, from top to bottom:
#   * a banner: green only when every component runs; when one fails it
#     turns red and names it (only that row is highlighted), with the time
#     of the check and the latest backup, and Start Koha while it is off
#   * quick access: the staff interface first, then the public catalog
#   * the components: Debian (WSL), MariaDB, Apache, RabbitMQ, Memcached,
#     koha-common and the staff page's HTTP answer
#   * the actions: the management panel (terminal menus), Restart Koha and
#     the terminal area; More actions holds Start, Stop, Restart Debian and
#     Koha, Rebuild search index, the library network test, diagnostics and
#     the Debian terminal
#   * the terminal area, folded by default: what every action does, line by
#     line, and a command line for one command at a time, inside this
#     window (no console window)
# No console window ever appears: the desktop icon, the tray and the Start
# menu open it through KohaEasy.exe (a Windows program that starts
# PowerShell with CreateNoWindow; conhost --headless where Windows refuses
# it), and wsl.exe runs inside that hidden console. Only the management
# panel and the Debian terminal open a terminal window, on purpose.
# On the taskbar it is Koha (Koha's AppUserModelID, KohaEasy.exe), not
# Windows PowerShell. Like the tray, it never starts Debian by itself: only
# its Start buttons do. Every check and action runs in a background
# runspace, so the window never freezes. Windows PowerShell 5.1. Loaded by
# KohaEasy.ps1 (modules imported).

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
# Before any window exists: Windows reads it when the first one opens.
Set-KohaProcessAppId | Out-Null

$cfg = Get-KohaConfig
$here = $PSScriptRoot
$REFRESH_EVERY_S = 30
$W = 560

function New-Rgb { param([int]$R, [int]$G, [int]$B) return [System.Drawing.Color]::FromArgb($R, $G, $B) }
$theme = @{
    Bg          = New-Rgb 24 24 27
    Card        = New-Rgb 32 32 36
    Border      = New-Rgb 48 48 54
    Text        = New-Rgb 244 244 245
    Muted       = New-Rgb 161 161 170
    Green       = New-Rgb 34 197 94
    Red         = New-Rgb 239 68 68
    Amber       = New-Rgb 245 158 11
    Grey        = New-Rgb 113 113 122
    OkFill      = New-Rgb 20 44 30
    OkBorder    = New-Rgb 22 101 52
    FaultFill   = New-Rgb 58 22 24
    FaultBorder = New-Rgb 153 27 27
    WarnFill    = New-Rgb 54 42 16
    WarnBorder  = New-Rgb 146 96 8
    Accent      = New-Rgb 37 99 235
    AccentHover = New-Rgb 59 130 246
    Button      = New-Rgb 48 48 55
    ButtonHover = New-Rgb 63 63 72
    Term        = New-Rgb 12 12 14
    TermText    = New-Rgb 212 212 216
}
$dotColor = @{ running = $theme.Green; starting = $theme.Amber; failed = $theme.Red; stopped = $theme.Grey; unknown = $theme.Grey }
$banner = @{
    ok       = @{ Fill = $theme.OkFill; Border = $theme.OkBorder; Dot = $theme.Green }
    fault    = @{ Fill = $theme.FaultFill; Border = $theme.FaultBorder; Dot = $theme.Red }
    starting = @{ Fill = $theme.WarnFill; Border = $theme.WarnBorder; Dot = $theme.Amber }
    stopped  = @{ Fill = $theme.Card; Border = $theme.Border; Dot = $theme.Grey }
    unknown  = @{ Fill = $theme.Card; Border = $theme.Border; Dot = $theme.Grey }
}
$fontUi = New-Object System.Drawing.Font('Segoe UI', 9.5)
$fontSmall = New-Object System.Drawing.Font('Segoe UI', 8.5)
$fontCaption = New-Object System.Drawing.Font('Segoe UI Semibold', 8)
$fontBanner = New-Object System.Drawing.Font('Segoe UI Semibold', 12)
$fontDot = New-Object System.Drawing.Font('Segoe UI', 16)
$fontMono = New-Object System.Drawing.Font('Consolas', 9.5)

# ----------------------------------------------------------------------
# Building blocks
# ----------------------------------------------------------------------
function Set-DoubleBuffered {
    param($Control)
    $p = $Control.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'NonPublic,Instance')
    if ($p) { $p.SetValue($Control, $true, $null) }
}

function New-RoundedPath {
    param([System.Drawing.RectangleF]$Rect, [float]$Radius)
    $d = $Radius * 2
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.AddArc($Rect.X, $Rect.Y, $d, $d, 180, 90)
    $p.AddArc($Rect.Right - $d, $Rect.Y, $d, $d, 270, 90)
    $p.AddArc($Rect.Right - $d, $Rect.Bottom - $d, $d, $d, 0, 90)
    $p.AddArc($Rect.X, $Rect.Bottom - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

# A card is a one-column table whose BackColor is the card's colour (so
# every label in it takes that colour) with its corners painted round.
$paintCard = {
    param($s, $e)
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear($theme.Bg)
    $rect = New-Object System.Drawing.RectangleF(0.5, 0.5, ($s.Width - 1.5), ($s.Height - 1.5))
    $path = New-RoundedPath $rect 10
    $brush = New-Object System.Drawing.SolidBrush($s.Tag.Fill)
    $pen = New-Object System.Drawing.Pen($s.Tag.Border)
    try { $g.FillPath($brush, $path); $g.DrawPath($pen, $path) } finally { $brush.Dispose(); $pen.Dispose(); $path.Dispose() }
}

function New-Card {
    param([int]$Columns = 1)
    $c = New-Object System.Windows.Forms.TableLayoutPanel
    $c.ColumnCount = $Columns
    $c.AutoSize = $true
    $c.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $c.MinimumSize = New-Object System.Drawing.Size($W, 0)
    $c.MaximumSize = New-Object System.Drawing.Size($W, 0)
    $c.Padding = New-Object System.Windows.Forms.Padding(16, 12, 16, 14)
    $c.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 10)
    $c.BackColor = $theme.Card
    $c.ForeColor = $theme.Text
    $c.Tag = @{ Fill = $theme.Card; Border = $theme.Border }
    Set-DoubleBuffered $c
    $c.add_Paint($paintCard)
    $c.add_Resize({ param($s, $e) $s.Invalidate() })
    return $c
}

function Set-CardColor {
    param($Card, [System.Drawing.Color]$Fill, [System.Drawing.Color]$Border)
    $Card.Tag.Fill = $Fill
    $Card.Tag.Border = $Border
    $Card.BackColor = $Fill
    $Card.Invalidate()
}

function New-Text {
    param([string]$Text, $Font = $fontUi, $Color = $theme.Text, [int]$Width = 0)
    $l = New-Object System.Windows.Forms.Label
    $l.AutoSize = $true
    $l.Text = $Text
    $l.Font = $Font
    $l.ForeColor = $Color
    $l.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 2)
    if ($Width -gt 0) { $l.MaximumSize = New-Object System.Drawing.Size($Width, 0) }
    return $l
}

function New-Caption {
    param([string]$Text)
    $l = New-Text $Text.ToUpper() $fontCaption $theme.Muted
    $l.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
    return $l
}

# Flat buttons: primary (blue), secondary (grey) or ghost (the card's
# colour, for "More actions"). Hover and press change their shade.
function New-FlatButton {
    param([string]$Text, [string]$Kind = 'secondary', [scriptblock]$OnClick)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Font = $fontUi
    $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $b.FlatAppearance.BorderSize = 0
    $b.UseVisualStyleBackColor = $false
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $b.AutoSize = $true
    $b.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $b.Padding = New-Object System.Windows.Forms.Padding(10, 5, 10, 5)
    $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 8)
    $b.ForeColor = $theme.Text
    switch ($Kind) {
        'primary' { $b.BackColor = $theme.Accent; $b.FlatAppearance.MouseOverBackColor = $theme.AccentHover; $b.FlatAppearance.MouseDownBackColor = $theme.Accent; $b.ForeColor = [System.Drawing.Color]::White }
        'ghost'   { $b.BackColor = $theme.Card; $b.FlatAppearance.MouseOverBackColor = $theme.Button; $b.FlatAppearance.MouseDownBackColor = $theme.Card; $b.ForeColor = $theme.Muted }
        default   { $b.BackColor = $theme.Button; $b.FlatAppearance.MouseOverBackColor = $theme.ButtonHover; $b.FlatAppearance.MouseDownBackColor = $theme.Button }
    }
    $b.add_Click($OnClick)
    return $b
}

function New-Flow {
    param([bool]$Wrap = $false)
    $r = New-Object System.Windows.Forms.FlowLayoutPanel
    $r.AutoSize = $true
    $r.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $r.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
    $r.WrapContents = $Wrap
    if ($Wrap) { $r.MaximumSize = New-Object System.Drawing.Size(($W - 32), 0) }
    $r.Margin = New-Object System.Windows.Forms.Padding(0)
    return $r
}

function Confirm-Koha {
    param([string]$Question, [string]$Detail, [string]$Icon = 'Warning')
    return ([System.Windows.Forms.MessageBox]::Show($form, ($Question + "`n`n" + $Detail), 'Koha', 'YesNo', $Icon) -eq 'Yes')
}
$disconnectText = T 'Anyone using the catalog will be disconnected, and nightly backups will not run until Koha is started again.'

# ----------------------------------------------------------------------
# Layout
# ----------------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = $title
$form.Font = $fontUi
$form.BackColor = $theme.Bg
$form.ForeColor = $theme.Text
$form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
$form.MaximizeBox = $false
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.AutoSize = $true
$form.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
$form.KeyPreview = $true
$kohaIco = Join-Path $here 'koha.ico'
if (Test-Path -LiteralPath $kohaIco) { try { $form.Icon = New-Object System.Drawing.Icon($kohaIco) } catch { } }
# A dark title bar to match (KohaEasy.exe; Windows 10 1809 and later).
$form.add_HandleCreated({
        if (Import-KohaNative) { try { [void][KohaEasy.Native]::SetDarkTitleBar($form.Handle) } catch { } }
    })

$root = New-Object System.Windows.Forms.TableLayoutPanel
$root.AutoSize = $true
$root.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
$root.ColumnCount = 1
$root.Padding = New-Object System.Windows.Forms.Padding(16, 16, 16, 6)
$root.BackColor = $theme.Bg

# Banner: a dot, the state in words, when it was checked and the latest
# backup; Start Koha while Koha is off.
$cardBanner = New-Card 3
[void]$cardBanner.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$cardBanner.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$cardBanner.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
$lblDot = New-Text ([string][char]0x25CF) $fontDot $theme.Grey
$lblDot.Margin = New-Object System.Windows.Forms.Padding(0, 0, 10, 0)
$bannerText = New-Object System.Windows.Forms.TableLayoutPanel
$bannerText.AutoSize = $true
$bannerText.ColumnCount = 1
$bannerText.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 0)
$lblState = New-Text (T 'Checking...') $fontBanner $theme.Text ($W - 200)
$lblChecked = New-Text '' $fontSmall $theme.Muted ($W - 200)
[void]$bannerText.Controls.Add($lblState)
[void]$bannerText.Controls.Add($lblChecked)
$btnStart = New-FlatButton (T 'Start Koha') 'primary' { Invoke-Action 'start' }
$btnStart.Anchor = [System.Windows.Forms.AnchorStyles]::Right
$btnStart.Margin = New-Object System.Windows.Forms.Padding(8, 4, 0, 0)
$btnStart.Visible = $false
[void]$cardBanner.Controls.Add($lblDot, 0, 0)
[void]$cardBanner.Controls.Add($bannerText, 1, 0)
[void]$cardBanner.Controls.Add($btnStart, 2, 0)
[void]$root.Controls.Add($cardBanner)

# Quick access: the staff interface first, then the public catalog.
$cardQuick = New-Card
[void]$cardQuick.Controls.Add((New-Caption (T 'Quick access')))
$quick = New-Flow
$half = [int](($W - 32 - 10) / 2)
foreach ($l in @(
        @{ Text = (T 'Staff interface'); Url = $cfg.StaffUrl; Kind = 'primary' },
        @{ Text = (T 'Public catalog (OPAC)'); Url = $cfg.OpacUrl; Kind = 'secondary' })) {
    $b = New-FlatButton ('{0}{1}{2}' -f $l.Text, "`n", ($l.Url -replace '^https?://', '' -replace '/$', '')) $l.Kind { param($s, $e) Start-Process ([string]$s.Tag) }
    $b.Tag = $l.Url
    $b.AutoSize = $false
    $b.Size = New-Object System.Drawing.Size($half, 50)
    $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 10, 0)
    [void]$quick.Controls.Add($b)
}
$quick.Controls[1].Margin = New-Object System.Windows.Forms.Padding(0)
[void]$cardQuick.Controls.Add($quick)
$lblLan = New-Text '' $fontSmall $theme.Muted ($W - 32)
$lblLan.Margin = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)
$lblLan.Visible = $false
[void]$cardQuick.Controls.Add($lblLan)
[void]$root.Controls.Add($cardQuick)

# The components: a dot, the name, the state (a red badge when it failed).
$cardParts = New-Card
[void]$cardParts.Controls.Add((New-Caption (T 'Components')))
$grid = New-Object System.Windows.Forms.TableLayoutPanel
$grid.AutoSize = $true
$grid.ColumnCount = 3
$grid.MinimumSize = New-Object System.Drawing.Size(($W - 32), 0)
[void]$grid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$grid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$grid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$cardParts.Controls.Add($grid)
$lblNote = New-Text '' $fontSmall $theme.Muted ($W - 32)
$lblNote.Margin = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)
$lblNote.Visible = $false
[void]$cardParts.Controls.Add($lblNote)
[void]$root.Controls.Add($cardParts)
$script:rows = @{}

# The actions: three on the surface, the rest under More actions.
$cardActions = New-Card
[void]$cardActions.Controls.Add((New-Caption (T 'Actions')))
$main = New-Flow
$btnPanel = New-FlatButton ([string][char]0x2699 + '  ' + (T 'Management panel')) 'secondary' { Start-KohaHidden 'Panel' }
$btnServices = New-FlatButton ([string][char]0x27F3 + '  ' + (T 'Restart Koha')) 'secondary' { Invoke-Action 'services' }
$btnConsole = New-FlatButton '' 'secondary' { Set-TerminalOpen (-not $cardTerm.Visible) }
$btnMore = New-FlatButton '' 'ghost' { Set-MoreOpen (-not $more.Visible) }
foreach ($b in $btnPanel, $btnServices, $btnConsole, $btnMore) { [void]$main.Controls.Add($b) }
[void]$cardActions.Controls.Add($main)

$more = New-Flow $true
$more.Margin = New-Object System.Windows.Forms.Padding(0, 4, 0, 0)
$btnStop = New-FlatButton (T 'Stop Koha') 'secondary' { if (Confirm-Koha (T 'Stop Koha?') $disconnectText) { Invoke-Action 'stop' } }
$btnDebian = New-FlatButton (T 'Restart Debian and Koha') 'secondary' { if (Confirm-Koha (T 'Restart Koha?') $disconnectText) { Invoke-Action 'debian' } }
$btnReindex = New-FlatButton (T 'Rebuild search index') 'secondary' {
    if (Confirm-Koha (T 'Rebuild the search index from scratch?') (T 'Searches in the catalog may be incomplete until it finishes. On large catalogs this takes several minutes.') 'Question') { Invoke-Action 'reindex' }
}
$btnLan = New-FlatButton (T 'Test the library network') 'secondary' { Invoke-Action 'lan' }
$btnReport = New-FlatButton (T 'Export diagnostics (.txt)') 'secondary' { Invoke-Action 'report' }
$btnZip = New-FlatButton (T 'Export diagnostics (.zip)') 'secondary' { Start-KohaHidden 'ExportDiagnostics' }
$btnTerminal = New-FlatButton (T 'Debian terminal (advanced)') 'secondary' { Start-KohaHidden 'Terminal' }
foreach ($b in $btnStop, $btnDebian, $btnReindex, $btnLan, $btnReport, $btnZip, $btnTerminal) { [void]$more.Controls.Add($b) }
$more.Visible = $false
[void]$cardActions.Controls.Add($more)

$lblBusy = New-Text '' $fontUi $theme.Muted ($W - 32)
$lblBusy.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 0)
[void]$cardActions.Controls.Add($lblBusy)
[void]$root.Controls.Add($cardActions)

# The terminal area: what the actions do, and one command at a time as the
# Debian user. Folded until Terminal opens it.
$cardTerm = New-Card
$cardTerm.Tag.Fill = $theme.Term
$cardTerm.BackColor = $theme.Term
$termHead = New-Flow
[void]$termHead.Controls.Add((New-Caption (T 'Terminal')))
[void]$cardTerm.Controls.Add($termHead)
$term = New-Object System.Windows.Forms.RichTextBox
$term.ReadOnly = $true
$term.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$term.BackColor = $theme.Term
$term.ForeColor = $theme.TermText
$term.Font = $fontMono
$term.Size = New-Object System.Drawing.Size(($W - 32), 190)
$term.ScrollBars = [System.Windows.Forms.RichTextBoxScrollBars]::Vertical
$term.DetectUrls = $false
$term.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
[void]$cardTerm.Controls.Add($term)
$prompt = New-Flow
$lblPrompt = New-Text '~$' $fontMono $theme.Green
$lblPrompt.Margin = New-Object System.Windows.Forms.Padding(0, 3, 6, 0)
$txtCmd = New-Object System.Windows.Forms.TextBox
$txtCmd.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$txtCmd.BackColor = $theme.Term
$txtCmd.ForeColor = $theme.TermText
$txtCmd.Font = $fontMono
$txtCmd.Width = $W - 32 - 40
$txtCmd.Margin = New-Object System.Windows.Forms.Padding(0, 3, 0, 0)
$txtCmd.add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq 'Enter') {
            $e.SuppressKeyPress = $true
            $c = $txtCmd.Text.Trim()
            if ($c) { $txtCmd.Text = ''; Invoke-Action 'command' $c }
        }
    })
[void]$prompt.Controls.Add($lblPrompt)
[void]$prompt.Controls.Add($txtCmd)
[void]$cardTerm.Controls.Add($prompt)
$lblTermHint = New-Text (T 'One command at a time, as the Debian user. For programs that ask questions, use the Debian terminal (More actions).') $fontSmall $theme.Grey ($W - 32)
$lblTermHint.Margin = New-Object System.Windows.Forms.Padding(0, 6, 0, 0)
[void]$cardTerm.Controls.Add($lblTermHint)
$cardTerm.Visible = $false
[void]$root.Controls.Add($cardTerm)

$form.Controls.Add($root)

function Set-TerminalOpen {
    param([bool]$Open)
    $cardTerm.Visible = $Open
    $arrow = [string][char]0x25BE
    if ($Open) { $arrow = [string][char]0x25B4 }
    $btnConsole.Text = '>_  ' + (T 'Terminal') + '  ' + $arrow
    if ($Open) { $term.SelectionStart = $term.TextLength; $term.ScrollToCaret(); [void]$txtCmd.Focus() }
}
function Set-MoreOpen {
    param([bool]$Open)
    $more.Visible = $Open
    $arrow = [string][char]0x25BE
    if ($Open) { $arrow = [string][char]0x25B4 }
    $btnMore.Text = (T 'More actions') + '  ' + $arrow
}
Set-TerminalOpen $false
Set-MoreOpen $false

# ----------------------------------------------------------------------
# The terminal area's lines
# ----------------------------------------------------------------------
$script:queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
function Write-Term {
    param([string]$Line, $Color = $null)
    if ($null -eq $Color) {
        $Color = $theme.TermText
        if ($Line -match '\[OK\]') { $Color = $theme.Green }
        elseif ($Line -match '\[FAILED\]|failed|error') { $Color = $theme.Red }
    }
    if ($term.TextLength -gt 200000) { $term.Select(0, 100000); $term.SelectedText = '' }
    $term.SelectionStart = $term.TextLength
    $term.SelectionLength = 0
    $term.SelectionColor = $Color
    $term.AppendText($Line + "`n")
    $term.SelectionColor = $term.ForeColor
    $term.ScrollToCaret()
}
function Read-TermQueue {
    $line = $null
    $n = 0
    while ($n -lt 200 -and $script:queue.TryDequeue([ref]$line)) { Write-Term $line; $n++ }
}

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
$script:spin = 0

$worker = {
    param($LangDir, $Action, $Queue, $Command)
    Import-KeiLanguage -LangDir $LangDir
    # The terminal area shows what an action does, not the periodic checks.
    if ($Action -eq 'refresh') { Set-KohaOutputSink $null } else { Set-KohaOutputSink $Queue }
    $result = $null
    try {
        switch ($Action) {
            'start'    { $result = Start-Koha -Trigger user -Wait }
            'stop'     { $result = Stop-Koha }
            'services' { $result = Restart-KohaServices }
            'debian'   { Stop-Koha | Out-Null; $result = Start-Koha -Trigger user -Wait }
            'report'   { $result = Export-KohaDiagnosticsText }
            'reindex'  { $result = Invoke-KohaSearchReindex }
            'lan'      { $result = Test-KohaLanAccess }
            'command'  {
                $result = Invoke-KohaUserCommand -Command $Command
                if ($null -ne $result) {
                    foreach ($l in ([string]$result.Output -split "`n")) { $Queue.Enqueue($l.TrimEnd()) }
                }
                # A command changes nothing the banner shows: no new check.
                return [pscustomobject]@{ Action = $Action; Result = $result; Status = $null; Health = $null; Lan = $null }
            }
        }
    } finally {
        Set-KohaOutputSink $null
    }
    $lan = $null
    if ([bool](Get-KohaState)['lanAccess']) { $lan = Get-KohaLanUrls }
    return [pscustomobject]@{ Action = $Action; Result = $result; Status = (Get-KohaStatus); Health = (Get-KohaServiceHealth); Lan = $lan }
}

$busyText = @{
    refresh  = (T 'Checking...')
    start    = (T 'Starting Koha... (up to 3 minutes)')
    stop     = (T 'Stopping Koha...')
    services = (T 'Restarting Koha services...')
    debian   = (T 'Restarting Debian and Koha... (up to 3 minutes)')
    report   = (T 'Collecting diagnostics... This can take a minute.')
    reindex  = (T 'Rebuilding the search index... On large catalogs this takes several minutes.')
    lan      = (T 'Testing the library network...')
    command  = (T 'Running the command...')
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
    $btnReindex.Enabled = (-not $Busy) -and $on
    $btnLan.Enabled = (-not $Busy) -and $on
    $btnTerminal.Enabled = (-not $Busy) -and $on
    $txtCmd.Enabled = (-not $Busy) -and $on
    $btnReport.Enabled = -not $Busy
    $btnPanel.Enabled = $installed
}

function Invoke-Action {
    param([string]$Action, [string]$Command = '')
    if ($null -ne $script:job) { return }
    if ($Action -ne 'refresh') {
        $lblBusy.ForeColor = $theme.Amber
        $lblBusy.Text = $busyText[$Action]
        if ($Action -eq 'command') { Write-Term ('~$ ' + $Command) $theme.Green }
        else { Write-Term ('# ' + $busyText[$Action]) $theme.Muted }
    }
    Set-Buttons $true
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($worker).AddArgument($langDir).AddArgument($Action).AddArgument($script:queue).AddArgument($Command)
    $script:job = @{ PS = $ps; Handle = $ps.BeginInvoke(); Action = $Action }
}

# One row per component, made on the first check (the list never changes).
function Get-Row {
    param($Service)
    $u = [string]$Service.Unit
    if ($script:rows.ContainsKey($u)) { return $script:rows[$u] }
    $i = $grid.RowCount
    $grid.RowCount = $i + 1
    $dot = New-Text ([string][char]0x25CF) $fontUi $theme.Grey
    $dot.Margin = New-Object System.Windows.Forms.Padding(0, 5, 8, 5)
    $name = New-Text (Get-KohaServiceName $Service) $fontUi $theme.Text
    $name.Margin = New-Object System.Windows.Forms.Padding(0, 5, 8, 5)
    $state = New-Text '' $fontSmall $theme.Muted
    $state.Anchor = [System.Windows.Forms.AnchorStyles]::Right
    $state.Padding = New-Object System.Windows.Forms.Padding(8, 2, 8, 2)
    [void]$grid.Controls.Add($dot, 0, $i)
    [void]$grid.Controls.Add($name, 1, $i)
    [void]$grid.Controls.Add($state, 2, $i)
    $r = @{ Dot = $dot; Name = $name; State = $state }
    $script:rows[$u] = $r
    return $r
}

function Update-View {
    param($Status, $Health, $Lan)
    $script:status = $Status
    $script:health = $Health
    $sum = Get-KohaHealthSummary -Health $Health -State ([string]$Status.State)
    $look = $banner[$sum.Level]
    $root.SuspendLayout()
    Set-CardColor $cardBanner $look.Fill $look.Border
    $lblDot.ForeColor = $look.Dot
    $lblState.Text = $sum.Text
    $btnStart.Visible = ($Status.State -ne 'not_installed') -and (-not [bool]$Health.DebianRunning)

    $when = @((T 'Checked at {0}') -f (Get-Date).ToString('T'))
    if ($null -ne $Status.Linux) {
        if ([int64]$Status.Linux.backup.last_epoch -gt 0) {
            $at = [DateTimeOffset]::FromUnixTimeSeconds([int64]$Status.Linux.backup.last_epoch).LocalDateTime
            $when += (T 'Latest backup: {0} ({1})') -f $at.ToString('g'), (Format-KohaSize ([double]$Status.Linux.backup.last_size))
        } else {
            $when += T 'Latest backup: none yet'
        }
    }
    $lblChecked.Text = $when -join '   |   '

    foreach ($s in @($Health.Services)) {
        $r = Get-Row $s
        $r.State.Text = Get-KohaServiceStateText -State $s.State -Unit $s.Unit -Detail $s.Detail
        if (@($sum.Broken) -contains [string]$s.Unit) {
            # Only what is broken stands out: a red dot and a red badge.
            $r.Dot.ForeColor = $theme.Red
            $r.State.BackColor = $theme.Red
            $r.State.ForeColor = [System.Drawing.Color]::White
        } else {
            $c = $dotColor[[string]$s.State]
            if ($sum.Level -eq 'fault' -and [string]$s.State -ne 'running') { $c = $theme.Grey }
            $r.Dot.ForeColor = $c
            $r.State.BackColor = $cardParts.BackColor
            $r.State.ForeColor = $theme.Muted
        }
    }

    $notes = @()
    if ($Status.Autostart -eq 'manual') { $notes += T 'Koha starts only when you click Koha - Start.' }
    $lblNote.Text = $notes -join "`n"
    $lblNote.Visible = ($notes.Count -gt 0)

    if ($null -ne $Lan) {
        $staff = $Lan.StaffByName
        $opac = $Lan.OpacByName
        if (-not $staff) { $staff = $Lan.Staff; $opac = $Lan.Opac }
        $lblLan.Text = (T 'Other computers of the library network: staff interface {0}  public catalog {1}') -f $staff, $opac
        $lblLan.Visible = $true
    } else {
        $lblLan.Visible = $false
    }
    $root.ResumeLayout()
}

function Show-Result {
    param([string]$Action, $Result)
    $ok = $theme.Green
    $bad = $theme.Red
    $text = ''
    $color = $ok
    switch ($Action) {
        'start' {
            if ($Result -eq 'ready') { $text = T 'Koha is running' } else { $text = T 'Koha did not start. Open Koha - Status, or export the diagnostics from the tray menu.'; $color = $bad }
        }
        'debian' {
            if ($Result -eq 'ready') { $text = T 'Koha is running' } else { $text = T 'Koha did not start. Open Koha - Status, or export the diagnostics from the tray menu.'; $color = $bad }
        }
        'stop' { $text = T 'Koha is stopped. Use Koha - Start to turn it on again.'; $color = $theme.Muted }
        'services' {
            switch ([string]$Result) {
                'ready'       { $text = T 'Koha services restarted.' }
                'not_running' { $text = T 'Debian is stopped. Start Koha first.'; $color = $bad }
                default       { $text = T 'Koha services restarted, but the staff interface does not answer yet. Export the diagnostics and send them to whoever supports your library.'; $color = $bad }
            }
        }
        'reindex' {
            switch ([string]$Result) {
                'rebuilt'     { $text = T 'The search index was rebuilt.' }
                'not_running' { $text = T 'Debian is stopped. Start Koha first.'; $color = $bad }
                default       { $text = T 'Rebuilding the search index failed. Export the diagnostics and send them to whoever supports your library.'; $color = $bad }
            }
        }
        'lan' {
            $text = @($Result.Lines | ForEach-Object { $_.Text }) -join "`n"
            if (-not $Result.Ok -or @($Result.Lines | Where-Object { $_.Kind -eq 'warn' }).Count -gt 0) { $color = $bad }
        }
        'report' {
            $text = ((T 'Diagnostics saved on the desktop: {0}') -f $Result) + "`n" + (T 'Send this file to whoever supports your library. Passwords are not included.')
            try { Start-Process explorer.exe -ArgumentList ('/select,"{0}"' -f $Result) } catch { }
        }
        'command' {
            if ($null -eq $Result) { $text = T 'Debian is stopped. Start Koha first.'; $color = $bad }
            elseif ([int]$Result.ExitCode -eq 124) { $text = T 'The command took too long and was stopped. For programs that ask questions, use the Debian terminal (More actions).'; $color = $bad }
            else {
                $text = ''
                if ([int]$Result.ExitCode -ne 0) { Write-Term ((T 'exit code {0}') -f $Result.ExitCode) $theme.Red }
            }
        }
    }
    if ($Action -ne 'command' -and $text) { Write-Term ('# ' + ($text -split "`n")[0]) $color }
    $lblBusy.ForeColor = $color
    $lblBusy.Text = $text
}

$spinner = @([char]0x25D0, [char]0x25D3, [char]0x25D1, [char]0x25D2)
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 250
$timer.add_Tick({
        Read-TermQueue
        if ($null -ne $script:job) {
            if (-not $script:job.Handle.IsCompleted) {
                if ($script:job.Action -ne 'refresh') {
                    $script:spin = ($script:spin + 1) % 4
                    $lblBusy.Text = [string]$spinner[$script:spin] + '  ' + $busyText[$script:job.Action]
                }
                return
            }
            $action = $script:job.Action
            try {
                $res = @($script:job.PS.EndInvoke($script:job.Handle))
                $r = $null
                if ($res.Count -gt 0) { $r = $res[-1] }
                if ($null -ne $r) {
                    if ($null -ne $r.Status) { Update-View $r.Status $r.Health $r.Lan }
                    Read-TermQueue
                    if ($action -ne 'refresh') { Show-Result $action $r.Result }
                } elseif ($script:job.PS.Streams.Error.Count -gt 0) {
                    throw $script:job.PS.Streams.Error[0].Exception
                }
            } catch {
                Write-KohaLog ('Koha window: {0} failed: {1}' -f $action, $_.Exception.Message)
                $lblBusy.ForeColor = $theme.Red
                $lblBusy.Text = $_.Exception.Message
                Write-Term $_.Exception.Message $theme.Red
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
            Invoke-Action 'refresh'
        }
    })

# F5 checks again now (the check also runs every 30 seconds).
$form.add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq 'F5') { $e.Handled = $true; Invoke-Action 'refresh' }
    })
$form.add_Shown({ $form.Activate(); Invoke-Action 'refresh'; $timer.Start() })
$script:closeWhenDone = $false
$form.add_FormClosing({
        param($s, $e)
        # A Start, Stop or Restart in progress finishes first, out of sight:
        # cutting it short could leave Debian's services half restarted.
        if ($null -ne $script:job -and $script:job.Action -ne 'refresh' -and $script:job.Action -ne 'command') {
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
