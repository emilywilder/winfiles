# Invoke-Clean.ps1 runs real commands under the real mise, from the repo, so its children see mise.toml's tools.
# They only print what they were given. Not covered: a missing mise, since the environment comes from the registry
BeforeAll {
    . (Join-Path $PSScriptRoot '..\resources\Resource.ps1')

    # Runs pwsh -Command $Command through Invoke-Clean.ps1, with -Environment set in the caller
    function Invoke-Clean([string]$Command, [hashtable]$Environment = @{}) {
        Invoke-Script Invoke-Clean.ps1 pwsh, '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', $Command -Environment $Environment
    }

    # A script that prints the arguments it got, as JSON
    $printArgs = Join-Path $TestDrive 'Print-Args.ps1'
    Set-Content $printArgs 'ConvertTo-Json -Compress -InputObject @($args)'
}

Describe 'Invoke-Clean.ps1' {
    It "leaves out a variable set only in the caller, and a folder added to the caller's PATH" {
        $result = Invoke-Clean '"$env:WINFILES_TEST_CALLER|$env:PATH"' @{
            WINFILES_TEST_CALLER = 'from the caller'
            PATH                 = "$TestDrive\caller-bin;$env:PATH"
        }
        $result.ExitCode | Should -Be 0
        $variable, $path = $result.Stdout[-1] -split '\|', 2
        $variable | Should -BeNullOrEmpty
        $path | Should -Not -BeLike "*$TestDrive\caller-bin*"
    }

    # The old version kept a list of these and took them from the caller
    It "builds USERNAME and USERPROFILE for the user, whatever the caller's are" {
        $result = Invoke-Clean '"$env:USERNAME|$env:USERPROFILE"' @{ USERNAME = 'someone-else'; USERPROFILE = "$TestDrive" }
        $result.ExitCode | Should -Be 0
        $result.Stdout[-1] | Should -Be "$env:USERNAME|$env:USERPROFILE"
    }

    It "runs the command under mise exec, with mise.toml's pwsh" {
        $result = Invoke-Clean '(Get-Process -Id $PID).Path'
        $result.ExitCode | Should -Be 0
        $result.Stdout[-1] | Should -Be (mise which pwsh)
    }

    # mise's pwsh defaults to RemoteSigned, which refuses a script with a mark of the web
    It 'runs the command with the execution policy Bypass' {
        $result = Invoke-Clean 'Get-ExecutionPolicy'
        $result.ExitCode | Should -Be 0
        $result.Stdout[-1] | Should -Be 'Bypass'
    }

    It "exits with the command's exit code" {
        (Invoke-Clean 'exit 7').ExitCode | Should -Be 7
    }

    It 'passes on stderr' {
        $result = Invoke-Clean '[Console]::Error.WriteLine(''to stderr'')'
        $result.ExitCode | Should -Be 0
        $result.Stderr | Should -Contain 'to stderr'
    }

    # Start-Process joins its arguments with no quoting, which the encoded command avoids
    It 'passes on arguments with spaces, quotes, apostrophes and $ intact' {
        $arguments = 'two words', 'say "hi"', "it's", '$HOME', 'a\b\'
        $result = Invoke-Script Invoke-Clean.ps1 (@('pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $printArgs) + $arguments)
        $result.ExitCode | Should -Be 0
        $result.Stdout[-1] | ConvertFrom-Json | Should -Be $arguments
    }

    Context 'under Windows PowerShell 5.1' {
        BeforeAll {
            $script = Join-Path $repo 'scripts\Invoke-Clean.ps1'
        }

        It 'refuses to run, and exits 1' {
            $result = Invoke-Child $repo @{} {
                powershell.exe -NoLogo -NoProfile -NonInteractive -File $script pwsh -NoProfile -Command 'exit 0'
            }
            $result.ExitCode | Should -Be 1
            $result.Stderr | Should -BeLike "Invoke-Clean.ps1 needs PowerShell 7.3 or later, and this is 5.1.* ($env:SystemRoot\System32\WindowsPowerShell\v1.0)."
        }

        # What #Requires would get wrong: the recipe line carries on to `exit $LASTEXITCODE`
        It 'fails a recipe line that calls it' {
            $result = Invoke-Child $repo @{} {
                powershell.exe -NoLogo -NoProfile -NonInteractive -Command "& '$script' pwsh -NoProfile -Command 'exit 0'; exit `$LASTEXITCODE"
            }
            $result.ExitCode | Should -Be 1
        }
    }
}
