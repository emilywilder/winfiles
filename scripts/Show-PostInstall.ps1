#Requires -Version 7.4
<#
.SYNOPSIS
Prints what a host still needs done by hand after an install.

.DESCRIPTION
A note is a YAML comment in dsc/hosts/<host>/ that starts with `# post-install: ` and runs to the end of that block of
comment lines, so the text lives once, beside the setting it's about. A host with no notes prints nothing.

.EXAMPLE
./scripts/Show-PostInstall.ps1 dsc/hosts/iris
#>
$ErrorActionPreference = 'Stop'

$pattern = '(?m)^[ \t]*# post-install: (.*(?:\r?\n[ \t]*#.*)*)'
$notes = foreach ($file in Get-ChildItem -LiteralPath $args[0] -Filter *.yaml) {
    foreach ($match in [regex]::Matches((Get-Content -LiteralPath $file.FullName -Raw), $pattern)) {
        $match.Groups[1].Value -replace '\r' -replace '(?m)^[ \t]*# ?'
    }
}
if (-not $notes) { exit 0 }

Write-Host "`nStill to do by hand:"
foreach ($note in $notes) {
    Write-Host "`n$note"
}
