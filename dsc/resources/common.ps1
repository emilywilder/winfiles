# Shared by the Winfiles/* resource scripts, which dot-source it first.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# DSC pipes the instance as JSON on stdin, and the manifest's `$input | ./<script>.ps1` passes it on line by line
function Read-ResourceInput {
    $input -join "`n" | ConvertFrom-Json
}

# DSC logs plain stderr lines at trace only, so anything meant to be seen needs this form. warn is the lowest level
# it shows by default (tests/dsc-messages/README.md). Flush so each line goes out when it's written.
function Write-ResourceMessage([string]$Level, [string]$Text) {
    [Console]::Error.WriteLine((@{ $Level = $Text } | ConvertTo-Json -Compress))
    [Console]::Error.Flush()
}
