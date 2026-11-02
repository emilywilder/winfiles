# Shared by the Winfiles/* resource scripts, which dot-source it first.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# DSC pipes the instance as JSON on stdin, and the manifest's `$input | ./<script>.ps1` passes it on line by line
function Read-ResourceInput {
    $input -join "`n" | ConvertFrom-Json
}
