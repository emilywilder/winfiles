#Requires -Version 7.4

<#
.SYNOPSIS
Runs dsc with resource discovery limited to the folders winfiles uses, passing all arguments through.

.DESCRIPTION
By default dsc searches every PATH entry for resource manifests, and every dsc process does it again.
This sets DSC_RESOURCE_PATH for this process only to:
  - the running dsc's install folder (Microsoft.DSC/*, Microsoft.Windows/*, PowerShellScript, ...)
  - App Installer's install folder (Microsoft.WinGet/*)
  - the PSResourceGet module bundled with the pwsh running this (Microsoft.PowerShell.PSResourceGet/*),
    when it has DSC manifests (PSResourceGet 1.3.1, bundled from pwsh 7.7.0). The recipes run this under
    mise's pwsh, which is also the pwsh DSC starts for those resources
  - dsc/resources (Winfiles/*)
The persistent PATH is never touched. dsc comes from mise.toml, whose postinstall deletes DSC's
discovery extensions; this warns when they're back, since they make every dsc process ~3.3s slower.
It refuses the Store DSC (under a WindowsApps folder), which a shell without mise finds first on PATH:
it doesn't find the Winfiles/* resources, so every document using them fails with "Resource not found".

.EXAMPLE
./scripts/Invoke-Dsc.ps1 config test --file ./dsc/iris.system.dsc.yaml
#>
$dsc = Get-Command dsc -CommandType Application -ErrorAction Stop | Select-Object -First 1
$dscHome = Split-Path $dsc.Source
if ($dscHome -split '\\' -contains 'WindowsApps') {
    $host.UI.WriteErrorLine("dsc on PATH is the Store DSC ($($dsc.Source)), not mise.toml's, and it can't find the Winfiles/* resources. Run it under mise: mise exec -- just dsc ..., or activate mise in your shell.")
    exit 1
}
if (Get-ChildItem $dscHome -Filter *.dsc.extension.json) {
    Write-Warning "DSC's discovery extensions are in $dscHome, which slows every dsc process. Run: mise install --force github:PowerShell/DSC"
}
$appInstaller = (Get-AppxPackage Microsoft.DesktopAppInstaller | Sort-Object Version | Select-Object -Last 1).InstallLocation

$psResourceGet = Join-Path $PSHOME 'Modules\Microsoft.PowerShell.PSResourceGet'
if (-not (Get-ChildItem $psResourceGet -Filter *.dsc.resource.json -ErrorAction Ignore)) { $psResourceGet = $null }

$folders = @($dscHome, $appInstaller, $psResourceGet, (Join-Path (Split-Path $PSScriptRoot) 'dsc\resources')) |
    Where-Object { $_ }
$env:DSC_RESOURCE_PATH = $folders -join ';'
& $dsc.Source @args
exit $LASTEXITCODE
