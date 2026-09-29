# Pester 5 tests for windows\KohaEasy.*.psm1. They run under PowerShell 7 on
# Linux too: wsl.exe, the Task Scheduler and diskpart are replaced by mocks
# of the module's own wrappers (Invoke-KohaWsl, Start-KohaKeepAlive...).
#   pwsh -NoProfile -Command "Invoke-Pester tests/windows"

BeforeAll {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $env:KOHAEASY_ROOT = Join-Path $TestDrive 'KohaEasy'
    $env:TEMP = Join-Path $TestDrive 'tmp'
    New-Item -ItemType Directory -Path $env:TEMP -Force | Out-Null
    Import-Module (Join-Path $repo 'windows/KohaEasy.Lang.psm1') -Force
    Import-Module (Join-Path $repo 'windows/KohaEasy.Core.psm1') -Force
    Set-KohaConfig @{ Root = $env:KOHAEASY_ROOT }

    function New-Status {
        param([string]$State = 'running', [string]$Result = 'ok', [int64]$LogEpoch = 0, [int64]$LastEpoch = 0, [int64]$Size = 30000)
        $linux = [pscustomobject]@{
            state = 'ok'; koha_installed = $true
            backup = [pscustomobject]@{ last_result = $Result; log_epoch = $LogEpoch; last_epoch = $LastEpoch; last_size = $Size }
            disk = [pscustomobject]@{ total = 100GB; free = 60GB }
        }
        return [pscustomobject]@{ State = $State; Linux = $linux }
    }
}

AfterAll {
    Remove-Module KohaEasy.Core, KohaEasy.Lang -ErrorAction SilentlyContinue
}

Describe 'Windows PowerShell 5.1 compatibility' {
    It 'parses, is saved as UTF-8 with BOM and uses no PowerShell 7 operator: <_>' -ForEach @('KohaEasy.ps1', 'KohaEasy.Tray.ps1', 'KohaEasy.Window.ps1', 'KohaEasy.Core.psm1', 'KohaEasy.Lang.psm1', 'KohaEasy.Install.psm1') {
        $file = Join-Path $repo ('windows/' + $_)
        $bytes = [System.IO.File]::ReadAllBytes($file)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeTrue
        $tokens = $null; $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors) | Out-Null
        @($errors).Count | Should -Be 0
        $ps7 = @('AndAnd', 'OrOr', 'QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket', 'QuestionMark')
        @($tokens | Where-Object { $ps7 -contains [string]$_.Kind } | ForEach-Object { '{0} line {1}' -f $_.Text, $_.Extent.StartLineNumber }) | Should -BeNullOrEmpty
    }
}

Describe 'Translations (lang\*.cache)' {
    It 'maps Windows culture names like the panel does' {
        ConvertTo-KeiLanguageCode 'pt-BR' | Should -Be 'pt'
        ConvertTo-KeiLanguageCode 'fil-PH' | Should -Be 'tl'
        ConvertTo-KeiLanguageCode 'en-US' | Should -Be 'en'
        ConvertTo-KeiLanguageCode '' | Should -Be 'en'
    }

    It 'reads the base64 dictionary and refuses a translation that lost a placeholder' {
        $dir = Join-Path $TestDrive 'lang'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $b = { param($s) [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)) }
        @(
            '# koha-easy-installer lang test'
            ((& $b 'Stop Koha') + '|' + (& $b 'Parar o Koha'))
            ((& $b 'Latest backup: {0} ({1})') + '|' + (& $b 'Último backup: {0}'))
            'garbage line'
        ) | Set-Content -LiteralPath (Join-Path $dir 'pt.cache') -Encoding UTF8
        Import-KeiLanguage -LangDir $dir -Culture 'pt-BR'
        T 'Stop Koha' | Should -Be 'Parar o Koha'
        T 'Latest backup: {0} ({1})' | Should -Be 'Latest backup: {0} ({1})'
        T 'Not in the dictionary' | Should -Be 'Not in the dictionary'
        Import-KeiLanguage -LangDir $dir -Culture 'en-GB'
        T 'Stop Koha' | Should -Be 'Stop Koha'
    }

    It 'has every Windows text in the shipped pt dictionary' {
        Import-KeiLanguage -LangDir (Join-Path $repo 'lang') -Culture 'pt-BR'
        T 'Stop Koha' | Should -Not -Be 'Stop Koha'
        T 'Koha is running' | Should -Not -Be 'Koha is running'
        Import-KeiLanguage -LangDir (Join-Path $repo 'lang') -Culture 'en-US'
    }
}

Describe 'state.json' {
    BeforeEach { Remove-Item -LiteralPath (Get-KohaPath Root) -Recurse -Force -ErrorAction SilentlyContinue }

    It 'starts from the defaults and merges changes without leaving temporary files' {
        $s = Get-KohaState
        $s.desired | Should -Be 'running'
        $s.autostart | Should -Be 'logon'
        Set-KohaState @{ desired = 'stopped' } | Out-Null
        Set-KohaState @{ autostart = 'manual' } | Out-Null
        $s = Get-KohaState
        $s.desired | Should -Be 'stopped'
        $s.autostart | Should -Be 'manual'
        @(Get-ChildItem (Get-KohaPath Root) -Filter '*.tmp').Count | Should -Be 0
    }

    It 'keeps a damaged file aside and never returns invalid choices' {
        New-Item -ItemType Directory -Path (Get-KohaPath Root) -Force | Out-Null
        Set-Content -LiteralPath (Get-KohaPath State) -Value '{ not json'
        (Get-KohaState).desired | Should -Be 'running'
        Test-Path ((Get-KohaPath State) + '.bad') | Should -BeTrue
        Set-Content -LiteralPath (Get-KohaPath State) -Value '{"desired":"maybe","autostart":"always"}'
        $s = Get-KohaState
        $s.desired | Should -Be 'running'
        $s.autostart | Should -Be 'logon'
    }
}

Describe 'Status' {
    It 'resolves one word from the distro, Koha''s answer and the choice of the librarian' {
        $st = @{ desired = 'running'; startedAt = 0 }
        Resolve-KohaState -Installed $false -Running $false -Linux $null -State $st | Should -Be 'not_installed'
        Resolve-KohaState -Installed $true -Running $false -Linux $null -State $st | Should -Be 'stopped'
        Resolve-KohaState -Installed $true -Running $false -Linux $null -State @{ desired = 'stopped'; startedAt = 0 } | Should -Be 'stopped_by_user'
        Resolve-KohaState -Installed $true -Running $true -Linux ([pscustomobject]@{ state = 'ok' }) -State $st | Should -Be 'running'
        Resolve-KohaState -Installed $true -Running $true -Linux $null -State $st | Should -Be 'not_responding'
        Resolve-KohaState -Installed $true -Running $true -Linux ([pscustomobject]@{ state = 'degraded' }) -State @{ desired = 'running'; startedAt = 1000 } -Now 1060 | Should -Be 'starting'
    }

    It 'never starts a stopped distro to read its status' {
        Mock -ModuleName KohaEasy.Core Get-KohaInstalledDistros { @('Ubuntu', 'koha') }
        Mock -ModuleName KohaEasy.Core Get-KohaRunningDistros { @('Ubuntu') }
        Mock -ModuleName KohaEasy.Core Invoke-KohaLinux { throw 'must not be called' }
        (Get-KohaStatus).State | Should -BeIn @('stopped', 'stopped_by_user')
        Should -Invoke -ModuleName KohaEasy.Core Invoke-KohaLinux -Times 0
    }

    It 'reads the JSON line of config.sh --status-json' {
        Mock -ModuleName KohaEasy.Core Invoke-KohaLinux { [pscustomobject]@{ ExitCode = 0; Output = "noise`n{""state"":""ok"",""backup"":{""last_result"":""ok""}}" } }
        $j = Get-KohaLinuxStatus
        $j.state | Should -Be 'ok'
        Should -Invoke -ModuleName KohaEasy.Core Invoke-KohaLinux -ParameterFilter { $Command[-1] -eq '--status-json' }
    }
}

Describe 'Notifications' {
    It 'announces a new nightly backup once, and a failure always' {
        $now = 2000000000
        $st = @{ desired = 'running'; autostart = 'logon'; lastBackupLogEpoch = $now - 90000; lastStaleBackupWarn = 0; firstSeen = $now - 999999; lastDiskLevel = 'ok'; lastDiskWarn = 0; notifyBackupOk = $true }
        $r = Get-KohaNotifications -Previous 'running' -Status (New-Status -LogEpoch ($now - 60) -LastEpoch ($now - 60)) -Disk $null -State $st -Now $now
        @($r.Notifications).Count | Should -Be 1
        $r.Notifications[0].Level | Should -Be 'info'
        $r.Notifications[0].Text | Should -Match '\(29 KB\)'
        $r.Changes.lastBackupLogEpoch | Should -Be ($now - 60)

        $st.lastBackupLogEpoch = $now - 60
        $r = Get-KohaNotifications -Previous 'running' -Status (New-Status -LogEpoch ($now - 60) -LastEpoch ($now - 60)) -Disk $null -State $st -Now $now
        @($r.Notifications).Count | Should -Be 0

        $st.notifyBackupOk = $false
        $r = Get-KohaNotifications -Previous 'running' -Status (New-Status -Result 'failed' -LogEpoch ($now - 5) -LastEpoch ($now - 60)) -Disk $null -State $st -Now $now
        @($r.Notifications).Count | Should -Be 1
        $r.Notifications[0].Level | Should -Be 'error'
    }

    It 'reports service events only while Koha is meant to run' {
        $st = @{ desired = 'running'; autostart = 'logon'; lastBackupLogEpoch = 0; lastStaleBackupWarn = 0; firstSeen = 0; lastDiskLevel = 'ok'; lastDiskWarn = 0; notifyBackupOk = $true }
        $down = [pscustomobject]@{ State = 'not_responding'; Linux = $null }
        (Get-KohaNotifications -Previous 'running' -Status $down -Disk $null -State $st).Notifications[0].Level | Should -Be 'error'
        (Get-KohaNotifications -Previous 'not_responding' -Status $down -Disk $null -State $st).Notifications.Count | Should -Be 0
        $back = [pscustomobject]@{ State = 'running'; Linux = $null }
        (Get-KohaNotifications -Previous 'not_responding' -Status $back -Disk $null -State $st).Notifications[0].Level | Should -Be 'info'
        $st.desired = 'stopped'
        $off = [pscustomobject]@{ State = 'stopped_by_user'; Linux = $null }
        (Get-KohaNotifications -Previous 'running' -Status $off -Disk $null -State $st).Notifications.Count | Should -Be 0
    }

    It 'warns once a day about an old backup, with the manual-start reason, never on a new install' {
        $now = 2000000000
        $st = @{ desired = 'running'; autostart = 'manual'; lastBackupLogEpoch = $now; lastStaleBackupWarn = 0; firstSeen = 0; lastDiskLevel = 'ok'; lastDiskWarn = 0; notifyBackupOk = $true }
        $old = New-Status -LogEpoch $now -LastEpoch ($now - 3 * 86400)
        $r = Get-KohaNotifications -Previous 'running' -Status $old -Disk $null -State $st -Now $now
        @($r.Notifications).Count | Should -Be 0
        $r.Changes.firstSeen | Should -Be $now

        $st.firstSeen = $now - 5 * 86400
        $r = Get-KohaNotifications -Previous 'running' -Status $old -Disk $null -State $st -Now $now
        $r.Notifications[0].Level | Should -Be 'warning'
        $r.Notifications[0].Text | Should -Match 'Koha - Start'
        $st.lastStaleBackupWarn = $now - 3600
        (Get-KohaNotifications -Previous 'running' -Status $old -Disk $null -State $st -Now $now).Notifications.Count | Should -Be 0
    }

    It 'warns on each disk level change and repeats a critical level every 6 hours' {
        $now = 2000000000
        $st = @{ desired = 'running'; autostart = 'logon'; lastBackupLogEpoch = 0; lastStaleBackupWarn = 0; firstSeen = 0; lastDiskLevel = 'ok'; lastDiskWarn = 0; notifyBackupOk = $true }
        $s = [pscustomobject]@{ State = 'running'; Linux = $null }
        $crit = [pscustomobject]@{ Level = 'critical'; Message = 'full' }
        $r = Get-KohaNotifications -Previous 'running' -Status $s -Disk $crit -State $st -Now $now
        $r.Notifications[0].Level | Should -Be 'error'
        $st.lastDiskLevel = 'critical'; $st.lastDiskWarn = $now - 3600
        (Get-KohaNotifications -Previous 'running' -Status $s -Disk $crit -State $st -Now $now).Notifications.Count | Should -Be 0
        $st.lastDiskWarn = $now - 7 * 3600
        (Get-KohaNotifications -Previous 'running' -Status $s -Disk $crit -State $st -Now $now).Notifications.Count | Should -Be 1
    }
}

Describe 'Virtual disk watchdog' {
    It 'uses the free space of the Windows drive and the fill level inside Linux' {
        (Measure-KohaDiskLevel -HostFree 200GB -HostTotal 500GB -VhdxSize 20GB -LinuxUsed 15GB -LinuxTotal 1TB).Level | Should -Be 'ok'
        (Measure-KohaDiskLevel -HostFree 8GB -HostTotal 500GB -VhdxSize 20GB -LinuxUsed 15GB -LinuxTotal 1TB).Level | Should -Be 'warning'
        (Measure-KohaDiskLevel -HostFree 4GB -HostTotal 500GB -VhdxSize 20GB -LinuxUsed 15GB -LinuxTotal 1TB).Level | Should -Be 'critical'
        (Measure-KohaDiskLevel -HostFree 40GB -HostTotal 2000GB -VhdxSize 20GB -LinuxUsed 15GB -LinuxTotal 1TB).Level | Should -Be 'ok'
        (Measure-KohaDiskLevel -HostFree 200GB -HostTotal 500GB -VhdxSize 20GB -LinuxUsed 92GB -LinuxTotal 100GB).Level | Should -Be 'warning'
    }

    It 'suggests compacting when much of the virtual disk is unused space' {
        $m = Measure-KohaDiskLevel -HostFree 8GB -HostTotal 500GB -VhdxSize 60GB -LinuxUsed 12GB -LinuxTotal 1TB
        $m.Reclaimable | Should -Be 48GB
        $m.Message | Should -Match 'Compact'
    }

    It 'compacts in order: fstrim, stop, wsl --shutdown, diskpart, start again' {
        $vhdx = Join-Path $TestDrive 'ext4.vhdx'
        Set-Content -LiteralPath $vhdx -Value 'x'
        $script:calls = New-Object System.Collections.ArrayList
        Mock -ModuleName KohaEasy.Core Get-KohaVhdxPath { $vhdx }
        Mock -ModuleName KohaEasy.Core Test-KohaAdmin { $true }
        Mock -ModuleName KohaEasy.Core Test-KohaDistroRunning { $true }
        Mock -ModuleName KohaEasy.Core Invoke-KohaLinux { [void]$script:calls.Add('linux ' + ($Command -join ' ')) }
        Mock -ModuleName KohaEasy.Core Invoke-KohaWsl { [void]$script:calls.Add('wsl ' + ($Arguments -join ' ')) }
        Mock -ModuleName KohaEasy.Core Stop-KohaKeepAlive { [void]$script:calls.Add('stop task') }
        Mock -ModuleName KohaEasy.Core Start-KohaKeepAlive { [void]$script:calls.Add('start task') }
        Mock -ModuleName KohaEasy.Core Invoke-KohaDiskpart { [void]$script:calls.Add('diskpart ' + ((Get-Content -LiteralPath $ScriptFile) -join ';')) }
        Set-KohaState @{ desired = 'running' } | Out-Null
        Invoke-KohaDiskCompact -Confirm:$false | Out-Null
        $script:calls[0] | Should -Be 'linux fstrim -av'
        $script:calls[1] | Should -Be 'stop task'
        $script:calls[2] | Should -Be 'wsl --shutdown'
        $script:calls[3] | Should -Be ('diskpart select vdisk file="{0}";attach vdisk readonly;compact vdisk;detach vdisk' -f $vhdx)
        $script:calls[4] | Should -Be 'start task'
    }
}

Describe 'Start, Stop and automatic start' {
    BeforeEach {
        Remove-Item -LiteralPath (Get-KohaPath Root) -Recurse -Force -ErrorAction SilentlyContinue
        $script:calls = New-Object System.Collections.ArrayList
        Mock -ModuleName KohaEasy.Core Start-KohaKeepAlive { [void]$script:calls.Add('start task') }
        Mock -ModuleName KohaEasy.Core Stop-KohaKeepAlive { [void]$script:calls.Add('stop task:' + (Get-KohaState).desired) }
        Mock -ModuleName KohaEasy.Core Invoke-KohaWsl { [void]$script:calls.Add('wsl ' + ($Arguments -join ' ')); [pscustomobject]@{ ExitCode = 0; Output = '' } }
        Mock -ModuleName KohaEasy.Core Set-KohaSignInTask { [void]$script:calls.Add('sign-in task ' + $Enabled) }
    }

    It 'Stop records "stopped" before ending the task, so it is not restarted' {
        Stop-Koha | Should -Be 'stopped'
        $script:calls | Should -Contain 'stop task:stopped'
        $script:calls | Should -Contain 'wsl --terminate koha'
        (Get-KohaState).desired | Should -Be 'stopped'
    }

    It 'the sign-in task starts nothing in manual mode; the Start shortcut always does' {
        Set-KohaState @{ autostart = 'manual'; desired = 'stopped' } | Out-Null
        Start-Koha -Trigger logon | Should -Be 'skipped'
        $script:calls | Should -Not -Contain 'start task'
        (Get-KohaState).desired | Should -Be 'stopped'
        Start-Koha -Trigger user | Should -Be 'started'
        $script:calls | Should -Contain 'start task'
        (Get-KohaState).desired | Should -Be 'running'

        Set-KohaState @{ autostart = 'logon'; desired = 'stopped' } | Out-Null
        Start-Koha -Trigger logon | Should -Be 'started'
        (Get-KohaState).desired | Should -Be 'running'
    }

    It 'the keep-alive task exits at once when Koha is meant to be off' {
        Set-KohaState @{ desired = 'stopped' } | Out-Null
        $script:holder = $false
        Invoke-KohaRun -Holder { $script:holder = $true } | Should -Be 0
        $script:holder | Should -BeFalse
    }

    It 'the keep-alive task fails when the holder dies, unless Stop was pressed meanwhile' {
        Mock -ModuleName KohaEasy.Core Update-KohaHandshake { $true }
        Mock -ModuleName KohaEasy.Core Wait-KohaHttp { $true }
        Mock -ModuleName KohaEasy.Core Start-Sleep { }
        Mock -ModuleName KohaEasy.Core Start-KohaNetworkTask { [void]$script:calls.Add('network task'); $true }
        Set-KohaState @{ desired = 'running' } | Out-Null
        $proc = [pscustomobject]@{ ExitCode = 1 } | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { } -PassThru
        Invoke-KohaRun -Holder { $proc } | Should -Be 1
        $script:calls | Should -Contain 'network task'
        $proc2 = [pscustomobject]@{ ExitCode = 0 } | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { Set-KohaState @{ desired = 'stopped' } | Out-Null } -PassThru
        Invoke-KohaRun -Holder { $proc2 } | Should -Be 0
    }

    It 'the automatic start toggle changes the sign-in task and waits to tell a stopped Koha' {
        Mock -ModuleName KohaEasy.Core Test-KohaDistroRunning { $false }
        Mock -ModuleName KohaEasy.Core Invoke-KohaLinux { throw 'must not start the distro' }
        Set-KohaAutostart -Mode manual | Out-Null
        $script:calls | Should -Contain 'sign-in task False'
        $s = Get-KohaState
        $s.autostart | Should -Be 'manual'
        $s.handshakePending | Should -BeTrue
        Set-KohaAutostart -Mode logon | Out-Null
        $script:calls | Should -Contain 'sign-in task True'
    }
}

Describe 'Shortcuts' {
    It 'gives every shortcut the Koha icon and puts one Koha icon on the desktop' {
        $list = Get-KohaShortcutList
        $list.Count | Should -BeGreaterThan 8
        foreach ($s in $list) { $s.Icon | Should -BeLike '*koha.ico' }
        $desk = @($list | Where-Object { $_.ContainsKey('Desktop') -and $_.Desktop })
        $desk.Count | Should -Be 1
        $desk[0].Name | Should -Be 'Koha'
        $desk[0].Arguments | Should -BeLike '* Window'
        ($list | Where-Object { $_.Name -like '*Control panel*' }).Arguments | Should -BeLike '* Panel'
        ($list | Where-Object { $_.Name -like '*Status' -and $_.Kind -eq 'lnk' }).Arguments | Should -BeLike '* Window'
        ($list | Where-Object { $_.Name -like '*Export diagnostics' }).Arguments | Should -BeLike '* ExportReport'
        ($list | Where-Object { $_.Arguments -like '* Stop' }).Target | Should -BeLike '*powershell.exe'
    }

    It 'starts Koha commands through a console nobody sees when conhost.exe is there' {
        $conhost = Join-Path $TestDrive 'conhost.exe'
        Set-Content -LiteralPath $conhost -Value ''
        $l = Get-KohaHiddenLaunch -Arguments 'Tray' -Conhost $conhost
        $l.Target | Should -Be $conhost
        $l.Arguments | Should -Match '^--headless ".*powershell\.exe" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ".*KohaEasy\.ps1" Tray$'
        $f = Get-KohaHiddenLaunch -Arguments 'Tray' -Conhost (Join-Path $TestDrive 'missing.exe')
        $f.Target | Should -BeLike '*powershell.exe'
        $f.Arguments | Should -BeLike '-NoProfile -WindowStyle Hidden *'
    }

    It 'writes .url files with IconFile, program shortcuts through WScript.Shell, and copies koha.ico' {
        Mock -ModuleName KohaEasy.Core Save-KohaLnkShortcut { }
        $sm = Join-Path $TestDrive 'Programs/Koha'
        $dt = Join-Path $TestDrive 'Desktop'
        New-Item -ItemType Directory -Path $dt -Force | Out-Null
        $made = New-KohaShortcuts -StartMenu $sm -Desktop $dt -IconSource (Join-Path $repo 'windows/koha.ico')
        Test-Path -LiteralPath (Get-KohaIconPath) | Should -BeTrue
        $url = Get-ChildItem -LiteralPath $sm -Filter '*.url' | Select-Object -First 1
        @(Get-ChildItem -LiteralPath $sm -Filter '*.url').Count | Should -Be 2
        Get-Content -Raw -LiteralPath $url.FullName | Should -Match ('IconFile=' + [regex]::Escape((Get-KohaIconPath)))
        Should -Invoke -ModuleName KohaEasy.Core Save-KohaLnkShortcut -Times 9 -Exactly -ParameterFilter { $Icon -like '*koha.ico' }
        Should -Invoke -ModuleName KohaEasy.Core Save-KohaLnkShortcut -Times 1 -Exactly -ParameterFilter { $Path -eq [System.IO.Path]::Combine($dt, 'Koha.lnk') }
        $made.Count | Should -Be 11
    }

    It 'ships koha.ico as a real Windows icon with a 16x16 image' {
        $b = [System.IO.File]::ReadAllBytes((Join-Path $repo 'windows/koha.ico'))
        ($b[0] -eq 0 -and $b[1] -eq 0 -and $b[2] -eq 1 -and $b[3] -eq 0) | Should -BeTrue
        $b[6] | Should -Be 16
    }
}

Describe 'Distro icon' {
    BeforeEach {
        $script:base = Join-Path $TestDrive 'wsl'
        New-Item -ItemType Directory -Path $script:base -Force | Out-Null
        $script:ico = Join-Path $TestDrive 'koha.ico'
        Copy-Item -LiteralPath (Join-Path $repo 'windows/koha.ico') -Destination $script:ico -Force
        $script:frag = Join-Path $TestDrive 'Fragments/KohaEasy'
        Remove-Item -LiteralPath $script:frag -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'puts koha.ico on the terminal profile WSL wrote and on shortcut.ico' {
        $prof = Join-Path $TestDrive 'profile.json'
        '{"profiles":[{"updates":"{1234}","name":"koha","icon":"C:\\KohaEasy\\wsl\\shortcut.ico"}]}' | Set-Content -LiteralPath $prof
        $script:p = $prof
        Mock -ModuleName KohaEasy.Core Get-KohaLxssEntry { [pscustomobject]@{ PSPath = 'x'; Name = 'koha'; BasePath = $script:base; ShortcutPath = ''; TerminalProfilePath = $script:p } }
        $done = Set-KohaDistroIcon -Icon $script:ico -FragmentDir $script:frag
        $done | Should -Contain 'shortcut.ico'
        $done | Should -Contain 'terminal'
        (Get-Content -Raw $prof | ConvertFrom-Json).profiles[0].icon | Should -Be $script:ico
        (Get-Content -Raw $prof | ConvertFrom-Json).profiles[0].updates | Should -Be '{1234}'
        (Get-FileHash (Join-Path $script:base 'shortcut.ico')).Hash | Should -Be (Get-FileHash $script:ico).Hash
        Test-Path -LiteralPath $script:frag | Should -BeFalse
    }

    It 'adds a Koha terminal profile when WSL wrote none' {
        Mock -ModuleName KohaEasy.Core Get-KohaLxssEntry { [pscustomobject]@{ PSPath = 'x'; Name = 'koha'; BasePath = $script:base; ShortcutPath = ''; TerminalProfilePath = '' } }
        Set-KohaDistroIcon -Icon $script:ico -FragmentDir $script:frag | Should -Contain 'terminal-fragment'
        $j = Get-Content -Raw (Join-Path $script:frag 'koha.json') | ConvertFrom-Json
        $j.profiles[0].commandline | Should -Be 'wsl.exe -d koha'
        $j.profiles[0].icon | Should -Be $script:ico
    }

    It 'does nothing when WSL does not know the distro' {
        Mock -ModuleName KohaEasy.Core Get-KohaLxssEntry { $null }
        @(Set-KohaDistroIcon -Icon $script:ico -FragmentDir $script:frag).Count | Should -Be 0
    }
}

Describe 'Library network' {
    It 'checks IPv4 addresses' {
        Test-KohaIPv4 '172.28.1.20' | Should -BeTrue
        foreach ($bad in '', '256.1.1.1', 'fe80::1', '1.2.3', '1.2.3.4; calc') { Test-KohaIPv4 $bad | Should -BeFalse -Because $bad }
    }

    It 'forwards ports 80 and 8080 of every Windows address to Debian, deleting old rules first' {
        $c = @(Get-KohaPortProxyCommands -WslIp '172.28.1.20' | ForEach-Object { $_ -join ' ' })
        $c | Should -Be @(
            'interface portproxy delete v4tov4 listenport=80 listenaddress=0.0.0.0'
            'interface portproxy add v4tov4 listenport=80 listenaddress=0.0.0.0 connectport=80 connectaddress=172.28.1.20'
            'interface portproxy delete v4tov4 listenport=8080 listenaddress=0.0.0.0'
            'interface portproxy add v4tov4 listenport=8080 listenaddress=0.0.0.0 connectport=8080 connectaddress=172.28.1.20')
    }

    It 'needs no forwarding in mirrored mode, and never forwards to a bad address' {
        Mock -ModuleName KohaEasy.Core Get-KohaNetMode { 'mirrored' }
        Update-KohaPortProxy -WslIp '172.28.1.20' | Should -Be 'mirrored'
        Mock -ModuleName KohaEasy.Core Get-KohaNetMode { 'nat' }
        Mock -ModuleName KohaEasy.Core Get-KohaWslIp { '' }
        Update-KohaPortProxy | Should -Be 'no-address'
    }

    It 'reads Debian''s address without starting a stopped distro' {
        Mock -ModuleName KohaEasy.Core Test-KohaDistroRunning { $false }
        Mock -ModuleName KohaEasy.Core Invoke-KohaLinux { throw 'must not start the distro' }
        Get-KohaWslIp | Should -Be ''
        Mock -ModuleName KohaEasy.Core Test-KohaDistroRunning { $true }
        Mock -ModuleName KohaEasy.Core Invoke-KohaLinux { [pscustomobject]@{ ExitCode = 0; Output = 'fd00::5 172.28.1.20 10.255.255.254' } }
        Get-KohaWslIp | Should -Be '172.28.1.20'
    }
}

Describe 'Handshake file' {
    It 'writes only KEY=value lines the panel parser accepts' {
        Set-KohaState @{ autostart = 'manual' } | Out-Null
        $env:COMPUTERNAME = 'BIBLIO$(reboot)'
        $env:USERNAME = 'ana;rm -rf'
        $text = New-KohaHandshake
        foreach ($line in ($text -split "`n" | Where-Object { $_ -and -not $_.StartsWith('#') })) {
            $line | Should -Match '^[A-Z][A-Z_]*=[A-Za-z0-9._:/ -]*$'
        }
        $text | Should -Match '(?m)^WIN_AUTOSTART=manual$'
        $text | Should -Match '(?m)^WIN_HOSTNAME=BIBLIOreboot$'
        $text | Should -Match '(?m)^WIN_NET_MODE=nat$'
    }

    It 'is sent through stdin to a root-owned file replaced in one step' {
        Mock -ModuleName KohaEasy.Core Test-KohaDistroRunning { $true }
        $script:linux = New-Object System.Collections.ArrayList
        Mock -ModuleName KohaEasy.Core Invoke-KohaLinux { [void]$script:linux.Add([pscustomobject]@{ Command = $Command; InputText = $InputText }); [pscustomobject]@{ ExitCode = 0; Output = '' } }
        Update-KohaHandshake | Should -BeTrue
        $script:linux.Count | Should -Be 3
        $script:linux[0].Command[0] | Should -Be 'tee'
        $script:linux[0].InputText | Should -Match 'chown root:root'
        $script:linux[0].InputText | Should -Match 'mv -f'
        $script:linux[1].Command[0] | Should -Be 'sh'
        $script:linux[1].Command[1] | Should -Be $script:linux[0].Command[1]
        $script:linux[1].InputText | Should -Match 'WIN_AUTOSTART='
        $script:linux[2].Command -join ' ' | Should -Be ('rm -f ' + $script:linux[0].Command[1])
    }

    It 'never puts quotes or spaces on the wsl.exe command line, which Windows PowerShell 5.1 would mangle' {
        $script:linux = New-Object System.Collections.ArrayList
        Mock -ModuleName KohaEasy.Core Invoke-KohaLinux { [void]$script:linux.Add($Command); [pscustomobject]@{ ExitCode = 0; Output = '' } }
        Invoke-KohaLinuxScript -Script 'd="/a b"; echo "$d" > /dev/null' -InputText 'x' | Out-Null
        foreach ($c in $script:linux) { foreach ($a in $c) { $a | Should -Not -Match '[\s"'']' } }
    }
}

Describe 'Diagnostics' {
    It 'removes passwords, tokens and keys like the Linux side' {
        $t = Protect-KohaText "<pass>KeiTest-Pass_42</pass>`npassword=hunter2 user=koha`nAuthorization: Bearer abcdefghijklmnop`nhttps://backup:S3cr3t@example.org/`n{""refresh_token"":""1//0gAbCdEfGhIjKlMnOpQrStUv""}`nTimezone: America/Sao_Paulo"
        foreach ($secret in 'KeiTest-Pass_42', 'hunter2', 'abcdefghijklmnop', 'S3cr3t', '1//0gAb') { $t | Should -Not -Match ([regex]::Escape($secret)) }
        $t | Should -Match 'user=koha'
        $t | Should -Match 'Timezone: America/Sao_Paulo'
    }

    It 'zips the Windows part and the Linux bundle, and stops Koha again if it was off' {
        New-Item -ItemType Directory -Path (Get-KohaPath Logs) -Force | Out-Null
        Set-Content -LiteralPath (Join-Path (Get-KohaPath Logs) 'koha-20260928.log') -Value 'start requested; password=hunter2'
        Set-KohaState @{ desired = 'stopped' } | Out-Null
        $script:calls = New-Object System.Collections.ArrayList
        Mock -ModuleName KohaEasy.Core Test-KohaDistroRunning { $false }
        Mock -ModuleName KohaEasy.Core Test-KohaDistroInstalled { $true }
        Mock -ModuleName KohaEasy.Core Invoke-KohaWsl { [void]$script:calls.Add('wsl ' + ($Arguments -join ' ')); [pscustomobject]@{ ExitCode = 0; Output = 'WSL version: 2.3.26.0' } }
        Mock -ModuleName KohaEasy.Core Invoke-KohaLinux {
            if ($Command[0] -eq 'wslpath') { return [pscustomobject]@{ ExitCode = 0; Output = $Command[-1] } }
            $d = Join-Path $Command[-1] 'koha-diagnostics-vm-1'
            New-Item -ItemType Directory -Path $d -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $d 'status.json') -Value '{"state":"stopped"}'
            [pscustomobject]@{ ExitCode = 0; Output = $d }
        }
        $out = Join-Path $TestDrive 'desktop'
        $zip = Export-KohaDiagnostics -Destination $out
        Test-Path -LiteralPath $zip | Should -BeTrue
        $x = Join-Path $TestDrive 'unzipped'
        Expand-Archive -LiteralPath $zip -DestinationPath $x -Force
        Test-Path (Join-Path $x 'linux/status.json') | Should -BeTrue
        Test-Path (Join-Path $x 'windows/wsl.txt') | Should -BeTrue
        Test-Path (Join-Path $x 'windows/state.json') | Should -BeTrue
        Get-Content -Raw (Join-Path $x 'windows/logs/koha-20260928.log') | Should -Not -Match 'hunter2'
        $script:calls | Should -Contain 'wsl --terminate koha'
        @(Get-ChildItem $env:TEMP -Filter 'KohaEasy-diagnostics-*').Count | Should -Be 0
    }
}
