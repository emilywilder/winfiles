# Implements Winfiles/ScoopPackageList (see scooppackagelist.dsc.resource.json).
# DSC pipes the instance as JSON on stdin; the operation is the first argument. Only JSON goes to stdout.
param(
    [ValidateSet('get', 'test', 'set')]
    [string]$Operation
)

. (Join-Path $PSScriptRoot 'common.ps1')
# A trap only covers the scope that declares it, so common.ps1 can't hold this one
trap { Write-ResourceMessage error "$_"; exit 1 }
$desired = $input | Read-ResourceInput
$packages = @($desired.packages)
$buckets = [ordered]@{}
if ($desired.buckets) {
    foreach ($property in $desired.buckets.PSObject.Properties) { $buckets[$property.Name] = $property.Value }
}

. (Join-Path $PSScriptRoot 'scooproot.ps1')
$root = Get-ScoopRoot
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

# Scoop reports through Write-Host and Write-Error. Send all of it to stderr, and keep its errors non-terminating.
# Its line naming each app it starts on is raised to warn, because a slow download otherwise looks like a hang
function Invoke-Scoop {
    $ErrorActionPreference = 'Continue'
    & $scoop @args *>&1 | ForEach-Object {
        if ("$_" -like "Installing '*") { Write-ResourceMessage warn "$_" } else { [Console]::Error.WriteLine("$_") }
    }
}

# @() at each call: PowerShell unrolls function output, so 0 or 1 results wouldn't stay arrays
$missingBuckets = @(Get-MissingBuckets)
$missing = @(Get-MissingPackages)

if ($Operation -eq 'set' -and ($missingBuckets -or $missing)) {
    if (-not (Test-Path $scoop)) {
        Write-ResourceMessage error "Scoop is not installed at $root; Winfiles/Scoop installs it, so make this list depend on one"
        exit 3
    }
    # Adding a bucket other than main needs git, so a list that adds buckets should depend on one that installs git.
    # Scoop finds git through its shims, which its installer adds to the user PATH. A process started before
    # Scoop was installed (a fresh `just install`) doesn't have them, so add them for this process only
    $shims = Join-Path $root 'shims'
    if (($env:Path -split ';') -notcontains $shims) { $env:Path = "$shims;$env:Path" }
    foreach ($name in $missingBuckets) {
        $bucketArgs = @('bucket', 'add', $name) + @($buckets[$name] | Where-Object { $_ })
        Invoke-Scoop @bucketArgs
    }
    # One call installs the lot and checks for Scoop updates once; Scoop moves on past an app that fails
    if ($missing) { Invoke-Scoop install @missing }

    $missingBuckets = @(Get-MissingBuckets)
    $missing = @(Get-MissingPackages)
    foreach ($item in $missingBuckets + $missing) { Write-ResourceMessage error "Failed to install ${item}" }
}

$state = [ordered]@{
    packages       = $packages
    buckets        = $buckets
    missing        = $missing
    missingBuckets = $missingBuckets
}
if ($Operation -eq 'test') { $state['_inDesiredState'] = $missing.Count + $missingBuckets.Count -eq 0 }
$state | ConvertTo-Json -Compress -Depth 3

# What failed stays in `missing` or `missingBuckets` and still exits 0: DSC stops the whole configuration when a
# resource exits non-zero, and `just check` reports it after the run.
# The manifest ends its command with `exit $LASTEXITCODE`, so always exit explicitly
exit 0
