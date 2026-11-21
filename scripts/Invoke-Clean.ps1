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
There's no param() block: every argument is the command, passed on as it is.

.EXAMPLE
./scripts/Invoke-Clean.ps1 pwsh -NoProfile -File ./scripts/Test-Winfiles.ps1 dsc/iris.system.dsc.yaml

Tests iris's system configuration with nothing from this shell's environment.
#>

$ErrorActionPreference = 'Stop'
try {
    # Not #Requires: a recipe line carries on past that error, and its `exit $LASTEXITCODE` then reports success.
    # 7.1 brought CreateEnvironmentBlock (before it, and on 5.1, USERNAME is SYSTEM and USERPROFILE is missing), and
    # 7.3 passes quotes inside arguments on correctly.
    if ($PSVersionTable.PSVersion -lt '7.3') {
        [Console]::Error.WriteLine(
            "Invoke-Clean.ps1 needs PowerShell 7.3 or later, and this is $($PSVersionTable.PSVersion) ($PSHOME).")
        exit 1
    }


    function ConvertTo-SingleQuoted {
        <#
        .SYNOPSIS
        Returns text as a PowerShell single-quoted string literal.
        #>
        [CmdletBinding()]
        [OutputType([string])]
        param(
            # The text.
            [Parameter(Mandatory, Position = 0)]
            [AllowEmptyString()]
            [string]$Text
        )

        "'" + [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Text) + "'"
    }


    # Encoded, because Start-Process joins its arguments with no quoting. The new environment is built from the
    # registry, so mise's presence and the mise configuration to ignore are worked out inside it
    $arguments = $args | ForEach-Object -Process { ConvertTo-SingleQuoted -Text $_ }
    $miseToml = ConvertTo-SingleQuoted -Text (Join-Path -Path (Split-Path -Path $PSScriptRoot) -ChildPath 'mise.toml')
    $miseIgnore = ConvertTo-SingleQuoted -Text (Join-Path -Path $PSScriptRoot -ChildPath 'miseignore.ps1')
    $command = @"
`$ErrorActionPreference = 'Stop'
if (-not (Get-Command -Name mise -ErrorAction SilentlyContinue)) {
    [Console]::Error.WriteLine('mise isn''t on the machine or user PATH.')
    exit 1
}
. $miseIgnore
`$listing = (& mise config ls --json 2>`$null) -join "``n"
`$env:MISE_IGNORED_CONFIG_PATHS = Get-MiseIgnoredConfig -Listing `$listing -Own $miseToml -Ignored `$env:MISE_IGNORED_CONFIG_PATHS
& mise exec '--' $arguments
exit `$LASTEXITCODE
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $start = @{
        FilePath           = 'pwsh'
        ArgumentList       = '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded
        UseNewEnvironment  = $true
        NoNewWindow        = $true
        Wait               = $true
        PassThru           = $true
    }
    $process = Start-Process @start
    exit $process.ExitCode
} catch {
    # Rethrown, so an error that only ends a statement still ends the script, with exit code 1
    $failure = $_
    throw $failure
} finally {
    $ErrorActionPreference = 'Continue'
}
