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

    It 'tells the librarian about a repair after an unclean stop: once when it starts, once when it ends' {
        $now = 2000000000
        $st = @{ desired = 'running'; autostart = 'logon'; lastBackupLogEpoch = $now; lastStaleBackupWarn = 0; firstSeen = 0; lastDiskLevel = 'ok'; lastDiskWarn = 0; notifyBackupOk = $true; lastRecoveryEpoch = 0; lastRecoveryNotice = 0 }
        $status = New-Status -LogEpoch $now -LastEpoch $now
        $status.Linux | Add-Member -NotePropertyName recovery -NotePropertyValue ([pscustomobject]@{ epoch = $now - 100; state = 'running'; finished = 0; db = ''; backup = ''; index = '' })
        $r = Get-KohaNotifications -Previous 'running' -Status $status -Disk $null -State $st -Now $now
        @($r.Notifications).Count | Should -Be 1
        $r.Notifications[0].Level | Should -Be 'warning'
        $st.lastRecoveryNotice = $r.Changes.lastRecoveryNotice
        @((Get-KohaNotifications -Previous 'running' -Status $status -Disk $null -State $st -Now $now).Notifications).Count | Should -Be 0

        $status.Linux.recovery = [pscustomobject]@{ epoch = $now - 100; state = 'done'; finished = $now - 10; db = 'ok'; backup = 'ok'; index = 'updated' }
        $r = Get-KohaNotifications -Previous 'running' -Status $status -Disk $null -State $st -Now $now
        @($r.Notifications).Count | Should -Be 1
        $r.Notifications[0].Level | Should -Be 'info'
        $r.Changes.lastRecoveryEpoch | Should -Be ($now - 100)
        $st.lastRecoveryEpoch = $r.Changes.lastRecoveryEpoch
        @((Get-KohaNotifications -Previous 'running' -Status $status -Disk $null -State $st -Now $now).Notifications).Count | Should -Be 0

        $st.lastRecoveryEpoch = 0
        $status.Linux.recovery = [pscustomobject]@{ epoch = $now - 100; state = 'done'; finished = $now - 10; db = 'errors'; backup = 'ok'; index = 'failed' }
        $r = Get-KohaNotifications -Previous 'running' -Status $status -Disk $null -State $st -Now $now
        $r.Notifications[0].Level | Should -Be 'error'
        $r.Notifications[0].Text | Should -Match 'database check reported errors; the search index could not be rebuilt'
    }

    It 'says nothing about a repair older than a week or a status without one' {
        $now = 2000000000
        $st = @{ desired = 'running'; autostart = 'logon'; lastBackupLogEpoch = $now; lastStaleBackupWarn = 0; firstSeen = 0; lastDiskLevel = 'ok'; lastDiskWarn = 0; notifyBackupOk = $true; lastRecoveryEpoch = 0; lastRecoveryNotice = 0 }
        $status = New-Status -LogEpoch $now -LastEpoch $now
        @((Get-KohaNotifications -Previous 'running' -Status $status -Disk $null -State $st -Now $now).Notifications).Count | Should -Be 0
        $status.Linux | Add-Member -NotePropertyName recovery -NotePropertyValue ([pscustomobject]@{ epoch = $now - 8 * 86400; state = 'done'; finished = 0; db = 'ok'; backup = 'ok'; index = 'updated' })
        @((Get-KohaNotifications -Previous 'running' -Status $status -Disk $null -State $st -Now $now).Notifications).Count | Should -Be 0
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

    It 'compacts in order: fstrim, stop, Koha stopped cleanly, wsl --shutdown, diskpart, start again' {
        $vhdx = Join-Path $TestDrive 'ext4.vhdx'
        Set-Content -LiteralPath $vhdx -Value 'x'
        $script:calls = New-Object System.Collections.ArrayList
        Mock -ModuleName KohaEasy.Core Get-KohaVhdxPath { $vhdx }
        Mock -ModuleName KohaEasy.Core Test-KohaAdmin { $true }
        Mock -ModuleName KohaEasy.Core Test-KohaDistroRunning { $true }
        Mock -ModuleName KohaEasy.Core Invoke-KohaLinux { [void]$script:calls.Add('linux ' + ($Command -join ' ')) }
        Mock -ModuleName KohaEasy.Core Invoke-KohaWsl { [void]$script:calls.Add('wsl ' + ($Arguments -join ' ')); [pscustomobject]@{ ExitCode = 0; Output = '' } }
        Mock -ModuleName KohaEasy.Core Get-KohaRunningDistros { @('koha') }
        Mock -ModuleName KohaEasy.Core Invoke-KohaLinuxScript { [void]$script:calls.Add('stop Koha inside Debian'); [pscustomobject]@{ ExitCode = 0; Output = '' } }
        Mock -ModuleName KohaEasy.Core Stop-KohaKeepAlive { [void]$script:calls.Add('stop task') }
        Mock -ModuleName KohaEasy.Core Start-KohaKeepAlive { [void]$script:calls.Add('start task') }
        Mock -ModuleName KohaEasy.Core Invoke-KohaDiskpart { [void]$script:calls.Add('diskpart ' + ((Get-Content -LiteralPath $ScriptFile) -join ';')) }
        Set-KohaState @{ desired = 'running' } | Out-Null
        Invoke-KohaDiskCompact -Confirm:$false | Out-Null
        $script:calls[0] | Should -Be 'linux fstrim -av'
        $script:calls[1] | Should -Be 'stop task'
        $script:calls[2] | Should -Be 'stop Koha inside Debian'
        $script:calls[3] | Should -Be 'wsl --shutdown'
        $script:calls[4] | Should -Be ('diskpart select vdisk file="{0}";attach vdisk readonly;compact vdisk;detach vdisk' -f $vhdx)
        $script:calls[5] | Should -Be 'start task'
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

    It 'Stop stops Koha inside Debian first (with a time limit), then WSL' {
        Mock -ModuleName KohaEasy.Core Get-KohaRunningDistros { @('koha') }
        Mock -ModuleName KohaEasy.Core Invoke-KohaLinuxScript { [void]$script:calls.Add(('linux script ({0} s) as {1}' -f $TimeoutSeconds, (Get-KohaState).desired)); [pscustomobject]@{ ExitCode = 0; Output = '' } }
        Stop-Koha | Should -Be 'stopped'
        $script:calls | Should -Be @('stop task:stopped', 'linux script (60 s) as stopped', 'wsl --terminate koha')
    }

    It 'a Koha that does not stop in time is stopped anyway and the reason logged' {
        Mock -ModuleName KohaEasy.Core Get-KohaRunningDistros { @('koha') }
        Mock -ModuleName KohaEasy.Core Invoke-KohaLinuxScript { [pscustomobject]@{ ExitCode = 124; Output = 'did not stop: mariadb.service' } }
        Stop-KohaDebianGracefully -TimeoutSeconds 5 | Should -Be 'forced'
        $script:calls | Should -Contain 'wsl --terminate koha'
        $log = Get-Content -LiteralPath (Join-Path (Get-KohaPath Logs) ('koha-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))) -Raw
        $log | Should -Match 'Koha did not stop within 5 s'
    }

    It 'never starts a stopped distro just to stop it; -Shutdown stops all of WSL' {
        Mock -ModuleName KohaEasy.Core Get-KohaRunningDistros { @('Ubuntu') }
        Mock -ModuleName KohaEasy.Core Invoke-KohaLinuxScript { throw 'must not start the distro' }
        Stop-KohaDebianGracefully -Shutdown | Should -Be 'not_running'
        $script:calls | Should -Be @('wsl --shutdown')
        (Get-KohaState).desired | Should -Be 'running'
    }

    It 'a time limit runs the Linux script under timeout' {
        $script:wsl = New-Object System.Collections.ArrayList
        Mock -ModuleName KohaEasy.Core Invoke-KohaWsl { [void]$script:wsl.Add($Arguments -join ' '); [pscustomobject]@{ ExitCode = 0; Output = '' } }
        Invoke-KohaLinuxScript -Script 'true' -Distro 'KohaEasy' -TimeoutSeconds 60 | Out-Null
        $script:wsl[1] | Should -Match '^-d KohaEasy -u root -- timeout -k 5 60 sh /run/kohaeasy-[0-9a-f]+\.sh$'
    }

    It 'the stop inside Debian goes web first, then queue and cache, then MariaDB, then the clean-stop mark' -Skip:(-not (Get-Command bash -ErrorAction SilentlyContinue)) {
        $bin = Join-Path $TestDrive 'stopbin'
        New-Item -ItemType Directory -Path $bin -Force | Out-Null
        $trace = Join-Path $TestDrive 'stop-trace.txt'
        $stub = "#!/bin/sh`necho `"`$(basename `$0) `$*`" >> '$trace'`n"
        foreach ($n in @('systemctl', 'koha-plack', 'koha-worker', 'koha-indexer', 'koha-zebra', 'sync', 'koha-stop-guard')) {
            Set-Content -LiteralPath (Join-Path $bin $n) -Value $stub -NoNewline
        }
        Set-Content -LiteralPath (Join-Path $bin 'ps') -Value "#!/bin/sh`necho systemd`n" -NoNewline
        Set-Content -LiteralPath (Join-Path $bin 'koha-list') -Value "#!/bin/sh`necho library`n" -NoNewline
        & chmod +x (Get-ChildItem -LiteralPath $bin | ForEach-Object { $_.FullName })
        $sh = (InModuleScope KohaEasy.Core { $script:GracefulStopScript }) -replace '/usr/local/sbin/koha-stop-guard', (Join-Path $bin 'koha-stop-guard')
        $sh = $sh -replace 'systemctl cat "\$s.service" >/dev/null 2>&1', 'true'
        $file = Join-Path $TestDrive 'stop.sh'
        Set-Content -LiteralPath $file -Value $sh -NoNewline
        $env:PATH = $bin + ':' + $env:PATH
        try { & sh $file | Out-Null; $LASTEXITCODE | Should -Be 0 } finally { $env:PATH = $env:PATH.Substring($bin.Length + 1) }
        $lines = @(Get-Content -LiteralPath $trace)
        $lines | Should -Be @(
            'systemctl stop apache2.service koha-common.service'
            'koha-plack --stop library', 'koha-worker --stop library', 'koha-indexer --stop library', 'koha-zebra --stop library'
            'systemctl stop rabbitmq-server.service memcached.service elasticsearch.service'
            'systemctl stop mariadb.service'
            'sync '
            'koha-stop-guard stop'
        )
    }

    It 'at the end of the Windows session Koha is stopped cleanly and stays wanted' {
        Mock -ModuleName KohaEasy.Core Test-KohaDistroRunning { $true }
        Mock -ModuleName KohaEasy.Core Get-KohaRunningDistros { @('koha') }
        Mock -ModuleName KohaEasy.Core Invoke-KohaLinuxScript { [void]$script:calls.Add('stop Koha inside Debian'); [pscustomobject]@{ ExitCode = 0; Output = '' } }
        Set-KohaState @{ desired = 'running' } | Out-Null
        Stop-KohaForSessionEnd | Should -Be 'clean'
        $script:calls | Should -Be @('stop Koha inside Debian', 'wsl --terminate koha')
        (Get-KohaState).desired | Should -Be 'running'
        Mock -ModuleName KohaEasy.Core Test-KohaDistroRunning { $false }
        Stop-KohaForSessionEnd | Should -Be 'not_running'
    }

    It 'Rebuild search index asks the panel, and never starts a stopped Debian' {
        Mock -ModuleName KohaEasy.Core Test-KohaDistroRunning { $true }
        Mock -ModuleName KohaEasy.Core Invoke-KohaLinux { [void]$script:calls.Add('linux ' + ($Command -join ' ')); [pscustomobject]@{ ExitCode = 0; Output = '' } }
        Invoke-KohaSearchReindex | Should -Be 'rebuilt'
        $script:calls | Should -Contain 'linux /usr/local/bin/koha-panel --rebuild-search-index'
        Mock -ModuleName KohaEasy.Core Invoke-KohaLinux { [pscustomobject]@{ ExitCode = 1; Output = 'zebra failed' } }
        Invoke-KohaSearchReindex | Should -Be 'failed'
        Mock -ModuleName KohaEasy.Core Test-KohaDistroRunning { $false }
        Mock -ModuleName KohaEasy.Core Invoke-KohaLinux { throw 'must not start the distro' }
        Invoke-KohaSearchReindex | Should -Be 'not_running'
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
        $proc = [pscustomobject]@{ ExitCode = 1 } | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($ms) $true } -PassThru
        Invoke-KohaRun -Holder { $proc } | Should -Be 1
        $script:calls | Should -Contain 'network task'
        $proc2 = [pscustomobject]@{ ExitCode = 0 } | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($ms) Set-KohaState @{ desired = 'stopped' } | Out-Null; $true } -PassThru
        Invoke-KohaRun -Holder { $proc2 } | Should -Be 0
    }

    It 'while the holder runs, the keep-alive task brings the Koha icon back, at most 5 times' {
        Mock -ModuleName KohaEasy.Core Update-KohaHandshake { $true }
        Mock -ModuleName KohaEasy.Core Wait-KohaHttp { $true }
        Mock -ModuleName KohaEasy.Core Start-Sleep { }
        Mock -ModuleName KohaEasy.Core Start-KohaNetworkTask { $true }
        Mock -ModuleName KohaEasy.Core Repair-KohaTray { [void]$script:calls.Add('tray check'); 'restarted' }
        Set-KohaState @{ desired = 'running' } | Out-Null
        $script:waits = 0
        $proc = [pscustomobject]@{ ExitCode = 1 } | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($ms) $script:waits++; ($script:waits -gt 8) } -PassThru
        Invoke-KohaRun -Holder { $proc } -WatchMs 5 | Should -Be 1
        $script:waits | Should -Be 9
        @($script:calls | Where-Object { $_ -eq 'tray check' }).Count | Should -Be 5
    }

    It 'a start that Stop ended meanwhile is not reported as a failure' {
        Mock -ModuleName KohaEasy.Core Update-KohaHandshake { $true }
        Mock -ModuleName KohaEasy.Core Start-Sleep { }
        Mock -ModuleName KohaEasy.Core Start-KohaNetworkTask { $true }
        Mock -ModuleName KohaEasy.Core Show-KohaNotification { }
        Mock -ModuleName KohaEasy.Core Wait-KohaHttp { Set-KohaState @{ desired = 'stopped' } | Out-Null; $false }
        Set-KohaState @{ desired = 'running' } | Out-Null
        $proc = [pscustomobject]@{ ExitCode = 1 } | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($ms) $true } -PassThru
        Invoke-KohaRun -Holder { $proc } | Should -Be 0
        Should -Invoke -ModuleName KohaEasy.Core Show-KohaNotification -Times 0 -Exactly
        Mock -ModuleName KohaEasy.Core Wait-KohaHttp { $false }
        Set-KohaState @{ desired = 'running' } | Out-Null
        Invoke-KohaRun -Holder { $proc } | Should -Be 1
        Should -Invoke -ModuleName KohaEasy.Core Show-KohaNotification -Times 1 -Exactly
    }

    It 'the holder that keeps Debian running has no window of its own' {
        $psi = Get-KohaHolderStartInfo
        $psi.FileName | Should -BeLike '*wsl.exe'
        $psi.Arguments | Should -Be '-d koha -u root --exec /bin/sleep infinity'
        $psi.UseShellExecute | Should -BeFalse
        $psi.CreateNoWindow | Should -BeTrue
    }

    It 'the Koha icon is started again only when it is missing and the librarian did not close it' {
        Mock -ModuleName KohaEasy.Core Start-KohaHidden { [void]$script:calls.Add('start ' + $Arguments) }
        Mock -ModuleName KohaEasy.Core Test-KohaTrayRunning { $true }
        Set-KohaState @{ trayClosed = $false } | Out-Null
        Repair-KohaTray | Should -Be 'running'
        Mock -ModuleName KohaEasy.Core Test-KohaTrayRunning { $false }
        Repair-KohaTray | Should -Be 'restarted'
        $script:calls | Should -Contain 'start Tray'
        $script:calls.Clear()
        Set-KohaState @{ trayClosed = $true } | Out-Null
        Repair-KohaTray | Should -Be 'closed'
        $script:calls.Count | Should -Be 0
    }

    It 'restarts a keep-alive task that still runs with an older version''s action' {
        if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) { function global:Get-ScheduledTask { param($TaskPath, $TaskName) } }
        $want = Get-KohaHiddenLaunch -Arguments 'Run'
        $script:task = [pscustomobject]@{ State = 'Running'; Actions = @([pscustomobject]@{ Execute = 'powershell.exe'; Arguments = '-NoProfile -WindowStyle Hidden -File "x" Run' }) }
        Mock -ModuleName KohaEasy.Core Get-ScheduledTask { $script:task }
        Test-KohaKeepAliveOutdated | Should -BeTrue
        $script:task.Actions = @([pscustomobject]@{ Execute = $want.Target; Arguments = $want.Arguments })
        Test-KohaKeepAliveOutdated | Should -BeFalse
        $script:task = [pscustomobject]@{ State = 'Ready'; Actions = @([pscustomobject]@{ Execute = 'powershell.exe'; Arguments = '' }) }
        Test-KohaKeepAliveOutdated | Should -BeFalse
        Mock -ModuleName KohaEasy.Core Get-ScheduledTask { throw 'no such task' }
        Test-KohaKeepAliveOutdated | Should -BeFalse
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
        $desk[0].Arguments | Should -BeLike '* Launch -Hidden'
        ($list | Where-Object { $_.Name -like '*Control panel*' }).Arguments | Should -BeLike '* Panel -Hidden'
        ($list | Where-Object { $_.Name -like '*Status' -and $_.Kind -eq 'lnk' }).Arguments | Should -BeLike '* Window -Hidden'
        ($list | Where-Object { $_.Name -like '*Export diagnostics' }).Arguments | Should -BeLike '* ExportReport -Hidden'
        ($list | Where-Object { $_.Arguments -like '* Stop -Hidden' }).Target | Should -BeLike '*powershell.exe'
    }

    It 'removes the web shortcuts older versions put on the desktop' {
        Mock -ModuleName KohaEasy.Core Save-KohaLnkShortcut { }
        $dt = Join-Path $TestDrive 'OneDrive/Area de Trabalho'
        New-Item -ItemType Directory -Path $dt -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dt 'Koha - Staff interface.url') -Value 'x'
        Set-Content -LiteralPath (Join-Path $dt 'Koha - Public catalog.url') -Value 'x'
        New-KohaShortcuts -StartMenu (Join-Path $TestDrive 'Programs/Koha') -Desktop $dt -IconSource (Join-Path $repo 'windows/koha.ico') | Out-Null
        Test-Path -LiteralPath (Join-Path $dt 'Koha - Staff interface.url') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $dt 'Koha - Public catalog.url') | Should -BeFalse
    }

    It 'falls back to a hidden PowerShell once conhost did not start the tray' {
        $conhost = Join-Path $TestDrive 'conhost.exe'
        Set-Content -LiteralPath $conhost -Value ''
        Set-KohaState @{ hiddenLaunch = 'powershell' } | Out-Null
        try {
            Get-KohaConhostPath | Should -Be ''
            (Get-KohaHiddenLaunch -Arguments 'Tray').Target | Should -BeLike '*powershell.exe'
        } finally { Set-KohaState @{ hiddenLaunch = 'conhost' } | Out-Null }
    }

    It 'starts Koha commands through a console nobody sees when conhost.exe is there' {
        $conhost = Join-Path $TestDrive 'conhost.exe'
        Set-Content -LiteralPath $conhost -Value ''
        $l = Get-KohaHiddenLaunch -Arguments 'Tray' -Conhost $conhost
        $l.Target | Should -Be $conhost
        $l.Arguments | Should -Match '^--headless ".*powershell\.exe" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ".*KohaEasy\.ps1" Tray -Hidden$'
        $f = Get-KohaHiddenLaunch -Arguments 'Tray' -Conhost (Join-Path $TestDrive 'missing.exe')
        $f.Target | Should -BeLike '*powershell.exe'
        $f.Arguments | Should -BeLike '-NoProfile -WindowStyle Hidden *'
    }

    It 'starts Koha commands through KohaEasy.exe once the installer built it and Windows let it run' {
        $exe = Join-Path $TestDrive 'KohaEasy.exe'
        Set-Content -LiteralPath $exe -Value ''
        $conhost = Join-Path $TestDrive 'conhost.exe'
        Set-Content -LiteralPath $conhost -Value ''
        $l = Get-KohaHiddenLaunch -Arguments 'Start -Trigger logon' -Conhost $conhost -Launcher $exe
        $l.Target | Should -Be $exe
        $l.Arguments | Should -Be 'Start -Trigger logon -Hidden'
        (Get-KohaHiddenLaunch -Arguments 'Tray' -Conhost $conhost -Launcher (Join-Path $TestDrive 'missing.exe')).Target | Should -Be $conhost
        Set-KohaState @{ launcher = 'failed' } | Out-Null
        Get-KohaLauncherPath | Should -Be ''
        Set-KohaState @{ launcher = 'ok' } | Out-Null
        Get-KohaLauncherPath | Should -Be ([System.IO.Path]::Combine((Get-KohaPath Bin), 'KohaEasy.exe'))
        Set-KohaState @{ launcher = '' } | Out-Null
    }

    It 'writes .url files with IconFile, program shortcuts through WScript.Shell, and copies koha.ico' {
        Mock -ModuleName KohaEasy.Core Save-KohaLnkShortcut { [System.IO.File]::WriteAllText($Path, '') }
        Mock -ModuleName KohaEasy.Core Set-KohaShortcutAppId { $true }
        $sm = Join-Path $TestDrive 'Programs/Koha'
        $dt = Join-Path $TestDrive 'Desktop'
        New-Item -ItemType Directory -Path $dt -Force | Out-Null
        $made = New-KohaShortcuts -StartMenu $sm -Desktop $dt -IconSource (Join-Path $repo 'windows/koha.ico')
        Test-Path -LiteralPath (Get-KohaIconPath) | Should -BeTrue
        $url = Get-ChildItem -LiteralPath $sm -Filter '*.url' | Select-Object -First 1
        @(Get-ChildItem -LiteralPath $sm -Filter '*.url').Count | Should -Be 2
        Get-Content -Raw -LiteralPath $url.FullName | Should -Match ('IconFile=' + [regex]::Escape((Get-KohaIconPath)))
        Should -Invoke -ModuleName KohaEasy.Core Save-KohaLnkShortcut -Times 10 -Exactly -ParameterFilter { $Icon -like '*koha.ico' }
        Should -Invoke -ModuleName KohaEasy.Core Save-KohaLnkShortcut -Times 1 -Exactly -ParameterFilter { $Path -eq [System.IO.Path]::Combine($dt, 'Koha.lnk') }
        Should -Invoke -ModuleName KohaEasy.Core Save-KohaLnkShortcut -Times 1 -Exactly -ParameterFilter { $Path -eq [System.IO.Path]::Combine($sm, 'Koha.lnk') }
        $made.Count | Should -Be 12
        (Get-KohaState).appIdShortcut | Should -BeTrue
    }

    It 'gives the Koha shortcuts Koha''s identity, and says so only when the Start menu one took it' {
        Mock -ModuleName KohaEasy.Core Save-KohaLnkShortcut { }
        $script:ids = New-Object System.Collections.ArrayList
        Mock -ModuleName KohaEasy.Core Set-KohaShortcutAppId { [void]$script:ids.Add($Path); $false }
        $sm = Join-Path $TestDrive 'Programs2/Koha'
        $dt = Join-Path $TestDrive 'Desktop2'
        New-Item -ItemType Directory -Path $dt -Force | Out-Null
        New-KohaShortcuts -StartMenu $sm -Desktop $dt -IconSource (Join-Path $repo 'windows/koha.ico') | Out-Null
        $script:ids | Should -Be @([System.IO.Path]::Combine($sm, 'Koha.lnk'), [System.IO.Path]::Combine($dt, 'Koha.lnk'))
        (Get-KohaState).appIdShortcut | Should -BeFalse
        Get-KohaToastAppId | Should -Be (Get-KohaConfig).ToastAppId
        Set-KohaState @{ appIdShortcut = $true } | Out-Null
        Get-KohaToastAppId | Should -Be 'KohaEasy.Koha'
        Set-KohaState @{ appIdShortcut = $false } | Out-Null
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

    It 'needs no forwarding in mirrored mode (and removes an old one), and never forwards to a bad address' {
        Mock -ModuleName KohaEasy.Core Get-KohaNetMode { 'mirrored' }
        Mock -ModuleName KohaEasy.Core Remove-KohaPortProxy { 2 }
        Update-KohaPortProxy -WslIp '172.28.1.20' | Should -Be 'mirrored'
        Should -Invoke -ModuleName KohaEasy.Core Remove-KohaPortProxy -Times 1 -Exactly
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
        Mock -ModuleName KohaEasy.Core Test-KohaDistroRunning { $false }
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
        Mock -ModuleName KohaEasy.Core Get-KohaNetMode { 'nat' }
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

    It 'warns when Windows no longer flushes the write cache of the disk holding ext4.vhdx' {
        Mock -ModuleName KohaEasy.Core Get-KohaDiskOfDrive { [pscustomobject]@{ Number = 0; Model = 'ACME SSD'; PnpId = 'SCSI\DISK&VEN_ACME\1' } }
        Mock -ModuleName KohaEasy.Core Get-KohaDiskFlushOff { $true }
        $r = Get-KohaWriteCacheCheck -Vhdx 'D:\WSL\koha\ext4.vhdx'
        $r.Level | Should -Be 'warning'
        $r.Text | Should -Match 'turned OFF for drive D: \(disk 0, ACME SSD\)'
        Mock -ModuleName KohaEasy.Core Get-KohaDiskFlushOff { $false }
        (Get-KohaWriteCacheCheck -Vhdx 'D:\WSL\koha\ext4.vhdx').Level | Should -Be 'ok'
        Mock -ModuleName KohaEasy.Core Get-KohaDiskOfDrive { throw 'no Storage module' }
        (Get-KohaWriteCacheCheck -Vhdx 'D:\WSL\koha\ext4.vhdx').Level | Should -Be 'unknown'
        (Get-KohaWriteCacheCheck -Vhdx '').Level | Should -Be 'unknown'
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

Describe 'Network mode WSL really runs in' {
    It 'takes WSL''s own answer, else whether Debian carries this PC''s address' {
        Resolve-KohaNetMode -WslInfo "mirrored`n" -DebianIps '' -LanIp '' | Should -Be 'mirrored'
        Resolve-KohaNetMode -WslInfo 'NAT' -DebianIps '192.168.0.9' -LanIp '192.168.0.9' | Should -Be 'nat'
        Resolve-KohaNetMode -WslInfo '' -DebianIps '192.168.0.9 fe80::1' -LanIp '192.168.0.9' | Should -Be 'mirrored'
        Resolve-KohaNetMode -WslInfo 'wslinfo: command not found' -DebianIps '172.28.1.20' -LanIp '192.168.0.9' | Should -Be 'nat'
        Resolve-KohaNetMode -WslInfo '' -DebianIps '' -LanIp '192.168.0.9' | Should -Be ''
    }

    It 'asks the running Debian, even when .wslconfig asks for mirrored, and never starts a stopped one' {
        Mock -ModuleName KohaEasy.Core Test-KohaDistroRunning { $true }
        Mock -ModuleName KohaEasy.Core Get-KohaConfiguredNetMode { 'mirrored' }
        Mock -ModuleName KohaEasy.Core Invoke-KohaLinux {
            if ($Command[0] -eq 'wslinfo') { return [pscustomobject]@{ ExitCode = 0; Output = 'nat' } }
            [pscustomobject]@{ ExitCode = 0; Output = '172.28.1.20' }
        }
        Get-KohaNetMode | Should -Be 'nat'
        Mock -ModuleName KohaEasy.Core Invoke-KohaLinux { [pscustomobject]@{ ExitCode = 1; Output = '' } }
        Get-KohaNetMode | Should -Be 'mirrored'
        Mock -ModuleName KohaEasy.Core Test-KohaDistroRunning { $false }
        Mock -ModuleName KohaEasy.Core Invoke-KohaLinux { throw 'must not start the distro' }
        Get-KohaNetMode | Should -Be 'mirrored'
    }

    It 'reads the forwarding table of netsh in any language' {
        $en = "`r`nListen on ipv4:             Connect to ipv4:`r`n`r`nAddress         Port        Address         Port`r`n--------------- ----------  --------------- ----------`r`n0.0.0.0         80          172.28.1.20     80`r`n0.0.0.0         8080        172.28.1.20     8080`r`n"
        $rows = @(ConvertFrom-KohaPortProxyTable -Text $en)
        $rows.Count | Should -Be 2
        $rows[1].ListenPort | Should -Be 8080
        $rows[1].ConnectAddress | Should -Be '172.28.1.20'
        $pt = "Escutar em ipv4:           Conectar a ipv4:`nEndereço        Porta       Endereço        Porta`n--------------- ----------  --------------- ----------`n0.0.0.0         80          172.28.1.20     80`n"
        @(ConvertFrom-KohaPortProxyTable -Text $pt).Count | Should -Be 1
        @(ConvertFrom-KohaPortProxyTable -Text '').Count | Should -Be 0
    }

    It 'removes only Koha''s own forwarding' {
        Mock -ModuleName KohaEasy.Core Get-KohaPortProxyRules {
            @([pscustomobject]@{ ListenAddress = '0.0.0.0'; ListenPort = 80; ConnectAddress = '172.28.1.20'; ConnectPort = 80 }
              [pscustomobject]@{ ListenAddress = '0.0.0.0'; ListenPort = 3389; ConnectAddress = '10.0.0.5'; ConnectPort = 3389 }
              [pscustomobject]@{ ListenAddress = '0.0.0.0'; ListenPort = 8080; ConnectAddress = '172.28.1.20'; ConnectPort = 8080 })
        }
        $script:netsh = New-Object System.Collections.ArrayList
        if (-not (Get-Command netsh.exe -ErrorAction SilentlyContinue)) { function global:netsh.exe { } }
        Mock -ModuleName KohaEasy.Core netsh.exe { [void]$script:netsh.Add($args -join ' ') }
        Remove-KohaPortProxy | Should -Be 2
        $script:netsh | Should -Be @('interface portproxy delete v4tov4 listenport=80 listenaddress=0.0.0.0', 'interface portproxy delete v4tov4 listenport=8080 listenaddress=0.0.0.0')
    }
}

Describe 'Library network test' {
    BeforeAll {
        $script:ok = [pscustomobject]@{ Ok = $true; Code = 302; Error = '' }
        $script:bad = [pscustomobject]@{ Ok = $false; Code = 0; Error = 'timed out' }
        $script:fwOk = [pscustomobject]@{ Rule = $true; HyperVRule = $true; Others = @() }
    }

    It 'gives the addresses by this PC''s name and by its IPv4 address' {
        $u = Get-KohaLanUrls -Ip '192.168.0.9' -ComputerName 'BIBLIOTECA-01'
        $u.Staff | Should -Be 'http://192.168.0.9:8080/'
        $u.Opac | Should -Be 'http://192.168.0.9/'
        $u.StaffByName | Should -Be 'http://biblioteca-01:8080/'
        $u.OpacByName | Should -Be 'http://biblioteca-01/'
        (Get-KohaLanUrls -Ip '192.168.0.9' -ComputerName 'BIBLIO$(x)').StaffByName | Should -Be ''
        Get-KohaLanUrls -Ip '' -ComputerName 'PC' | Should -BeNullOrEmpty
    }

    It 'passes when Koha answers on this PC''s address, and prints the name first' {
        $u = Get-KohaLanUrls -Ip '192.168.0.9' -ComputerName 'PC-BIB'
        $r = Resolve-KohaLanCheck -Urls $u -Staff $script:ok -Opac $script:ok -Mode 'mirrored' -Firewall $script:fwOk -Loopback $true
        $r.Ok | Should -BeTrue
        @($r.Lines | Where-Object { $_.Kind -eq 'warn' }).Count | Should -Be 0
        $r.Lines[0].Text | Should -Match 'passed.*\(192\.168\.0\.9\)'
        $r.Lines[1].Text | Should -Match 'http://pc-bib:8080/'
        $r.Lines[2].Text | Should -Match 'http://192\.168\.0\.9:8080/'
    }

    It 'says what to fix: loopback in mirrored mode, forwarding in NAT, firewall rules, another firewall' {
        $u = Get-KohaLanUrls -Ip '192.168.0.9' -ComputerName 'PC'
        $r = Resolve-KohaLanCheck -Urls $u -Staff $script:bad -Opac $script:ok -Mode 'mirrored' -Firewall ([pscustomobject]@{ Rule = $false; HyperVRule = $false; Others = @('ACME Firewall') }) -Loopback $false
        $r.Ok | Should -BeFalse
        $w = @($r.Lines | Where-Object { $_.Kind -eq 'warn' } | ForEach-Object { $_.Text }) -join "`n"
        $w | Should -Match 'failed'
        $w | Should -Match 'hostAddressLoopback'
        $w | Should -Match 'Koha \(web, local network\)'
        $w | Should -Match 'Hyper-V'
        $w | Should -Match 'ACME Firewall'
        $n = Resolve-KohaLanCheck -Urls $u -Staff $script:bad -Opac $script:bad -Mode 'nat' -Firewall ([pscustomobject]@{ Rule = $true; HyperVRule = $false; Others = @() }) -Loopback $false
        $t = @($n.Lines | ForEach-Object { $_.Text }) -join "`n"
        $t | Should -Match 'NAT mode'
        $t | Should -Not -Match 'Hyper-V'
        $t | Should -Not -Match 'hostAddressLoopback'
    }

    It 'asks for Koha to be started, or for a network, before testing' {
        $r = Resolve-KohaLanCheck -Urls $null -Staff $null -Opac $null -Mode 'nat' -Firewall $null -Running $false
        $r.Ok | Should -BeFalse
        $r.Lines[0].Kind | Should -Be 'warn'
        (Resolve-KohaLanCheck -Urls $null -Staff $null -Opac $null -Mode 'nat' -Firewall $null).Lines[0].Text | Should -Match 'no local network address'
    }

    It 'tests through this PC''s own address and never starts a stopped Debian' {
        $script:u = Get-KohaLanUrls -Ip '192.168.0.9' -ComputerName 'PC'
        Mock -ModuleName KohaEasy.Core Get-KohaLanUrls { $script:u }
        Mock -ModuleName KohaEasy.Core Get-KohaNetMode { 'nat' }
        Mock -ModuleName KohaEasy.Core Get-KohaFirewallFacts { $script:fwOk }
        Mock -ModuleName KohaEasy.Core Test-KohaLoopbackConfigured { $true }
        Mock -ModuleName KohaEasy.Core Test-KohaHttpUrl { [void]$script:urls.Add($Url); $script:ok }
        $script:urls = New-Object System.Collections.ArrayList
        Mock -ModuleName KohaEasy.Core Test-KohaDistroRunning { $true }
        (Test-KohaLanAccess).Ok | Should -BeTrue
        $script:urls | Should -Be @('http://192.168.0.9:8080/', 'http://192.168.0.9/')
        $script:urls.Clear()
        Mock -ModuleName KohaEasy.Core Test-KohaDistroRunning { $false }
        (Test-KohaLanAccess).Ok | Should -BeFalse
        $script:urls.Count | Should -Be 0
    }
}

Describe 'Library network setup' {
    BeforeAll {
        foreach ($n in 'Get-NetFirewallRule', 'Get-CimInstance') {
            if (-not (Get-Command $n -ErrorAction SilentlyContinue)) { New-Item -Path ('function:global:' + $n) -Value { param($DisplayName, $Namespace, $ClassName, $Filter) } | Out-Null }
        }
    }

    It 'names another firewall only when its firewall is on' {
        Mock -ModuleName KohaEasy.Core Get-NetFirewallRule { [pscustomobject]@{ Enabled = 'True' } }
        Mock -ModuleName KohaEasy.Core Get-CimInstance { @([pscustomobject]@{ displayName = 'ACME Firewall'; productState = 266240 }, [pscustomobject]@{ displayName = 'Old Trial'; productState = 262144 }) }
        $f = Get-KohaFirewallFacts
        $f.Rule | Should -BeTrue
        @($f.Others) | Should -Be @('ACME Firewall')
    }

    It 'asks for the administrator setup again only when something is missing or out of date' {
        $script:fw = [pscustomobject]@{ Rule = $true; HyperVRule = $true; Others = @() }
        Mock -ModuleName KohaEasy.Core Get-KohaFirewallFacts { $script:fw }
        Mock -ModuleName KohaEasy.Core Test-KohaNetTaskRegistered { $true }
        $now = (Get-KohaHiddenLaunch -Arguments 'UpdatePortProxy').Target
        Set-KohaState @{ lanAccess = $false; lanSetup = 0; netLaunch = '' } | Out-Null
        Get-KohaLanSetupNeed | Should -Be 'open'
        Set-KohaState @{ lanAccess = $true } | Out-Null
        Get-KohaLanSetupNeed | Should -Be 'update'
        Set-KohaState @{ lanSetup = 2 } | Out-Null
        Get-KohaLanSetupNeed | Should -Be 'update'
        Set-KohaState @{ netLaunch = $now } | Out-Null
        Get-KohaLanSetupNeed | Should -Be ''
        $script:fw.HyperVRule = $null
        Get-KohaLanSetupNeed | Should -Be ''
        $script:fw.HyperVRule = $false
        Get-KohaLanSetupNeed | Should -Be 'repair'
        $script:fw.HyperVRule = $true
        Mock -ModuleName KohaEasy.Core Test-KohaNetTaskRegistered { $false }
        Get-KohaLanSetupNeed | Should -Be 'repair'
        Set-KohaState @{ lanAccess = $false; lanSetup = 0; netLaunch = '' } | Out-Null
    }
}

Describe 'KohaEasy.exe' {
    BeforeEach {
        $script:bin = Join-Path $TestDrive ('bin-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:bin -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $repo 'windows/KohaEasy.Launcher.cs') -Destination $script:bin
        Copy-Item -LiteralPath (Join-Path $repo 'windows/koha.ico') -Destination $script:bin
        Set-KohaState @{ launcher = ''; launcherHash = '' } | Out-Null
        $script:compiles = 0
        $script:compile = { param($Source, $Output, $Options) $script:compiles++; $script:options = $Options; Set-Content -LiteralPath $Output -Value 'exe' }
    }
    AfterAll { Set-KohaState @{ launcher = ''; launcherHash = '' } | Out-Null }

    It 'is built once, checked, and built again only when its source changes' {
        Install-KohaLauncher -Bin $script:bin -Compile $script:compile -SelfTest { param($Path) $true } | Should -Be 'built'
        Test-Path -LiteralPath (Join-Path $script:bin 'KohaEasy.exe') | Should -BeTrue
        @(Get-ChildItem -LiteralPath $script:bin -Filter '*.new.exe').Count | Should -Be 0
        (Get-KohaState).launcher | Should -Be 'ok'
        $script:options | Should -Match '/target:winexe'
        $script:options | Should -Match ([regex]::Escape('/win32icon:"' + (Join-Path $script:bin 'koha.ico') + '"'))
        Install-KohaLauncher -Bin $script:bin -Compile $script:compile -SelfTest { param($Path) $true } | Should -Be 'current'
        $script:compiles | Should -Be 1
        Add-Content -LiteralPath (Join-Path $script:bin 'KohaEasy.Launcher.cs') -Value '// changed'
        Install-KohaLauncher -Bin $script:bin -Compile $script:compile -SelfTest { param($Path) $true } | Should -Be 'built'
        $script:compiles | Should -Be 2
    }

    It 'is not used when it does not compile or Windows does not let it run' {
        Install-KohaLauncher -Bin $script:bin -Compile $script:compile -SelfTest { param($Path) $false } | Should -Be 'failed'
        (Get-KohaState).launcher | Should -Be 'failed'
        Test-Path -LiteralPath (Join-Path $script:bin 'KohaEasy.exe') | Should -BeFalse
        @(Get-ChildItem -LiteralPath $script:bin -Filter '*.new.exe').Count | Should -Be 0
        Install-KohaLauncher -Bin $script:bin -Compile { throw 'csc.exe not found' } -SelfTest { param($Path) $true } | Should -Be 'failed'
        Get-KohaLauncherPath | Should -Be ''
    }

    It 'is not tried again after the tray did not start through it, until its source changes' {
        Install-KohaLauncher -Bin $script:bin -Compile $script:compile -SelfTest { param($Path) $true } | Should -Be 'built'
        Set-KohaState @{ launcher = 'refused' } | Out-Null
        Install-KohaLauncher -Bin $script:bin -Compile $script:compile -SelfTest { param($Path) $true } | Should -Be 'refused'
        $script:compiles | Should -Be 1
        Add-Content -LiteralPath (Join-Path $script:bin 'KohaEasy.Launcher.cs') -Value '// changed'
        Install-KohaLauncher -Bin $script:bin -Compile $script:compile -SelfTest { param($Path) $true } | Should -Be 'built'
    }

    It 'says so when its source is missing' {
        Remove-Item -LiteralPath (Join-Path $script:bin 'KohaEasy.Launcher.cs')
        Install-KohaLauncher -Bin $script:bin -Compile $script:compile -SelfTest { param($Path) $true } | Should -Be 'no-source'
        (Get-KohaState).launcher | Should -Be 'failed'
    }

    It 'replaces a copy in use by renaming it, and removes the old copies later' {
        $exe = Join-Path $script:bin 'KohaEasy.exe'
        Set-Content -LiteralPath $exe -Value 'old'
        Set-Content -LiteralPath ($exe + '.old-1') -Value 'older'
        $new = Join-Path $script:bin 'new.exe'
        Set-Content -LiteralPath $new -Value 'new'
        Set-KohaFileInPlace -NewFile $new -Path $exe
        Get-Content -LiteralPath $exe | Should -Be 'new'
        Test-Path -LiteralPath ($exe + '.old-1') | Should -BeFalse
        Test-Path -LiteralPath $new | Should -BeFalse
    }

    It 'compiles as C# 5 (the compiler of Windows'' .NET Framework) and passes arguments as Windows reads them' {
        $src = [System.IO.File]::ReadAllText((Join-Path $repo 'windows/KohaEasy.Launcher.cs'))
        @([System.Text.Encoding]::UTF8.GetBytes($src) | Where-Object { $_ -gt 127 }).Count | Should -Be 0
        if (-not ('KohaEasy.Launcher' -as [type])) { Add-Type -TypeDefinition $src -Language CSharp -CompilerOptions '-langversion:5' }
        [KohaEasy.Launcher]::Quote('Tray') | Should -Be 'Tray'
        [KohaEasy.Launcher]::Quote('') | Should -Be '""'
        [KohaEasy.Launcher]::Quote('C:\Program Files\x') | Should -Be '"C:\Program Files\x"'
        [KohaEasy.Launcher]::Quote('C:\a b\') | Should -Be '"C:\a b\\"'
        [KohaEasy.Launcher]::Quote('say "hi"') | Should -Be '"say \"hi\""'
        [KohaEasy.Launcher]::BuildArguments('C:\Koha Easy\bin\KohaEasy.ps1', @('Start', '-Trigger', 'logon')) |
            Should -Be '-NoProfile -ExecutionPolicy Bypass -File "C:\Koha Easy\bin\KohaEasy.ps1" Start -Trigger logon'
        $src | Should -Match 'psi\.CreateNoWindow = true'
        $src | Should -Match 'psi\.UseShellExecute = false'
    }
}

Describe 'Koha windows that close cleanly' {
    BeforeAll {
        $script:kw = Join-Path $TestDrive 'koha-window'
        [System.IO.File]::WriteAllText($script:kw, (InModuleScope KohaEasy.Core { $script:WindowScript }))
    }

    It 'koha-window is valid sh and always ends with exit 0, so the window closes' {
        & sh -n $script:kw
        $LASTEXITCODE | Should -Be 0
        '' | & sh $script:kw sh -c 'exit 3'
        $LASTEXITCODE | Should -Be 0
        & sh $script:kw true
        $LASTEXITCODE | Should -Be 0
    }

    It 'koha-window stops what the panel left holding the terminal' -Skip:(-not (Get-Command script -ErrorAction SilentlyContinue)) {
        $cmd = "sh '$($script:kw)' sh -c 'trap \`"\`" HUP; sleep 3099 & exit 0'"
        & timeout 30 script -qec $cmd /dev/null | Out-Null
        Start-Sleep -Milliseconds 300
        @(& pgrep -f '^sleep 3099$').Count | Should -Be 0
    }

    It 'is written into Debian as root, executable and with Linux line ends (script run by a real sh)' {
        $target = Join-Path $TestDrive 'usr/local/bin/koha-window'
        Mock -ModuleName KohaEasy.Core Invoke-KohaLinuxScript {
            $f = Join-Path $TestDrive 'kw-install.sh'
            [System.IO.File]::WriteAllText($f, $Script)
            $out = ($InputText -replace "`n", "`r`n") | & sh $f 2>&1
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($out -join "`n") }
        }
        $saved = (Get-KohaConfig).WindowPath
        Set-KohaConfig @{ WindowPath = $target }
        try {
            Install-KohaWindowScript | Should -BeTrue
            [System.IO.File]::ReadAllText($target) | Should -Not -Match "`r"
            (& sh -c "test -x '$target' && echo yes") | Should -Be 'yes'
        } finally { Set-KohaConfig @{ WindowPath = $saved } }
    }

    It 'opens the Debian terminal in its own window as the Debian user, through koha-window' {
        $l = Get-KohaDebianTerminalLaunch -Wsl 'C:\Windows\System32\wsl.exe' -Terminal ''
        $l.File | Should -Be 'C:\Windows\System32\wsl.exe'
        $l.Arguments | Should -Be '-d koha --cd ~ -- /usr/local/bin/koha-window --shell'
        $w = Get-KohaDebianTerminalLaunch -Wsl 'C:\Windows\System32\wsl.exe' -Terminal 'C:\wt.exe'
        $w.File | Should -Be 'C:\wt.exe'
        $w.Arguments | Should -Be '-w new --title "Koha - Debian" "C:\Windows\System32\wsl.exe" -d koha --cd ~ -- /usr/local/bin/koha-window --shell'
    }

    It 'the Koha window has the Debian terminal and the library network test' {
        $w = Get-Content -LiteralPath (Join-Path $repo 'windows/KohaEasy.Window.ps1') -Raw
        $w | Should -Match "Start-KohaHidden 'Terminal'"
        $w | Should -Match '\$btnTerminal.Enabled = \(-not \$Busy\) -and \$on'
        $w | Should -Match "'lan'\s+\{ \`$result = Test-KohaLanAccess \}"
        $t = Get-Content -LiteralPath (Join-Path $repo 'windows/KohaEasy.Tray.ps1') -Raw
        $t | Should -Match "Invoke-KohaCommand 'RebuildIndex'"
    }
}

Describe 'Koha icon next to the clock' {
    BeforeEach { Set-KohaState @{ trayPromoted = $false } | Out-Null }
    AfterAll { Set-KohaState @{ trayPromoted = $false } | Out-Null }

    It 'shows the Koha icon next to the clock once, on Windows 11 only' {
        $root = 'HKCU:\Control Panel\NotifyIconSettings'
        $script:set = New-Object System.Collections.ArrayList
        Mock -ModuleName KohaEasy.Core Test-Path { $true } -ParameterFilter { $LiteralPath -eq $root }
        Mock -ModuleName KohaEasy.Core Get-ChildItem { @([pscustomobject]@{ PSPath = 'k1' }, [pscustomobject]@{ PSPath = 'k2' }, [pscustomobject]@{ PSPath = 'k3' }) } -ParameterFilter { $LiteralPath -eq $root }
        Mock -ModuleName KohaEasy.Core Get-ItemProperty {
            switch ($LiteralPath) {
                'k1' { [pscustomobject]@{ ExecutablePath = 'C:\Windows\explorer.exe'; InitialTooltip = 'Koha' } }
                'k2' { [pscustomobject]@{ ExecutablePath = 'C:\KohaEasy\bin\KohaEasy.exe'; InitialTooltip = 'Koha' } }
                'k3' { [pscustomobject]@{ ExecutablePath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'; InitialTooltip = 'Other' } }
            }
        }
        Mock -ModuleName KohaEasy.Core New-ItemProperty { [void]$script:set.Add(('{0} {1}={2} {3}' -f ($LiteralPath -join ','), $Name, $Value, $PropertyType)) }
        Set-KohaTrayPromoted -Root $root | Should -Be 'promoted'
        $script:set | Should -Be @('k2 IsPromoted=1 DWord')
        Set-KohaTrayPromoted -Root $root | Should -Be 'done'
        $script:set.Count | Should -Be 1
    }

    It 'does nothing where Windows has no such list' {
        Set-KohaTrayPromoted -Root (Join-Path $TestDrive 'no-such-key') | Should -Be 'unsupported'
        (Get-KohaState).trayPromoted | Should -BeFalse
    }
}

Describe 'No console window, whatever started Koha' {
    AfterEach { Set-KohaState @{ launcher = ''; hiddenLaunch = 'conhost' } | Out-Null }

    It 'prefers Windows Script Host over conhost, and gives it no PowerShell command line' {
        $js = [System.IO.Path]::Combine((Get-KohaPath Bin), 'KohaEasy.Hidden.js')
        New-Item -ItemType Directory -Path (Split-Path -Parent $js) -Force | Out-Null
        Set-Content -LiteralPath $js -Value '//'
        $ws = Join-Path $TestDrive 'wscript.exe'
        Set-Content -LiteralPath $ws -Value ''
        $conhost = Join-Path $TestDrive 'conhost.exe'
        Set-Content -LiteralPath $conhost -Value ''
        try {
            $l = Get-KohaHiddenLaunch -Arguments 'Window' -Conhost $conhost -Launcher '' -Wscript $ws
            $l.Target | Should -Be $ws
            $l.Arguments | Should -Be ('//B //Nologo "{0}" Window -Hidden' -f $js)
            $l.Arguments | Should -Not -Match 'powershell|Bypass'
            Get-KohaWscriptPath | Should -BeLike '*wscript.exe'
            Set-KohaState @{ hiddenLaunch = 'nowscript' } | Out-Null
            Get-KohaWscriptPath | Should -Be ''
            Get-KohaConhostPath | Should -BeLike '*conhost.exe'
        } finally { Remove-Item -LiteralPath $js -Force }
    }

    It 'KohaEasy.Hidden.js is plain ASCII, hides PowerShell and waits for it' {
        $src = [System.IO.File]::ReadAllText((Join-Path $repo 'windows/KohaEasy.Hidden.js'))
        @([System.Text.Encoding]::UTF8.GetBytes($src) | Where-Object { $_ -gt 127 }).Count | Should -Be 0
        $src | Should -Match 'shell\.Run\(cmd, 0, true\)'
        $src | Should -Match 'KohaEasy\.ps1'
    }

    It 'starts again the hidden way when it was started with a console someone sees' {
        $exe = 'C:\KohaEasy\bin\KohaEasy.exe'
        Test-KohaRelaunchHidden -Command 'Window' -Hidden $false -Target $exe | Should -BeTrue
        Test-KohaRelaunchHidden -Command 'Tray' -Hidden $false -Target 'C:\Windows\System32\wscript.exe' | Should -BeTrue
        Test-KohaRelaunchHidden -Command 'Window' -Hidden $true -Target $exe | Should -BeFalse
        Test-KohaRelaunchHidden -Command 'Run' -Hidden $false -Target $exe | Should -BeFalse
        Test-KohaRelaunchHidden -Command 'Install' -Hidden $false -Target $exe | Should -BeFalse
        Test-KohaRelaunchHidden -Command 'SetupNetwork' -Hidden $false -Target $exe | Should -BeFalse
        # Never into powershell.exe again: that would loop.
        Test-KohaRelaunchHidden -Command 'Window' -Hidden $false -Target 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' | Should -BeFalse
        Get-KohaRelaunchArguments -Command 'Start' -Bound @{ Trigger = 'logon'; Quiet = [switch]$true } | Should -Be 'Start -Trigger logon -Quiet'
        Get-KohaRelaunchArguments -Command 'Stop' -Bound @{ Force = [switch]$true; Pause = [switch]$false } | Should -Be 'Stop -Force'
        $ps = Get-Content -LiteralPath (Join-Path $repo 'windows/KohaEasy.ps1') -Raw
        $ps.IndexOf('Test-KohaRelaunchHidden') | Should -BeLessThan $ps.IndexOf('switch ($Command)')
    }
}

Describe 'Desktop shortcut' {
    It 'uses the desktop that exists, never the Public one' {
        $user = Join-Path $TestDrive 'Users/paulo'
        $od = Join-Path $user 'OneDrive - Biblioteca/Desktop'
        New-Item -ItemType Directory -Path $od -Force | Out-Null
        Get-KohaDesktopPath -Known (Join-Path $user 'Desktop') -Registry '' -UserProfile $user | Should -Be $od
        $plain = Join-Path $user 'Desktop'
        New-Item -ItemType Directory -Path $plain -Force | Out-Null
        Get-KohaDesktopPath -Known $plain -Registry $od -UserProfile $user | Should -Be $plain
        Get-KohaDesktopPath -Known 'C:\Users\Public\Desktop' -Registry '' -UserProfile '' | Should -Be ''
        Get-KohaDesktopPath -Known (Join-Path $TestDrive 'nowhere') -Registry '' -UserProfile '' | Should -Be ''
    }

    It 'does not count a shortcut that is gone right after it was written' {
        Mock -ModuleName KohaEasy.Core Save-KohaLnkShortcut { }
        Mock -ModuleName KohaEasy.Core Set-KohaShortcutAppId { $true }
        $dt = Join-Path $TestDrive 'Desk2'
        New-Item -ItemType Directory -Path $dt -Force | Out-Null
        $made = @(New-KohaShortcuts -StartMenu (Join-Path $TestDrive 'Programs2/Koha') -Desktop $dt -IconSource (Join-Path $repo 'windows/koha.ico'))
        @($made | Where-Object { $_ -like '*.lnk' }).Count | Should -Be 0
        @($made | Where-Object { $_ -like '*.url' }).Count | Should -Be 2
    }
}

Describe 'The Koha icon as the one way in' {
    BeforeEach {
        $script:did = New-Object System.Collections.ArrayList
        Mock -ModuleName KohaEasy.Core Set-KohaTrayAtSignIn { [void]$script:did.Add('signin') }
        Mock -ModuleName KohaEasy.Core Register-KohaTasks { [void]$script:did.Add('register ' + $Autostart) }
        Mock -ModuleName KohaEasy.Core Start-KohaHidden { [void]$script:did.Add('hidden ' + $Arguments) }
        Mock -ModuleName KohaEasy.Core Start-KohaKeepAlive { [void]$script:did.Add('keep-alive') }
        Mock -ModuleName KohaEasy.Core Update-KohaHandshake { }
    }

    It 'starts the tray and Koha, and puts back what was deleted, when nothing runs' {
        Mock -ModuleName KohaEasy.Core Test-KohaTrayAtSignIn { $false }
        Mock -ModuleName KohaEasy.Core Test-KohaTaskPresent { $false }
        Mock -ModuleName KohaEasy.Core Test-KohaTrayRunning { $false }
        Mock -ModuleName KohaEasy.Core Test-KohaDistroRunning { $false }
        Set-KohaState @{ autostart = 'logon'; trayClosed = $true } | Out-Null
        $r = Invoke-KohaLaunch
        $r | Should -Be @('signin', 'tasks', 'tray', 'start')
        $script:did | Should -Contain 'hidden Tray'
        $script:did | Should -Contain 'register logon'
        $script:did | Should -Contain 'keep-alive'
        (Get-KohaState).trayClosed | Should -BeFalse
        (Get-KohaState).desired | Should -Be 'running'
    }

    It 'starts nothing twice when Koha and the tray already run' {
        Mock -ModuleName KohaEasy.Core Test-KohaTrayAtSignIn { $true }
        Mock -ModuleName KohaEasy.Core Test-KohaTaskPresent { $true }
        Mock -ModuleName KohaEasy.Core Test-KohaTrayRunning { $true }
        Mock -ModuleName KohaEasy.Core Test-KohaDistroRunning { $true }
        @(Invoke-KohaLaunch).Count | Should -Be 0
        $script:did.Count | Should -Be 0
    }

    It 'still opens the window when the sign-in entry or the tasks cannot be written' {
        Mock -ModuleName KohaEasy.Core Test-KohaTrayAtSignIn { $false }
        Mock -ModuleName KohaEasy.Core Set-KohaTrayAtSignIn { throw 'denied' }
        Mock -ModuleName KohaEasy.Core Test-KohaTaskPresent { $false }
        Mock -ModuleName KohaEasy.Core Register-KohaTasks { throw 'denied' }
        Mock -ModuleName KohaEasy.Core Test-KohaTrayRunning { $true }
        Mock -ModuleName KohaEasy.Core Test-KohaDistroRunning { $true }
        @(Invoke-KohaLaunch).Count | Should -Be 0
    }

    It 'registers the Koha tasks again before a start when they were deleted' {
        Mock -ModuleName KohaEasy.Core Test-KohaTaskPresent { $Name -ne 'Keep Koha running' }
        Set-KohaState @{ autostart = 'manual' } | Out-Null
        Start-Koha -Trigger user | Should -Be 'started'
        $script:did | Should -Be @('register manual', 'keep-alive')
        Set-KohaState @{ autostart = 'logon' } | Out-Null
    }

    It 'makes the sign-in task again when the sign-in toggle finds it deleted' {
        Mock -ModuleName KohaEasy.Core Test-KohaTaskPresent { $false }
        Set-KohaSignInTask -Enabled $true
        $script:did | Should -Be @('register logon')
    }

    It 'keeps making the other shortcuts when Windows refuses one, and says why' {
        Mock -ModuleName KohaEasy.Core Save-KohaLnkShortcut { if ($Path -like '*Desk3*Koha.lnk') { throw 'Unable to save shortcut' }; [System.IO.File]::WriteAllText($Path, '') }
        Mock -ModuleName KohaEasy.Core Set-KohaShortcutAppId { $true }
        $sm = Join-Path $TestDrive 'Programs3/Koha'
        $dt = Join-Path $TestDrive 'Desk3'
        New-Item -ItemType Directory -Path $dt -Force | Out-Null
        $made = @(New-KohaShortcuts -StartMenu $sm -Desktop $dt -IconSource (Join-Path $repo 'windows/koha.ico') -PublicDesktop '')
        # The desktop one is the Start menu one, copied as a plain file.
        $made.Count | Should -Be 12
        Test-Path -LiteralPath (Join-Path $sm 'Koha.lnk') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $dt 'Koha.lnk') | Should -BeTrue
        Get-KohaIconPlace | Should -Be 'desktop'
        @(Get-KohaShortcutErrors).Count | Should -Be 1
        @(Get-KohaShortcutErrors)[0] | Should -BeLike '*Koha.lnk: Unable to save shortcut'
    }

    It 'puts the Koha icon on the desktop of all users only when neither the desktop nor the Start menu took it' {
        Mock -ModuleName KohaEasy.Core Save-KohaLnkShortcut { if ($Path -like '*Pub4*') { [System.IO.File]::WriteAllText($Path, ''); return }; throw 'Access is denied' }
        Mock -ModuleName KohaEasy.Core Set-KohaShortcutAppId { $true }
        $pub = Join-Path $TestDrive 'Pub4'
        $dt = Join-Path $TestDrive 'Desk4'
        New-Item -ItemType Directory -Path $pub, $dt -Force | Out-Null
        New-KohaShortcuts -StartMenu (Join-Path $TestDrive 'Programs4/Koha') -Desktop $dt -IconSource (Join-Path $repo 'windows/koha.ico') -PublicDesktop $pub | Out-Null
        Get-KohaIconPlace | Should -Be 'public'
        Test-Path -LiteralPath (Join-Path $pub 'Koha.lnk') | Should -BeTrue
        # Once the own desktop takes it again, the second icon goes.
        Mock -ModuleName KohaEasy.Core Save-KohaLnkShortcut { [System.IO.File]::WriteAllText($Path, '') }
        New-KohaShortcuts -StartMenu (Join-Path $TestDrive 'Programs4/Koha') -Desktop $dt -IconSource (Join-Path $repo 'windows/koha.ico') -PublicDesktop $pub | Out-Null
        Get-KohaIconPlace | Should -Be 'desktop'
        Test-Path -LiteralPath (Join-Path $pub 'Koha.lnk') | Should -BeFalse
    }

    It 'writes a shortcut the second way when WScript.Shell cannot, and gives both reasons when neither can' {
        Mock -ModuleName KohaEasy.Core Import-KohaNative { $false }
        { Save-KohaLnkShortcut -Path (Join-Path $TestDrive 'x.lnk') -Target 'a' -Arguments '' -Icon 'i' } | Should -Throw '*WScript.Shell*'
    }

    It 'logs why a window, the tray or the Koha icon ended, and reads the tray''s reason back' {
        $ps = Get-Content -LiteralPath (Join-Path $repo 'windows/KohaEasy.ps1') -Raw
        $ps.IndexOf('trap {') | Should -BeLessThan $ps.IndexOf('Import-Module')
        $ps | Should -Match "'\{0\} failed: \{1\} \| stack: \{2\}'"
        Write-KohaLog 'Tray failed: Add-Type: compile error | stack: at <ScriptBlock>'
        Get-KohaLastFailure 'Tray' | Should -Be 'Add-Type: compile error'
        Get-KohaLastFailure 'Window' | Should -Be ''
    }

    It 'downloads the panel dependencies with one status line, APT''s output only in its log' {
        $sh = Get-Content -LiteralPath (Join-Path $repo 'installer') -Raw
        $sh | Should -Match 'Downloading the panel dependencies\.\.\.'
        $sh | Should -Match 'apt_install "\$\{MISSING_DEPS\[@\]\}" >/dev/null 2>&1'
        $sh | Should -Match 'KEI_VERBOSE'
    }

    It 'opens the Koha window from the Koha icon, and brings an open one to the front' {
        $ps = Get-Content -LiteralPath (Join-Path $repo 'windows/KohaEasy.ps1') -Raw
        $at = $ps.IndexOf("    'Launch' {")
        $at | Should -BeGreaterThan 0
        $ps.IndexOf('Invoke-KohaLaunch', $at) | Should -BeLessThan $ps.IndexOf("    'Window' {")
        $ps.IndexOf('KohaEasy.Window.ps1', $at) | Should -BeLessThan $ps.IndexOf("    'Window' {")
        Test-KohaRelaunchHidden -Command 'Launch' -Hidden $false -Target 'C:\KohaEasy\bin\KohaEasy.exe' | Should -BeTrue
        $w = Get-Content -LiteralPath (Join-Path $repo 'windows/KohaEasy.Window.ps1') -Raw
        $w | Should -Match 'Show-KohaOpenWindow \$title'
        $cs = Get-Content -LiteralPath (Join-Path $repo 'windows/KohaEasy.Launcher.cs') -Raw
        $cs | Should -Match 'public static bool FocusWindow'
        $cs.IndexOf('Native.AllowForeground()') | Should -BeLessThan $cs.IndexOf('Process.Start(psi)')
    }
}

Describe 'Cold boot' {
    It 'reads a Koha that should run as starting in the first seconds after Windows starts' {
        $st = @{ desired = 'running'; startedAt = 0; autostart = 'logon' }
        Resolve-KohaState -Installed $true -Running $false -Linux $null -State $st -Now 1000 -GraceUntil 1045 | Should -Be 'starting'
        Resolve-KohaState -Installed $true -Running $true -Linux $null -State $st -Now 1000 -GraceUntil 1045 | Should -Be 'starting'
        Resolve-KohaState -Installed $true -Running $false -Linux $null -State $st -Now 1050 -GraceUntil 1045 | Should -Be 'stopped'
        Resolve-KohaState -Installed $true -Running $true -Linux $null -State $st -Now 1050 -GraceUntil 1045 | Should -Be 'not_responding'
        Resolve-KohaState -Installed $true -Running $false -Linux $null -State @{ desired = 'stopped'; startedAt = 0 } -Now 1000 -GraceUntil 1045 | Should -Be 'stopped_by_user'
        Resolve-KohaState -Installed $true -Running $false -Linux $null -State @{ desired = 'running'; startedAt = 0; autostart = 'manual' } -Now 1000 -GraceUntil 1045 | Should -Be 'stopped'
    }

    It 'counts the grace from when Windows started' {
        Get-KohaBootGraceUntil -UptimeMs 10000 -Now 5000 | Should -Be 5035
        Get-KohaBootGraceUntil -UptimeMs 600000 -Now 5000 | Should -Be 4445
        # TickCount wraps negative after 24.9 days: that is a long uptime.
        Get-KohaBootGraceUntil -UptimeMs -1000 -Now 5000000 | Should -BeLessThan 5000000
    }

    It 'sends no failure notification during the grace' {
        $n = Get-KohaNotifications -Previous 'running' -Status ([pscustomobject]@{ State = 'starting'; Linux = $null }) -Disk $null -State @{ desired = 'running' }
        @($n.Notifications).Count | Should -Be 0
    }
}

Describe 'Clean stop when Windows ends the session' {
    BeforeEach { Set-KohaState @{ stopScriptHash = '' } | Out-Null }
    AfterAll { Set-KohaState @{ stopScriptHash = '' } | Out-Null }

    It 'writes the stop script into Debian once, and again when it changes' {
        Mock -ModuleName KohaEasy.Core Test-KohaDistroRunning { $true }
        Mock -ModuleName KohaEasy.Core Invoke-KohaLinuxScript { $script:sent = $Script; $script:body = $InputText; [pscustomobject]@{ ExitCode = 0; Output = '' } }
        Update-KohaStopScript | Should -Be 'written'
        $script:sent | Should -Match "f='/usr/local/sbin/koha-easy-stop'"
        $script:body | Should -Match 'koha-stop-guard stop'
        Update-KohaStopScript | Should -Be 'current'
        Should -Invoke -ModuleName KohaEasy.Core Invoke-KohaLinuxScript -Times 1 -Exactly
    }

    It 'runs the stop and the terminate through wsl.exe with no console, and never asks WSL first' {
        Set-KohaState @{ stopScriptHash = (Get-KohaStopScriptHash) } | Out-Null
        Mock -ModuleName KohaEasy.Core Test-KohaDistroRunning { throw 'must not ask WSL' }
        Mock -ModuleName KohaEasy.Core Stop-KohaDebianGracefully { throw 'must not run' }
        $script:ran = New-Object System.Collections.ArrayList
        $d = { param($c, $ms) [void]$script:ran.Add(@{ C = $c; Ms = $ms }); 0 }
        Stop-KohaForSessionEnd -RunDetached $d | Should -Be 'clean'
        $script:ran[0].C | Should -Match '"[^"]*wsl\.exe" -d koha -u root -- timeout -k 5 60 sh /usr/local/sbin/koha-easy-stop$'
        $script:ran[0].Ms | Should -Be 70000
        $script:ran[1].C | Should -Match '"[^"]*wsl\.exe" --terminate koha$'
        $d2 = { param($c, $ms) if ($c -match 'koha-easy-stop') { Start-Sleep -Milliseconds 2100; 1 } else { 0 } }
        Stop-KohaForSessionEnd -RunDetached $d2 | Should -Be 'forced'
    }

    It 'falls back to the usual stop when the script is not in Debian yet or wsl.exe cannot start' {
        Mock -ModuleName KohaEasy.Core Test-KohaDistroRunning { $true }
        Mock -ModuleName KohaEasy.Core Stop-KohaDebianGracefully { 'clean' }
        Stop-KohaForSessionEnd -RunDetached { throw 'must not run' } | Should -Be 'clean'
        Set-KohaState @{ stopScriptHash = (Get-KohaStopScriptHash) } | Out-Null
        Stop-KohaForSessionEnd -RunDetached { param($c, $ms) -2 } | Should -Be 'clean'
        # wsl.exe failed at once: it stopped nothing.
        Stop-KohaForSessionEnd -RunDetached { param($c, $ms) 1 } | Should -Be 'clean'
        Should -Invoke -ModuleName KohaEasy.Core Stop-KohaDebianGracefully -Times 3 -Exactly
    }

    It 'the tray asks to be told first, and uses the detached stop' {
        $t = Get-Content -LiteralPath (Join-Path $repo 'windows/KohaEasy.Tray.ps1') -Raw
        $t | Should -Match 'SetProcessShutdownParameters\(0x3FF, 0\)'
        $t | Should -Match 'DETACHED_PROCESS \| CREATE_NEW_PROCESS_GROUP'
        $t | Should -Match '\[KohaSessionWindow\]::ShutDownFirst\(\)'
        $t | Should -Match 'Update-KohaStopScript'
    }
}
