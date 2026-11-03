#Requires -Version 7.4
<#
.SYNOPSIS
Lists the software a host installs by hand that's missing, and downloads its installers without running them.

.DESCRIPTION
A list is dsc/hosts/<host>/manual.yaml, and a host without one has nothing to install by hand. A program counts as
installed when its display name among installed programs contains the entry's `detect`. Installers go in
~/.cache/winfiles/manual. Exits 1 if a download failed, and still tries the rest.

.EXAMPLE
./scripts/Get-ManualInstaller.ps1 dsc/hosts/iris/manual.yaml
#>
$ErrorActionPreference = 'Stop'

$file = $args[0]
if (-not (Test-Path -LiteralPath $file)) {
    Write-Host "Nothing to install by hand: there's no $file"
    exit 0
}

$uninstallKeys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
$installed = @((Get-ItemProperty $uninstallKeys).DisplayName | Where-Object { $_ })

$entries = @(yq -o=json '.' $file | ConvertFrom-Json)
if ($LASTEXITCODE) { throw "yq couldn't read $file" }
$missing = @($entries | Where-Object {
    $detect = $_.detect
    -not ($installed | Where-Object { $_.Contains($detect, [StringComparison]::OrdinalIgnoreCase) })
})
if (-not $missing) {
    Write-Host "All $($entries.Count) programs in $file are installed."
    exit 0
}

$folder = Join-Path $HOME '.cache/winfiles/manual'
New-Item -ItemType Directory -Force $folder | Out-Null
$failed = @()
foreach ($entry in $missing) {
    Write-Host "$($entry.name) is missing. $($entry.why)"
    winget download --id $entry.winget --exact --source winget --download-directory $folder --accept-package-agreements --accept-source-agreements --disable-interactivity
    if ($LASTEXITCODE) { $failed += $entry.name }
}

Write-Host "Install them by hand, in the order above, from $folder"
if ($failed) {
    Write-Host "Couldn't download: $($failed -join ', ')"
    exit 1
}
