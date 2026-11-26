# winfiles.cmd for real, with mise and pwsh from this machine, running only commands that change nothing. What
# Start-Winfiles.ps1 does behind it is in Start-Winfiles.Tests.ps1.
BeforeAll {
    . (Join-Path $PSScriptRoot '..\resources\Resource.ps1')
    $winfilesCmd = Join-Path $repo 'winfiles.cmd'
}

Describe 'winfiles.cmd' {
    It 'runs winfiles.ps1 with its arguments as they are, from any folder' {
        $result = Invoke-Child $TestDrive @{} { & $winfilesCmd hosts }
        $result.ExitCode | Should -Be 0
        $result.Stdout | Should -Contain 'iris.system'
    }

    It 'passes the exit code back' {
        $result = Invoke-Child $TestDrive @{} { & $winfilesCmd no-such-command }
        $result.ExitCode | Should -Be 2
    }

    It 'runs from a terminal with no mise and no pwsh on PATH, as after the bootstrap' {
        $system32 = Join-Path $env:SystemRoot 'System32'
        $path = "$system32;$(Join-Path $system32 'WindowsPowerShell\v1.0')"
        $result = Invoke-Child $TestDrive @{ PATH = $path } { & $winfilesCmd hosts }
        $result.ExitCode | Should -Be 0
        $result.Stdout | Should -Contain 'iris.system'
    }
}
