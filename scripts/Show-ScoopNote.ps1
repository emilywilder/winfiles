#Requires -Version 7.4

<#
.SYNOPSIS
Prints the notes of every installed Scoop app, for reviewing what Scoop suggests doing after an install.

.DESCRIPTION
Reads the `notes` field of each app's installed manifest under the Scoop root, without running Scoop, and fills in
`$dir`, `$original_dir` and `$persist_dir` the way `scoop info --verbose` does. Covers every installed app, not just
the ones in the repo's lists, since a note is about what's on the machine. Global apps are left out: winfiles
installs none. Nothing is run or changed.

.EXAMPLE
./scripts/Show-ScoopNote.ps1
#>
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/../dsc/resources/scooproot.ps1"
$root = Get-ScoopRoot

$found = $false
foreach ($app in Get-ChildItem -LiteralPath (Join-Path $root 'apps') -Directory -ErrorAction SilentlyContinue) {
    $dir = Join-Path $app.FullName 'current'
    # scoop-manifest.json from current Scoop, manifest.json from older versions
    $manifestFile = @('scoop-manifest.json', 'manifest.json') | ForEach-Object { Join-Path $dir $_ } |
        Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $manifestFile) { continue }
    $manifest = Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json
    if (-not $manifest.notes) { continue }

    # Longest name first, as Scoop's substitute does, so $dir doesn't replace part of $original_dir
    $notes = $manifest.notes -join "`n"
    $notes = $notes.Replace('$original_dir', (Join-Path $app.FullName $manifest.version))
    $notes = $notes.Replace('$persist_dir', (Join-Path $root "persist\$($app.Name)"))
    $notes = $notes.Replace('$dir', $dir)

    Write-Host "`n$($app.Name):"
    Write-Host $notes
    $found = $true
}
if (-not $found) { Write-Host 'No installed Scoop app has notes.' }
