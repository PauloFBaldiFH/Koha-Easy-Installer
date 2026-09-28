<#
.SYNOPSIS
    Koha Easy Installer for Windows: shortcuts, scheduled tasks and tray.
.DESCRIPTION
    KohaEasy.ps1 Start [-Trigger user|logon]   Koha - Start shortcut, tray, sign-in task
    KohaEasy.ps1 Stop [-Force]                 Koha - Stop shortcut, tray
    KohaEasy.ps1 Restart [-Force]              Koha - Restart shortcut, tray
    KohaEasy.ps1 Status                        Koha - Status shortcut
    KohaEasy.ps1 Run                           action of the "Keep Koha running" task
    KohaEasy.ps1 Tray                          notification-area icon (starts at sign-in)
    KohaEasy.ps1 ExportDiagnostics             .zip for support on the desktop
    KohaEasy.ps1 CheckDisk                     free space around the virtual disk
    KohaEasy.ps1 CompactDisk                   give unused space back to Windows (admin)
    KohaEasy.ps1 SetAutostart -Mode logon|manual
    KohaEasy.ps1 RegisterTasks [-Mode logon|manual]   tasks, tray at sign-in and shortcuts
    KohaEasy.ps1 CreateShortcuts               Start menu "Koha" and desktop, with koha.ico
    -Quiet: no dialog boxes (scheduled tasks). Windows PowerShell 5.1.
#>
param(
    [Parameter(Position = 0)]
    [ValidateSet('Start', 'Stop', 'Restart', 'Status', 'Run', 'Tray', 'ExportDiagnostics', 'CheckDisk', 'CompactDisk', 'SetAutostart', 'RegisterTasks', 'CreateShortcuts')]
    [string]$Command = 'Status',
    [ValidateSet('user', 'logon')][string]$Trigger = 'user',
    [ValidateSet('logon', 'manual')][string]$Mode,
    [switch]$Force,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'KohaEasy.Lang.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'KohaEasy.Core.psm1') -Force
$langDir = Join-Path $PSScriptRoot 'lang'
if (-not (Test-Path -LiteralPath $langDir)) { $langDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'lang' }
Import-KeiLanguage -LangDir $langDir
$cfg = Get-KohaConfig
if ($Trigger -eq 'logon') { $Quiet = $true }

function Show-Box {
    param([string]$Text, [string]$Buttons = 'OK', [string]$Icon = 'Information')
    if ($Quiet) { return 'None' }
    Add-Type -AssemblyName System.Windows.Forms
    return [string][System.Windows.Forms.MessageBox]::Show($Text, 'Koha', $Buttons, $Icon)
}

function Confirm-Stop {
    param([string]$Question)
    if ($Force -or $Quiet) { return $true }
    return ((Show-Box ($Question + "`n`n" + (T 'Anyone using the catalog will be disconnected, and nightly backups will not run until Koha is started again.')) 'YesNo' 'Warning') -eq 'Yes')
}

function Invoke-Start {
    $r = Start-Koha -Trigger $Trigger -Wait:(-not $Quiet)
    if ($Quiet) { return }
    if ($r -eq 'ready') {
        if ((Show-Box (T 'Koha is running. Open the staff interface now?') 'YesNo') -eq 'Yes') { Start-Process $cfg.StaffUrl }
    } elseif ($r -eq 'timeout') {
        Show-Box (T 'Koha did not start. Open Koha - Status, or export the diagnostics from the tray menu.') 'OK' 'Error' | Out-Null
    }
}

switch ($Command) {
    'Start' {
        if (-not $Quiet) { Show-KohaNotification -Title 'Koha' -Text (T 'Starting Koha... (up to 3 minutes)') | Out-Null }
        Invoke-Start
    }
    'Stop' {
        if (Confirm-Stop (T 'Stop Koha?')) {
            Stop-Koha | Out-Null
            Show-Box (T 'Koha is stopped. Use Koha - Start to turn it on again.') | Out-Null
        }
    }
    'Restart' {
        if (Confirm-Stop (T 'Restart Koha?')) {
            Stop-Koha | Out-Null
            Invoke-Start
        }
    }
    'Status' {
        $s = Get-KohaStatus
        $lines = @(Get-KohaStateText $s.State)
        if ($s.Autostart -eq 'manual') { $lines += T 'Koha starts only when you click Koha - Start.' }
        if ($null -ne $s.Linux) {
            if ([int64]$s.Linux.backup.last_epoch -gt 0) {
                $when = [DateTimeOffset]::FromUnixTimeSeconds([int64]$s.Linux.backup.last_epoch).LocalDateTime
                $lines += (T 'Latest backup: {0} ({1})') -f $when.ToString('g'), (Format-KohaSize ([double]$s.Linux.backup.last_size))
            } else {
                $lines += T 'Latest backup: none yet'
            }
        }
        $disk = Get-KohaDiskHealth -Linux $s.Linux
        if ($disk.Message) { $lines += $disk.Message }
        if ($s.State -eq 'not_responding') {
            if ((Show-Box (($lines -join "`n`n") + "`n`n" + (T 'Restart Koha now?')) 'YesNo' 'Warning') -eq 'Yes') {
                Stop-Koha | Out-Null
                Invoke-Start
            }
        } else {
            Show-Box ($lines -join "`n`n") | Out-Null
        }
    }
    'Run' { exit (Invoke-KohaRun) }
    'Tray' { & (Join-Path $PSScriptRoot 'KohaEasy.Tray.ps1') }
    'ExportDiagnostics' {
        if (-not $Quiet) { Show-KohaNotification -Title 'Koha' -Text (T 'Collecting diagnostics... This can take a minute.') | Out-Null }
        $zip = Export-KohaDiagnostics
        if (-not $Quiet) {
            Show-Box ((T 'Diagnostics saved on the desktop:') + "`n$zip`n`n" + (T 'Send this file to whoever supports your library. Passwords are not included.')) | Out-Null
            Start-Process explorer.exe -ArgumentList ('/select,"{0}"' -f $zip)
        } else {
            $zip
        }
    }
    'CheckDisk' {
        $linux = $null
        if (Test-KohaDistroRunning) { $linux = Get-KohaLinuxStatus }
        $d = Get-KohaDiskHealth -Linux $linux
        $text = (T 'Free on drive {0}: {1}. Koha virtual disk: {2}.') -f $d.Drive, (Format-KohaSize $d.HostFree), (Format-KohaSize $d.VhdxSize)
        if ($d.Message) { $text += "`n`n" + $d.Message }
        if ($Quiet) { $d; break }
        if ($d.Reclaimable -gt 10GB) {
            $q = $text + "`n`n" + ((T 'About {0} can be given back to Windows. Compact the disk now? Koha stops for a few minutes and Windows asks for administrator rights.') -f (Format-KohaSize $d.Reclaimable))
            if ((Show-Box $q 'YesNo') -eq 'Yes') {
                $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                Start-Process $ps -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "{0}" CompactDisk -Force' -f $PSCommandPath)
            }
        } else {
            Show-Box $text | Out-Null
        }
    }
    'CompactDisk' {
        if (-not $Force) {
            if ((Show-Box (T 'Compact the Koha disk? Koha and any other Linux (WSL) window stop for a few minutes.') 'YesNo' 'Warning') -ne 'Yes') { break }
        }
        $r = Invoke-KohaDiskCompact
        Show-Box ((T 'Done. {0} given back to Windows.') -f (Format-KohaSize $r.Freed)) | Out-Null
    }
    'SetAutostart' {
        if (-not $Mode) { throw 'SetAutostart needs -Mode logon or -Mode manual' }
        Set-KohaAutostart -Mode $Mode | Out-Null
        if ($Mode -eq 'manual' -and (Test-KohaDistroRunning) -and -not $Quiet) {
            if ((Show-Box (T 'Koha will no longer start when you sign in to Windows. It is still running now: stop it now?') 'YesNo') -eq 'Yes') {
                Stop-Koha | Out-Null
            }
        }
    }
    'RegisterTasks' {
        if ($Mode) { Register-KohaTasks -Autostart $Mode } else { Register-KohaTasks }
        Set-KohaTrayAtSignIn -Enabled $true
        New-KohaShortcuts | Out-Null
    }
    'CreateShortcuts' { New-KohaShortcuts }
}
