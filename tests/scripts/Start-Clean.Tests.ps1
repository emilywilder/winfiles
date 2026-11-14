# Start-Clean.ps1 for real, under Windows PowerShell 5.1 as install.cmd runs it, with mise from this machine. What it
# starts is Invoke-Clean.ps1's business (tested in its own file). Not covered: a missing mise, since the registry's PATH
# can't be faked
BeforeAll {
    . (Join-Path $PSScriptRoot '..\resources\Resource.ps1')
    $script = Join-Path $repo 'scripts\Start-Clean.ps1'
    # A PATH with Windows PowerShell and no mise, like a terminal opened before the bootstrap installed mise
    $system32 = Join-Path $env:SystemRoot 'System32'
    $stalePath = "$system32;$(Join-Path $system32 'WindowsPowerShell\v1.0')"

    function Start-Clean([string]$Command, [hashtable]$Environment = @{}) {
        Invoke-Child $repo $Environment {
            powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script pwsh -NoLogo -NoProfile -NonInteractive -Command $Command
        }
    }
}

Describe 'Start-Clean.ps1' {
    It 'finds mise from the registry''s PATH when the caller''s has none, and runs the command under mise''s pwsh' {
        $result = Start-Clean '(Get-Process -Id $PID).Path' @{ PATH = $stalePath }
        $result.ExitCode | Should -Be 0
        $result.Stdout[-1] | Should -Be (mise which pwsh)
    }

    It "leaves out a variable set only in the caller" {
        $result = Start-Clean '(''['' + $env:WINFILES_TEST_CALLER + '']'')' @{ PATH = $stalePath; WINFILES_TEST_CALLER = 'from the caller' }
        $result.ExitCode | Should -Be 0
        $result.Stdout[-1] | Should -Be '[]'
    }

    It "exits with the command's exit code" {
        (Start-Clean 'exit 7' @{ PATH = $stalePath }).ExitCode | Should -Be 7
    }
}
