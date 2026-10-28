#Requires -Version 7.4
<#
.SYNOPSIS
Runs dsc with resource discovery limited to the folders winfiles uses, passing all arguments through.

.DESCRIPTION
By default dsc searches every PATH entry for resource manifests, and every dsc process does it again
(about 4.5s each time). This sets DSC_RESOURCE_PATH for this process only to:
  - the running dsc's install folder (Microsoft.DSC/*, Microsoft.Windows/*, PowerShellScript, ...)
  - App Installer's install folder (Microsoft.WinGet/*)
  - dsc/resources (Winfiles/*)
  - pwsh's folder (for tryWhich('pwsh') conditions)
The persistent PATH is never touched.

.EXAMPLE
./scripts/Invoke-Dsc.ps1 config test --file ./dsc/winfiles.dsc.yaml
#>
$dsc = Get-Command dsc -CommandType Application -ErrorAction Stop | Select-Object -First 1
# The Store package puts an app execution alias on PATH; its real folder comes from the Appx package
$dscHome = if ($dsc.Source -like "$env:LOCALAPPDATA\Microsoft\WindowsApps\*") {
    (Get-AppxPackage Microsoft.DesiredStateConfiguration | Sort-Object Version | Select-Object -Last 1).InstallLocation
} else {
    Split-Path $dsc.Source
}
$appInstaller = (Get-AppxPackage Microsoft.DesktopAppInstaller | Sort-Object Version | Select-Object -Last 1).InstallLocation

# pwsh's folder too: manifest conditions like tryWhich('pwsh') search DSC_RESOURCE_PATH, not PATH
$pwshHome = Split-Path (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$folders = @($dscHome, $appInstaller, (Join-Path (Split-Path $PSScriptRoot) 'dsc\resources'), $pwshHome) | Where-Object { $_ }
$env:DSC_RESOURCE_PATH = $folders -join ';'
& $dsc.Source @args
exit $LASTEXITCODE
