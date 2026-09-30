# Pester 5 tests for the Windows install flow (windows\KohaEasy.Install.psm1,
# windows\install.ps1). wsl.exe, UAC and downloads are mocked.

BeforeAll {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $env:KOHAEASY_ROOT = Join-Path $TestDrive 'KohaEasy'
    $env:TEMP = Join-Path $TestDrive 'tmp'
    New-Item -ItemType Directory -Path $env:TEMP -Force | Out-Null
    Import-Module (Join-Path $repo 'windows/KohaEasy.Install.psm1') -Force
    Set-KohaConfig @{ Root = $env:KOHAEASY_ROOT }
    $good = @{ Build = 22631; Is64 = $true; MemGB = 16; FreeGB = 120; VirtFirmware = $true; Hypervisor = $false; Arm = $false }
}

AfterAll { Remove-Module KohaEasy.Install, KohaEasy.Core, KohaEasy.Lang -ErrorAction SilentlyContinue }

Describe 'Checks before installing' {
    It 'passes a normal Windows 11 PC' {
        @(Get-KohaPreflight -Facts $good | Where-Object { $_.Level -ne 'ok' }).Count | Should -Be 0
    }

    It 'stops on old Windows, 32-bit, little memory or disk, and virtualization off' {
        $cases = @(
            @{ Build = 18363 }, @{ Is64 = $false }, @{ MemGB = 3 }, @{ FreeGB = 8 }, @{ VirtFirmware = $false }
        )
        foreach ($c in $cases) {
            $f = $good.Clone(); foreach ($k in $c.Keys) { $f[$k] = $c[$k] }
            @(Get-KohaPreflight -Facts $f | Where-Object { $_.Level -eq 'error' }).Count | Should -Be 1 -Because ($c.Keys -join ',')
        }
    }

    It 'only warns below the recommended memory and disk, and trusts a running hypervisor' {
        $f = $good.Clone(); $f.MemGB = 6; $f.FreeGB = 15
        @(Get-KohaPreflight -Facts $f | Where-Object { $_.Level -eq 'warn' }).Count | Should -Be 2
        $f = $good.Clone(); $f.VirtFirmware = $false; $f.Hypervisor = $true
        @(Get-KohaPreflight -Facts $f | Where-Object { $_.Level -eq 'error' }).Count | Should -Be 0
    }
}

Describe 'Debian image and WSL settings' {
    It 'picks the default Debian of Microsoft''s list for the processor, with its SHA-256' {
        $m = '{"ModernDistributions":{"Debian":[{"Name":"Debian","Default":true,"Amd64Url":{"Url":"https://x.test/debian-amd64.wsl","Sha256":"0xab12"},"Arm64Url":{"Url":"https://x.test/debian-arm64.wsl","Sha256":"cd34"}}],"Ubuntu":[]}}' | ConvertFrom-Json
        $i = Get-KohaDebianImage -Manifest $m
        $i.Url | Should -Be 'https://x.test/debian-amd64.wsl'
        $i.Sha256 | Should -Be 'AB12'
        (Get-KohaDebianImage -Manifest $m -Arm $true).Url | Should -Be 'https://x.test/debian-arm64.wsl'
        { Get-KohaDebianImage -Manifest ('{"Distributions":[]}' | ConvertFrom-Json) } | Should -Throw
    }

    It 'enables systemd, makes the chosen user the default and keeps Windows paths out of Linux' {
        $c = Get-KohaWslConf -User 'maria'
        $c | Should -Match '(?m)^\[boot\]$'
        $c | Should -Match '(?m)^systemd=true$'
        $c | Should -Match '(?s)\[user\]\ndefault=maria\n'
        $c | Should -Match '(?m)^appendWindowsPath=false$'
        Get-KohaWslConf | Should -Match '(?m)^default=root$'
    }

    It 'keeps what the panel wrote in wsl.conf (the timezone) when it writes it again' {
        $old = "[boot]`nsystemd=false`n`n[user]`ndefault=root`n`n[time]`nuseWindowsTimezone=false`n"
        $c = Get-KohaWslConf -Existing $old -User 'maria'
        $c | Should -Match '(?s)\[boot\]\nsystemd=true\n'
        $c | Should -Match '(?s)\[user\]\ndefault=maria\n'
        $c | Should -Match '(?s)\[time\]\nuseWindowsTimezone=false\n'
        $c | Should -Not -Match 'systemd=false'
        Get-KohaWslConf -Existing $c -User 'maria' | Should -Be $c
    }

    It 'adds only missing .wslconfig keys, mirrored networking only on Windows 11 22H2+' {
        $new = Merge-KohaWslConfig -Text '' -Build 22631
        $new | Should -Match '(?m)^\[wsl2\]\r?$'
        $new | Should -Match '(?m)^vmIdleTimeout=-1\r?$'
        $new | Should -Match '(?m)^networkingMode=mirrored\r?$'
        Merge-KohaWslConfig -Text '' -Build 19045 | Should -Not -Match 'networkingMode'

        $mine = "[wsl2]`r`nmemory=6GB`r`nnetworkingMode=nat`r`n`r`n[experimental]`r`nsparseVhd=true`r`n"
        $new = Merge-KohaWslConfig -Text $mine -Build 22631
        $new | Should -Match 'networkingMode=nat'
        $new | Should -Not -Match 'mirrored'
        $new | Should -Match '(?s)memory=6GB\r\nnetworkingMode=nat\r\nvmIdleTimeout=-1\r\n.*\[experimental\]\r\nsparseVhd=true'
        Merge-KohaWslConfig -Text $new -Build 22631 | Should -Be $new
    }

    It 'turns on hostAddressLoopback in [experimental] on Windows 11 22H2+, keeping the user''s own choice' {
        $new = Merge-KohaWslConfig -Text '' -Build 22631
        $new | Should -Match '(?s)\[wsl2\]\r\n.*\r\n\r\n\[experimental\]\r\nhostAddressLoopback=true\r\n$'
        Merge-KohaWslConfig -Text $new -Build 22631 | Should -Be $new
        Merge-KohaWslConfig -Text '' -Build 19045 | Should -Not -Match 'experimental'
        $mine = "[experimental]`r`nhostAddressLoopback=false`r`n"
        $m = Merge-KohaWslConfig -Text $mine -Build 22631
        $m | Should -Match 'hostAddressLoopback=false'
        $m | Should -Not -Match 'hostAddressLoopback=true'
        $m | Should -Match '(?m)^networkingMode=mirrored\r?$'
    }

    It 'turns C:\ paths into /mnt/c paths' {
        ConvertTo-KohaWslPath 'C:\KohaEasy\bin' | Should -Be '/mnt/c/KohaEasy/bin'
    }
}

Describe 'Debian download' {
    It 'refuses an image whose SHA-256 does not match, and removes it' {
        Mock -ModuleName KohaEasy.Install Test-KohaDistroInstalled { $false }
        Mock -ModuleName KohaEasy.Install Get-KohaDistributionManifest { '{"ModernDistributions":{"Debian":[{"Name":"Debian","Default":true,"Amd64Url":{"Url":"https://x.test/d.wsl","Sha256":"0x00"}}]}}' | ConvertFrom-Json }
        Mock -ModuleName KohaEasy.Install Save-KohaDownload { Set-Content -LiteralPath $Path -Value 'not debian' }
        Mock -ModuleName KohaEasy.Install Invoke-KohaWsl { if ($Arguments[0] -eq '--install') { return [pscustomobject]@{ ExitCode = 1; Output = 'Invalid command line argument: --location' } }; throw 'must not import' }
        { New-KohaDistro } | Should -Throw '*SHA-256*'
        @(Get-ChildItem (Get-KohaPath Wsl) -Filter '*.tar.gz').Count | Should -Be 0
    }

    It 'imports a good image as koha with WSL 2, and leaves an existing one alone' {
        Mock -ModuleName KohaEasy.Install Test-KohaDistroInstalled { $false }
        $script:img = Join-Path $TestDrive 'img'
        Set-Content -LiteralPath $script:img -Value 'debian' -NoNewline
        $sha = (Get-FileHash -LiteralPath $script:img -Algorithm SHA256).Hash
        Mock -ModuleName KohaEasy.Install Get-KohaDistributionManifest { ('{"ModernDistributions":{"Debian":[{"Name":"Debian","Amd64Url":{"Url":"https://x.test/d.wsl","Sha256":"0x' + $sha + '"}}]}}') | ConvertFrom-Json }
        Mock -ModuleName KohaEasy.Install Save-KohaDownload { Copy-Item -LiteralPath $script:img -Destination $Path }
        Mock -ModuleName KohaEasy.Install Invoke-KohaWsl { [pscustomobject]@{ ExitCode = [int]($Arguments[0] -eq '--install'); Output = '' } }
        New-KohaDistro | Should -Be 'imported'
        Should -Invoke -ModuleName KohaEasy.Install Invoke-KohaWsl -ParameterFilter { $Arguments[0] -eq '--import' -and $Arguments[1] -eq 'koha' -and $Arguments[-1] -eq '2' }
        Mock -ModuleName KohaEasy.Install Test-KohaDistroInstalled { $true }
        New-KohaDistro | Should -Be 'exists'
    }

    It 'lets WSL install and check Debian itself when it can, without downloading anything here' {
        $script:installed = $false
        Mock -ModuleName KohaEasy.Install Test-KohaDistroInstalled { $script:installed }
        Mock -ModuleName KohaEasy.Install Invoke-KohaWsl { $script:installed = $true; [pscustomobject]@{ ExitCode = 0; Output = '' } }
        Mock -ModuleName KohaEasy.Install Get-KohaDistributionManifest { throw 'must not download' }
        New-KohaDistro | Should -Be 'installed'
        Should -Invoke -ModuleName KohaEasy.Install Invoke-KohaWsl -Times 1 -Exactly -ParameterFilter {
            ($Arguments -join ' ') -eq ('--install Debian --name koha --location {0} --no-launch --web-download' -f (Get-KohaPath Wsl))
        }
    }

    It 'downloads with a user agent that download servers do not treat as a browser' {
        $text = [System.IO.File]::ReadAllText((Join-Path $repo 'windows/KohaEasy.Install.psm1'))
        $body = $text.Substring($text.IndexOf('function Save-KohaDownload'))
        $body = $body.Substring(0, $body.IndexOf("`n}"))
        $body | Should -Match 'curl\.exe'
        $body | Should -Match "Invoke-WebRequest [^\r\n]*-UserAgent 'KohaEasyInstaller'"
    }
}

Describe 'Install flow' {
    BeforeEach {
        Remove-Item -LiteralPath (Get-KohaPath Root) -Recurse -Force -ErrorAction SilentlyContinue
        $script:calls = New-Object System.Collections.ArrayList
        Mock -ModuleName KohaEasy.Install Write-Host { }
        Mock -ModuleName KohaEasy.Install Install-KohaWslPlatform { [void]$script:calls.Add('wsl platform') }
        Mock -ModuleName KohaEasy.Install Register-KohaResume { [void]$script:calls.Add('resume') }
        Mock -ModuleName KohaEasy.Install New-KohaDistro { [void]$script:calls.Add('distro'); 'imported' }
        Mock -ModuleName KohaEasy.Install Set-KohaDistroConfig { [void]$script:calls.Add('systemd'); $true }
        Mock -ModuleName KohaEasy.Install Copy-KohaPanelIntoDistro { [void]$script:calls.Add('copy panel') }
        Mock -ModuleName KohaEasy.Install Test-KohaInstalledInDistro { $true }
        Mock -ModuleName KohaEasy.Install Register-KohaTasks { [void]$script:calls.Add('tasks ' + $Autostart) }
        Mock -ModuleName KohaEasy.Install Set-KohaTrayAtSignIn { [void]$script:calls.Add('tray at sign-in') }
        Mock -ModuleName KohaEasy.Install New-KohaShortcuts { [void]$script:calls.Add('shortcuts') }
        Mock -ModuleName KohaEasy.Install Start-Koha { [void]$script:calls.Add('start'); 'ready' }
        Mock -ModuleName KohaEasy.Install Start-KohaTray { }
        Mock -ModuleName KohaEasy.Install Restart-KohaTray { [void]$script:calls.Add('tray restart') }
        Mock -ModuleName KohaEasy.Install Start-KohaTrayChecked { [void]$script:calls.Add('tray') }
        Mock -ModuleName KohaEasy.Install Test-KohaLinuxUserExists { $true }
        Mock -ModuleName KohaEasy.Install Test-KohaDistroInstalled { $false }
        Mock -ModuleName KohaEasy.Install Restore-KohaDistro { 'ok' }
        Mock -ModuleName KohaEasy.Install Rename-KohaLegacyDistro { 'none' }
        Mock -ModuleName KohaEasy.Install Set-KohaDistroIcon { [void]$script:calls.Add('icons') }
        Mock -ModuleName KohaEasy.Install Enable-KohaLanAccess { [void]$script:calls.Add('lan'); $true }
        Mock -ModuleName KohaEasy.Install Get-KohaLanUrls { $null }
        Mock -ModuleName KohaEasy.Install New-KohaLinuxUser { [void]$script:calls.Add('user ' + $User) }
        Mock -ModuleName KohaEasy.Install Read-KohaLinuxAccount { throw 'must not ask' }
        Mock -ModuleName KohaEasy.Install Install-KohaLauncherStep { [void]$script:calls.Add('launcher') }
        Mock -ModuleName KohaEasy.Install Show-KohaLanCheck { [void]$script:calls.Add('lan check') }
        Mock -ModuleName KohaEasy.Install Update-KohaWslConfig { $false }
        Mock -ModuleName KohaEasy.Install Test-KohaKeepAliveOutdated { $false }
        Mock -ModuleName KohaEasy.Install Stop-KohaDebianGracefully { [void]$script:calls.Add('stop koha' + $(if ($Shutdown) { ', shutdown' } else { '' })); 'clean' }
        Mock -ModuleName KohaEasy.Install Get-KohaLanSetupNeed {
            $s = Get-KohaState
            if (-not [bool]$s['lanAccess']) { return 'open' }
            if ([int]$s['lanSetup'] -lt 2) { return 'update' }
            ''
        }
    }

    It 'stops before touching Windows when a check fails' {
        $f = $good.Clone(); $f.Build = 17763
        Install-Koha -Facts $f -NonInteractive | Should -Be 1
        $script:calls.Count | Should -Be 0
    }

    It 'asks for a restart when WSL needs one, and continues from there afterwards' {
        Mock -ModuleName KohaEasy.Install Test-KohaWslReady { $false }
        Install-Koha -Facts $good -NonInteractive | Should -Be 3
        $script:calls | Should -Be @('wsl platform', 'resume')
        (Get-KohaState).phase | Should -Be 'wsl'

        Mock -ModuleName KohaEasy.Install Test-KohaWslReady { $true }
        $script:calls.Clear()
        Install-Koha -Facts $good -NonInteractive | Should -Be 0
        $script:calls | Should -Be @('distro', 'systemd', 'copy panel', 'launcher', 'tasks logon', 'tray at sign-in', 'shortcuts', 'icons', 'tray', 'start', 'lan check')
        (Get-KohaState).phase | Should -Be 'done'
        (Get-KohaState).autostart | Should -Be 'logon'
    }

    It 'creates the Debian user chosen at the start before systemd, and keeps only its name' {
        Mock -ModuleName KohaEasy.Install Test-KohaWslReady { $true }
        Mock -ModuleName KohaEasy.Install Set-KohaDistroConfig { [void]$script:calls.Add('systemd ' + $User); $true }
        $acc = [pscustomobject]@{ User = 'maria'; Password = 'S3gredo!long' }
        Install-Koha -Facts $good -NonInteractive -Account $acc | Should -Be 0
        $script:calls[0..2] | Should -Be @('distro', 'user maria', 'systemd maria')
        (Get-KohaState).linuxUser | Should -Be 'maria'
        [System.IO.File]::ReadAllText((Get-KohaPath State)) | Should -Not -Match 'S3gredo'
        Get-ChildItem (Get-KohaPath Logs) -ErrorAction SilentlyContinue | ForEach-Object { Get-Content -Raw $_.FullName | Should -Not -Match 'S3gredo' }
    }

    It 'asks for the Debian user before installing anything, and again after a restart' {
        Mock -ModuleName KohaEasy.Install Test-KohaWslReady { $false }
        Mock -ModuleName KohaEasy.Install Read-KohaLinuxAccount { [void]$script:calls.Add('ask'); [pscustomobject]@{ User = 'maria'; Password = 'x' * 8 } }
        Mock -ModuleName KohaEasy.Install Read-Host { '' }
        Install-Koha -Facts $good | Should -Be 3
        $script:calls | Should -Be @('ask', 'wsl platform', 'resume')
    }

    It 'adds the Debian user to an install that had none, with the restart that applies it' {
        Mock -ModuleName KohaEasy.Install Test-KohaWslReady { $true }
        Set-KohaState @{ phase = 'windows' } | Out-Null
        Mock -ModuleName KohaEasy.Install Write-KohaWslConf { [void]$script:calls.Add('wsl.conf ' + $User) }
        Mock -ModuleName KohaEasy.Install Restart-KohaDistro { [void]$script:calls.Add('restart'); $true }
        Install-Koha -Facts $good -NonInteractive -Account ([pscustomobject]@{ User = 'maria'; Password = 'x' * 8 }) | Should -Be 0
        $script:calls[0..3] | Should -Be @('copy panel', 'user maria', 'wsl.conf maria', 'restart')
        (Get-KohaState).linuxUser | Should -Be 'maria'
    }

    It 'asks again for a Debian user that went missing, creates it and restarts Debian' {
        Mock -ModuleName KohaEasy.Install Test-KohaWslReady { $true }
        Mock -ModuleName KohaEasy.Install Test-KohaLinuxUserExists { $false }
        Mock -ModuleName KohaEasy.Install Read-KohaLinuxAccount { [void]$script:calls.Add('ask ' + $Default); [pscustomobject]@{ User = 'paulo'; Password = 'x' * 8 } }
        Mock -ModuleName KohaEasy.Install Write-KohaWslConf { [void]$script:calls.Add('wsl.conf ' + $User) }
        Mock -ModuleName KohaEasy.Install Restart-KohaDistro { [void]$script:calls.Add('restart'); $true }
        Mock -ModuleName KohaEasy.Install Start-Process { }
        Set-KohaState @{ phase = 'done'; linuxUser = 'paulo'; lanAccess = $true } | Out-Null
        Install-Koha -Facts $good | Should -Be 0
        $script:calls[0..4] | Should -Be @('copy panel', 'ask paulo', 'user paulo', 'wsl.conf paulo', 'restart')
        $script:calls | Should -Contain 'shortcuts'
        $script:calls | Should -Contain 'tray'
    }

    It 'never asks when running unattended, even with the Debian user missing' {
        Mock -ModuleName KohaEasy.Install Test-KohaWslReady { $true }
        Mock -ModuleName KohaEasy.Install Test-KohaLinuxUserExists { $false }
        Set-KohaState @{ phase = 'done'; linuxUser = 'paulo'; lanAccess = $true } | Out-Null
        Install-Koha -Facts $good -NonInteractive | Should -Be 0
        $script:calls | Should -Not -Contain 'user paulo'
    }

    It 'keeps going with the other Windows steps when one fails' {
        Mock -ModuleName KohaEasy.Install Test-KohaWslReady { $true }
        Mock -ModuleName KohaEasy.Install Register-KohaTasks { throw 'Access is denied' }
        Set-KohaState @{ phase = 'windows'; linuxUser = 'maria' } | Out-Null
        Install-Koha -Facts $good -NonInteractive | Should -Be 0
        $script:calls | Should -Contain 'shortcuts'
        $script:calls | Should -Contain 'tray'
        Should -Invoke -ModuleName KohaEasy.Install Write-Host -ParameterFilter { "$Object" -like '*Access is denied*' }
    }

    It 'opens Koha to the library network in the Windows step' {
        Mock -ModuleName KohaEasy.Install Test-KohaWslReady { $true }
        Set-KohaState @{ phase = 'windows' } | Out-Null
        Mock -ModuleName KohaEasy.Install Read-Host { 'y' }
        Mock -ModuleName KohaEasy.Install Start-Process { }
        Set-KohaState @{ linuxUser = 'maria' } | Out-Null
        Install-Koha -Facts $good | Should -Be 0
        $script:calls | Should -Be @('copy panel', 'launcher', 'tasks logon', 'tray at sign-in', 'shortcuts', 'icons', 'tray', 'lan', 'start', 'lan check')
        (Get-KohaState).lanAccess | Should -BeTrue
        (Get-KohaState).lanSetup | Should -Be 2
    }

    It 'offers the library network again to a finished install that does not have it' {
        Mock -ModuleName KohaEasy.Install Test-KohaWslReady { $true }
        Set-KohaState @{ phase = 'done'; linuxUser = 'maria' } | Out-Null
        Install-Koha -Facts $good | Should -Be 0
        $script:calls | Should -Be @('copy panel', 'launcher', 'tasks logon', 'tray at sign-in', 'shortcuts', 'icons', 'tray', 'start', 'lan', 'lan check')
        (Get-KohaState).lanAccess | Should -BeTrue
        $script:calls.Clear()
        Install-Koha -Facts $good | Should -Be 0
        $script:calls | Should -Be @('copy panel', 'launcher', 'tasks logon', 'tray at sign-in', 'shortcuts', 'icons', 'tray', 'start', 'lan check')
    }

    It 'updates the library network rules an older version set up, once' {
        Mock -ModuleName KohaEasy.Install Test-KohaWslReady { $true }
        Set-KohaState @{ phase = 'done'; linuxUser = 'maria'; lanAccess = $true; lanSetup = 1 } | Out-Null
        Mock -ModuleName KohaEasy.Install Enable-KohaLanAccess { [void]$script:calls.Add('lan'); $false }
        Install-Koha -Facts $good | Should -Be 0
        $script:calls | Should -Contain 'lan'
        Should -Invoke -ModuleName KohaEasy.Install Write-Host -ParameterFilter { "$Object" -like '*were not updated*' }
        (Get-KohaState).lanAccess | Should -BeTrue
        (Get-KohaState).lanSetup | Should -Be 1
        $script:calls | Should -Contain 'lan check'
        Mock -ModuleName KohaEasy.Install Enable-KohaLanAccess { [void]$script:calls.Add('lan'); $true }
        $script:calls.Clear()
        Install-Koha -Facts $good | Should -Be 0
        (Get-KohaState).lanSetup | Should -Be 2
        $script:calls.Clear()
        Install-Koha -Facts $good | Should -Be 0
        $script:calls | Should -Not -Contain 'lan'
    }

    It 'sets the library network up again when a firewall rule or its task went missing' {
        Mock -ModuleName KohaEasy.Install Test-KohaWslReady { $true }
        Set-KohaState @{ phase = 'done'; linuxUser = 'maria'; lanAccess = $true; lanSetup = 2 } | Out-Null
        Mock -ModuleName KohaEasy.Install Get-KohaLanSetupNeed { 'repair' }
        Install-Koha -Facts $good | Should -Be 0
        $script:calls | Should -Contain 'lan'
        Should -Invoke -ModuleName KohaEasy.Install Write-Host -ParameterFilter { "$Object" -like '*Updating the library network settings*' }
        Mock -ModuleName KohaEasy.Install Get-KohaLanSetupNeed { '' }
        $script:calls.Clear()
        Install-Koha -Facts $good | Should -Be 0
        $script:calls | Should -Not -Contain 'lan'
    }

    It 'restarts Koha cleanly once when the keep-alive task ran with an older action, or WSL got new settings' {
        Mock -ModuleName KohaEasy.Install Test-KohaWslReady { $true }
        Set-KohaState @{ phase = 'done'; linuxUser = 'maria'; lanAccess = $true; lanSetup = 2 } | Out-Null
        Mock -ModuleName KohaEasy.Install Test-KohaKeepAliveOutdated { $true }
        Install-Koha -Facts $good | Should -Be 0
        $script:calls | Should -Be @('copy panel', 'launcher', 'tasks logon', 'tray at sign-in', 'shortcuts', 'icons', 'stop koha', 'tray', 'start', 'lan check')
        Mock -ModuleName KohaEasy.Install Update-KohaWslConfig { $true }
        $script:calls.Clear()
        Install-Koha -Facts $good | Should -Be 0
        $script:calls | Should -Contain 'stop koha, shutdown'
        $script:calls | Should -Not -Contain 'stop koha'
        $script:calls.IndexOf('stop koha, shutdown') | Should -BeLessThan $script:calls.IndexOf('start')
    }

    It 'renames the KohaEasy distro of an older install and refreshes its shortcuts' {
        Mock -ModuleName KohaEasy.Install Test-KohaWslReady { $true }
        Mock -ModuleName KohaEasy.Install Rename-KohaLegacyDistro { 'renamed' }
        Set-KohaState @{ phase = 'done'; desired = 'running' } | Out-Null
        Install-Koha -Facts $good -NonInteractive | Should -Be 0
        $script:calls | Should -Be @('copy panel', 'shortcuts', 'icons', 'start')
    }

    It 'sends a Koha install that stopped half-way back to the control panel' {
        Mock -ModuleName KohaEasy.Install Test-KohaWslReady { $true }
        $script:installed = $false
        Mock -ModuleName KohaEasy.Install Test-KohaInstalledInDistro { $script:installed }
        Mock -ModuleName KohaEasy.Install Invoke-KohaPanel { [void]$script:calls.Add('panel'); $script:installed = $true; 0 }
        Mock -ModuleName KohaEasy.Install Read-Host { 'y' }
        Mock -ModuleName KohaEasy.Install Start-Process { }
        Set-KohaState @{ phase = 'done'; linuxUser = 'maria'; lanAccess = $true } | Out-Null
        Install-Koha -Facts $good | Should -Be 0
        $script:calls[0..2] | Should -Be @('copy panel', 'copy panel', 'panel')
        (Get-KohaState).phase | Should -Be 'done'
    }

    It 'shows what Debian reports, saves the diagnostics and offers the panel when Koha does not start' {
        Mock -ModuleName KohaEasy.Install Test-KohaWslReady { $true }
        Mock -ModuleName KohaEasy.Install Start-Koha { [void]$script:calls.Add('start'); 'timeout' }
        Mock -ModuleName KohaEasy.Install Get-KohaQuickCheck { @('apache2: failed', 'koha-common package: iF 24.11') }
        Mock -ModuleName KohaEasy.Install Export-KohaDiagnostics { [void]$script:calls.Add('diagnostics'); 'C:\Users\x\Desktop\d.zip' }
        Mock -ModuleName KohaEasy.Install Invoke-KohaPanel { [void]$script:calls.Add('panel'); 0 }
        Mock -ModuleName KohaEasy.Install Read-Host { 'y' }
        Set-KohaState @{ phase = 'done'; linuxUser = 'maria'; lanAccess = $true } | Out-Null
        Install-Koha -Facts $good | Should -Be 0
        $script:calls | Should -Be @('copy panel', 'launcher', 'tasks logon', 'tray at sign-in', 'shortcuts', 'icons', 'tray', 'start', 'diagnostics', 'panel', 'start', 'lan')
        Should -Invoke -ModuleName KohaEasy.Install Write-Host -ParameterFilter { "$Object" -like '*koha-common package: iF*' }
    }

    It 'does nothing again once done' {
        Mock -ModuleName KohaEasy.Install Test-KohaWslReady { $true }
        Set-KohaState @{ phase = 'done' } | Out-Null
        Install-Koha -Facts $good -NonInteractive | Should -Be 0
        $script:calls | Should -Be @('copy panel')
    }

    It 'gives the Koha panel the console itself, never a captured pipe' {
        Mock -ModuleName KohaEasy.Install Start-Process { [pscustomobject]@{ ExitCode = 0 } }
        Invoke-KohaPanel | Should -Be 0
        Should -Invoke -ModuleName KohaEasy.Install Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'wsl.exe' -and $NoNewWindow -and $Wait -and $ArgumentList -like '-d koha -u root --cd /root/koha-easy-installer -- /usr/local/bin/koha-window bash ./installer'
        }
    }

    It 'installs Debian again when it went missing after its phase, then carries on' {
        Mock -ModuleName KohaEasy.Install Test-KohaWslReady { $true }
        Mock -ModuleName KohaEasy.Install Restore-KohaDistro { 'missing' }
        Set-KohaState @{ phase = 'koha' } | Out-Null
        Install-Koha -Facts $good -NonInteractive | Should -Be 0
        $script:calls[0..2] | Should -Be @('distro', 'systemd', 'copy panel')
    }

    It 'goes straight on when Debian was registered again from its disk' {
        Mock -ModuleName KohaEasy.Install Test-KohaWslReady { $true }
        Mock -ModuleName KohaEasy.Install Restore-KohaDistro { 'reattached' }
        Set-KohaState @{ phase = 'koha' } | Out-Null
        Install-Koha -Facts $good -NonInteractive | Should -Be 0
        $script:calls[0] | Should -Be 'copy panel'
    }

    It 'stops when systemd does not start in WSL' {
        Mock -ModuleName KohaEasy.Install Test-KohaWslReady { $true }
        Mock -ModuleName KohaEasy.Install Set-KohaDistroConfig { $false }
        Install-Koha -Facts $good -NonInteractive | Should -Be 1
        (Get-KohaState).phase | Should -Be 'systemd'
    }
}

Describe 'Install messages' {
    BeforeEach {
        Remove-Item -LiteralPath (Get-KohaPath Root) -Recurse -Force -ErrorAction SilentlyContinue
        $script:calls = New-Object System.Collections.ArrayList
        Mock -ModuleName KohaEasy.Install Write-Host { }
    }

    It 'prints the library network test: what works, what to fix, and the addresses' {
        Mock -ModuleName KohaEasy.Install Test-KohaLanAccess { [pscustomobject]@{ Ok = $false; Lines = @(
                    [pscustomobject]@{ Kind = 'warn'; Text = 'test failed' }
                    [pscustomobject]@{ Kind = 'info'; Text = 'staff interface http://192.168.0.9:8080/' }) } }
        Show-KohaLanCheck
        Should -Invoke -ModuleName KohaEasy.Install Write-Host -ParameterFilter { "$Object" -like '*test failed*' }
        Should -Invoke -ModuleName KohaEasy.Install Write-Host -ParameterFilter { "$Object" -like '*http://192.168.0.9:8080/*' }
    }

    It 'tells the librarian whether KohaEasy.exe is used, and nothing when it did not change' {
        Mock -ModuleName KohaEasy.Install Install-KohaLauncher { 'built' }
        Install-KohaLauncherStep | Should -BeNullOrEmpty
        Should -Invoke -ModuleName KohaEasy.Install Write-Host -Times 1 -Exactly -ParameterFilter { "$Object" -like '*KohaEasy.exe is ready*' }
        Mock -ModuleName KohaEasy.Install Install-KohaLauncher { 'failed' }
        Install-KohaLauncherStep
        Should -Invoke -ModuleName KohaEasy.Install Write-Host -Times 1 -Exactly -ParameterFilter { "$Object" -like '*hidden console instead*' }
        Mock -ModuleName KohaEasy.Install Install-KohaLauncher { 'current' }
        Install-KohaLauncherStep
        Should -Invoke -ModuleName KohaEasy.Install Write-Host -Times 2 -Exactly
    }

    It 'goes back to conhost for good when the tray does not start through KohaEasy.exe' {
        Set-KohaState @{ launcher = 'ok'; hiddenLaunch = 'conhost' } | Out-Null
        $script:running = [System.Collections.Queue]::new(@($false, $true, $true))
        Mock -ModuleName KohaEasy.Install Restart-KohaTray { [void]$script:calls.Add('tray restart') }
        Mock -ModuleName KohaEasy.Install Start-KohaTray { [void]$script:calls.Add('tray ' + (Get-KohaState).launcher) }
        Mock -ModuleName KohaEasy.Install Start-Sleep { }
        Mock -ModuleName KohaEasy.Install Test-KohaTrayRunning { $script:running.Dequeue() }
        Mock -ModuleName KohaEasy.Install Set-KohaTrayAtSignIn { [void]$script:calls.Add('tray at sign-in') }
        Mock -ModuleName KohaEasy.Install New-KohaShortcuts { [void]$script:calls.Add('shortcuts') }
        Mock -ModuleName KohaEasy.Install Register-KohaTasks { [void]$script:calls.Add('tasks') }
        Start-KohaTrayChecked
        $script:calls | Should -Be @('tray restart', 'tray at sign-in', 'shortcuts', 'tasks', 'tray refused')
        (Get-KohaState).launcher | Should -Be 'refused'
        (Get-KohaState).hiddenLaunch | Should -Be 'conhost'
        Should -Invoke -ModuleName KohaEasy.Install Write-Host -ParameterFilter { "$Object" -like '*notification area*' }
    }

    It 'goes to a hidden PowerShell for the tray, the shortcuts and the tasks when conhost does not start the tray' {
        Set-KohaState @{ launcher = 'failed'; hiddenLaunch = 'conhost' } | Out-Null
        $script:running = [System.Collections.Queue]::new(@($false, $false, $true, $true))
        Mock -ModuleName KohaEasy.Install Restart-KohaTray { [void]$script:calls.Add('tray restart') }
        Mock -ModuleName KohaEasy.Install Start-KohaTray { [void]$script:calls.Add('tray ' + (Get-KohaState).hiddenLaunch) }
        Mock -ModuleName KohaEasy.Install Start-Sleep { }
        Mock -ModuleName KohaEasy.Install Test-KohaTrayRunning { $script:running.Dequeue() }
        Mock -ModuleName KohaEasy.Install Set-KohaTrayAtSignIn { [void]$script:calls.Add('tray at sign-in') }
        Mock -ModuleName KohaEasy.Install New-KohaShortcuts { [void]$script:calls.Add('shortcuts') }
        Mock -ModuleName KohaEasy.Install Register-KohaTasks { [void]$script:calls.Add('tasks') }
        Start-KohaTrayChecked
        $script:calls | Should -Be @('tray restart', 'tray at sign-in', 'shortcuts', 'tasks', 'tray powershell')
        (Get-KohaState).hiddenLaunch | Should -Be 'powershell'
        Set-KohaState @{ launcher = ''; hiddenLaunch = 'conhost' } | Out-Null
    }
}

Describe 'Debian gone missing' {
    BeforeEach {
        Remove-Item -LiteralPath (Get-KohaPath Root) -Recurse -Force -ErrorAction SilentlyContinue
        $script:wsl = New-Object System.Collections.ArrayList
        Mock -ModuleName KohaEasy.Install Invoke-KohaLinux { [pscustomobject]@{ ExitCode = 1; Output = 'Wsl/Service/WSL_E_DISTRO_NOT_FOUND' } }
    }

    It 'does nothing while WSL still knows it' {
        Mock -ModuleName KohaEasy.Install Test-KohaDistroInstalled { $true }
        Mock -ModuleName KohaEasy.Install Invoke-KohaWsl { throw 'must not touch WSL' }
        Restore-KohaDistro | Should -Be 'ok'
    }

    It 'trusts a direct check over the list' {
        Mock -ModuleName KohaEasy.Install Test-KohaDistroInstalled { $false }
        Mock -ModuleName KohaEasy.Install Invoke-KohaLinux { [pscustomobject]@{ ExitCode = 0; Output = '' } }
        Mock -ModuleName KohaEasy.Install Invoke-KohaWsl { throw 'must not touch WSL' }
        Restore-KohaDistro | Should -Be 'ok'
    }

    It 'registers its disk again in place when the disk is still there' {
        $script:installed = $false
        Mock -ModuleName KohaEasy.Install Test-KohaDistroInstalled { $script:installed }
        Mock -ModuleName KohaEasy.Install Invoke-KohaWsl { [void]$script:wsl.Add($Arguments -join ' '); if ($Arguments[0] -eq '--import-in-place') { $script:installed = $true }; [pscustomobject]@{ ExitCode = 0; Output = '' } }
        New-Item -ItemType Directory -Path (Get-KohaPath Wsl) -Force | Out-Null
        $vhd = [System.IO.Path]::Combine((Get-KohaPath Wsl), 'ext4.vhdx')
        Set-Content -LiteralPath $vhd -Value 'disk'
        Restore-KohaDistro | Should -Be 'reattached'
        $script:wsl | Should -Contain ('--import-in-place koha ' + $vhd)
    }

    It 'reports missing when there is no disk to bring back' {
        Mock -ModuleName KohaEasy.Install Test-KohaDistroInstalled { $false }
        Mock -ModuleName KohaEasy.Install Invoke-KohaWsl { [pscustomobject]@{ ExitCode = 0; Output = '' } }
        Restore-KohaDistro | Should -Be 'missing'
    }

    It 'sets an old disk aside instead of deleting it before importing a new Debian' {
        Mock -ModuleName KohaEasy.Install Test-KohaDistroInstalled { $false }
        Mock -ModuleName KohaEasy.Install Invoke-KohaWsl { [pscustomobject]@{ ExitCode = [int]($Arguments[0] -eq '--install'); Output = '' } }
        $script:img = Join-Path $TestDrive 'img'
        Set-Content -LiteralPath $script:img -Value 'debian' -NoNewline
        $sha = (Get-FileHash -LiteralPath $script:img -Algorithm SHA256).Hash
        Mock -ModuleName KohaEasy.Install Get-KohaDistributionManifest { ('{"ModernDistributions":{"Debian":[{"Name":"Debian","Amd64Url":{"Url":"https://x.test/d.wsl","Sha256":"' + $sha + '"}}]}}') | ConvertFrom-Json }
        Mock -ModuleName KohaEasy.Install Save-KohaDownload { Copy-Item -LiteralPath $script:img -Destination $Path }
        New-Item -ItemType Directory -Path (Get-KohaPath Wsl) -Force | Out-Null
        Set-Content -LiteralPath ([System.IO.Path]::Combine((Get-KohaPath Wsl), 'ext4.vhdx')) -Value 'library data'
        New-KohaDistro | Should -Be 'imported'
        @(Get-ChildItem -LiteralPath (Get-KohaPath Wsl) -Filter 'ext4.vhdx.*.bak').Count | Should -Be 1
    }
}

Describe 'Panel copy into Debian' {
    It 'copies the installer and its dictionaries and checks the SHA-256 (script run by a real sh)' {
        $src = Join-Path $TestDrive 'bin'
        $dst = Join-Path $TestDrive 'distro/root/koha-easy-installer'
        New-Item -ItemType Directory -Path (Join-Path $src 'lang') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $src 'installer') -Value 'echo panel' -NoNewline
        Set-Content -LiteralPath (Join-Path $src 'lang/pt.cache') -Value 'x' -NoNewline
        $sha = (Get-FileHash -LiteralPath (Join-Path $src 'installer') -Algorithm SHA256).Hash.ToLowerInvariant()
        Set-Content -LiteralPath (Join-Path $src 'installer.sha256') -Value "$sha  installer"
        Mock -ModuleName KohaEasy.Install Get-KohaPath { $src } -ParameterFilter { $Name -eq 'Bin' }
        Mock -ModuleName KohaEasy.Install Invoke-KohaLinuxScript {
            $f = Join-Path $TestDrive 'script.sh'
            [System.IO.File]::WriteAllText($f, $Script)
            $out = & sh $f 2>&1
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($out -join "`n") }
        }
        $launcher = Join-Path $TestDrive 'koha-panel'
        Mock -ModuleName KohaEasy.Install Install-KohaWindowScript { $true }
        InModuleScope KohaEasy.Install -Parameters @{ Dst = $dst; L = $launcher } { param($Dst, $L) $script:DistroDir = $Dst; $script:LauncherPath = $L }
        try {
            Copy-KohaPanelIntoDistro
            Test-Path -LiteralPath (Join-Path $dst 'installer') | Should -BeTrue
            (& sh $launcher --status-json 2>&1) | Should -Be 'panel'
            [System.IO.File]::ReadAllText($launcher) | Should -Match ([regex]::Escape("cd '$dst' && exec bash ./installer"))
            Test-Path -LiteralPath (Join-Path $dst 'lang/pt.cache') | Should -BeTrue
            Should -Invoke -ModuleName KohaEasy.Install Install-KohaWindowScript -Times 1 -Exactly

            Set-Content -LiteralPath (Join-Path $src 'installer') -Value 'tampered' -NoNewline
            { Copy-KohaPanelIntoDistro } | Should -Throw '*copy:*'
        } finally {
            InModuleScope KohaEasy.Install { $script:DistroDir = '/root/koha-easy-installer'; $script:LauncherPath = '/usr/local/bin/koha-panel' }
        }
    }
}

Describe 'Install flow output' {
    It 'returns one exit code even when a step writes values (the UAC exit codes of wsl --install)' {
        Remove-Item -LiteralPath (Get-KohaPath Root) -Recurse -Force -ErrorAction SilentlyContinue
        Mock -ModuleName KohaEasy.Install Write-Host { }
        Mock -ModuleName KohaEasy.Install Register-KohaResume { }
        Mock -ModuleName KohaEasy.Install Start-KohaElevated { 0 }
        Mock -ModuleName KohaEasy.Install Test-KohaWslReady { $false }
        $out = @(Install-Koha -Facts $good -NonInteractive)
        $out.Count | Should -Be 1
        $out[0] | Should -Be 3
    }
}

Describe 'Bootstrapper' {
    It 'install.ps1 is plain ASCII without BOM, parses, and uses no PowerShell 7 operator' {
        $file = Join-Path $repo 'windows/install.ps1'
        $bytes = [System.IO.File]::ReadAllBytes($file)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
        $tokens = $null; $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors) | Out-Null
        @($errors).Count | Should -Be 0
        $ps7 = @('AndAnd', 'OrOr', 'QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket', 'QuestionMark')
        @($tokens | Where-Object { $ps7 -contains [string]$_.Kind }) | Should -BeNullOrEmpty
    }

    It 'install.ps1 hands the console to the install instead of capturing its output' {
        $text = [System.IO.File]::ReadAllText((Join-Path $repo 'windows/install.ps1'))
        $text | Should -Match 'Start-Process -FilePath \$ps -ArgumentList \$arg -NoNewWindow -Wait -PassThru'
        $text | Should -Not -Match '(?m)^\s*&\s*\$ps\b'
    }

    It 'is the only way to install: no .cmd, and both READMEs show the same one-liner' {
        @(Get-ChildItem -LiteralPath $repo -Recurse -Filter '*.cmd' -File).Count | Should -Be 0
        $url = 'https://raw.githubusercontent.com/PauloFBaldiFH/Koha-Easy-Installer/main/windows/install.ps1'
        Get-Content -Raw (Join-Path $repo 'README.md') | Should -Match ([regex]::Escape("irm $url | iex"))
        Get-Content -Raw (Join-Path $repo 'README.pt-BR.md') | Should -Match ([regex]::Escape("irm $url | iex"))
    }
}

Describe 'Debian user' {
    It 'makes a valid Debian name from the Windows one' {
        ConvertTo-KohaLinuxUserName 'João.Silva' | Should -Be 'joaosilva'
        ConvertTo-KohaLinuxUserName '1Biblioteca Municipal' | Should -Be 'bibliotecamunicipal'
        ConvertTo-KohaLinuxUserName 'Administrator' | Should -Be 'administrator'
        ConvertTo-KohaLinuxUserName 'root' | Should -Be 'librarian'
        ConvertTo-KohaLinuxUserName '' | Should -Be 'librarian'
    }

    It 'refuses names Debian would refuse or already uses, and short passwords' {
        foreach ($bad in 'Maria', '1maria', 'ma ria', 'maria;rm', ('a' * 33), 'root', 'koha', 'www-data', '') {
            Test-KohaLinuxUserName $bad | Should -Not -BeNullOrEmpty -Because $bad
        }
        Test-KohaLinuxUserName 'maria_s-2' | Should -BeNullOrEmpty
        Test-KohaLinuxPassword 'short' | Should -Not -BeNullOrEmpty
        Test-KohaLinuxPassword "long enough`n" | Should -Not -BeNullOrEmpty
        Test-KohaLinuxPassword 'çãõ: long enough' | Should -BeNullOrEmpty
    }

    It 'asks again until the name is valid and both passwords match' {
        $script:answers = [System.Collections.Queue]::new(@('Maria', 'maria'))
        $script:secrets = [System.Collections.Queue]::new(@('short', 'S3gredo!long', 'other-one', 'S3gredo!long', 'S3gredo!long'))
        Mock -ModuleName KohaEasy.Install Write-Host { }
        Mock -ModuleName KohaEasy.Install Read-Host -ParameterFilter { $AsSecureString } { ConvertTo-SecureString $script:secrets.Dequeue() -AsPlainText -Force }
        Mock -ModuleName KohaEasy.Install Read-Host -ParameterFilter { -not $AsSecureString } { $script:answers.Dequeue() }
        $a = Read-KohaLinuxAccount -Default 'joao'
        $a.User | Should -Be 'maria'
        $a.Password | Should -Be 'S3gredo!long'
        $script:secrets.Count | Should -Be 0
    }

    It 'sends the password on stdin in base64, never on the script or the command line' {
        $script:seen = $null
        Mock -ModuleName KohaEasy.Install Invoke-KohaLinuxScript { $script:seen = @{ Script = $Script; Input = $InputText }; [pscustomobject]@{ ExitCode = 0; Output = '' } }
        Mock -ModuleName KohaEasy.Install Get-KohaLxssEntry { $null }
        New-KohaLinuxUser -User 'maria' -Password 'Pão: 12345678'
        $script:seen.Script | Should -Not -Match '12345678'
        $script:seen.Script | Should -Match "u='maria'"
        $script:seen.Script | Should -Match 'useradd -m -s /bin/bash'
        $script:seen.Script | Should -Match 'usermod -aG sudo'
        $script:seen.Script | Should -Match 'chpasswd'
        [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($script:seen.Input)) | Should -Be 'Pão: 12345678'
        { New-KohaLinuxUser -User 'bad name' -Password '12345678' } | Should -Throw
    }

    It 'the user script creates the user and sets the password (run by a real sh with stand-ins)' {
        $bin = Join-Path $TestDrive 'fakebin'
        New-Item -ItemType Directory -Path $bin -Force | Out-Null
        $log = Join-Path $TestDrive 'user.log'
        foreach ($c in 'useradd', 'usermod', 'chpasswd', 'sudo') {
            $f = Join-Path $bin $c
            [System.IO.File]::WriteAllText($f, "#!/bin/sh`necho `"$c `$* `$(cat 2>/dev/null)`" >> '$log'`n")
            & chmod +x $f
        }
        [System.IO.File]::WriteAllText((Join-Path $bin 'id'), "#!/bin/sh`nexit 1`n"); & chmod +x (Join-Path $bin 'id')
        Mock -ModuleName KohaEasy.Install Get-KohaLxssEntry { $null }
        Mock -ModuleName KohaEasy.Install Invoke-KohaLinuxScript {
            $f = Join-Path $TestDrive 'user.sh'
            [System.IO.File]::WriteAllText($f, $Script)
            $out = ($InputText + "`r`n") | & /usr/bin/env "PATH=$(Join-Path $TestDrive 'fakebin'):/usr/bin:/bin" sh $f 2>&1
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($out -join "`n") }
        }
        New-KohaLinuxUser -User 'maria' -Password 'Pão: 12345678'
        $l = Get-Content -Raw $log
        $l | Should -Match 'useradd -m -s /bin/bash maria'
        $l | Should -Match 'usermod -aG sudo maria'
        $l | Should -Match 'chpasswd  maria:Pão: 12345678'
    }
}

Describe 'Restarting Debian for systemd' {
    BeforeEach {
        $script:log = New-Object System.Collections.ArrayList
        $script:running = 3
        Mock -ModuleName KohaEasy.Install Start-Sleep { [void]$script:log.Add('sleep ' + $Seconds) }
        Mock -ModuleName KohaEasy.Install Invoke-KohaWsl { [void]$script:log.Add('wsl ' + ($Arguments -join ' ')); [pscustomobject]@{ ExitCode = 0; Output = '' } }
        Mock -ModuleName KohaEasy.Install Stop-KohaDebianGracefully { [void]$script:log.Add('stop koha, then ' + $(if ($Shutdown) { 'shutdown' } else { 'terminate' })); 'clean' }
        Mock -ModuleName KohaEasy.Install Test-KohaDistroRunning { $script:running--; [void]$script:log.Add('running?'); ($script:running -gt 0) }
        Mock -ModuleName KohaEasy.Install Test-KohaSystemd { [void]$script:log.Add('systemd?'); $true }
    }

    It 'stops Koha cleanly and terminates, waits until WSL lists it as stopped, waits 8 s, then checks systemd' {
        Restart-KohaDistro | Should -BeTrue
        $script:log | Should -Be @('stop koha, then terminate', 'running?', 'sleep 1', 'running?', 'sleep 1', 'running?', 'sleep 8', 'systemd?')
    }

    It 'shuts WSL down when .wslconfig changed' {
        Restart-KohaDistro -Shutdown | Should -BeTrue
        $script:log[0] | Should -Be 'stop koha, then shutdown'
    }

    It 'rewrites wsl.conf keeping its other sections, and tries once more with WSL shut down' {
        $script:sys = 0
        Mock -ModuleName KohaEasy.Install Test-KohaSystemd { $script:sys++; ($script:sys -gt 1) }
        Mock -ModuleName KohaEasy.Install Test-KohaDistroRunning { $false }
        Mock -ModuleName KohaEasy.Install Update-KohaWslConfig { $false }
        Mock -ModuleName KohaEasy.Install Write-Host { }
        Mock -ModuleName KohaEasy.Install Invoke-KohaLinux { [pscustomobject]@{ ExitCode = 0; Output = "[time]`nuseWindowsTimezone=false" } }
        Mock -ModuleName KohaEasy.Install Invoke-KohaLinuxScript { $script:conf = $InputText; [pscustomobject]@{ ExitCode = 0; Output = '' } }
        Set-KohaDistroConfig -User 'maria' | Should -BeTrue
        $script:conf | Should -Match 'useWindowsTimezone=false'
        $script:conf | Should -Match 'default=maria'
        Should -Invoke -ModuleName KohaEasy.Install Stop-KohaDebianGracefully -Times 1 -Exactly -ParameterFilter { -not $Shutdown }
        Should -Invoke -ModuleName KohaEasy.Install Stop-KohaDebianGracefully -Times 1 -Exactly -ParameterFilter { $Shutdown }
    }
}

Describe 'systemd probe' {
    It 'the probe accepts running and degraded, and refuses a PID 1 that is not systemd' {
        foreach ($case in @(@{ Code = 0; Out = 'pid1=systemd state=running'; Ok = $true }, @{ Code = 4; Out = 'pid1=systemd state=starting'; Ok = $true },
                @{ Code = 3; Out = 'pid1=init'; Ok = $false })) {
            $script:case = $case
            Mock -ModuleName KohaEasy.Install Invoke-KohaLinuxScript { [pscustomobject]@{ ExitCode = $script:case.Code; Output = $script:case.Out } }
            InModuleScope KohaEasy.Install { Test-KohaSystemd } | Should -Be $case.Ok
        }
        InModuleScope KohaEasy.Install { $script:SystemdProbe } | Should -Match 'systemctl is-system-running --wait'
    }
}

Describe 'Old distro name' {
    BeforeEach {
        $script:log = New-Object System.Collections.ArrayList
        Mock -ModuleName KohaEasy.Install Invoke-KohaWsl { [void]$script:log.Add('wsl ' + ($Arguments -join ' ')); [pscustomobject]@{ ExitCode = 0; Output = '' } }
        Mock -ModuleName KohaEasy.Install Stop-KohaKeepAlive { }
        Mock -ModuleName KohaEasy.Install Stop-KohaDebianGracefully { [void]$script:log.Add(('stop {0}, then {1}' -f $Distro, $(if ($Shutdown) { 'shutdown' } else { 'terminate' }))); 'clean' }
        Mock -ModuleName KohaEasy.Install Get-KohaLxssEntry { [pscustomobject]@{ PSPath = 'HKCU:\x\{1}'; Name = 'KohaEasy' } }
        Mock -ModuleName KohaEasy.Install Set-ItemProperty { [void]$script:log.Add(('set {0}={1}' -f $Name, $Value)) }
    }

    It 'renames KohaEasy to koha in WSL''s registration, with WSL stopped' {
        $script:lists = [System.Collections.Queue]::new(@(, @('Ubuntu', 'KohaEasy')))
        $script:lists.Enqueue(@('Ubuntu', 'koha'))
        Mock -ModuleName KohaEasy.Install Get-KohaInstalledDistros { $script:lists.Dequeue() }
        Rename-KohaLegacyDistro | Should -Be 'renamed'
        $script:log | Should -Be @('stop KohaEasy, then shutdown', 'set DistributionName=koha')
    }

    It 'asks for a Windows restart when WSL still lists the old name' {
        Mock -ModuleName KohaEasy.Install Get-KohaInstalledDistros { @('Ubuntu', 'KohaEasy') }
        Rename-KohaLegacyDistro | Should -Be 'restart'
        Mock -ModuleName KohaEasy.Install Rename-KohaLegacyDistro { 'restart' }
        Mock -ModuleName KohaEasy.Install Register-KohaResume { [void]$script:log.Add('resume') }
        Mock -ModuleName KohaEasy.Install Write-Host { }
        Set-KohaState @{ phase = 'koha'; linuxUser = 'maria' } | Out-Null
        Install-Koha -Facts $good -NonInteractive | Should -Be 3
        $script:log | Should -Contain 'resume'
        (Get-KohaState).phase | Should -Be 'koha'
    }

    It 'leaves everything alone when there is nothing to rename or both names exist' {
        Mock -ModuleName KohaEasy.Install Get-KohaInstalledDistros { @('koha') }
        Rename-KohaLegacyDistro | Should -Be 'none'
        Mock -ModuleName KohaEasy.Install Get-KohaInstalledDistros { @('koha', 'KohaEasy') }
        Rename-KohaLegacyDistro | Should -Be 'kept'
        $script:log.Count | Should -Be 0
    }
}

Describe 'Panel window' {
    It 'passes the symbol mode into Linux through WSLENV, once' {
        Add-KohaWslEnv -Current '' -Name 'KEI_PLAIN_GLYPHS' | Should -Be 'KEI_PLAIN_GLYPHS'
        Add-KohaWslEnv -Current 'WT_SESSION:WT_PROFILE_ID' -Name 'KEI_PLAIN_GLYPHS' | Should -Be 'WT_SESSION:WT_PROFILE_ID:KEI_PLAIN_GLYPHS'
        Add-KohaWslEnv -Current 'KEI_PLAIN_GLYPHS/u' -Name 'KEI_PLAIN_GLYPHS' | Should -Be 'KEI_PLAIN_GLYPHS/u'
    }

    It 'asks for plain symbols in the classic console and emoji in Windows Terminal' {
        $saved = $env:WT_SESSION
        try {
            $env:WT_SESSION = ''
            Get-KohaGlyphMode | Should -Be '1'
            $env:WT_SESSION = 'b0f4c2f6-1111-2222-3333-444455556666'
            Get-KohaGlyphMode | Should -Be '0'
        } finally { $env:WT_SESSION = $saved }
    }

    It 'starts the panel with KEI_PLAIN_GLYPHS in WSLENV and puts the environment back' {
        $env:WSLENV = 'WT_SESSION'
        Mock -ModuleName KohaEasy.Install Start-Process { $script:env = $env:WSLENV + '|' + $env:KEI_PLAIN_GLYPHS; [pscustomobject]@{ ExitCode = 0 } }
        Invoke-KohaPanel | Should -Be 0
        $script:env | Should -Match '^WT_SESSION:KEI_PLAIN_GLYPHS\|[01]$'
        $env:WSLENV | Should -Be 'WT_SESSION'
    }
}

Describe 'Checks inside Debian' {
    It 'the installed and quick-check scripts are valid sh' {
        foreach ($name in 'InstalledProbe', 'SystemdProbe') {
            $f = Join-Path $TestDrive "$name.sh"
            [System.IO.File]::WriteAllText($f, (InModuleScope KohaEasy.Install -Parameters @{ N = $name } { param($N) (Get-Variable -Scope Script -Name $N).Value }))
            & sh -n $f
            $LASTEXITCODE | Should -Be 0 -Because $name
        }
        $f = Join-Path $TestDrive 'quick.sh'
        [System.IO.File]::WriteAllText($f, (InModuleScope KohaEasy.Core { $script:QuickCheckScript }))
        & sh -n $f
        $LASTEXITCODE | Should -Be 0
    }

    It 'counts Koha as installed only with the instance, the credentials file and koha-common configured' {
        $p = InModuleScope KohaEasy.Install { $script:InstalledProbe }
        $p | Should -Match 'koha-conf.xml'
        $p | Should -Match 'koha_credentials.txt'
        $p | Should -Match "grep -q '\^ii'"
    }

    It 'opens the control panel in its own window, through the koha-panel launcher, and starts Koha' {
        Mock -ModuleName KohaEasy.Core Start-Koha { 'started' }
        Mock -ModuleName KohaEasy.Core Get-KohaTerminalPath { $null }
        Mock -ModuleName KohaEasy.Core Start-Process { $script:file = $FilePath; $script:args = $ArgumentList }
        Mock -ModuleName KohaEasy.Core Confirm-KohaWindowScript { $true }
        Open-KohaPanel
        Should -Invoke -ModuleName KohaEasy.Core Start-Koha -Times 1 -Exactly
        Should -Invoke -ModuleName KohaEasy.Core Confirm-KohaWindowScript -Times 1 -Exactly
        $script:file | Should -Match 'wsl\.exe$'
        ([string]$script:args) -match '^-d koha -u root --cd /root -- env KEI_PLAIN_GLYPHS=1 KEI_WINDOW_PAUSE=([A-Za-z0-9+/=]+) /usr/local/bin/koha-window /usr/local/bin/koha-panel$' | Should -BeTrue
        [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Matches[1])) | Should -Be 'The control panel ended with an error. Press Enter to close this window.'
    }

    It 'opens the control panel in Windows Terminal, with emoji, when it is installed' {
        $l = Get-KohaPanelLaunch -Wsl 'C:\Windows\System32\wsl.exe' -Terminal 'C:\Users\a\AppData\Local\Microsoft\WindowsApps\wt.exe'
        $l.File | Should -Match 'wt\.exe$'
        $l.Arguments | Should -Be '-w new --title Koha "C:\Windows\System32\wsl.exe" -d koha -u root --cd /root -- env KEI_PLAIN_GLYPHS=0 /usr/local/bin/koha-window /usr/local/bin/koha-panel'
    }
}

Describe 'Emoji and UTF-8' {
    It 'marks steps with emoji in Windows Terminal and plain tags in the classic console' {
        Get-KohaStepMark -Kind ok -Mode 1 | Should -Be '[OK]'
        Get-KohaStepMark -Kind error -Mode 1 | Should -Be '[X]'
        Get-KohaStepMark -Kind ok -Mode 0 | Should -Be ([char]::ConvertFromUtf32(0x2705))
        Get-KohaStepMark -Kind step -Mode 0 | Should -Be ([char]::ConvertFromUtf32(0x23F3))
        Get-KohaStepMark -Kind warn -Mode 0 | Should -Be ([char]::ConvertFromUtf32(0x26A0) + [char]::ConvertFromUtf32(0xFE0F))
        Get-KohaStepMark -Kind error -Mode 0 | Should -Be ([char]::ConvertFromUtf32(0x274C))
    }

    It 'sets UTF-8 without a BOM, so scripts piped into Debian do not start with one' {
        $saved = $global:OutputEncoding
        try {
            Set-KohaUtf8Console
            $global:OutputEncoding.WebName | Should -Be 'utf-8'
            $global:OutputEncoding.GetPreamble().Length | Should -Be 0
        } finally { $global:OutputEncoding = $saved }
    }

    It 'continues the install in Windows Terminal after a restart when it is installed' {
        $ps = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
        Get-KohaInstallCommand -PowerShell $ps -Script 'C:\KohaEasy\bin\KohaEasy.ps1' -Terminal $null |
            Should -Be ('"{0}" -NoProfile -ExecutionPolicy Bypass -File "C:\KohaEasy\bin\KohaEasy.ps1" Install' -f $ps)
        Get-KohaInstallCommand -PowerShell $ps -Script 'C:\KohaEasy\bin\KohaEasy.ps1' -Terminal 'C:\wt.exe' |
            Should -Be ('"C:\wt.exe" -w new --title Koha "{0}" -NoProfile -ExecutionPolicy Bypass -File "C:\KohaEasy\bin\KohaEasy.ps1" Install -Pause' -f $ps)
    }

    It 'keeps install.ps1 plain ASCII, with UTF-8 set before anything is printed' {
        $f = Join-Path $PSScriptRoot '..\..\windows\install.ps1'
        $bytes = [System.IO.File]::ReadAllBytes($f)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
        $text = [System.IO.File]::ReadAllText($f)
        $text.IndexOf('UTF8Encoding($false)') | Should -BeLessThan $text.IndexOf('Write-Host')
        $text | Should -Not -Match '\[System\.Text\.Encoding\]::UTF8'
    }
}

Describe 'Koha window' {
    It 'reads the quick check as one row per service, and the staff page by its HTTP code' {
        $lines = @(
            'Debian (koha) running: True'
            'Keep Koha running task: Running, last result 0x41301, last run 09/29/2026 09:00:00'
            'systemd: running'
            'mariadb: active'
            'apache2: active'
            'memcached: activating'
            'rabbitmq-server: failed'
            'koha-common: inactive'
            'koha-common package: ii 24.11.03-1'
            'installation finished: yes'
            'staff page inside Debian: 302'
        )
        $h = ConvertFrom-KohaQuickCheck -Lines $lines
        $h.DebianRunning | Should -BeTrue
        $h.Finished | Should -BeTrue
        $rows = @{}
        foreach ($r in $h.Services) { $rows[$r.Unit] = $r.State }
        $rows['wsl'] | Should -Be 'running'
        $rows['mariadb'] | Should -Be 'running'
        $rows['memcached'] | Should -Be 'starting'
        $rows['rabbitmq-server'] | Should -Be 'failed'
        $rows['koha-common'] | Should -Be 'stopped'
        $rows['http'] | Should -Be 'running'
        @($h.Services).Count | Should -Be 7
    }

    It 'shows every row as stopped while Debian is off, without asking Debian' {
        $h = ConvertFrom-KohaQuickCheck -Lines @('Debian (koha) running: False', 'Keep Koha running task: not found')
        $h.DebianRunning | Should -BeFalse
        @($h.Services | Where-Object { $_.State -ne 'stopped' }).Count | Should -Be 0
    }

    It 'reports a staff page that does not answer as failed' {
        $h = ConvertFrom-KohaQuickCheck -Lines @('Debian (koha) running: True', 'staff page inside Debian: 000')
        ($h.Services | Where-Object { $_.Unit -eq 'http' }).State | Should -Be 'failed'
        Get-KohaServiceStateText -State 'failed' -Unit 'http' -Detail '000' | Should -Be 'Does not answer'
        Get-KohaServiceStateText -State 'running' -Unit 'http' -Detail '200' | Should -Be 'Answers (HTTP 200)'
    }

    It 'restarts the services only when Debian is already running' {
        Mock -ModuleName KohaEasy.Core Test-KohaDistroRunning { $false }
        Mock -ModuleName KohaEasy.Core Invoke-KohaLinuxScript { throw 'must not run' }
        Restart-KohaServices | Should -Be 'not_running'
        Mock -ModuleName KohaEasy.Core Test-KohaDistroRunning { $true }
        Mock -ModuleName KohaEasy.Core Invoke-KohaLinuxScript { $script:sent = $Script; [pscustomobject]@{ ExitCode = 0; Output = '' } }
        Mock -ModuleName KohaEasy.Core Wait-KohaHttp { $true }
        Restart-KohaServices | Should -Be 'ready'
        $script:sent | Should -Match 'systemctl restart'
        $script:sent | Should -Match 'mariadb memcached rabbitmq-server koha-common apache2'
    }

    It 'the restart and log scripts are valid sh' {
        foreach ($name in 'RestartServicesScript', 'ServiceLogScript') {
            $f = Join-Path $TestDrive "$name.sh"
            [System.IO.File]::WriteAllText($f, (InModuleScope KohaEasy.Core -Parameters @{ N = $name } { param($N) (Get-Variable -Scope Script -Name $N).Value }))
            & sh -n $f
            $LASTEXITCODE | Should -Be 0 -Because $name
        }
    }

    It 'saves diagnostico_koha.txt with the services and no password, and starts nothing' {
        Mock -ModuleName KohaEasy.Core Invoke-KohaWsl { [pscustomobject]@{ ExitCode = 0; Output = 'WSL version: 2.3.26.0' } }
        Mock -ModuleName KohaEasy.Core Test-KohaDistroRunning { $true }
        Mock -ModuleName KohaEasy.Core Get-KohaQuickCheck { @('Debian (koha) running: True', 'mariadb: active') }
        Mock -ModuleName KohaEasy.Core Invoke-KohaLinuxScript { [pscustomobject]@{ ExitCode = 0; Output = 'db_password=hunter2secret' } }
        Mock -ModuleName KohaEasy.Core Start-Koha { throw 'must not start' }
        $file = Export-KohaDiagnosticsText -Destination (Join-Path $TestDrive 'Desktop')
        Split-Path -Leaf $file | Should -Be 'diagnostico_koha.txt'
        $text = Get-Content -LiteralPath $file -Raw
        $text | Should -Match 'mariadb: active'
        $text | Should -Match 'WSL version'
        $text | Should -Not -Match 'hunter2secret'
    }

    It 'asks before closing the tray, with Koha kept running as the first choice' {
        $tray = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../windows/KohaEasy.Tray.ps1') -Raw
        $tray | Should -Match 'Show-KohaChoice'
        $tray | Should -Match "keep\s+= \(T 'Keep Koha running'\)"
        $tray | Should -Match "Invoke-KohaCommand 'Stop -Force'"
        $tray | Should -Match "add_DoubleClick\(\{ Invoke-KohaCommand 'Window' \}\)"
    }

    It 'holds a shutdown block reason only while Koha runs, and stops Koha cleanly when the session ends' {
        $tray = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../windows/KohaEasy.Tray.ps1') -Raw
        $tray | Should -Match 'ShutdownBlockReasonCreate'
        $tray | Should -Match 'm.Msg == WM_ENDSESSION && m.WParam != IntPtr.Zero'
        $tray | Should -Match 'if \(\$on\) \{ \$session.Block\(\$blockReason\) \} else \{ \$session.Unblock\(\) \}'
        $tray | Should -Match "AddScript\(\{ Stop-KohaForSessionEnd \}\)"
        $tray | Should -Match 'Application\]::DoEvents\(\)'
    }

    It 'the Koha window offers Rebuild search index only while Debian runs' {
        $w = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../windows/KohaEasy.Window.ps1') -Raw
        $w | Should -Match "'reindex'\s+\{ \`$result = Invoke-KohaSearchReindex \}"
        $w | Should -Match '\$btnReindex.Enabled = \(-not \$Busy\) -and \$on'
    }
}

Describe 'The Koha window banner and terminal area' {
    BeforeAll {
        function New-Health {
            param([bool]$Debian = $true, [hashtable]$States = @{})
            $rows = foreach ($u in 'wsl', 'mariadb', 'apache2', 'rabbitmq-server', 'memcached', 'koha-common', 'http') {
                $st = 'running'
                if ($States.ContainsKey($u)) { $st = $States[$u] }
                $name = @{ wsl = 'Debian (WSL)'; mariadb = 'MariaDB'; apache2 = 'Apache'; 'rabbitmq-server' = 'RabbitMQ'; memcached = 'Memcached'; 'koha-common' = 'Koha (koha-common)'; http = 'staff' }[$u]
                [pscustomobject]@{ Unit = $u; Name = $name; State = $st; Detail = '200' }
            }
            return [pscustomobject]@{ DebianRunning = $Debian; Services = @($rows) }
        }
    }

    It 'is green only when every component runs' {
        $s = Get-KohaHealthSummary -Health (New-Health) -State 'running'
        $s.Level | Should -Be 'ok'
        $s.Text | Should -Be 'All services are running'
        @($s.Broken).Count | Should -Be 0
    }

    It 'names the one component that is down, and highlights only that one' {
        $s = Get-KohaHealthSummary -Health (New-Health -States @{ mariadb = 'failed' }) -State 'running'
        $s.Level | Should -Be 'fault'
        $s.Text | Should -Be 'Attention: MariaDB is offline'
        @($s.Broken) | Should -Be @('mariadb')
    }

    It 'counts and lists several components that are down' {
        $s = Get-KohaHealthSummary -Health (New-Health -States @{ apache2 = 'stopped'; http = 'failed' }) -State 'not_responding'
        $s.Level | Should -Be 'fault'
        $s.Text | Should -Be 'Attention: 2 components are offline (Apache, HTTP response)'
        @($s.Broken) | Should -Be @('apache2', 'http')
    }

    It 'says the staff interface does not answer when only the web answer fails' {
        $s = Get-KohaHealthSummary -Health (New-Health -States @{ http = 'failed' }) -State 'not_responding'
        $s.Text | Should -Be 'Attention: the staff interface does not answer'
    }

    It 'names only Debian when Debian is down while Koha should run' {
        $all = @{ wsl = 'stopped'; mariadb = 'stopped'; apache2 = 'stopped'; 'rabbitmq-server' = 'stopped'; memcached = 'stopped'; 'koha-common' = 'stopped'; http = 'stopped' }
        $s = Get-KohaHealthSummary -Health (New-Health -Debian $false -States $all) -State 'stopped'
        $s.Level | Should -Be 'fault'
        $s.Text | Should -Be 'Attention: Debian (WSL) is offline'
        @($s.Broken) | Should -Be @('wsl')
    }

    It 'highlights nothing when the librarian stopped Koha, or while it starts' {
        $all = @{ wsl = 'stopped'; mariadb = 'stopped'; apache2 = 'stopped'; 'rabbitmq-server' = 'stopped'; memcached = 'stopped'; 'koha-common' = 'stopped'; http = 'stopped' }
        $s = Get-KohaHealthSummary -Health (New-Health -Debian $false -States $all) -State 'stopped_by_user'
        $s.Level | Should -Be 'stopped'
        @($s.Broken).Count | Should -Be 0
        $s = Get-KohaHealthSummary -Health (New-Health -States @{ memcached = 'starting' }) -State 'running'
        $s.Level | Should -Be 'starting'
        $s = Get-KohaHealthSummary -Health (New-Health -States @{ apache2 = 'stopped'; http = 'failed' }) -State 'starting'
        $s.Level | Should -Be 'starting'
        @($s.Broken).Count | Should -Be 0
        (Get-KohaHealthSummary -Health $null -State 'running').Level | Should -Be 'unknown'
    }

    It 'runs one command as the Debian user, from home, with a time limit and the command on stdin' {
        Mock -ModuleName KohaEasy.Core Test-KohaDistroRunning { $false }
        Mock -ModuleName KohaEasy.Core Invoke-KohaWsl { throw 'must not run' }
        Invoke-KohaUserCommand -Command 'df -h' | Should -BeNullOrEmpty
        Mock -ModuleName KohaEasy.Core Test-KohaDistroRunning { $true }
        Mock -ModuleName KohaEasy.Core Invoke-KohaWsl { $script:wargs = $Arguments; $script:win = $InputText; [pscustomobject]@{ ExitCode = 0; Output = 'ok' } }
        (Invoke-KohaUserCommand -Command "df -h`r").Output | Should -Be 'ok'
        ($script:wargs -join ' ') | Should -Be '-d koha --cd ~ -- timeout -k 5 120 bash -l'
        $script:wargs | Should -Not -Contain '-u'
        $script:win | Should -Be "df -h`nexit `$?`n"
    }

    It 'sends the log lines of an action to the terminal area while it is set' {
        $q = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
        Set-KohaOutputSink $q
        try { Write-KohaLog 'restart services: [OK] mariadb' } finally { Set-KohaOutputSink $null }
        Write-KohaLog 'not shown'
        $q.Count | Should -Be 1
        $line = $null
        [void]$q.TryDequeue([ref]$line)
        $line | Should -Match '^\d\d:\d\d:\d\d  restart services: \[OK\] mariadb$'
    }

    It 'shows each restarted service in the terminal area' {
        Mock -ModuleName KohaEasy.Core Test-KohaDistroRunning { $true }
        Mock -ModuleName KohaEasy.Core Invoke-KohaLinuxScript { [pscustomobject]@{ ExitCode = 0; Output = "[OK] mariadb`n[OK] apache2`n" } }
        Mock -ModuleName KohaEasy.Core Wait-KohaHttp { $true }
        Mock -ModuleName KohaEasy.Core Write-KohaLog { }
        Restart-KohaServices | Should -Be 'ready'
        Should -Invoke -ModuleName KohaEasy.Core Write-KohaLog -ParameterFilter { $Message -eq 'restart services: [OK] mariadb' } -Times 1 -Exactly
        Should -Invoke -ModuleName KohaEasy.Core Write-KohaLog -ParameterFilter { $Message -eq 'restart services: [OK] apache2' } -Times 1 -Exactly
    }

    It 'the window keeps three actions on its surface, Staff before the catalog, and no Refresh button' {
        $w = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../windows/KohaEasy.Window.ps1') -Raw
        $w.IndexOf("T 'Staff interface'") | Should -BeLessThan $w.IndexOf("T 'Public catalog (OPAC)'")
        $w | Should -Match 'foreach \(\$b in \$btnPanel, \$btnServices, \$btnConsole, \$btnMore\)'
        $w | Should -Not -Match "T 'Refresh'"
        $w | Should -Match "'command'\s+\{"
        $w | Should -Match 'SetDarkTitleBar'
    }
}

Describe 'Linux errors are answers, not PowerShell errors' {
    BeforeAll {
        $script:bin = Join-Path $TestDrive 'fakebin'
        New-Item -ItemType Directory -Path $script:bin -Force | Out-Null
        $fake = Join-Path $script:bin 'wsl.exe'
        [System.IO.File]::WriteAllText($fake, "#!/bin/sh`necho `"id: 'paulo': no such user`" >&2`nexit 1`n")
        & chmod +x $fake
        $script:path = $env:PATH
        $env:PATH = $script:bin + [System.IO.Path]::PathSeparator + $env:PATH
    }
    AfterAll { $env:PATH = $script:path }

    It 'returns what wsl.exe wrote to stderr with its exit code, even under Stop' {
        $ErrorActionPreference = 'Stop'
        $r = Invoke-KohaWsl -Arguments @('-d', 'koha', '--', 'id', '-u', 'paulo')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'no such user'
    }

    It 'reports a missing Debian user as missing instead of stopping the installer' {
        $ErrorActionPreference = 'Stop'
        Test-KohaLinuxUserExists 'paulo' | Should -BeFalse
        Test-KohaLinuxUserExists 'root' | Should -BeTrue
    }

    It 'keeps an existing Debian instead of downloading it again' {
        Remove-Item -LiteralPath (Get-KohaPath Root) -Recurse -Force -ErrorAction SilentlyContinue
        Mock -ModuleName KohaEasy.Install Write-Host { }
        Mock -ModuleName KohaEasy.Install Test-KohaDistroInstalled { $true }
        Mock -ModuleName KohaEasy.Install Restore-KohaDistro { 'ok' }
        Mock -ModuleName KohaEasy.Install New-KohaDistro { throw 'must not download' }
        Mock -ModuleName KohaEasy.Install Test-KohaLinuxUserExists { $true }
        Mock -ModuleName KohaEasy.Install Set-KohaDistroConfig { $false }
        Set-KohaState @{ phase = 'distro'; linuxUser = 'paulo' } | Out-Null
        Install-Koha -Facts @{ Build = 22631; Is64 = $true; MemGB = 16; FreeGB = 200; VirtFirmware = $true; Hypervisor = $true; Arm = $false } -NonInteractive | Should -Be 1
        Should -Invoke -ModuleName KohaEasy.Install Write-Host -ParameterFilter { "$Object" -like '*already installed*' }
        (Get-KohaState).phase | Should -Be 'systemd'
    }
}
