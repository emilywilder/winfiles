# Install-Wsl.ps1 names its CIM classes, registry key and wsl.exe itself, and elevates and restarts Windows, so it runs
# in this process with mocks, like Winfiles/WslDistribution. The fake WSL is a hashtable: what --version reports,
# whether Virtual Machine Platform is enabled, whether a restart is pending and whether a hypervisor runs, which
# --install and --update change the way the real ones do on a fresh install. wsl.exe is mocked whether the test runs
# elevated (called directly) or not (through Start-Process).
BeforeAll {
    . (Join-Path $PSScriptRoot '..\resources\Resource.ps1')
    $script:file = Join-Path $repo 'scripts\Install-Wsl.ps1'

    function Invoke-FakeWsl {
        $fake.Calls += , ($args -join ' ')
        $global:LASTEXITCODE = 0
        switch ($args[0]) {
            '--version' {
                if ($fake.Version) { "WSL version: $($fake.Version).0" } else { $global:LASTEXITCODE = -1; 'Usage: wsl.exe [Argument]' }
            }
            '--install' {
                $fake.Version = $fake.Version ?? '2.6.1'
                $fake.Vmp = 1
                $fake.Pending = $fake.Pending -or $fake.InstallRestarts
                $global:LASTEXITCODE = $fake.InstallExit
            }
            '--update' {
                if ($fake.UpdateWorks) { $fake.Version = '2.6.1' }
                $global:LASTEXITCODE = $fake.UpdateExit
            }
        }
    }

    # Returns the exit code; a throw from the script reaches the test
    function Invoke-InstallWsl {
        $saved = $env:WSL_UTF8
        try {
            & $file *> $null
            $LASTEXITCODE
        } finally {
            $env:WSL_UTF8 = $saved
        }
    }
}

Describe 'Install-Wsl.ps1' {
    BeforeEach {
        # A fresh install: the inbox wsl.exe, Virtual Machine Platform off, and a hypervisor once it's on
        $script:fake = @{
            Version = $null; Vmp = 2; Pending = $false; Hypervisor = $true; InstallRestarts = $true
            InstallExit = 0; UpdateExit = 0; UpdateWorks = $true; Calls = @(); Warnings = @()
        }
        Mock wsl.exe { Invoke-FakeWsl @args }
        Mock Start-Process { Invoke-FakeWsl @ArgumentList | Out-Null; [pscustomobject]@{ ExitCode = $global:LASTEXITCODE } }
        Mock Get-CimInstance {
            if ($ClassName -eq 'Win32_ComputerSystem') { [pscustomobject]@{ HypervisorPresent = $fake.Hypervisor } }
            else { [pscustomobject]@{ Name = 'VirtualMachinePlatform'; InstallState = $fake.Vmp } }
        }
        Mock Test-Path { $fake.Pending }
        Mock Write-Warning { $fake.Warnings += $Message }
        Mock Start-Sleep {}
        Mock Restart-Computer {}
    }

    It 'skips when WSL is ready' {
        $fake.Version = '2.6.1'; $fake.Vmp = 1
        Invoke-InstallWsl | Should -Be 0
        $fake.Calls | Should -Not -Contain '--install --no-distribution'
    }

    It 'stops for a restart that is already pending, without restarting' {
        $fake.Version = '2.6.1'; $fake.Vmp = 1; $fake.Pending = $true
        Invoke-InstallWsl | Should -Be 3010
        $fake.Warnings | Should -BeLike '*Windows has a restart pending*'
        Should -Invoke Restart-Computer -Times 0 -Exactly
    }

    It 'installs WSL on a fresh install, then restarts and exits 3010' {
        Invoke-InstallWsl | Should -Be 3010
        $fake.Calls | Should -Contain '--install --no-distribution'
        $fake.Calls | Should -Not -Contain '--update'
        Should -Invoke Restart-Computer -Times 1 -Exactly
    }

    It 'accepts 3010 from wsl.exe' {
        $fake.InstallExit = 3010
        Invoke-InstallWsl | Should -Be 3010
        Should -Invoke Restart-Computer -Times 1 -Exactly
    }

    It 'stops without restarting again when wsl.exe has started a restart (1641)' {
        $fake.InstallExit = 1641
        Invoke-InstallWsl | Should -Be 3010
        $fake.Warnings | Should -BeLike '*has started a restart*'
        Should -Invoke Restart-Computer -Times 0 -Exactly
    }

    It 'fails on any other exit code from wsl.exe' {
        $fake.InstallExit = 1
        { Invoke-InstallWsl } | Should -Throw '*exited with code 1'
    }

    It 'updates a WSL older than 2.4.4, without installing or restarting' {
        $fake.Version = '2.3.26'; $fake.Vmp = 1
        Invoke-InstallWsl | Should -Be 0
        $fake.Calls | Should -Contain '--update'
        $fake.Calls | Should -Not -Contain '--install --no-distribution'
        Should -Invoke Restart-Computer -Times 0 -Exactly
    }

    It 'only warns when a restart is pending after an update, since it may be Windows Update''s' {
        $fake.Version = '2.3.26'; $fake.Vmp = 1; $fake.Pending = $true
        Invoke-InstallWsl | Should -Be 3010
        $fake.Warnings | Should -BeLike 'WSL updated. Windows has a restart pending*'
        Should -Invoke Restart-Computer -Times 0 -Exactly
    }

    It 'updates an old WSL and enables the feature when both are needed' {
        $fake.Version = '2.3.26'
        Invoke-InstallWsl | Should -Be 3010
        $fake.Calls | Should -Contain '--update'
        $fake.Calls | Should -Contain '--install --no-distribution'
    }

    It 'fails, rather than asking for a restart, when WSL still isn''t ready and none is pending' {
        $fake.Version = '2.3.26'; $fake.Vmp = 1; $fake.UpdateWorks = $false
        { Invoke-InstallWsl } | Should -Throw '*still isn''t ready*WSL 2.3.26*Virtual Machine Platform is enabled*'
        Should -Invoke Restart-Computer -Times 0 -Exactly
    }

    It 'fails when WSL is ready but no hypervisor is running' {
        $fake.Version = '2.6.1'; $fake.Vmp = 1; $fake.Hypervisor = $false
        { Invoke-InstallWsl } | Should -Throw '*no hypervisor is running*'
    }

    It 'checks the hypervisor after the restart, not before' {
        $fake.Hypervisor = $false
        Invoke-InstallWsl | Should -Be 3010
        Should -Invoke Restart-Computer -Times 1 -Exactly
    }
}
