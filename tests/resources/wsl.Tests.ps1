# Winfiles/Wsl names its CIM classes, registry key, wsl.exe and whoami.exe itself, so it runs in this process with mocks
# (Invoke-ResourceScript), like Winfiles/WslDistribution and Winfiles/ComputerName. The fake WSL is a hashtable: its
# version, whether Virtual Machine Platform is enabled, whether a restart is pending and whether a hypervisor runs, which
# --install and --update change the way the real ones do on a fresh install. Nothing here can touch the real WSL.
BeforeAll {
    . (Join-Path $PSScriptRoot 'Resource.ps1')

    # A stand-in to mock: the script defines the real one when it dot-sources common.ps1, and the mock still wins
    function Write-ResourceMessage([string]$Level, [string]$Text) {}
    function Start-WslConsole([string[]]$WslArgs, [string]$OutFile) {}
    function Write-WinfilesLog([string]$Phase, [string]$Message) {}

    function Invoke-FakeWsl {
        $fake.Calls += , ($args -join ' ')
        $global:LASTEXITCODE = 0
        switch ($args[0]) {
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

    function Invoke-Wsl([string]$Operation, [hashtable]$Instance = @{}) {
        Invoke-ResourceScript wsl $Operation $Instance
    }
}

Describe 'Winfiles/Wsl' {
    BeforeEach {
        # A fresh install: the inbox wsl.exe, Virtual Machine Platform off, and a hypervisor once it's on
        $script:fake = @{
            Version = $null; Vmp = 2; Pending = $false; Hypervisor = $true; InstallRestarts = $true
            InstallExit = 0; UpdateExit = 0; UpdateWorks = $true; Elevated = $true; Calls = @()
        }
        Mock Write-ResourceMessage {}
        # The run log is the real file in the user's profile, so no test writes to it
        Mock Write-WinfilesLog {}
        # What runs wsl.exe, in a console of its own; the fake takes its place, so no test starts a real process
        Mock Start-WslConsole { Invoke-FakeWsl @WslArgs; $global:LASTEXITCODE }
        Mock whoami.exe { if ($fake.Elevated) { 'Mandatory Label\High Mandatory Level   Label   S-1-16-12288' } else { 'Mandatory Label\Medium Mandatory Level   Label   S-1-16-8192' } }
        Mock Get-CimInstance {
            if ($ClassName -eq 'Win32_ComputerSystem') { [pscustomobject]@{ HypervisorPresent = $fake.Hypervisor } }
            else { [pscustomobject]@{ Name = 'VirtualMachinePlatform'; InstallState = $fake.Vmp } }
        }
        Mock Test-Path { $fake.Pending }
        # The package's wsl.exe exists once WSL is installed; the inbox one doesn't count
        Mock Test-Path { [bool]$fake.Version } -ParameterFilter { $Path -like '*\WSL\wsl.exe' }
        # Always mocked, so a test never reads the real package registration on the machine it runs on
        Mock Get-ChildItem -ParameterFilter { $Path -like '*AppxAllUserStore*' } {
            if ($fake.StoreVersion) { "MicrosoftCorporationII.WindowsSubsystemForLinux_$($fake.StoreVersion).0_x64__8wekyb3d8bbwe" }
        }
        Mock Get-Item -ParameterFilter { $LiteralPath -like '*\WSL\wsl.exe' } {
            [pscustomobject]@{ VersionInfo = [pscustomobject]@{ ProductVersion = "$($fake.Version).0" } }
        }
    }

    Context 'test' {
        It 'is in the desired state when WSL is installed, enabled and running, and asks for no restart' {
            $fake.Version = '2.6.1'; $fake.Vmp = 1
            $result = Invoke-Wsl test
            $result.ExitCode | Should -Be 0
            $result.State._inDesiredState | Should -BeTrue
            $result.State.version | Should -Be '2.6.1'
            $result.State.Keys | Should -Not -Contain '_restartRequired'
        }

        # What lets a run know before it applies anything that set will need a restart
        It 'says a restart will be needed while Virtual Machine Platform is off, before anything is installed' {
            $result = Invoke-Wsl test
            $result.State._inDesiredState | Should -BeFalse
            @($result.State._restartRequired) | Should -HaveCount 1
            Assert-RestartRequiredSchema $result.State
            $fake.Calls | Should -BeNullOrEmpty
        }

        It 'does not predict a restart for WSL that only needs installing with the feature already on' {
            $fake.Vmp = 1
            $result = Invoke-Wsl test
            $result.State._inDesiredState | Should -BeFalse
            $result.State.Keys | Should -Not -Contain '_restartRequired'
        }

        It 'does not predict a restart for a WSL that only needs updating' {
            $fake.Version = '2.3.26'; $fake.Vmp = 1
            $result = Invoke-Wsl test
            $result.State._inDesiredState | Should -BeFalse
            $result.State.Keys | Should -Not -Contain '_restartRequired'
        }

        It 'is not in the desired state while a restart is pending, and says so' {
            $fake.Version = '2.6.1'; $fake.Vmp = 1; $fake.Pending = $true
            $result = Invoke-Wsl test
            $result.State._inDesiredState | Should -BeFalse
            $result.State.restartPending | Should -BeTrue
            @($result.State._restartRequired) | Should -HaveCount 1
        }

        It 'is not in the desired state without a hypervisor, once no restart is pending' {
            $fake.Version = '2.6.1'; $fake.Vmp = 1; $fake.Hypervisor = $false
            (Invoke-Wsl test).State._inDesiredState | Should -BeFalse
        }

        It 'reads a WSL installed as a package elsewhere from its registration' {
            $fake.Vmp = 1; $fake.StoreVersion = '2.5.9'
            $result = Invoke-Wsl test
            $result.State.version | Should -Be '2.5.9'
            $result.State._inDesiredState | Should -BeTrue
        }

        It 'counts a WSL older than minimumVersion as not installed' {
            $fake.Version = '2.6.1'; $fake.Vmp = 1
            (Invoke-Wsl test @{ minimumVersion = '3.0.0' }).State._inDesiredState | Should -BeFalse
        }
    }

    Context 'get' {
        It 'reports a restart only while one is pending' {
            $fake.Version = '2.6.1'; $fake.Vmp = 1
            (Invoke-Wsl get).State.Keys | Should -Not -Contain '_restartRequired'
            $fake.Pending = $true
            @((Invoke-Wsl get).State._restartRequired) | Should -HaveCount 1
        }

        It 'does not report a restart for a missing Virtual Machine Platform, which only test predicts' {
            (Invoke-Wsl get).State.Keys | Should -Not -Contain '_restartRequired'
        }
    }

    Context 'set' {
        It 'does nothing when WSL is ready' {
            $fake.Version = '2.6.1'; $fake.Vmp = 1
            $result = Invoke-Wsl set
            $result.ExitCode | Should -Be 0
            $fake.Calls | Should -BeNullOrEmpty
            $result.State.Keys | Should -Not -Contain '_restartRequired'
        }

        It 'installs WSL on a fresh install, exits 0 and reports the restart it leaves pending' {
            $result = Invoke-Wsl set
            $result.ExitCode | Should -Be 0
            $fake.Calls | Should -Contain '--install --no-distribution'
            $fake.Calls | Should -Not -Contain '--update'
            $result.State.restartPending | Should -BeTrue
            @($result.State._restartRequired) | Should -HaveCount 1
            Should -Invoke Write-ResourceMessage -ParameterFilter { $Level -eq 'warn' -and $Text -like '*restart pending*' }
        }

        It 'accepts 3010 from wsl.exe' {
            $fake.InstallExit = 3010
            (Invoke-Wsl set).ExitCode | Should -Be 0
        }

        It 'accepts 1641, a restart wsl.exe has already started, with a warning' {
            $fake.InstallExit = 1641
            (Invoke-Wsl set).ExitCode | Should -Be 0
            Should -Invoke Write-ResourceMessage -ParameterFilter { $Level -eq 'warn' -and $Text -like '*has started a restart*' }
        }

        It 'fails on any other exit code from wsl.exe' {
            $fake.InstallExit = 1
            (Invoke-Wsl set).ExitCode | Should -Be 2
            Should -Invoke Write-ResourceMessage -ParameterFilter { $Level -eq 'error' -and $Text -like '*exited with code 1' }
        }

        It 'puts what wsl.exe printed, without the NULs of its UTF-16 output, in the error' {
            Mock Start-WslConsole {
                [IO.File]::WriteAllText($OutFile, "T`0h`0e`0 `0r`0e`0a`0s`0o`0n`0`r`n`r`nsee the link`r`n")
                1
            }
            (Invoke-Wsl set).ExitCode | Should -Be 2
            Should -Invoke Write-ResourceMessage -ParameterFilter { $Level -eq 'error' -and $Text -like '*code 1: The reason | see the link' }
        }

        It 'updates a WSL older than 2.4.4, without installing' {
            $fake.Version = '2.3.26'; $fake.Vmp = 1
            (Invoke-Wsl set).ExitCode | Should -Be 0
            $fake.Calls | Should -Contain '--update'
            $fake.Calls | Should -Not -Contain '--install --no-distribution'
        }

        It 'updates an old WSL and enables the feature when both are needed' {
            $fake.Version = '2.3.26'; $fake.Vmp = 2
            (Invoke-Wsl set).ExitCode | Should -Be 0
            $fake.Calls | Should -Be '--update', '--install --no-distribution'
        }

        It 'writes what it ran and its exit code to the run log' {
            $fake.Version = '2.3.26'; $fake.Vmp = 1
            (Invoke-Wsl set).ExitCode | Should -Be 0
            Should -Invoke Write-WinfilesLog -ParameterFilter { $Phase -eq 'wsl' -and $Message -eq 'running wsl.exe --update' }
            Should -Invoke Write-WinfilesLog -ParameterFilter { $Phase -eq 'wsl' -and $Message -eq 'wsl.exe --update exited with code 0' }
        }

        It 'writes each non-blank line wsl.exe printed to the run log, without NULs, and logs a failure too' {
            $fake.Version = '2.3.26'; $fake.Vmp = 1
            Mock Start-WslConsole {
                [IO.File]::WriteAllText($OutFile, "C`0h`0e`0c`0k`0i`0n`0g`0`r`n`r`nUpdating to 3.0.5.`r`n")
                1
            }
            (Invoke-Wsl set).ExitCode | Should -Be 2
            Should -Invoke Write-WinfilesLog -Times 1 -Exactly -ParameterFilter { $Phase -eq 'wsl' -and $Message -eq 'wsl.exe: Checking' }
            Should -Invoke Write-WinfilesLog -Times 1 -Exactly -ParameterFilter { $Phase -eq 'wsl' -and $Message -eq 'wsl.exe: Updating to 3.0.5.' }
            Should -Invoke Write-WinfilesLog -Times 1 -Exactly -ParameterFilter { $Phase -eq 'wsl' -and $Message -eq 'wsl.exe --update exited with code 1' }
            # Two output lines, the command and the exit code: the blank line isn't logged
            Should -Invoke Write-WinfilesLog -Times 4 -Exactly
        }

        It 'does not install when the update fails' {
            $fake.Version = '2.3.26'; $fake.Vmp = 2; $fake.UpdateExit = 1
            (Invoke-Wsl set).ExitCode | Should -Be 2
            $fake.Calls | Should -Be '--update'
        }

        It 'fails, without running wsl.exe, when it is not elevated' {
            $fake.Elevated = $false
            (Invoke-Wsl set).ExitCode | Should -Be 2
            $fake.Calls | Should -BeNullOrEmpty
            Should -Invoke Write-ResourceMessage -ParameterFilter { $Level -eq 'error' -and $Text -like '*needs elevation*' }
        }

        It 'does not need elevation when there is nothing to do' {
            $fake.Elevated = $false; $fake.Version = '2.6.1'; $fake.Vmp = 1
            (Invoke-Wsl set).ExitCode | Should -Be 0
        }

        It 'fails, rather than asking for another restart, when WSL still is not ready and none is pending' {
            $fake.InstallRestarts = $false; $fake.UpdateWorks = $false
            Mock Start-WslConsole { $fake.Calls += , ($WslArgs -join ' '); 0 }
            (Invoke-Wsl set).ExitCode | Should -Be 2
            Should -Invoke Write-ResourceMessage -ParameterFilter { $Level -eq 'error' -and $Text -like "*still isn't ready*" }
        }

        It 'fails when WSL is ready but no hypervisor is running' {
            $fake.Version = '2.6.1'; $fake.Vmp = 1; $fake.Hypervisor = $false
            (Invoke-Wsl set).ExitCode | Should -Be 2
            Should -Invoke Write-ResourceMessage -ParameterFilter { $Level -eq 'error' -and $Text -like '*no hypervisor*' }
        }

        It 'does not judge the hypervisor while a restart is pending, since it starts at boot' {
            $fake.Version = '2.6.1'; $fake.Vmp = 1; $fake.Hypervisor = $false; $fake.Pending = $true
            (Invoke-Wsl set).ExitCode | Should -Be 0
        }
    }
}