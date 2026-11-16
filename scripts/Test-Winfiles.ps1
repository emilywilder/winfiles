#Requires -Version 7.4

<#
.SYNOPSIS
Tests DSC configurations, reports what isn't in its desired state, and exits 1 if anything isn't.

.DESCRIPTION
`dsc config test` exits 0 whatever it finds, so this reads its results. Every configuration is tested, even after
one fails. The whole result is kept in ~/.local/state/winfiles/dsc.

.EXAMPLE
./scripts/Test-Winfiles.ps1 dsc/iris.system.dsc.yaml dsc/emily@iris.home.dsc.yaml
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'dsclog.ps1')
. (Join-Path $PSScriptRoot 'winlog.ps1')

$passed = $true
$total = 0
$wrong = 0
Write-WinfilesLog check "testing $($args.Count) $(if ($args.Count -eq 1) { 'configuration' } else { 'configurations' })"
foreach ($file in $args) {
    $json = Invoke-DscLogged test $file
    if ($LASTEXITCODE) {
        $message = "${file}: dsc failed with exit code $LASTEXITCODE"
        Write-Host $message -ForegroundColor Red
        Write-WinfilesLog check $message
        $passed = $false
        continue
    }
    $resources = @(Get-ResourceResult ($json | ConvertFrom-Json).results)
    $differing = @($resources | Where-Object { -not $_.result.inDesiredState })
    $total += $resources.Count
    $wrong += $differing.Count
    $message = "${file}: $($resources.Count - $differing.Count) of $($resources.Count) in desired state"
    Write-Host $message
    Write-WinfilesLog check $message
    foreach ($resource in $differing) {
        $message = "  $($resource.type) '$($resource.name)': $((Get-ResourceProblem $resource 'actualState') -join ', ')"
        Write-Host $message
        Write-WinfilesLog check $message
        $passed = $false
    }
}
if ($passed) {
    $message = "passed: all $total resources are in desired state"
    Write-Host $message
} else {
    $message = "failed: $wrong of $total resources are not in desired state, or dsc failed"
    Write-Host $message -ForegroundColor Red
}
Write-WinfilesLog check $message
exit ($passed ? 0 : 1)
