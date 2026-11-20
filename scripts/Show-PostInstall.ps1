#Requires -Version 7.4

<#
.SYNOPSIS
Prints what a host and its user still need done by hand after an install.

.DESCRIPTION
A note is a YAML comment in dsc/hosts/<host>/ or dsc/users/<user>@<host>/ that starts with `# post-install: ` and runs
to the end of that block of comment lines, so the text lives once, beside the setting it's about. Each folder given is
read in turn; one that doesn't exist (a user with no documents of their own) is skipped. No notes prints nothing.

.EXAMPLE
./scripts/Show-PostInstall.ps1 dsc/hosts/iris dsc/users/emily@iris
#>
param(
    # The folders to read notes from
    [Parameter(Mandatory, ValueFromRemainingArguments)]
    [string[]]$Path
)
$ErrorActionPreference = 'Stop'

$pattern = '(?m)^[ \t]*# post-install: (.*(?:\r?\n[ \t]*#.*)*)'
$notes = foreach ($folder in $Path | Where-Object { Test-Path -LiteralPath $_ -PathType Container }) {
    foreach ($file in Get-ChildItem -LiteralPath $folder -Filter *.yaml) {
        foreach ($match in [regex]::Matches((Get-Content -LiteralPath $file.FullName -Raw), $pattern)) {
            $match.Groups[1].Value -replace '\r' -replace '(?m)^[ \t]*# ?'
        }
    }
}
if (-not $notes) { exit 0 }

Write-Host "`nStill to do by hand:"
foreach ($note in $notes) {
    Write-Host "`n$note"
}
