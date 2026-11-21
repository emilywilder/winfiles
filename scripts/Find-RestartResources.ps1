#Requires -Version 7.4

<#
.SYNOPSIS
Tests a document and prints the resources that report they will need a restart to be applied.

.DESCRIPTION
Invoke-Configuration.ps1 runs this, elevated, on each elevated batch before applying anything. A resource says it will
need a restart by returning `_restartRequired` (Winfiles/WSL and Winfiles/ComputerName do), which DSC 3.3.0 puts in the
resource's result from `test` too (Get-RestartReport in dsclog.ps1). It prints one line for each, `winfiles-restart:
<type>|<name>`, the form ConvertTo-FlatConfiguration.ps1's -First takes, and nothing else on the output that
matters: Invoke-Configuration.ps1 picks those lines out of the rest. It exits with dsc's exit code when the test fails
(and prints that), and otherwise 0, whatever it finds.

.PARAMETER File
The document to test, which has to be flat (a batch of Invoke-Configuration.ps1).

.EXAMPLE
gsudo --direct mise exec -- pwsh -NoLogo -NoProfile -File ./scripts/Find-RestartResources.ps1 `
    ~/.local/state/winfiles/flat/iris.system.1-elevated.dsc.yaml
#>
param([Parameter(Mandatory)][string]$File)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'dsclog.ps1')
. (Join-Path $PSScriptRoot 'winlog.ps1')

$document = Get-RunDocument $File apply
if (-not $document) { exit 1 }
$json = Invoke-DscLogged test $document
if ($LASTEXITCODE) {
    $message = "${File}: dsc failed with exit code $LASTEXITCODE"
    Write-Host $message -ForegroundColor Red
    Write-WinfilesLog apply $message
    exit $LASTEXITCODE
}
# Nothing printed is nothing reported (the fake dsc in the tests answers a document it has no result for that way)
if (-not $json) { exit 0 }
foreach ($report in @(Get-RestartReport ($json | ConvertFrom-Json).results)) {
    Write-WinfilesLog apply "${File}: $($report.Type) '$($report.Name)' will need a restart"
    "winfiles-restart: $($report.Type)|$($report.Name)"
}
exit 0
