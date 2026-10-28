#Requires -Version 7.4
<#
.SYNOPSIS
Runs dsc with resource discovery limited to the folders winfiles uses, passing all arguments through.

.DESCRIPTION
By default dsc searches every PATH entry for resource manifests, and every dsc process does it again.
This sets DSC_RESOURCE_PATH for this process only to:
  - the running dsc's install folder (Microsoft.DSC/*, Microsoft.Windows/*, PowerShellScript, ...)
  - App Installer's install folder (Microsoft.WinGet/*)
  - dsc/resources (Winfiles/*)
The persistent PATH is never touched. dsc comes from mise.toml, whose postinstall deletes DSC's
discovery extensions; this warns when they're back, since they make every dsc process ~3.3s slower.

.EXAMPLE
./scripts/Invoke-Dsc.ps1 config test --file ./dsc/winfiles.dsc.yaml
#>
$dsc = Get-Command dsc -CommandType Application -ErrorAction Stop | Select-Object -First 1
$dscHome = Split-Path $dsc.Source
if (Get-ChildItem $dscHome -Filter *.dsc.extension.json) {
    Write-Warning "DSC's discovery extensions are in $dscHome, which slows every dsc process. Run: mise install --force github:PowerShell/DSC"
}
$appInstaller = (Get-AppxPackage Microsoft.DesktopAppInstaller | Sort-Object Version | Select-Object -Last 1).InstallLocation

$folders = @($dscHome, $appInstaller, (Join-Path (Split-Path $PSScriptRoot) 'dsc\resources')) | Where-Object { $_ }
$env:DSC_RESOURCE_PATH = $folders -join ';'
& $dsc.Source @args
exit $LASTEXITCODE
