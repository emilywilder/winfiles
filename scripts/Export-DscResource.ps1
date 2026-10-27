#Requires -Version 7.4
<#
.SYNOPSIS
Exports current state for every DSC resource that supports export, one YAML file per resource.
#>
[CmdletBinding()]
param(
    [string] $OutputDirectory = (Join-Path (Split-Path $PSScriptRoot) 'exports'),
    [string[]] $Exclude = @('Microsoft.DSC.Debug/Echo', 'Microsoft.PowerShell/Profile')
)

$null = New-Item -ItemType Directory -Force -Path $OutputDirectory
$invalidChars = [IO.Path]::GetInvalidFileNameChars()
$isElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
$dscHome = Split-Path (Get-Command dsc).Source

# Drops each resource's executionInformation block (the run's duration), so exports only change with the state
function Remove-ExecutionInformation([string[]] $Lines) {
    $skipping = $false
    foreach ($line in $Lines) {
        if ($line -match '^  executionInformation:\s*$') {
            $skipping = $true
        } elseif (-not $skipping -or $line -notmatch '^ {3,}\S') {
            $skipping = $false
            $line
        }
    }
}

Write-Progress -Activity 'Exporting DSC resources' -Status 'Discovering resources'
# A type found in more than one DSC install is listed once per copy (or once, when the versions match)
$resources = dsc resource list --output-format json |
    ConvertFrom-Json |
    Where-Object { $_.kind -ne 'adapter' -and $_.capabilities -contains 'export' -and $_.type -notin $Exclude }

$selected = foreach ($group in $resources | Group-Object type) {
    $resource = $group.Group[0]
    $isDism = $resource.manifest.export.executable -eq 'dism_dsc'
    if ($isDism) {
        # dism_dsc spends ~2 minutes and then fails with "not supported when installed via Appx" when it comes
        # from the Store/winget package, so only the copy installed with this dsc is used (just dsc-export-github)
        $resource = $group.Group | Where-Object { $_.path -like "$dscHome\*" } | Select-Object -First 1
        if (-not $resource) {
            Write-Warning "$($group.Name) skipped: no dism_dsc copy under $dscHome (the Appx install of dism_dsc doesn't work)"
            continue
        }
    }
    # dism_dsc fails with ERROR_ELEVATION_REQUIRED even where the manifest doesn't ask for elevation
    if (-not $isElevated -and ($isDism -or $resource.manifest.export.requireSecurityContext -eq 'elevated')) {
        Write-Warning "$($resource.type) skipped: export requires an elevated shell"
        continue
    }
    $resource
}

$index = 0
foreach ($resource in $selected) {
    $type = $resource.type
    $prefix = Join-Path $OutputDirectory "dsc.resource.export.$($type.Split($invalidChars) -join '_')"
    Write-Progress -Activity 'Exporting DSC resources' -Status $type -PercentComplete (100 * $index++ / @($selected).Count)
    Write-Verbose "Exporting $type $($resource.version) from $($resource.directory)"
    # --version takes a requirement; "=" pins the copy selected above when several installs provide the type
    $yaml = dsc resource export --resource $type --version "=$($resource.version)" --output-format yaml 2> "$prefix.log"

    if ($LASTEXITCODE -ne 0) {
        Remove-Item "$prefix.yaml" -ErrorAction Ignore
        Write-Warning "$type failed (exit $LASTEXITCODE), see $prefix.log"
    } else {
        Remove-ExecutionInformation $yaml | Set-Content "$prefix.yaml"
        if ((Get-Item "$prefix.log").Length -eq 0) {
            Remove-Item "$prefix.log"
        }
    }
}
Write-Progress -Activity 'Exporting DSC resources' -Completed
