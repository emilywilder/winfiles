#Requires -Version 5.1

<#
.SYNOPSIS
Runs a command under `mise exec` with an environment that owes nothing to the shell that started it.

.DESCRIPTION
The recipes that apply or test a configuration go through this, so a run is the same from any terminal: mise.toml
provides the tools, and PATH and the other variables are the machine's and user's, read from the registry. Only
Windows' per-session variables, which aren't in the registry, are kept. Neither mise nor just can clear an environment.
This changes this process and its children only, never the persistent PATH.
The execution policy is set here because the bootstrap's -ExecutionPolicy Bypass reaches children through a variable.
mise configuration other than the repo's mise.toml (the global ~\.config\mise\config.toml, a mise.local.toml, a
mise.toml in a parent folder) would add its tools and env to every run, so it's ignored for this process and its
children, with a warning naming each file.

.EXAMPLE
./scripts/Invoke-Clean.ps1 pwsh -NoProfile -File ./scripts/Test-Winfiles.ps1 dsc/iris.system.dsc.yaml
#>
$session = 'ALLUSERSPROFILE', 'APPDATA', 'CommonProgramFiles', 'CommonProgramFiles(x86)', 'CommonProgramW6432',
    'COMPUTERNAME', 'HOMEDRIVE', 'HOMEPATH', 'LOCALAPPDATA', 'LOGONSERVER', 'ProgramData', 'ProgramFiles',
    'ProgramFiles(x86)', 'ProgramW6432', 'PUBLIC', 'SESSIONNAME', 'SystemDrive', 'SystemRoot', 'USERDOMAIN',
    'USERDOMAIN_ROAMINGPROFILE', 'USERNAME', 'USERPROFILE'
# Not $null: PowerShell passes it as an empty string, which on current .NET leaves the variable set but empty
foreach ($name in @([Environment]::GetEnvironmentVariables().Keys)) {
    if ($name -notin $session) { [Environment]::SetEnvironmentVariable($name, [NullString]::Value) }
}
foreach ($scope in 'Machine', 'User') {
    $variables = [Environment]::GetEnvironmentVariables($scope)
    # Not the session's own: the machine's USERNAME is SYSTEM
    foreach ($name in $variables.Keys) {
        if ($name -notin $session) { [Environment]::SetEnvironmentVariable($name, $variables[$name]) }
    }
}
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
$env:PSExecutionPolicyPreference = 'Bypass'

# Otherwise the call below fails as a non-terminating error and the script exits 0
if (-not (Get-Command mise -ErrorAction SilentlyContinue)) {
    [Console]::Error.WriteLine('mise isn''t on the machine or user PATH.')
    exit 1
}

# Read after the registry's variables are in place, since a MISE_* variable there can add configuration too
. (Join-Path $PSScriptRoot 'miseignore.ps1')
$listing = (& mise config ls --json 2>$null) -join "`n"
$env:MISE_IGNORED_CONFIG_PATHS = Get-MiseIgnoredConfig $listing (Join-Path (Split-Path $PSScriptRoot) 'mise.toml') $env:MISE_IGNORED_CONFIG_PATHS

& mise exec -- @args
exit $LASTEXITCODE
