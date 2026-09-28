# Koha Easy Installer for Windows: the install flow (blueprint 2.3).
# Started by windows\install.ps1 (the irm | iex one-liner and Install Koha.cmd)
# as "KohaEasy.ps1 Install". Every phase is idempotent and recorded in
# state.json, so running Install again (or the RunOnce entry after a
# restart) continues where it stopped:
#   checks    Windows version, 64-bit, memory, disk, virtualization
#   wsl       WSL 2 platform (one UAC prompt; a restart when Windows asks)
#   distro    Debian imported as "KohaEasy" from Microsoft's own WSL list
#   systemd   /etc/wsl.conf with systemd, .wslconfig (mirrored on Win 11)
#   koha      the panel copied in and opened for "1 - Install Koha server"
#   windows   tasks, automatic start choice, shortcuts, tray, first start
# Windows PowerShell 5.1 compatible. UTF-8 with BOM.

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'KohaEasy.Lang.psm1')
Import-Module (Join-Path $PSScriptRoot 'KohaEasy.Core.psm1')

$script:ManifestUrl = 'https://raw.githubusercontent.com/microsoft/WSL/master/distributions/DistributionInfo.json'
$script:Phases = @('checks', 'wsl', 'distro', 'systemd', 'koha', 'windows', 'done')
$script:DistroDir = '/root/koha-easy-installer'

function Write-KohaStep {
    param([string]$Text, [ValidateSet('step', 'ok', 'warn', 'error')][string]$Kind = 'step')
    $color = @{ step = 'Cyan'; ok = 'Green'; warn = 'Yellow'; error = 'Red' }[$Kind]
    $mark = @{ step = '>'; ok = 'OK'; warn = '!'; error = 'X' }[$Kind]
    Write-Host ('[{0}] {1}' -f $mark, $Text) -ForegroundColor $color
    Write-KohaLog ('install: [{0}] {1}' -f $Kind, $Text) 'install'
}

function Test-KohaPhaseDone {
    param([string]$Phase, [string]$Current)
    $i = [array]::IndexOf($script:Phases, $Phase)
    $c = [array]::IndexOf($script:Phases, $Current)
    return ($c -gt $i)
}

# ----------------------------------------------------------------------
# Checks
# ----------------------------------------------------------------------
function Get-KohaHostFacts {
    $f = @{ Build = [Environment]::OSVersion.Version.Build; Is64 = [Environment]::Is64BitOperatingSystem
        MemGB = 0; FreeGB = 0; VirtFirmware = $null; Hypervisor = $false; Arm = $false }
    try { $f.MemGB = [Math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1) } catch { }
    try { $f.Hypervisor = [bool](Get-CimInstance Win32_ComputerSystem).HypervisorPresent } catch { }
    try { $f.VirtFirmware = [bool](Get-CimInstance Win32_Processor | Select-Object -First 1).VirtualizationFirmwareEnabled } catch { }
    try { $f.FreeGB = [Math]::Round((New-Object System.IO.DriveInfo((Get-KohaPath Root).Substring(0, 2))).AvailableFreeSpace / 1GB, 1) } catch { }
    $f.Arm = ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64')
    return $f
}

# Pure: one row per check (Level ok | warn | error).
function Get-KohaPreflight {
    param([hashtable]$Facts)
    $rows = New-Object System.Collections.ArrayList
    $add = { param($ok, $level, $text) [void]$rows.Add([pscustomobject]@{ Ok = $ok; Level = $(if ($ok) { 'ok' } else { $level }); Text = $text }) }
    & $add ($Facts.Build -ge 19041) 'error' ((T 'Windows 10 version 2004 (build 19041) or later, or Windows 11. This PC: build {0}.') -f $Facts.Build)
    & $add ([bool]$Facts.Is64) 'error' (T 'A 64-bit Windows.')
    if ($Facts.MemGB -lt 4) {
        & $add $false 'error' ((T 'At least 4 GB of memory (8 GB recommended). This PC: {0} GB.') -f $Facts.MemGB)
    } else {
        & $add ($Facts.MemGB -ge 8) 'warn' ((T 'At least 4 GB of memory (8 GB recommended). This PC: {0} GB.') -f $Facts.MemGB)
    }
    if ($Facts.FreeGB -lt 10) {
        & $add $false 'error' ((T 'At least 10 GB free on drive C: (20 GB recommended). Free now: {0} GB.') -f $Facts.FreeGB)
    } else {
        & $add ($Facts.FreeGB -ge 20) 'warn' ((T 'At least 10 GB free on drive C: (20 GB recommended). Free now: {0} GB.') -f $Facts.FreeGB)
    }
    # With Hyper-V already running, Windows hides the firmware flag: that is fine.
    $virt = ($Facts.Hypervisor -or $Facts.VirtFirmware -ne $false)
    & $add $virt 'error' (T 'Virtualization turned on in the BIOS/UEFI (Intel VT-x or AMD-V, sometimes called SVM).')
    return @($rows)
}

# ----------------------------------------------------------------------
# WSL 2 platform
# ----------------------------------------------------------------------
function Test-KohaWslReady {
    $r = Invoke-KohaWsl -Arguments @('--version')
    return ($r.ExitCode -eq 0)
}

# One UAC prompt: "wsl --install --no-distribution" enables the Windows
# features and installs WSL from the Store package; then "wsl --update".
function Install-KohaWslPlatform {
    Start-KohaElevated -FilePath 'wsl.exe' -Arguments '--install --no-distribution' | Out-Null
    Start-KohaElevated -FilePath 'wsl.exe' -Arguments '--update' | Out-Null
}

function Start-KohaElevated {
    param([string]$FilePath, [string]$Arguments)
    $p = Start-Process -FilePath $FilePath -ArgumentList $Arguments -Verb RunAs -Wait -PassThru
    return $p.ExitCode
}

# After a restart, Install runs again by itself (HKCU RunOnce, no admin).
function Register-KohaResume {
    $ps = [System.IO.Path]::Combine([string]$env:SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
    $cmd = '"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}" Install' -f $ps, (Get-KohaScriptPath)
    New-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'KohaEasyInstall' -Value $cmd -PropertyType String -Force | Out-Null
}

# ----------------------------------------------------------------------
# Debian distro
# ----------------------------------------------------------------------
# Pure: the Debian image of Microsoft's distribution list (the one that
# "wsl --install Debian" uses) for this processor: Url and Sha256.
function Get-KohaDebianImage {
    param([Parameter(Mandatory = $true)]$Manifest, [bool]$Arm = $false)
    if (-not $Manifest.PSObject.Properties['ModernDistributions']) { throw 'DistributionInfo.json has no ModernDistributions' }
    $debs = @($Manifest.ModernDistributions.Debian)
    $pick = @($debs | Where-Object { $_.PSObject.Properties['Default'] -and $_.Default }) + $debs | Select-Object -First 1
    if ($null -eq $pick) { throw 'Debian is not in the WSL distribution list' }
    $key = 'Amd64Url'
    if ($Arm) { $key = 'Arm64Url' }
    $img = $pick.$key
    $sha = ([string]$img.Sha256) -replace '^0x', ''
    return [pscustomobject]@{ Name = $pick.Name; Url = [string]$img.Url; Sha256 = $sha.ToUpperInvariant() }
}

function Get-KohaDistributionManifest { return (Invoke-RestMethod -Uri $script:ManifestUrl -UseBasicParsing) }

function Save-KohaDownload {
    param([string]$Url, [string]$Path)
    $prev = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'   # the progress bar makes 5.1 downloads many times slower
    try { Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing } finally { $ProgressPreference = $prev }
}

# Imports Debian as "KohaEasy" into C:\KohaEasy\wsl, after checking the
# SHA-256 that Microsoft publishes for the image.
function New-KohaDistro {
    param([bool]$Arm = $false)
    if (Test-KohaDistroInstalled) { return 'exists' }
    $img = Get-KohaDebianImage -Manifest (Get-KohaDistributionManifest) -Arm $Arm
    $dir = Get-KohaPath Wsl
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $file = [System.IO.Path]::Combine($dir, 'debian-rootfs.tar.gz')
    Save-KohaDownload -Url $img.Url -Path $file
    try {
        $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($img.Sha256 -and $hash -ne $img.Sha256) { throw ((T 'The downloaded Debian image is damaged (SHA-256 does not match). Run the installer again.')) }
        $r = Invoke-KohaWsl -Arguments @('--import', (Get-KohaConfig).Distro, $dir, $file, '--version', '2')
        if ($r.ExitCode -ne 0) { throw ('wsl --import: ' + $r.Output) }
    } finally {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
    return 'imported'
}

# ----------------------------------------------------------------------
# systemd and WSL settings
# ----------------------------------------------------------------------
function Get-KohaWslConf {
    return (@(
            '# Written by Koha Easy Installer for Windows.'
            '[boot]'
            'systemd=true'
            ''
            '[user]'
            'default=root'
            ''
            '[interop]'
            'appendWindowsPath=false'
        ) -join "`n") + "`n"
}

# Pure: adds the keys Koha needs to the user's .wslconfig without changing
# anything the user already set. vmIdleTimeout=-1 keeps WSL running while
# Koha waits for readers; networkingMode=mirrored (Windows 11 22H2+) lets
# other PCs of the library reach Koha by this PC's name.
function Merge-KohaWslConfig {
    param([AllowEmptyString()][string]$Text, [int]$Build)
    $want = [ordered]@{ vmIdleTimeout = '-1' }
    if ($Build -ge 22621) { $want['networkingMode'] = 'mirrored' }
    $lines = New-Object System.Collections.ArrayList
    if ($Text) { foreach ($l in ($Text -split "`r?`n")) { [void]$lines.Add($l) } }
    while ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') { $lines.RemoveAt($lines.Count - 1) }
    $start = -1; $end = $lines.Count
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*\[(.+)\]\s*$') {
            if ($start -ge 0) { $end = $i; break }
            if ($Matches[1].Trim() -ieq 'wsl2') { $start = $i }
        }
    }
    if ($start -lt 0) {
        if ($lines.Count -gt 0) { [void]$lines.Add('') }
        [void]$lines.Add('[wsl2]')
        $start = $lines.Count - 1; $end = $lines.Count
    }
    $present = @{}
    for ($i = $start + 1; $i -lt $end; $i++) {
        if ($lines[$i] -match '^\s*([A-Za-z0-9_.]+)\s*=') { $present[$Matches[1].ToLowerInvariant()] = $true }
    }
    $insert = $end
    while ($insert -gt $start + 1 -and $lines[$insert - 1].Trim() -eq '') { $insert-- }
    foreach ($k in $want.Keys) {
        if (-not $present.ContainsKey($k.ToLowerInvariant())) {
            $lines.Insert($insert, ('{0}={1}' -f $k, $want[$k]))
            $insert++
        }
    }
    return (($lines -join "`r`n") + "`r`n")
}

function Update-KohaWslConfig {
    param([int]$Build = [Environment]::OSVersion.Version.Build)
    $file = [System.IO.Path]::Combine([string]$env:USERPROFILE, '.wslconfig')
    $old = ''
    if (Test-Path -LiteralPath $file) { $old = [System.IO.File]::ReadAllText($file) }
    $new = Merge-KohaWslConfig -Text $old -Build $Build
    if ($new -eq $old) { return $false }
    if ($old) { Copy-Item -LiteralPath $file -Destination ($file + '.kohaeasy.bak') -Force }
    [System.IO.File]::WriteAllText($file, $new, (New-Object System.Text.UTF8Encoding($false)))
    return $true
}

function Test-KohaSystemd {
    $r = Invoke-KohaLinux -Command @('sh', '-c', 'cat /proc/1/comm')
    return ($r.ExitCode -eq 0 -and $r.Output.Trim() -eq 'systemd')
}

function Set-KohaDistroConfig {
    $r = Invoke-KohaLinux -Command @('sh', '-c', 'cat > /etc/wsl.conf') -InputText (Get-KohaWslConf)
    if ($r.ExitCode -ne 0) { throw ('wsl.conf: ' + $r.Output) }
    $changed = Update-KohaWslConfig
    if ($changed) {
        # .wslconfig is read when the WSL virtual machine starts.
        Write-KohaStep (T 'Restarting WSL to apply the settings (other Linux windows will close).') 'warn'
        Invoke-KohaWsl -Arguments @('--shutdown') | Out-Null
    } else {
        Invoke-KohaWsl -Arguments @('--terminate', (Get-KohaConfig).Distro) | Out-Null
    }
    Start-Sleep -Seconds 3
    for ($i = 0; $i -lt 10; $i++) {
        if (Test-KohaSystemd) { return $true }
        Start-Sleep -Seconds 3
    }
    return $false
}

# ----------------------------------------------------------------------
# Koha (the panel inside Debian)
# ----------------------------------------------------------------------
function ConvertTo-KohaWslPath {
    param([string]$Path)
    if ($Path -match '^([A-Za-z]):[\\/](.*)$') { return '/mnt/' + $Matches[1].ToLowerInvariant() + '/' + ($Matches[2] -replace '[\\/]', '/') }
    return $Path
}

# Copies the installer and its dictionaries into Debian and checks the
# SHA-256 again on the Linux side.
function Copy-KohaPanelIntoDistro {
    $src = ConvertTo-KohaWslPath (Get-KohaPath Bin)
    $sh = 'set -e; d={0}; mkdir -p "$d/lang"; cp "{1}/installer" "{1}/installer.sha256" "$d/"; cp "{1}"/lang/*.cache "$d/lang/" 2>/dev/null || true; cd "$d" && sha256sum -c installer.sha256' -f $script:DistroDir, $src
    $r = Invoke-KohaLinux -Command @('sh', '-c', $sh)
    if ($r.ExitCode -ne 0) { throw ('copy: ' + $r.Output) }
}

function Test-KohaInstalledInDistro {
    $r = Invoke-KohaLinux -Command @('test', '-f', '/etc/koha/sites/library/koha-conf.xml')
    return ($r.ExitCode -eq 0)
}

# The panel runs in this window: the librarian picks the language and
# "1 - Install Koha server", then leaves the panel with Exit. Start-Process
# -NoNewWindow hands it the console itself; "& wsl.exe" here would send its
# screens into Install-Koha's return value, and the panel could not draw.
function Invoke-KohaPanel {
    $a = '-d {0} -u root --cd {1} -- bash ./installer' -f (Get-KohaConfig).Distro, $script:DistroDir
    $p = Start-Process -FilePath 'wsl.exe' -ArgumentList $a -NoNewWindow -Wait -PassThru
    return [int]$p.ExitCode
}

# ----------------------------------------------------------------------
# The whole flow
# ----------------------------------------------------------------------
# Yes unless the answer starts with n (no, não, non, nein, nee, nej, nie, net...).
function Read-KohaYesNo {
    param([string]$Question)
    $a = Read-Host ('{0} [Y/n]' -f $Question)
    if ([string]::IsNullOrWhiteSpace($a)) { return $true }
    return -not ($a.Trim().ToLowerInvariant().StartsWith('n') -or $a.Trim().ToLowerInvariant().StartsWith([string][char]0x43D))
}

# Returns 0 when done, 3 when Windows must restart first, 1 on a failure.
function Install-Koha {
    param([hashtable]$Facts, [switch]$NonInteractive)
    $state = Get-KohaState
    $phase = [string]$state['phase']
    if (-not $phase -or $script:Phases -notcontains $phase) { $phase = 'checks' }
    Write-Host ''
    Write-Host (T 'Koha Easy Installer for Windows') -ForegroundColor Green
    Write-Host ''

    if (-not (Test-KohaPhaseDone 'checks' $phase)) {
        Write-KohaStep (T 'Checking this computer...')
        if (-not $Facts) { $Facts = Get-KohaHostFacts }
        $rows = Get-KohaPreflight -Facts $Facts
        foreach ($r in $rows) { Write-KohaStep $r.Text $(if ($r.Level -eq 'ok') { 'ok' } else { $r.Level }) }
        if (@($rows | Where-Object { $_.Level -eq 'error' }).Count -gt 0) {
            Write-KohaStep (T 'This computer cannot run Koha yet. Fix the items marked X and run the installer again.') 'error'
            return 1
        }
        Set-KohaState @{ phase = 'wsl' } | Out-Null; $phase = 'wsl'
    }

    if (-not (Test-KohaPhaseDone 'wsl' $phase)) {
        if (-not (Test-KohaWslReady)) {
            Write-KohaStep (T 'Installing WSL 2 (Windows asks for permission once)...')
            Install-KohaWslPlatform
            if (-not (Test-KohaWslReady)) {
                Register-KohaResume
                Write-KohaStep (T 'Windows must restart to finish installing WSL. After the restart, the installer continues by itself when you sign in.') 'warn'
                return 3
            }
        }
        Write-KohaStep (T 'WSL 2 is ready.') 'ok'
        Set-KohaState @{ phase = 'distro' } | Out-Null; $phase = 'distro'
    }

    if (-not (Test-KohaPhaseDone 'distro' $phase)) {
        Write-KohaStep (T 'Downloading and installing Debian (a few minutes)...')
        if (-not $Facts) { $Facts = Get-KohaHostFacts }
        New-KohaDistro -Arm ([bool]$Facts.Arm) | Out-Null
        Write-KohaStep (T 'Debian is installed.') 'ok'
        Set-KohaState @{ phase = 'systemd' } | Out-Null; $phase = 'systemd'
    }

    if (-not (Test-KohaPhaseDone 'systemd' $phase)) {
        Write-KohaStep (T 'Configuring Debian for Koha (systemd)...')
        if (-not (Set-KohaDistroConfig)) {
            Write-KohaStep (T 'systemd did not start in WSL. Update WSL with "wsl --update" and run the installer again.') 'error'
            return 1
        }
        Write-KohaStep (T 'Debian is ready for Koha.') 'ok'
        Set-KohaState @{ phase = 'koha' } | Out-Null; $phase = 'koha'
    }

    if (-not (Test-KohaPhaseDone 'koha' $phase)) {
        Copy-KohaPanelIntoDistro
        if (-not (Test-KohaInstalledInDistro)) {
            if ($NonInteractive) { return 1 }
            Write-Host ''
            Write-KohaStep (T 'The Koha control panel opens now. Choose your language, then 1 - Install Koha server. When it finishes, leave the panel with Exit.')
            Read-Host (T 'Press Enter to continue') | Out-Null
            Invoke-KohaPanel | Out-Null
            if (-not (Test-KohaInstalledInDistro)) {
                Write-KohaStep (T 'Koha was not installed. Run the installer again to continue from here.') 'error'
                return 1
            }
        }
        Write-KohaStep (T 'Koha is installed.') 'ok'
        Set-KohaState @{ phase = 'windows' } | Out-Null; $phase = 'windows'
    }

    if (-not (Test-KohaPhaseDone 'windows' $phase)) {
        $auto = $true
        if (-not $NonInteractive) { $auto = Read-KohaYesNo (T 'Start Koha automatically when you sign in to Windows?') }
        $mode = 'manual'
        if ($auto) { $mode = 'logon' }
        Set-KohaState @{ autostart = $mode; desired = 'running' } | Out-Null
        Register-KohaTasks -Autostart $mode
        Set-KohaTrayAtSignIn -Enabled $true
        New-KohaShortcuts | Out-Null
        Write-KohaStep (T 'Shortcuts created in the Start menu (folder Koha) and on the desktop.') 'ok'
        Write-KohaStep (T 'Starting Koha (up to 3 minutes)...')
        $r = Start-Koha -Trigger user -Wait
        Start-KohaTray
        Set-KohaState @{ phase = 'done' } | Out-Null
        Write-Host ''
        if ($r -eq 'ready') {
            Write-KohaStep ((T 'Done! Staff interface: {0}  Public catalog: {1}') -f (Get-KohaConfig).StaffUrl, (Get-KohaConfig).OpacUrl) 'ok'
            Write-KohaStep (T 'The first-access user and password are in the control panel, option 2. Keep this computer on during opening hours.') 'ok'
            if (-not $NonInteractive) { Start-Process (Get-KohaConfig).StaffUrl }
        } else {
            Write-KohaStep (T 'Koha did not start. Open Koha - Status, or export the diagnostics from the tray menu.') 'warn'
        }
    }
    return 0
}

function Start-KohaTray {
    $ps = [System.IO.Path]::Combine([string]$env:SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
    Start-Process $ps -ArgumentList ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" Tray' -f (Get-KohaScriptPath)) -WindowStyle Hidden
}

Export-ModuleMember -Function *
