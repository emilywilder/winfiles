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
    foreach ($name in $variables.Keys) { [Environment]::SetEnvironmentVariable($name, $variables[$name]) }
}
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
$env:PSExecutionPolicyPreference = 'Bypass'

& mise exec -- @args
exit $LASTEXITCODE
