#Requires -Version 7.4

<#
.SYNOPSIS
Tests DSC configurations, reports what isn't in its desired state, and exits 1 if anything isn't.

.DESCRIPTION
`dsc config test` exits 0 whatever it finds, so this reads its results. Every configuration is tested, even after
one fails. The whole result is kept in ~/.local/state/winfiles/dsc. Like Set-Winfiles.ps1, it takes flat
documents (the batches Invoke-Configuration.ps1 makes with ConvertTo-FlatConfiguration.ps1), so it tests what a set
applies, and refuses one that still has an Include.

.EXAMPLE
./scripts/Test-Winfiles.ps1 ~/.local/state/winfiles/flat/iris.system.1-elevated.dsc.yaml

Tests iris's first elevated batch.
#>
[CmdletBinding()]
param(
    # The flat documents to test.
    [Parameter(Mandatory, Position = 0, ValueFromRemainingArguments)]
    [string[]]$File,

    # A file to add the line "<resources> <not in desired state>" to, instead of printing the final "passed" or
    # "failed" line. Invoke-Configuration.ps1 adds the batches' lines up and prints one for the run. Named only: a
    # second positional parameter would take a document that belongs to File.
    [Parameter(ParameterSetName = 'Totals')]
    [string]$TotalsFile
)

$ErrorActionPreference = 'Stop'
try {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'winlog.ps1')
    . (Join-Path -Path $PSScriptRoot -ChildPath 'dsclog.ps1')

    $passed = $true
    $total = 0
    $wrong = 0
    $noun = if ($File.Count -eq 1) { 'configuration' } else { 'configurations' }
    Write-WinfilesLog -Phase check -Message "testing $($File.Count) $noun"
    foreach ($path in $File) {
        $document = Get-RunDocument -File $path -Phase check
        if (-not $document) {
            $passed = $false
            continue
        }
        $json = Invoke-DscLogged -Operation test -File $document
        if ($LASTEXITCODE) {
            $message = "${path}: dsc failed with exit code $LASTEXITCODE"
            Write-Host -Object $message -ForegroundColor Red
            Write-WinfilesLog -Phase check -Message $message
            $passed = $false
            continue
        }
        $resources = @(Get-ResourceResult -Results ($json | ConvertFrom-Json).results)
        $differing = @($resources | Where-Object -FilterScript { -not $_.result.inDesiredState })
        $total += $resources.Count
        $wrong += $differing.Count
        $message = "${path}: $($resources.Count - $differing.Count) of $($resources.Count) in desired state"
        Write-Host -Object $message
        Write-WinfilesLog -Phase check -Message $message
        foreach ($resource in $differing) {
            $problems = (Get-ResourceProblem -Resource $resource -State actualState) -join ', '
            $message = "  $($resource.type) '$($resource.name)': $problems"
            Write-Host -Object $message
            Write-WinfilesLog -Phase check -Message $message
            $passed = $false
        }
    }
    # Run as one of several batches (Invoke-Configuration.ps1), which says the total once at the end
    if ($TotalsFile) {
        Add-Content -LiteralPath $TotalsFile -Value "$total $wrong"
    } elseif ($passed) {
        $message = "passed: all $total resources are in desired state"
        Write-Host -Object $message
        Write-WinfilesLog -Phase check -Message $message
    } else {
        $message = "failed: $wrong of $total resources are not in desired state, or dsc failed"
        Write-Host -Object $message -ForegroundColor Red
        Write-WinfilesLog -Phase check -Message $message
    }
    exit ($passed ? 0 : 1)
} catch {
    # Rethrown, so an error that only ends a statement still ends the script, with exit code 1
    $failure = $_
    throw $failure
} finally {
    $ErrorActionPreference = 'Continue'
}
