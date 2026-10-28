# Implements Winfiles/WinGetPackageList (see wingetpackagelist.dsc.resource.json).
# DSC pipes the instance as JSON on stdin; the operation is the first argument. Only JSON goes to stdout.
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('get', 'test', 'set')]
    [string]$Operation,

    [Parameter(ValueFromPipeline)]
    [string]$InputJson
)

begin {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    $lines = [System.Collections.Generic.List[string]]::new()
}

process {
    if ($InputJson) { $lines.Add($InputJson) }
}

end {
    $desired = $lines -join "`n" | ConvertFrom-Json
    $packages = @($desired.packages)
    $source = if ($desired.source) { $desired.source } else { 'winget' }

    Import-Module Microsoft.WinGet.Client

    # One listing of everything installed is far faster than a lookup per package.
    function Get-MissingPackages {
        $installed = @(Get-WinGetPackage | Where-Object Source -eq $source | ForEach-Object Id)
        $packages | Where-Object { $_ -notin $installed }
    }

    # @() at each call: PowerShell unrolls function output, so 0 or 1 results wouldn't stay arrays
    $missing = @(Get-MissingPackages)

    if ($Operation -eq 'set' -and $missing) {
        $failed = foreach ($id in $missing) {
            $result = Install-WinGetPackage -Id $id -Source $source -MatchOption Equals -Mode Silent
            if ($result.Status -ne 'Ok') {
                [Console]::Error.WriteLine("Failed to install ${id}: $($result.Status) $($result.ExtendedErrorCode)")
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
    if ($Operation -eq 'test') { $state['_inDesiredState'] = $missing.Count -eq 0 }
    $state | ConvertTo-Json -Compress -Depth 3

    if ($failed) { exit 2 }
}
