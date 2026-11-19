#Requires -Version 7.4

<#
.SYNOPSIS
Tests DSC configurations, reports what isn't in its desired state, and exits 1 if anything isn't.

.DESCRIPTION
`dsc config test` exits 0 whatever it finds, so this reads its results. Every configuration is tested, even after
one fails. The whole result is kept in ~/.local/state/winfiles/dsc. Like Set-Winfiles.ps1, it tests a flat copy of
each document (ConvertTo-FlatConfiguration.ps1), so it tests what a set applies.

.PARAMETER File
The documents to test.

.PARAMETER NoFlatten
Give dsc the documents themselves, Includes and all, rather than their flat copies.

.PARAMETER TotalsFile
A file to add the line "<resources> <not in desired state>" to, instead of printing the final "passed" or "failed"
line. Invoke-Configuration.ps1 adds the batches' lines up and prints one for the run.

.EXAMPLE
./scripts/Test-Winfiles.ps1 dsc/iris.system.dsc.yaml dsc/emily@iris.home.dsc.yaml
#>
param(
    [Parameter(Mandatory, Position = 0, ValueFromRemainingArguments)]
    [string[]]$File,
    [switch]$NoFlatten,
    # Named only: a second positional parameter would take a document that belongs to File
    [Parameter(ParameterSetName = 'Totals')]
    [string]$TotalsFile
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'dsclog.ps1')
. (Join-Path $PSScriptRoot 'winlog.ps1')

$passed = $true
$total = 0
$wrong = 0
Write-WinfilesLog check "testing $($File.Count) $(if ($File.Count -eq 1) { 'configuration' } else { 'configurations' })"
foreach ($file in $File) {
    $document = Get-RunDocument $file check -NoFlatten:$NoFlatten
    if (-not $document) {
        $passed = $false
        continue
    }
    $json = Invoke-DscLogged test $document
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
# Run as one of several batches (Invoke-Configuration.ps1), which says the total once at the end
if ($TotalsFile) {
    Add-Content -LiteralPath $TotalsFile -Value "$total $wrong"
    exit ($passed ? 0 : 1)
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
