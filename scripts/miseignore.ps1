# Dot-sourced by Invoke-Clean.ps1. Works out which mise configuration a run should ignore: every file in the listing
# from `mise config ls --json` other than the repo's own mise.toml. The global ~\.config\mise\config.toml, a
# mise.local.toml or a mise.toml in a parent folder would otherwise add its tools and env to every run.

# Warns about each file it ignores, and returns the new value for MISE_IGNORED_CONFIG_PATHS: -Ignored (what's ignored
# already, which the listing leaves out) plus those files, separated by ';' (mise reads ',' as part of a path, checked
# with 2026.11.2). Returns -Ignored unchanged when there's nothing more to ignore or no listing.
function Get-MiseIgnoredConfig {
    [CmdletBinding()]
    param([string]$Listing, [string]$Own, [string]$Ignored)
    if (-not $Listing) { return $Ignored }
    $others = @(($Listing | ConvertFrom-Json) | ForEach-Object { $_.path } | Where-Object { $_ -ne $Own })
    foreach ($path in $others) {
        Write-Warning "Ignoring mise configuration outside this repo's mise.toml: $path"
    }
    if (-not $others.Count) { return $Ignored }
    (@($Ignored) + $others | Where-Object { $_ }) -join ';'
}
