# Winfiles/Scoop runs as DSC runs it. Its installer comes from Start-FakeWebServer, which serves
# tests/fakes/scoop-install.ps1, and installs into a temporary Scoop root that $env:SCOOP points to.
BeforeDiscovery {
    # set refuses to run Scoop's installer elevated, so the tests of installing only mean something unelevated
    $script:elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'Resource.ps1')
    $script:installer = Join-Path $fakes 'scoop-install.ps1'

    # A Scoop root with Scoop installed, or an empty one with -Missing, and a temp folder of its own, so a test can
    # check the resource cleans up after itself. Pass .Environment to Invoke-Resource
    function New-ScoopRoot([switch]$Missing, [hashtable]$Environment = @{}) {
        $root = Join-Path $TestDrive "scoop-$([guid]::NewGuid())"
        $temp = New-Item -ItemType Directory "$root-temp"
        if (-not $Missing) {
            $bin = New-Item -ItemType Directory (Join-Path $root 'apps\scoop\current\bin')
            Set-Content (Join-Path $bin 'scoop.ps1') '# fake Scoop'
        }
        $variables = @{ SCOOP = $root; TMP = $temp.FullName; TEMP = $temp.FullName }
        foreach ($variable in $Environment.Keys) { $variables[$variable] = $Environment[$variable] }
        [pscustomobject]@{
            Path        = $root
            Temp        = $temp.FullName
            Environment = $variables
        }
    }

    function Invoke-Scoop($Operation, $Root, [hashtable]$Instance = @{}) {
        Invoke-Resource scoop $Operation $Instance $Root.Environment
    }
}

Describe 'Winfiles/Scoop' {
    Context 'test' {
        It 'is in the desired state when Scoop is installed' {
            $root = New-ScoopRoot
            $result = Invoke-Scoop test $root
            $result.ExitCode | Should -Be 0
            $result.State._inDesiredState | Should -BeTrue
            $result.State.root | Should -Be $root.Path
            $result.State.installerUrl | Should -Be 'https://get.scoop.sh'
        }

        It "isn't when Scoop is missing" {
            $result = Invoke-Scoop test (New-ScoopRoot -Missing)
            $result.State.installed | Should -BeFalse
            $result.State._inDesiredState | Should -BeFalse
        }

        It "finds the root in Scoop's config when SCOOP isn't set" {
            $config = New-Item -ItemType Directory (Join-Path $TestDrive "config-$([guid]::NewGuid())\scoop")
            @{ root_path = 'D:\elsewhere\scoop' } | ConvertTo-Json | Set-Content (Join-Path $config 'config.json')
            $root = New-ScoopRoot -Environment @{ SCOOP = $null; XDG_CONFIG_HOME = Split-Path $config }
            (Invoke-Scoop test $root).State.root | Should -Be 'D:\elsewhere\scoop'
        }

        It 'falls back to ~\scoop' {
            $root = New-ScoopRoot -Environment @{ SCOOP = $null; XDG_CONFIG_HOME = $TestDrive }
            (Invoke-Scoop test $root).State.root | Should -Be (Join-Path $HOME 'scoop')
        }
    }

    Context 'set' {
        BeforeEach {
            $server = Start-FakeWebServer $installer
        }

        AfterEach {
            Stop-FakeWebServer $server
        }

        It "doesn't download the installer when Scoop is installed" {
            $result = Invoke-Scoop set (New-ScoopRoot) @{ installerUrl = "$($server.Url)/install.ps1" }
            $result.ExitCode | Should -Be 0
            Get-FakeWebRequests $server | Should -BeNullOrEmpty
        }

        It 'downloads and runs the installer, keeping its output off stdout' -Skip:$elevated {
            $root = New-ScoopRoot -Missing
            $result = Invoke-Scoop set $root @{ installerUrl = "$($server.Url)/install.ps1" }
            $result.ExitCode | Should -Be 0
            $result.State.installed | Should -BeTrue
            Get-FakeWebRequests $server | Should -Be @('GET /install.ps1 HTTP/1.1')
            $result.Stderr | Should -Contain 'Scoop was installed successfully!'
            Get-ChildItem $root.Temp | Should -BeNullOrEmpty
        }

        It "carries on past the installer's errors" -Skip:$elevated {
            $root = New-ScoopRoot -Missing -Environment @{ WINFILES_FAKE_SCOOP_INSTALL = 'warn' }
            $result = Invoke-Scoop set $root @{ installerUrl = "$($server.Url)/install.ps1" }
            $result.ExitCode | Should -Be 0
            $result.State.installed | Should -BeTrue
            $result.Stderr | Should -Contain 'A fake problem that the installer carries on past'
        }

        It "exits 2 when the installer finishes but Scoop isn't there" -Skip:$elevated {
            $root = New-ScoopRoot -Missing -Environment @{ WINFILES_FAKE_SCOOP_INSTALL = 'nothing' }
            $result = Invoke-Scoop set $root @{ installerUrl = "$($server.Url)/install.ps1" }
            $result.ExitCode | Should -Be 2
            $result.State.installed | Should -BeFalse
            $result.Messages.Text | Should -Be @("Scoop's installer finished but Scoop isn't at $($root.Path)")
            Get-ChildItem $root.Temp | Should -BeNullOrEmpty
        }

        It 'exits 1 when the download fails, and cleans up' -Skip:$elevated {
            Stop-FakeWebServer $server
            $server = Start-FakeWebServer -Status 404
            $root = New-ScoopRoot -Missing
            $result = Invoke-Scoop set $root @{ installerUrl = "$($server.Url)/install.ps1" }
            $result.ExitCode | Should -Be 1
            $result.Messages.Level | Should -Be @('error')
            Get-ChildItem $root.Temp | Should -BeNullOrEmpty
        }

        It 'refuses to run the installer elevated, and exits 3' -Skip:(-not $elevated) {
            $result = Invoke-Scoop set (New-ScoopRoot -Missing) @{ installerUrl = "$($server.Url)/install.ps1" }
            $result.ExitCode | Should -Be 3
            Get-FakeWebRequests $server | Should -BeNullOrEmpty
        }
    }
}
