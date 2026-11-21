<#
.SYNOPSIS
Runs a command under `mise exec` with an environment that owes nothing to the shell that started it.

.DESCRIPTION
The recipes that apply or test a configuration go through this, so a run is the same from any terminal: mise.toml
provides the tools, and every variable is one Windows builds for this user, from the registry and the logon session
(Start-Process -UseNewEnvironment, through CreateEnvironmentBlock). Neither mise nor just can clear an environment.
This never changes the persistent PATH.
The command goes through a second pwsh because -UseNewEnvironment ignores -Environment, and the bootstrap's
-ExecutionPolicy Bypass, which reaches children through a variable, would otherwise be lost. That pwsh sets it again.
mise configuration other than the repo's mise.toml (the global ~\.config\mise\config.toml, a mise.local.toml, a
mise.toml in a parent folder) would add its tools and env to every run, so it's ignored, with a warning naming each
file.
install.cmd starts this through scripts/Start-Clean.ps1, which finds mise from Windows PowerShell 5.1.
Output goes straight to this process's own stdout and stderr, so `$x = & Invoke-Clean.ps1` captures nothing.

.EXAMPLE
./scripts/Invoke-Clean.ps1 pwsh -NoProfile -File ./scripts/Test-Winfiles.ps1 dsc/iris.system.dsc.yaml
#>
$ErrorActionPreference = 'Stop'

# Not #Requires: a recipe line carries on past that error, and its `exit $LASTEXITCODE` then reports success.
# 7.1 brought CreateEnvironmentBlock (before it, and on 5.1, USERNAME is SYSTEM and USERPROFILE is missing), and
# 7.3 passes quotes inside arguments on correctly.
if ($PSVersionTable.PSVersion -lt '7.3') {
    [Console]::Error.WriteLine(
        "Invoke-Clean.ps1 needs PowerShell 7.3 or later, and this is $($PSVersionTable.PSVersion) ($PSHOME).")
    exit 1
}

function Quote([string]$Text) {
    "'" + [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Text) + "'"
}

# Encoded, because Start-Process joins its arguments with no quoting. The new environment is built from the
# registry, so mise's presence and the mise configuration to ignore are worked out inside it
$arguments = $args | ForEach-Object { Quote $_ }
$miseToml = Quote (Join-Path (Split-Path $PSScriptRoot) 'mise.toml')
$command = @"
`$ErrorActionPreference = 'Stop'
if (-not (Get-Command mise -ErrorAction SilentlyContinue)) {
    [Console]::Error.WriteLine('mise isn''t on the machine or user PATH.')
    exit 1
}
. $(Quote (Join-Path $PSScriptRoot 'miseignore.ps1'))
`$listing = (& mise config ls --json 2>`$null) -join "``n"
`$env:MISE_IGNORED_CONFIG_PATHS = Get-MiseIgnoredConfig `$listing $miseToml `$env:MISE_IGNORED_CONFIG_PATHS
& mise exec '--' $arguments
exit `$LASTEXITCODE
"@
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
$process = Start-Process -UseNewEnvironment -NoNewWindow -Wait -PassThru pwsh `
    '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded

exit $process.ExitCode
