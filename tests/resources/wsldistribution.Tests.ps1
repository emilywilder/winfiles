# Winfiles/WslDistribution names its registry keys, CIM class and wsl.exe itself, so it runs in this process with
# mocks (Invoke-ResourceScript). The fake machine is still real where it can be: both registry keys are redirected
# to Pester's TestRegistry:, where the fake wsl.exe registers what it installs, and sources are files in TestDrive:.
# Pester 6 has no fallthrough for a mock whose filters don't match, so the registry mocks are defaults that rewrite
# the path and call the cmdlet itself through its CommandInfo, which a mock can't intercept.
BeforeAll {
    . (Join-Path $PSScriptRoot 'Resource.ps1')

    # A stand-in to mock: the script defines the real one when it dot-sources common.ps1, and the mock still wins
    function Write-ResourceMessage([string]$Level, [string]$Text) {}

    $script:distro = Join-Path $TestDrive 'nixos.wsl'
    Set-Content $distro 'not really a distribution'
    $script:distroHash = (Get-FileHash $distro -Algorithm SHA256).Hash

    function ConvertTo-FakePath([string[]]$Path) {
        $Path -replace '^HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Lxss', 'TestRegistry:\Lxss' `
            -replace '^HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Component Based Servicing\\RebootPending',
            'TestRegistry:\RebootPending'
    }

    # How WSL registers a distribution: a key per distribution under Lxss, and the default's key name on Lxss itself
    function Add-FakeRegistration([string]$Name, [string]$BasePath = "C:\fake\$Name", [switch]$Default) {
        if (-not (Test-Path TestRegistry:\Lxss)) { New-Item TestRegistry:\Lxss | Out-Null }
        $key = New-Item "TestRegistry:\Lxss\{$([guid]::NewGuid())}"
        New-ItemProperty $key.PSPath -Name DistributionName -Value $Name | Out-Null
        New-ItemProperty $key.PSPath -Name BasePath -Value $BasePath | Out-Null
        if ($Default) { Set-ItemProperty TestRegistry:\Lxss -Name DefaultDistribution -Value $key.PSChildName }
    }

    # A WSL 2.6.1 whose --install registers the distribution and --set-default changes the default
    function Invoke-FakeWsl {
        $global:LASTEXITCODE = 0
        switch ($args[0]) {
            '--version' { 'WSL version: 2.6.1.0'; 'Kernel version: 6.6.87.2-1' }
            '--install' {
                $name = $args[[array]::IndexOf($args, '--name') + 1]
                $location = if ($args -contains '--location') { $args[[array]::IndexOf($args, '--location') + 1] }
                Add-FakeRegistration $name -BasePath ($location ?? "C:\fake\$name")
            }
            '--set-default' {
                $name = $args[1]
                $key = Get-ChildItem TestRegistry:\Lxss | Where-Object { $_.GetValue('DistributionName') -eq $name }
                Set-ItemProperty TestRegistry:\Lxss -Name DefaultDistribution -Value $key.PSChildName
            }
        }
    }

    function Invoke-Wsl($Operation, [hashtable]$Instance) {
        Invoke-ResourceScript wsldistribution $Operation $Instance
    }
}

Describe 'Winfiles/WslDistribution' {
    BeforeEach {
        foreach ($key in 'TestRegistry:\Lxss', 'TestRegistry:\RebootPending') {
            if (Test-Path $key) { Remove-Item $key -Recurse }
        }
        Mock Write-ResourceMessage {}
        Mock wsl.exe { Invoke-FakeWsl @args }
        Mock Get-CimInstance { [pscustomobject]@{ Name = 'VirtualMachinePlatform'; InstallState = 1 } }
        # A mock body can't tell which command it stands in for, so each one has the name written into it
        foreach ($cmdlet in 'Test-Path', 'Get-ItemProperty', 'Get-ChildItem') {
            Mock $cmdlet ([scriptblock]::Create(@"
                `$parameters = @{} + `$PesterBoundParameters
                if (`$parameters.Path) { `$parameters.Path = ConvertTo-FakePath `$parameters.Path }
                & (Get-Command $cmdlet -CommandType Cmdlet) @parameters
"@))
        }
    }

    Context 'test' {
        It 'is in the desired state when the distribution is installed and the default' {
            Add-FakeRegistration NixOS -BasePath C:\wsl\NixOS -Default
            $result = Invoke-Wsl test @{ name = 'NixOS'; default = $true }
            $result.ExitCode | Should -Be 0
            $result.State._inDesiredState | Should -BeTrue
            $result.State.isDefault | Should -BeTrue
            $result.State.basePath | Should -Be 'C:\wsl\NixOS'
        }

        It "isn't when another distribution is the default" {
            Add-FakeRegistration Ubuntu -Default
            Add-FakeRegistration NixOS
            $result = Invoke-Wsl test @{ name = 'NixOS'; default = $true }
            $result.State.installed | Should -BeTrue
            $result.State.isDefault | Should -BeFalse
            $result.State._inDesiredState | Should -BeFalse
        }

        It "is when it needn't be the default" {
            Add-FakeRegistration Ubuntu -Default
            Add-FakeRegistration NixOS
            (Invoke-Wsl test @{ name = 'NixOS' }).State._inDesiredState | Should -BeTrue
        }

        It "isn't when the distribution isn't installed, or WSL has never registered one" {
            $result = Invoke-Wsl test @{ name = 'NixOS' }
            $result.State.installed | Should -BeFalse
            $result.State._inDesiredState | Should -BeFalse

            Add-FakeRegistration Ubuntu
            (Invoke-Wsl test @{ name = 'NixOS' }).State._inDesiredState | Should -BeFalse
        }

        # The schema doesn't allow null for them
        It 'echoes optional properties only when they are given' {
            $result = Invoke-Wsl test @{ name = 'NixOS' }
            $result.State.PSObject.Properties.Name | Should -Not -Contain 'source'
            $result.State.PSObject.Properties.Name | Should -Not -Contain 'sha256'
            $result.State.PSObject.Properties.Name | Should -Not -Contain 'location'
        }

        It "doesn't run wsl.exe or check the prerequisites" {
            Invoke-Wsl test @{ name = 'NixOS'; source = $distro } | Out-Null
            Should -Invoke wsl.exe -Times 0 -Exactly
            Should -Invoke Get-CimInstance -Times 0 -Exactly
        }
    }

    Context 'set, prerequisites' {
        It 'exits 3 when Virtual Machine Platform is not enabled' {
            Mock Get-CimInstance { [pscustomobject]@{ Name = 'VirtualMachinePlatform'; InstallState = 2 } }
            (Invoke-Wsl set @{ name = 'NixOS'; source = $distro }).ExitCode | Should -Be 3
            Should -Invoke Write-ResourceMessage -ParameterFilter { $Level -eq 'error' -and $Text -like 'Virtual Machine Platform is not enabled*' }
            Should -Invoke wsl.exe -Times 0 -Exactly
        }

        It 'exits 3 while a restart is pending' {
            New-Item TestRegistry:\RebootPending | Out-Null
            (Invoke-Wsl set @{ name = 'NixOS'; source = $distro }).ExitCode | Should -Be 3
            Should -Invoke Write-ResourceMessage -ParameterFilter { $Level -eq 'error' -and $Text -like 'Windows has a restart pending*' }
        }

        It 'exits 3 with the inbox WSL, which has no --version' {
            Mock wsl.exe { $global:LASTEXITCODE = -1; 'Usage: wsl.exe [Argument] [Options...] [CommandLine]' }
            (Invoke-Wsl set @{ name = 'NixOS'; source = $distro }).ExitCode | Should -Be 3
            Should -Invoke Write-ResourceMessage -ParameterFilter { $Level -eq 'error' -and $Text -like 'The inbox WSL is too old*' }
        }

        It 'exits 3 with a WSL older than 2.4.4, reading a localized version line' {
            Mock wsl.exe { $global:LASTEXITCODE = 0; 'WSL-Version: 2.4.3.0' }
            (Invoke-Wsl set @{ name = 'NixOS'; source = $distro }).ExitCode | Should -Be 3
            Should -Invoke Write-ResourceMessage -ParameterFilter { $Level -eq 'error' -and $Text -like 'WSL 2.4.3 is too old*' }
            Should -Invoke wsl.exe -Times 1 -Exactly
        }

        It "doesn't check them when the distribution is already installed" {
            Mock Get-CimInstance { [pscustomobject]@{ Name = 'VirtualMachinePlatform'; InstallState = 2 } }
            Add-FakeRegistration Ubuntu -Default
            Add-FakeRegistration NixOS
            $result = Invoke-Wsl set @{ name = 'NixOS'; default = $true }
            $result.ExitCode | Should -Be 0
            $result.State.isDefault | Should -BeTrue
            Should -Invoke Get-CimInstance -Times 0 -Exactly
        }
    }

    Context 'set' {
        It 'installs from a local file, then makes it the default' {
            $result = Invoke-Wsl set @{ name = 'NixOS'; source = $distro; sha256 = $distroHash; default = $true }
            $result.ExitCode | Should -Be 0
            $result.State.installed | Should -BeTrue
            $result.State.isDefault | Should -BeTrue
            Should -Invoke wsl.exe -Times 1 -Exactly -ParameterFilter {
                ($args -join ' ') -eq "--install --from-file $distro --name NixOS --no-launch"
            }
            Should -Invoke wsl.exe -Times 1 -Exactly -ParameterFilter { ($args -join ' ') -eq '--set-default NixOS' }
        }

        It 'expands variables in the source and location' {
            $env:WINFILES_TEST_DIR = $TestDrive
            try {
                $instance = @{ name = 'NixOS'; source = '%WINFILES_TEST_DIR%\nixos.wsl'; location = '%WINFILES_TEST_DIR%\NixOS' }
                $result = Invoke-Wsl set $instance
            } finally {
                $env:WINFILES_TEST_DIR = $null
            }
            $result.State.basePath | Should -Be "$TestDrive\NixOS"
            $result.State.source | Should -Be '%WINFILES_TEST_DIR%\nixos.wsl'
        }

        It 'refuses a file whose SHA256 differs, and exits 1' {
            $result = Invoke-Wsl set @{ name = 'NixOS'; source = $distro; sha256 = '0' * 64 }
            $result.ExitCode | Should -Be 1
            Should -Invoke Write-ResourceMessage -ParameterFilter { $Level -eq 'error' -and $Text -like 'SHA256 of * is *, expected 000*' }
            Should -Invoke wsl.exe -Times 0 -Exactly -ParameterFilter { $args[0] -eq '--install' }
        }

        It 'downloads a URL to a temporary folder, and removes it afterwards' {
            Mock Invoke-WebRequest { Set-Content $OutFile 'downloaded'; $script:downloadedTo = $OutFile }
            $result = Invoke-Wsl set @{ name = 'NixOS'; source = 'https://example.invalid/releases/nixos.wsl' }
            $result.ExitCode | Should -Be 0
            Should -Invoke wsl.exe -Times 1 -Exactly -ParameterFilter {
                $args[0] -eq '--install' -and $args[1] -eq '--from-file' -and (Split-Path -Leaf $args[2]) -eq 'nixos.wsl' -and
                    -not (Test-Path (Split-Path $args[2]))
            }
        }

        It 'passes a source that is neither a file nor a URL to wsl --install as a name' {
            Invoke-Wsl set @{ name = 'Ubuntu'; source = 'Ubuntu-24.04' } | Out-Null
            Should -Invoke wsl.exe -Times 1 -Exactly -ParameterFilter {
                ($args -join ' ') -eq '--install Ubuntu-24.04 --name Ubuntu --no-launch'
            }
        }

        It 'reports a failed install and exits 2' {
            Mock wsl.exe {
                if ($args[0] -eq '--version') { $global:LASTEXITCODE = 0; 'WSL version: 2.6.1.0' } else { $global:LASTEXITCODE = 1 }
            }
            $result = Invoke-Wsl set @{ name = 'NixOS'; source = $distro; default = $true }
            $result.ExitCode | Should -Be 2
            $result.State.installed | Should -BeFalse
            Should -Invoke Write-ResourceMessage -ParameterFilter { $Level -eq 'error' -and $Text -like "Failed to install NixOS from $distro" }
        }

        It 'reports a failure to change the default and exits 2' {
            Add-FakeRegistration Ubuntu -Default
            Add-FakeRegistration NixOS
            Mock wsl.exe { $global:LASTEXITCODE = 1 }
            $result = Invoke-Wsl set @{ name = 'NixOS'; default = $true }
            $result.ExitCode | Should -Be 2
            $result.State.isDefault | Should -BeFalse
            Should -Invoke Write-ResourceMessage -ParameterFilter { $Level -eq 'error' -and $Text -eq 'Failed to make NixOS the default distribution' }
        }

        It 'does nothing when it is already in the desired state' {
            Add-FakeRegistration NixOS -Default
            (Invoke-Wsl set @{ name = 'NixOS'; source = $distro; default = $true }).ExitCode | Should -Be 0
            Should -Invoke wsl.exe -Times 0 -Exactly
        }

        It 'exits 1 without a source to install from' {
            (Invoke-Wsl set @{ name = 'NixOS' }).ExitCode | Should -Be 1
            Should -Invoke Write-ResourceMessage -ParameterFilter { $Level -eq 'error' -and $Text -eq 'No source to install NixOS from' }
        }
    }
}
