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

Downloads the installers of what iris installs by hand and is missing.
#>
[CmdletBinding()]
param(
    # The host's list, dsc/hosts/<host>/manual.yaml.
    [Parameter(Mandatory, Position = 0)]
    [string]$Path
)

$ErrorActionPreference = 'Stop'
try {
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host -Object "Nothing to install by hand: there's no $Path"
        exit 0
    }

    $uninstallKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $installed = @((Get-ItemProperty -Path $uninstallKeys).DisplayName | Where-Object -FilterScript { $_ })

    $entries = @(yq -o=json '.' $Path | ConvertFrom-Json)
    if ($LASTEXITCODE) {
        throw "yq couldn't read $Path"
    }
    $missing = @($entries | Where-Object -FilterScript {
            $detect = $_.detect
            -not ($installed | Where-Object -FilterScript {
                    $_.Contains($detect, [StringComparison]::OrdinalIgnoreCase)
                })
        })
    if (-not $missing) {
        Write-Host -Object "All $($entries.Count) programs in $Path are installed."
        exit 0
    }

    $folder = Join-Path -Path $HOME -ChildPath '.cache/winfiles/manual'
    New-Item -ItemType Directory -Force -Path $folder | Out-Null
    $failed = @()
    foreach ($entry in $missing) {
        Write-Host -Object "$($entry.name) is missing. $($entry.why)"
        $download = @(
            'download', '--id', $entry.winget, '--exact', '--source', 'winget', '--download-directory', $folder
            '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity'
        )
        winget @download
        if ($LASTEXITCODE) {
            $failed += $entry.name
        }
    }

    Write-Host -Object "Install them by hand, in the order above, from $folder"
    if ($failed) {
        Write-Host -Object "Couldn't download: $($failed -join ', ')"
        exit 1
    }
    exit 0
} catch {
    # Rethrown, so an error that only ends a statement still ends the script, with exit code 1
    $failure = $_
    throw $failure
} finally {
    $ErrorActionPreference = 'Continue'
}
