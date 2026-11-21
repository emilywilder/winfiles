# Winfiles.WinGet/Package runs as DSC runs it, against the fake winget CLI (tests/fakes/bin/winget.cmd), which answers
# `winget dscv3 package` from a list of installed ids, as winget 1.29.380 does. So these cover what the wrapper does
# around winget: _scope kept from winget dscv3, and `winget install --scope` only when set has a missing package to
# install. Each test starts a child pwsh, which starts a pwsh per fake winget call.
BeforeAll {
    . (Join-Path $PSScriptRoot 'Resource.ps1')
    Assert-FakeWinGetCliRuns (New-FakeWinGetCli)

    function Invoke-Package($Fake, $Operation, [hashtable]$Instance) {
        $run = Invoke-Resource wingetpackage $Operation $Instance -Environment $Fake.Environment
        $run | Add-Member StateLine ($run.Stdout | Select-Object -First 1 | ConvertFrom-Json)
        $run | Add-Member DiffLine ($run.Stdout | Select-Object -Skip 1 -First 1)
        $run
    }

    function Get-RunLog($Fake) {
        $log = Join-Path $Fake.Home '.local\state\winfiles\run.log'
        if (Test-Path $log) { (Get-Content $log) -join "`n" } else { '' }
    }

    $script:options = '--disable-interactivity --source winget --silent'
}

Describe 'Winfiles.WinGet/Package' {
    Context 'get and test' {
        It 'passes the instance to winget dscv3 without _scope, and adds _scope to its state' {
            $fake = New-FakeWinGetCli -Installed GitHub.cli
            $run = Invoke-Package $fake get @{ id = 'GitHub.cli'; source = 'winget'; _scope = 'User' }
            $run.ExitCode | Should -Be 0
            $run.Stdout | Should -HaveCount 1
            $run.StateLine._exist | Should -BeTrue
            $run.StateLine._scope | Should -Be 'User'
            $sent = Get-FakeWinGetCliDscInput $fake
            $sent.id | Should -Be 'GitHub.cli'
            $sent.PSObject.Properties.Name | Should -Not -Contain '_scope'
            Get-FakeWinGetCliCalls $fake | Should -Be @('dscv3 package --get')
        }

        It "passes test's state and differing properties through" {
            $fake = New-FakeWinGetCli
            $run = Invoke-Package $fake test @{ id = 'GitHub.cli'; source = 'winget'; _scope = 'User' }
            $run.ExitCode | Should -Be 0
            $run.StateLine._inDesiredState | Should -BeFalse
            $run.StateLine._scope | Should -Be 'User'
            $run.DiffLine | Should -Be '["_exist"]'
            Get-FakeWinGetCliCalls $fake | Should -Be @('dscv3 package --test')
        }

        It 'adds no _scope when none is given' {
            $fake = New-FakeWinGetCli -Installed GitHub.cli
            $run = Invoke-Package $fake test @{ id = 'GitHub.cli'; source = 'winget' }
            $run.StateLine._inDesiredState | Should -BeTrue
            $run.StateLine.PSObject.Properties.Name | Should -Not -Contain '_scope'
            $run.DiffLine | Should -Be '[]'
        }
    }

    Context 'set' {
        It 'installs a missing package with winget install --scope, then runs winget dscv3 set' {
            $fake = New-FakeWinGetCli
            $run = Invoke-Package $fake set @{ id = 'GitHub.cli'; source = 'winget'; _scope = 'User' }
            $run.ExitCode | Should -Be 0
            $run.StateLine._exist | Should -BeTrue
            $run.StateLine._scope | Should -Be 'User'
            # winget dscv3 set found it already installed and changed nothing, but this set installed it
            $run.DiffLine | Should -Be '["_exist"]'
            Get-FakeWinGetCliCalls $fake | Should -Be @(
                'dscv3 package --get'
                "install --id GitHub.cli --exact --scope user $options"
                'dscv3 package --set'
            )
            (Get-FakeWinGetCliDscInput $fake)[-1].PSObject.Properties.Name | Should -Not -Contain '_scope'
        }

        It 'maps Machine, version, installMode and acceptAgreements to the install' {
            $fake = New-FakeWinGetCli
            $instance = @{
                id = 'GitHub.cli'; _scope = 'Machine'; version = '2.104.0'; installMode = 'interactive'
                acceptAgreements = $true
            }
            (Invoke-Package $fake set $instance).ExitCode | Should -Be 0
            (Get-FakeWinGetCliCalls $fake)[1] |
                Should -Be ('install --id GitHub.cli --exact --scope machine --disable-interactivity ' +
                    '--version 2.104.0 --interactive --accept-package-agreements --accept-source-agreements')
        }

        It "doesn't install a package that is already installed" {
            $fake = New-FakeWinGetCli -Installed GitHub.cli
            $run = Invoke-Package $fake set @{ id = 'GitHub.cli'; source = 'winget'; _scope = 'User' }
            $run.ExitCode | Should -Be 0
            $run.DiffLine | Should -Be '[]'
            Get-FakeWinGetCliCalls $fake | Should -Be @('dscv3 package --get', 'dscv3 package --set')
        }

        It 'leaves the install to winget dscv3 without _scope' {
            $fake = New-FakeWinGetCli
            $run = Invoke-Package $fake set @{ id = 'GitHub.cli'; source = 'winget' }
            $run.StateLine._exist | Should -BeTrue
            $run.DiffLine | Should -Be '["_exist"]'
            Get-FakeWinGetCliCalls $fake | Should -Be @('dscv3 package --set')
        }

        It 'leaves an uninstall (_exist false) to winget dscv3' {
            $fake = New-FakeWinGetCli -Installed GitHub.cli
            $run = Invoke-Package $fake set @{ id = 'GitHub.cli'; source = 'winget'; _scope = 'User'; _exist = $false }
            $run.StateLine._exist | Should -BeFalse
            Get-FakeWinGetCliCalls $fake | Should -Be @('dscv3 package --set')
        }

        It 'reports a failed install as an error and exits 2, without running winget dscv3 set' {
            $fake = New-FakeWinGetCli -ExitCode -1978334964
            $run = Invoke-Package $fake set @{ id = 'GitHub.cli'; source = 'winget'; _scope = 'User' }
            $run.ExitCode | Should -Be 2
            $run.Messages.Level | Should -Be 'error'
            $run.Messages.Text | Should -BeLike 'winget install --scope user GitHub.cli failed (0x8A15010C)*'
            Get-FakeWinGetCliCalls $fake | Should -Not -Contain 'dscv3 package --set'
            # The run log has it too, as DSC prints a resource's messages to the console only
            Get-RunLog $fake | Should -BeLike '*[[]winget] winget install --scope user GitHub.cli failed (0x8A15010C)*'
        }

        It 'reports a failed get before the install as an error, in the run log too, and exits with winget''s code' {
            $fake = New-FakeWinGetCli -GetExitCode -2147020496
            $run = Invoke-Package $fake set @{ id = 'GitHub.cli'; source = 'winget'; _scope = 'User' }
            $run.ExitCode | Should -Be -2147020496
            $run.Messages.Text | Should -Be 'winget dscv3 package --get GitHub.cli failed (0x80071130)'
            Get-RunLog $fake | Should -BeLike '*[[]winget] winget dscv3 package --get GitHub.cli failed (0x80071130)*'
            Get-FakeWinGetCliCalls $fake | Should -Be @('dscv3 package --get')
        }

        It 'reports a failed winget dscv3 set, with no _scope, as an error, in the run log too' {
            $fake = New-FakeWinGetCli -ExitCode -1978334964
            $run = Invoke-Package $fake set @{ id = 'GitHub.cli'; source = 'winget' }
            $run.ExitCode | Should -Be -1978334964
            $run.Messages.Text | Should -Be 'winget dscv3 package --set GitHub.cli failed (0x8A15010C)'
            Get-RunLog $fake | Should -BeLike '*[[]winget] winget dscv3 package --set GitHub.cli failed (0x8A15010C)*'
        }

        It 'refuses a matchOption that --exact would not honour, and exits 1' {
            $fake = New-FakeWinGetCli
            $run = Invoke-Package $fake set @{
                id = 'GitHub'; _scope = 'User'; matchOption = 'startsWithCaseInsensitive'
            }
            $run.ExitCode | Should -Be 1
            $run.Messages.Text | Should -BeLike '_scope needs matchOption equals*'
            Get-FakeWinGetCliCalls $fake | Should -Not -Contain 'dscv3 package --set'
        }
    }
}
