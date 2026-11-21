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

Prints what iris and emily@iris still need done by hand.
#>
[CmdletBinding()]
param(
    # The folders to read notes from.
    [Parameter(Mandatory, ValueFromRemainingArguments)]
    [string[]]$Path
)

$ErrorActionPreference = 'Stop'
try {
    $pattern = '(?m)^[ \t]*# post-install: (.*(?:\r?\n[ \t]*#.*)*)'
    $folders = $Path | Where-Object -FilterScript { Test-Path -LiteralPath $_ -PathType Container }
    $notes = foreach ($folder in $folders) {
        foreach ($file in Get-ChildItem -LiteralPath $folder -Filter *.yaml) {
            foreach ($match in [regex]::Matches((Get-Content -LiteralPath $file.FullName -Raw), $pattern)) {
                $match.Groups[1].Value -replace '\r' -replace '(?m)^[ \t]*# ?'
            }
        }
    }
    if ($notes) {
        Write-Host -Object "`nStill to do by hand:"
        foreach ($note in $notes) {
            Write-Host -Object "`n$note"
        }
    }
} catch {
    # Rethrown, so an error that only ends a statement still ends the script, with exit code 1
    $failure = $_
    throw $failure
} finally {
    $ErrorActionPreference = 'Continue'
}
