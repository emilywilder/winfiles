#Requires -Version 7.4
<#
.SYNOPSIS
Tests DSC configurations, reports what isn't in its desired state, and exits 1 if anything isn't.

.DESCRIPTION
`dsc config test` exits 0 whatever it finds, so this reads its results. Every configuration is tested, even after
one fails. The whole result is still available from `just dsc config test --file <doc>`.

.EXAMPLE
./scripts/Test-Winfiles.ps1 dsc/iris.system.dsc.yaml dsc/emily@iris.home.dsc.yaml
#>
$ErrorActionPreference = 'Stop'

# An Include's result is the list of results from its document
function Get-ResourceResult($Results) {
    foreach ($resource in $Results) {
        if ($resource.result -is [array]) { Get-ResourceResult $resource.result } else { $resource }
    }
}

$passed = $true
foreach ($file in $args) {
    $json = & (Join-Path $PSScriptRoot 'Invoke-Dsc.ps1') config test --output-format json --file $file
    if ($LASTEXITCODE) {
        Write-Host "${file}: dsc failed with exit code $LASTEXITCODE"
        $passed = $false
        continue
    }
    $resources = @(Get-ResourceResult ($json | ConvertFrom-Json).results)
    $differing = @($resources | Where-Object { -not $_.result.inDesiredState })
    Write-Host "${file}: $($resources.Count - $differing.Count) of $($resources.Count) in desired state"
    foreach ($resource in $differing) {
        $state = $resource.result.actualState
        # The lists name what's wrong in their own properties; other resources only have differingProperties
        $details = @($state.missing) + @($state.missingBuckets) + @($state.outOfDate) +
            @($resource.result.differingProperties) | Where-Object { $_ }
        Write-Host "  $($resource.type) '$($resource.name)': $($details -join ', ')"
        $passed = $false
    }
}
exit ($passed ? 0 : 1)
