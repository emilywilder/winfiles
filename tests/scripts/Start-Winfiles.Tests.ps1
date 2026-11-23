# Start-Winfiles.ps1 for real, under Windows PowerShell 5.1 as install.cmd runs it, with mise from this
# machine, and the repo's winfiles.ps1. Which commands winfiles.ps1 has is its own tests' business
# (Commands.Tests.ps1), and what Invoke-Clean.ps1 does to the environment is tested in its own file: this checks
# the way in. `hosts` is the command that runs, since it only lists files, and a name that isn't a command gives
# a usage error, exit code 2. Not covered: a missing mise, since the registry's PATH can't be faked
BeforeAll {
    . (Join-Path $PSScriptRoot '..\resources\Resource.ps1')
    $script = Join-Path $repo 'scripts\Start-Winfiles.ps1'
    # A PATH with Windows PowerShell and no mise, like a terminal opened before the bootstrap installed mise
    $system32 = Join-Path $env:SystemRoot 'System32'
    $stalePath = "$system32;$(Join-Path $system32 'WindowsPowerShell\v1.0')"

    function Start-Winfiles([string[]]$Arguments, [hashtable]$Environment = @{ PATH = $stalePath }) {
        Invoke-Child $repo $Environment {
            powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script @Arguments
        }
    }
}

Describe 'Start-Winfiles.ps1' {
    It ('finds mise from the registry''s PATH when the caller''s has none, ' +
        'and runs winfiles.ps1 with the arguments it was given') {
        $result = Start-Winfiles 'hosts'
        $result.ExitCode | Should -Be 0
        $result.Stdout | Should -Contain 'vm-quick.system'
    }

    It "exits with winfiles.ps1's exit code" {
        $result = Start-Winfiles 'no-such-command'
        $result.ExitCode | Should -Be 2
        $result.Stderr -join "`n" | Should -BeLike "*There's no command named 'no-such-command'*"
    }

    # 5.1 mangles double quotes, so only spaces, apostrophes and $ are expected to survive
    It 'passes on arguments with spaces, apostrophes and $ intact' {
        $result = Start-Winfiles "it's two words", '$HOME'
        $result.ExitCode | Should -Be 2
        $result.Stderr -join "`n" | Should -BeLike "*There's no command named 'it's two words'*"
    }

    # A mise.local.toml beside mise.toml would add its env to every run, so both scripts ignore it
    It 'ignores mise configuration other than the repo''s mise.toml, and says so' {
        $local = Join-Path $repo 'mise.local.toml'
        if (Test-Path $local) {
            Set-ItResult -Skipped -Because 'mise.local.toml exists and is not ours to replace'
            return
        }
        try {
            Set-Content $local "[env]`nWINFILES_TEST_LOCAL = 'from mise.local.toml'"
            $result = Start-Winfiles 'hosts'
            $result.ExitCode | Should -Be 0
            $text = ($result.Stdout + $result.Stderr) -join "`n"
            $text | Should -BeLike '*Ignoring mise configuration*mise.local.toml*'
        } finally { Remove-Item $local -ErrorAction SilentlyContinue }
    }
}
