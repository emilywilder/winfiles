# Implements Winfiles/ScoopPackageList (see scooppackagelist.dsc.resource.json).
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
    $buckets = [ordered]@{}
    if ($desired.buckets) {
        foreach ($property in $desired.buckets.PSObject.Properties) { $buckets[$property.Name] = $property.Value }
    }

    # Same lookup order as Scoop: $env:SCOOP, then root_path in Scoop's config, then ~\scoop
    $configDir = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME '.config' }
    $configFile = Join-Path $configDir 'scoop\config.json'
    $configRoot = if (Test-Path $configFile) { (Get-Content -Raw $configFile | ConvertFrom-Json).root_path }
    $root = @($env:SCOOP, $configRoot, (Join-Path $HOME 'scoop')) | Where-Object { $_ } | Select-Object -First 1
    $scoop = Join-Path $root 'apps\scoop\current\bin\scoop.ps1'

    # Read state from Scoop's folders: far faster than `scoop list` or `scoop export`, which load all of Scoop
    function Get-MissingBuckets {
        @($buckets.Keys) | Where-Object { -not (Test-Path (Join-Path $root "buckets\$_")) }
    }

    function Get-MissingPackages {
        foreach ($package in $packages) {
            $bucket, $name = if ($package -match '/') { $package -split '/', 2 } else { $null, $package }
            # Scoop writes scoop-install.json; apps installed by older Scoop versions have install.json
            $installFile = @('scoop-install.json', 'install.json') |
                ForEach-Object { Join-Path $root "apps\$name\current\$_" } |
                Where-Object { Test-Path $_ } | Select-Object -First 1
            $installed = $installFile -and (
                -not $bucket -or (Get-Content -Raw $installFile | ConvertFrom-Json).bucket -eq $bucket)
            if (-not $installed) { $package }
        }
    }

    # Scoop reports through Write-Host and Write-Error. Send all of it to stderr, and keep its errors non-terminating
    function Invoke-Scoop {
        $ErrorActionPreference = 'Continue'
        & $scoop @args *>&1 | ForEach-Object { [Console]::Error.WriteLine("$_") }
    }

    # @() at each call: PowerShell unrolls function output, so 0 or 1 results wouldn't stay arrays
    $missingBuckets = @(Get-MissingBuckets)
    $missing = @(Get-MissingPackages)

    if ($Operation -eq 'set' -and ($missingBuckets -or $missing)) {
        if (-not (Test-Path $scoop)) {
            [Console]::Error.WriteLine("Scoop is not installed at $root; install it with ``just scoop-install`` from an unelevated shell")
            exit 3
        }
        # Adding a bucket other than main needs git, so a list that adds buckets should depend on one that installs git
        foreach ($name in $missingBuckets) {
            $bucketArgs = @('bucket', 'add', $name) + @($buckets[$name] | Where-Object { $_ })
            Invoke-Scoop @bucketArgs
        }
        # One call installs the lot and checks for Scoop updates once; Scoop moves on past an app that fails
        if ($missing) { Invoke-Scoop install @missing }

        $missingBuckets = @(Get-MissingBuckets)
        $missing = @(Get-MissingPackages)
        foreach ($item in $missingBuckets + $missing) { [Console]::Error.WriteLine("Failed to install ${item}") }
        $failed = $missingBuckets.Count + $missing.Count -gt 0
    }

    $state = [ordered]@{
        packages       = $packages
        buckets        = $buckets
        missing        = $missing
        missingBuckets = $missingBuckets
    }
    if ($Operation -eq 'test') { $state['_inDesiredState'] = $missing.Count + $missingBuckets.Count -eq 0 }
    $state | ConvertTo-Json -Compress -Depth 3

    # The manifest ends its command with `exit $LASTEXITCODE`, so always exit explicitly
    if ($failed) { exit 2 }
    exit 0
}
