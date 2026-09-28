# Pester 5 tests for the Windows install flow (windows\KohaEasy.Install.psm1,
# windows\install.ps1, Install Koha.cmd). wsl.exe, UAC and downloads are mocked.

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

    It 'enables systemd and keeps Windows paths out of Linux' {
        $c = Get-KohaWslConf
        $c | Should -Match '(?m)^\[boot\]$'
        $c | Should -Match '(?m)^systemd=true$'
        $c | Should -Match '(?m)^appendWindowsPath=false$'
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

    It 'turns C:\ paths into /mnt/c paths' {
        ConvertTo-KohaWslPath 'C:\KohaEasy\bin' | Should -Be '/mnt/c/KohaEasy/bin'
    }
}

Describe 'Debian download' {
    It 'refuses an image whose SHA-256 does not match, and removes it' {
        Mock -ModuleName KohaEasy.Install Test-KohaDistroInstalled { $false }
        Mock -ModuleName KohaEasy.Install Get-KohaDistributionManifest { '{"ModernDistributions":{"Debian":[{"Name":"Debian","Default":true,"Amd64Url":{"Url":"https://x.test/d.wsl","Sha256":"0x00"}}]}}' | ConvertFrom-Json }
        Mock -ModuleName KohaEasy.Install Save-KohaDownload { Set-Content -LiteralPath $Path -Value 'not debian' }
        Mock -ModuleName KohaEasy.Install Invoke-KohaWsl { throw 'must not import' }
        { New-KohaDistro } | Should -Throw '*SHA-256*'
        @(Get-ChildItem (Get-KohaPath Wsl) -Filter '*.tar.gz').Count | Should -Be 0
    }

    It 'imports a good image as KohaEasy with WSL 2, and leaves an existing one alone' {
        Mock -ModuleName KohaEasy.Install Test-KohaDistroInstalled { $false }
        $script:img = Join-Path $TestDrive 'img'
        Set-Content -LiteralPath $script:img -Value 'debian' -NoNewline
        $sha = (Get-FileHash -LiteralPath $script:img -Algorithm SHA256).Hash
        Mock -ModuleName KohaEasy.Install Get-KohaDistributionManifest { ('{"ModernDistributions":{"Debian":[{"Name":"Debian","Amd64Url":{"Url":"https://x.test/d.wsl","Sha256":"0x' + $sha + '"}}]}}') | ConvertFrom-Json }
        Mock -ModuleName KohaEasy.Install Save-KohaDownload { Copy-Item -LiteralPath $script:img -Destination $Path }
        Mock -ModuleName KohaEasy.Install Invoke-KohaWsl { [pscustomobject]@{ ExitCode = 0; Output = '' } }
        New-KohaDistro | Should -Be 'imported'
        Should -Invoke -ModuleName KohaEasy.Install Invoke-KohaWsl -ParameterFilter { $Arguments[0] -eq '--import' -and $Arguments[1] -eq 'KohaEasy' -and $Arguments[-1] -eq '2' }
        Mock -ModuleName KohaEasy.Install Test-KohaDistroInstalled { $true }
        New-KohaDistro | Should -Be 'exists'
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
        $script:calls | Should -Be @('distro', 'systemd', 'copy panel', 'tasks logon', 'tray at sign-in', 'shortcuts', 'start')
        (Get-KohaState).phase | Should -Be 'done'
        (Get-KohaState).autostart | Should -Be 'logon'
    }

    It 'does nothing again once done' {
        Mock -ModuleName KohaEasy.Install Test-KohaWslReady { $true }
        Set-KohaState @{ phase = 'done' } | Out-Null
        Install-Koha -Facts $good -NonInteractive | Should -Be 0
        $script:calls.Count | Should -Be 0
    }

    It 'gives the Koha panel the console itself, never a captured pipe' {
        Mock -ModuleName KohaEasy.Install Start-Process { [pscustomobject]@{ ExitCode = 0 } }
        Invoke-KohaPanel | Should -Be 0
        Should -Invoke -ModuleName KohaEasy.Install Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'wsl.exe' -and $NoNewWindow -and $Wait -and $ArgumentList -like '-d KohaEasy -u root --cd /root/koha-easy-installer -- bash ./installer'
        }
    }

    It 'stops when systemd does not start in WSL' {
        Mock -ModuleName KohaEasy.Install Test-KohaWslReady { $true }
        Mock -ModuleName KohaEasy.Install Set-KohaDistroConfig { $false }
        Install-Koha -Facts $good -NonInteractive | Should -Be 1
        (Get-KohaState).phase | Should -Be 'systemd'
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

Describe 'Bootstrapper and Install Koha.cmd' {
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

    It 'Install Koha.cmd has Windows line endings and runs the same one-liner as the README' {
        $cmd = [System.IO.File]::ReadAllText((Join-Path $repo 'Install Koha.cmd'))
        ($cmd -replace "`r`n", '') | Should -Not -Match "`n"
        $cmd | Should -Not -Match '-File'
        $url = 'https://raw.githubusercontent.com/PauloFBaldiFH/Koha-Easy-Installer/main/windows/install.ps1'
        $cmd | Should -Match ([regex]::Escape($url))
        Get-Content -Raw (Join-Path $repo 'README.md') | Should -Match ([regex]::Escape("irm $url | iex"))
        Get-Content -Raw (Join-Path $repo 'README.pt-BR.md') | Should -Match ([regex]::Escape("irm $url | iex"))
    }
}
