# Implements Winfiles/WinGetPackageList (see wingetpackagelist.dsc.resource.json).
# DSC pipes the instance as JSON on stdin; the operation is the first argument. Only JSON goes to stdout.
param(
    [ValidateSet('get', 'test', 'set')]
    [string]$Operation
)

. (Join-Path $PSScriptRoot 'common.ps1')
$desired = $input | Read-ResourceInput
$packages = @($desired.packages)
$source = if ($desired.source) { $desired.source } else { 'winget' }
$installOptions = @{ Source = $source; MatchOption = 'Equals'; Mode = 'Silent' }
if ($desired.scope) { $installOptions['Scope'] = $desired.scope }

Import-Module Microsoft.WinGet.Client

# One listing of everything installed is far faster than a lookup per package.
function Get-MissingPackages {
    $installed = @(Get-WinGetPackage | Where-Object Source -eq $source | ForEach-Object Id)
    $packages | Where-Object { $_ -notin $installed }
}

# @() at each call: PowerShell unrolls function output, so 0 or 1 results wouldn't stay arrays
$missing = @(Get-MissingPackages)

if ($Operation -eq 'set' -and $missing) {
    # An id with no match throws instead of returning a status; catch it so the rest of the list still installs
    $position = 0
    $failed = foreach ($id in $missing) {
        $position++
        # DSC only shows this JSON form, and at warn without needing -l info and DSC's own lines (tests/dsc-messages/README.md)
        [Console]::Error.WriteLine((@{ warn = "Installing $id ($position/$($missing.Count))" } | ConvertTo-Json -Compress))
        [Console]::Error.Flush()
        try {
            $result = Install-WinGetPackage -Id $id @installOptions
            $reason = if ($result.Status -ne 'Ok') { "$($result.Status) $($result.ExtendedErrorCode)" }
        } catch {
            $reason = $_.Exception.Message
        }
        if ($reason) {
            [Console]::Error.WriteLine("Failed to install ${id}: $reason")
            $id
        }
    }
    $missing = @(Get-MissingPackages)
}

$state = [ordered]@{
    packages = $packages
    source   = $source
    missing  = $missing
}
if ($desired.scope) { $state['scope'] = $desired.scope }
if ($Operation -eq 'test') { $state['_inDesiredState'] = $missing.Count -eq 0 }
$state | ConvertTo-Json -Compress -Depth 3

# The manifest ends its command with `exit $LASTEXITCODE`, so always exit explicitly
if ($failed) { exit 2 }
exit 0
