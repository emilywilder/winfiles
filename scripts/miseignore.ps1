# Dot-sourced by Invoke-Clean.ps1 and Start-Clean.ps1. Runs under Windows PowerShell 5.1 too.


function Get-MiseIgnoredConfig {
    <#
    .SYNOPSIS
    Works out which mise configuration a run should ignore, and returns the new value for MISE_IGNORED_CONFIG_PATHS.

    .DESCRIPTION
    Every file in the listing from `mise config ls --json` other than the repo's own mise.toml is ignored: the global
    ~\.config\mise\config.toml, a mise.local.toml or a mise.toml in a parent folder would otherwise add its tools and env
    to every run. It warns about each, and returns -Ignored plus those files, separated by ';' (mise reads ',' as part
    of a path, checked with 2026.11.2). It returns -Ignored unchanged when there's nothing more to ignore or no listing.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        # The JSON from `mise config ls --json`.
        [Parameter(Position = 0)]
        [string]$Listing,

        # The repo's mise.toml, the one file to keep.
        [Parameter(Position = 1)]
        [string]$Own,

        # What MISE_IGNORED_CONFIG_PATHS holds already, which the listing leaves out.
        [Parameter(Position = 2)]
        [string]$Ignored
    )

    $others = @()
    if ($Listing) {
        $others = @(ConvertFrom-Json -InputObject $Listing |
                ForEach-Object -Process { $_.path } |
                Where-Object -FilterScript { $_ -ne $Own })
    }
    foreach ($path in $others) {
        Write-Warning -Message "Ignoring mise configuration outside this repo's mise.toml: $path"
    }
    if ($others.Count) {
        (@($Ignored) + $others | Where-Object -FilterScript { $_ }) -join ';'
    } else {
        $Ignored
    }
}
