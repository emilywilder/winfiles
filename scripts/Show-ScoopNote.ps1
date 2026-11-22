#Requires -Version 7.4

<#
.SYNOPSIS
Prints the notes of every installed Scoop app, for reviewing what Scoop suggests doing after an install.

.DESCRIPTION
Reads the `notes` field of each app's installed manifest under the Scoop root, without running Scoop, and fills in
`$dir`, `$original_dir` and `$persist_dir` the way `scoop info --verbose` does. Covers every installed app, not
just the ones in the repo's lists, since a note is about what's on the machine. Global apps are left out: winfiles
installs none. Nothing is run or changed.

.EXAMPLE
./scripts/Show-ScoopNote.ps1

Prints the notes of every app Scoop has installed.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
try {
    . (Join-Path -Path $PSScriptRoot -ChildPath '../dsc/resources/scooproot.ps1')
    $root = Get-ScoopRoot

    $found = $false
    $appsFolder = Join-Path -Path $root -ChildPath 'apps'
    $apps = Get-ChildItem -LiteralPath $appsFolder -Directory -ErrorAction SilentlyContinue
    foreach ($app in $apps) {
        $dir = Join-Path -Path $app.FullName -ChildPath 'current'
        # scoop-manifest.json from current Scoop, manifest.json from older versions
        $manifestFile = @('scoop-manifest.json', 'manifest.json') |
            ForEach-Object -Process { Join-Path -Path $dir -ChildPath $_ } |
            Where-Object -FilterScript { Test-Path -LiteralPath $_ } |
            Select-Object -First 1
        $manifest = if ($manifestFile) { Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json }
        if (-not $manifest.notes) {
            continue
        }

        # Longest name first, as Scoop's substitute does, so $dir doesn't replace part of $original_dir
        $notes = $manifest.notes -join "`n"
        $notes = $notes.Replace('$original_dir', (Join-Path -Path $app.FullName -ChildPath $manifest.version))
        $notes = $notes.Replace('$persist_dir', (Join-Path -Path $root -ChildPath "persist\$($app.Name)"))
        $notes = $notes.Replace('$dir', $dir)

        Write-Host -Object "`n$($app.Name):"
        Write-Host -Object $notes
        $found = $true
    }
    if (-not $found) {
        Write-Host -Object 'No installed Scoop app has notes.'
    }
} catch {
    # Rethrown, so an error that only ends a statement still ends the script, with exit code 1
    $failure = $_
    throw $failure
} finally {
    $ErrorActionPreference = 'Continue'
}
