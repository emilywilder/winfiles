#Requires -Version 7.4
<#
.SYNOPSIS
Exports current state for every DSC resource that supports export, one YAML file per resource.
#>
[CmdletBinding()]
param(
    [string] $OutputDirectory = (Join-Path $PSScriptRoot 'exports'),
    [string[]] $Exclude = @('Microsoft.DSC.Debug/Echo', 'Microsoft.PowerShell/Profile')
)

$null = New-Item -ItemType Directory -Force -Path $OutputDirectory
$invalidChars = [IO.Path]::GetInvalidFileNameChars()
$isElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

Write-Progress -Activity 'Exporting DSC resources' -Status 'Discovering resources'
$resources = dsc resource list --output-format json |
    ConvertFrom-Json |
    Where-Object { $_.kind -ne 'adapter' -and $_.capabilities -contains 'export' -and $_.type -notin $Exclude }

$types = foreach ($resource in $resources) {
    # dism_dsc spends ~2 minutes and then fails with "not supported when installed via Appx"
    # when DSC comes from the Store/winget package; run with the GitHub release (just dsc-export-github) to export these.
    if ($resource.manifest.export.executable -eq 'dism_dsc' -and $resource.directory -like '*\WindowsApps\*') {
        Write-Warning "$($resource.type) skipped: dism_dsc doesn't support the Appx install of DSC"
    } elseif (-not $isElevated -and $resource.manifest.export.requireSecurityContext -eq 'elevated') {
        Write-Warning "$($resource.type) skipped: export requires an elevated shell"
    } else {
        $resource.type
    }
}

$index = 0
foreach ($type in $types) {
    $prefix = Join-Path $OutputDirectory "dsc.resource.export.$($type.Split($invalidChars) -join '_')"
    Write-Progress -Activity 'Exporting DSC resources' -Status $type -PercentComplete (100 * $index++ / $types.Count)
    Write-Verbose "Exporting $type"
    dsc resource export --resource $type --output-format yaml > "$prefix.yaml" 2> "$prefix.log"

    if ($LASTEXITCODE -ne 0) {
        Remove-Item "$prefix.yaml"
        Write-Warning "$type failed (exit $LASTEXITCODE), see $prefix.log"
    } elseif ((Get-Item "$prefix.log").Length -eq 0) {
        Remove-Item "$prefix.log"
    }
}
Write-Progress -Activity 'Exporting DSC resources' -Completed
