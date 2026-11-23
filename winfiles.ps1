#Requires -Version 7.4

<#
.SYNOPSIS
Runs winfiles' commands by name: install, check, test, flatten and the rest, from commands.jsonc.

.DESCRIPTION
With no arguments, lists the commands. `help <command>` shows a command's usage, and the help of the script its
extra arguments go to. Anything else is `<command> [arguments]`: the files the command requires are checked first,
then the run goes once through scripts/Invoke-Clean.ps1 when it needs a clean environment, and once through
scripts/Invoke-AsAdmin.ps1 when it needs elevation, and exits with the exit code of the first script that failed,
unchanged. The runner is scripts/commands.ps1, and the commands and their reasons are in commands.jsonc.
--clean and --run, before the command, are for the runner's own second run: inside the clean environment, and
after a change of privilege. Start-Winfiles.ps1 (install.cmd's way in) passes --clean too, since it has cleaned the
environment already. There's no param() block, for the reason Invoke-AsAdmin.ps1 gives: a command's own dash
arguments (`-Ref`, say) pass on as they are. A usage error exits 2.

.EXAMPLE
./winfiles.ps1 check iris

Tests iris's system and home configurations, asking for UAC once unless the shell is elevated.
#>

$ErrorActionPreference = 'Stop'
try {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'scripts/commands.ps1')

    $mode = switch ($args[0]) {
        '--clean' { 'Clean' }
        '--run' { 'Run' }
        default { 'Outer' }
    }
    $arguments = [string[]]@(if ($mode -eq 'Outer') { $args } else { $args | Select-Object -Skip 1 })
    $tableFile = Join-Path -Path $PSScriptRoot -ChildPath 'commands.jsonc'
    $table = Read-WinfilesCommand -Path $tableFile -Root $PSScriptRoot

    # Commands run from the repo root, as their paths are written
    Push-Location -LiteralPath $PSScriptRoot
    try {
        if (-not $arguments) {
            Show-WinfilesCommand -Table $table
            $global:LASTEXITCODE = 0
        } else {
            $run = @{
                Root     = $PSScriptRoot
                Table    = $table
                Name     = $arguments[0]
                Argument = @($arguments | Select-Object -Skip 1)
                Mode     = $mode
            }
            Invoke-WinfilesCommand @run
        }
    } catch [ArgumentException] {
        $failure = $_
        [Console]::Error.WriteLine($failure.Exception.Message)
        $global:LASTEXITCODE = 2
    } finally {
        Pop-Location
    }
    exit $LASTEXITCODE
} catch {
    # Rethrown, so an error that only ends a statement still ends the script, with exit code 1
    $failure = $_
    throw $failure
} finally {
    $ErrorActionPreference = 'Continue'
}
