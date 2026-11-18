# Invoke-AsUser.ps1 and Invoke-AsAdmin.ps1 are mirror images, so one set of tests runs against both. Whether the process
# is elevated is given with WINFILES_ELEVATED, and the gsudo is a fake (tests/fakes/bin/gsudo.cmd) that records its arguments
# and runs nothing, so no test elevates or changes the machine. run.log goes under a USERPROFILE in TestDrive, never the
# real one.
BeforeAll {
    . (Join-Path $PSScriptRoot '..\resources\Resource.ps1')

    # $Elevated is what the script is told about itself; $Command is what it was asked to run
    function Invoke-As([string]$Script, [bool]$Elevated, [string[]]$Command, [int]$FakeExit = 0, [string]$Gsudo) {
        $bin = New-Item -ItemType Directory (Join-Path $TestDrive "gsudo-$([guid]::NewGuid())")
        Copy-Item (Join-Path $fakes 'bin\gsudo.cmd'), (Join-Path $fakes 'bin\fake-gsudo.ps1') $bin
        $record = Join-Path $bin 'arguments.txt'
        $userProfile = New-Item -ItemType Directory "$bin-home"
        if (-not $Gsudo) { $Gsudo = Join-Path $bin 'gsudo.cmd' }
        # The fake is also first on PATH, so a script that ignored WINFILES_GSUDO would still not reach the real gsudo,
        # which would ask for UAC and run the command elevated on the machine
        $result = Invoke-Script $Script -Arguments $Command -Environment @{
            PATH                = "$($bin.FullName);$env:PATH"
            WINFILES_ELEVATED   = "$Elevated".ToLower()
            WINFILES_GSUDO      = $Gsudo
            WINFILES_FAKE_GSUDO = $record
            FAKE_EXIT           = "$FakeExit"
            USERPROFILE         = $userProfile.FullName
        }
        $log = Join-Path $userProfile '.local\state\winfiles\run.log'
        $result | Add-Member GsudoArguments @(if (Test-Path $record) { Get-Content $record }) -PassThru |
            Add-Member Log @(if (Test-Path $log) { Get-Content $log }) -PassThru
    }
}

# $NeedsChange is whether the process is elevated in a case where the script has to change privilege, and $Already the
# other case, where the privilege is already right
Describe '<Script>' -ForEach @(
    @{ Script = 'Invoke-AsUser.ps1'; NeedsChange = $true; Already = $false; GsudoStart = @('-i', 'Medium', '--direct'); LogLines = 1 }
    @{ Script = 'Invoke-AsAdmin.ps1'; NeedsChange = $false; Already = $true; GsudoStart = @('--direct'); LogLines = 2 }
) {
    It 'runs the command itself when the privilege is already right, and passes its output and exit code back' {
        $result = Invoke-As $Script $Already @('pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', 'Write-Output hello; exit 5')
        $result.ExitCode | Should -Be 5
        $result.Stdout | Should -Contain 'hello'
        $result.GsudoArguments | Should -BeNullOrEmpty
        $result.Log | Should -BeNullOrEmpty
    }

    It 'runs the command under gsudo and mise when the privilege has to change, and passes its exit code back' {
        $result = Invoke-As $Script $NeedsChange @('pwsh', '-NoLogo', '-File', './scripts/Set-System.ps1', 'iris') -FakeExit 7
        $result.ExitCode | Should -Be 7
        $result.GsudoArguments | Should -Contain 'mise'
        $result.GsudoArguments | Should -Contain 'exec'
        $result.GsudoArguments[0..($GsudoStart.Count - 1)] | Should -Be $GsudoStart
        # The command comes last, in order
        $result.GsudoArguments[-5..-1] | Should -Be @('pwsh', '-NoLogo', '-File', './scripts/Set-System.ps1', 'iris')
    }

    It 'notes in the run log that it changed privilege' {
        $result = Invoke-As $Script $NeedsChange @('pwsh', '-File', 'x.ps1')
        $result.Log | Should -HaveCount $LogLines
        $result.Log[0] | Should -Match '\[privilege\] running (elevated|unelevated) through gsudo.*: pwsh -File x\.ps1$'
    }

    It 'says in the run log that it asked for UAC, and what gsudo returned, when it raises privilege' -Skip:($Script -ne 'Invoke-AsAdmin.ps1') {
        $result = Invoke-As $Script $NeedsChange @('pwsh', '-File', 'x.ps1') -FakeExit 7
        $result.Log[0] | Should -Match 'asking for UAC'
        $result.Log[1] | Should -Match '\[privilege\] gsudo returned exit code 7 after \d+s$'
    }

    It 'says so and exits 1 when gsudo is needed and missing' {
        $result = Invoke-As $Script $NeedsChange @('pwsh', '-File', 'x.ps1') -Gsudo 'gsudo-that-does-not-exist'
        $result.ExitCode | Should -Be 1
        $result.Stderr -join ' ' | Should -Match "gsudo-that-does-not-exist isn't on PATH"
        $result.Log[-1] | Should -Match "\[privilege\] .*isn't on PATH"
    }

    It 'passes a command''s own dash arguments on, even ones that look like PowerShell''s common parameters' {
        $echo = Join-Path $TestDrive 'echo.ps1'
        Set-Content $echo '$args -join '' '''
        $result = Invoke-As $Script $Already @('pwsh', '-NoLogo', '-NoProfile', '-File', $echo, '-Out', 'x', '-Verbose')
        $result.ExitCode | Should -Be 0
        $result.Stdout | Should -Contain '-Out x -Verbose'
    }

    It 'needs a command' {
        $result = Invoke-As $Script $Already @()
        $result.ExitCode | Should -Be 2
        $result.Stderr -join ' ' | Should -Match 'needs a command'
    }
}
