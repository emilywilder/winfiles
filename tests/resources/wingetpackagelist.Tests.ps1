BeforeAll {
    . (Join-Path $PSScriptRoot 'Resource.ps1')
    Assert-FakeWinGetLoads (New-FakeWinGet)

    function Invoke-List($Operation, $Fake, [hashtable]$Instance) {
        Invoke-Resource wingetpackagelist $Operation $Instance $Fake.Environment
    }
}

Describe 'Winfiles/WinGetPackageList' {
    Context 'test' {
        It 'is in the desired state when every package is installed' {
            $fake = New-FakeWinGet -Installed A.One, B.Two
            $result = Invoke-List test $fake @{ packages = @('A.One', 'B.Two') }
            $result.ExitCode | Should -Be 0
            $result.State._inDesiredState | Should -BeTrue
            $result.State.missing | Should -BeNullOrEmpty
        }

        It 'lists a missing package' {
            $fake = New-FakeWinGet -Installed A.One
            $result = Invoke-List test $fake @{ packages = @('A.One', 'B.Two') }
            $result.State._inDesiredState | Should -BeFalse
            $result.State.missing | Should -Be @('B.Two')
        }

        It "doesn't count a package installed from another source" {
            $fake = New-FakeWinGet -Other A.One
            $result = Invoke-List test $fake @{ packages = @('A.One') }
            $result.State.missing | Should -Be @('A.One')
        }

        It 'installs nothing' {
            $fake = New-FakeWinGet
            Invoke-List test $fake @{ packages = @('A.One') } | Out-Null
            (Get-FakeWinGetState $fake).installs | Should -BeNullOrEmpty
        }
    }

    Context 'set' {
        It 'installs only what is missing, in order, with progress shown at warn' {
            $fake = New-FakeWinGet -Installed A.One
            $result = Invoke-List set $fake @{ packages = @('A.One', 'B.Two', 'C.Three') }
            $result.ExitCode | Should -Be 0
            $result.State.missing | Should -BeNullOrEmpty
            (Get-FakeWinGetState $fake).installs.Id | Should -Be @('B.Two', 'C.Three')
            ($result.Messages | Where-Object Level -eq warn).Text | Should -Be @('Installing B.Two (1/2)', 'Installing C.Three (2/2)')
        }

        # A single failure used to stop the whole list, and DSC stops the whole configuration on a non-zero exit
        It 'carries on past a package that fails, and still exits 0' {
            $fake = New-FakeWinGet -Failing B.Two
            $result = Invoke-List set $fake @{ packages = @('A.One', 'B.Two', 'C.Three') }
            $result.ExitCode | Should -Be 0
            (Get-FakeWinGetState $fake).installs.Id | Should -Be @('A.One', 'B.Two', 'C.Three')
            $result.State.missing | Should -Be @('B.Two')
            ($result.Messages | Where-Object Level -eq error).Text | Should -BeLike 'Failed to install B.Two: InstallError *fake installer failure'
        }

        It 'carries on past an id that throws' {
            $fake = New-FakeWinGet -Unknown A.One
            $result = Invoke-List set $fake @{ packages = @('A.One', 'B.Two') }
            $result.ExitCode | Should -Be 0
            $result.State.missing | Should -Be @('A.One')
            ($result.Messages | Where-Object Level -eq error).Text | Should -BeLike 'Failed to install A.One: No packages found*'
        }

        It 'passes the scope on to winget' {
            $fake = New-FakeWinGet
            $result = Invoke-List set $fake @{ packages = @('A.One'); scope = 'User' }
            (Get-FakeWinGetState $fake).installs[0].Scope | Should -Be 'User'
            $result.State.scope | Should -Be 'User'
        }

        It 'installs from the winget source, matching the id exactly and silently' {
            $fake = New-FakeWinGet
            Invoke-List set $fake @{ packages = @('A.One') } | Out-Null
            $install = (Get-FakeWinGetState $fake).installs[0]
            $install.Source | Should -Be 'winget'
            $install.MatchOption | Should -Be 'Equals'
            $install.Mode | Should -Be 'Silent'
            $install.Scope | Should -BeNullOrEmpty
        }
    }

    It 'reports an error that escapes the script, and exits 1' {
        $fake = New-FakeWinGet
        $fake.Environment.WINFILES_FAKE_WINGET = Join-Path $TestDrive 'no-such-file.json'
        $result = Invoke-List get $fake @{ packages = @('A.One') }
        $result.ExitCode | Should -Be 1
        $result.Messages.Level | Should -Be @('error')
    }
}
