# Shared by the Winfiles/Scoop and Winfiles/ScoopPackageList scripts, which dot-source it.


function Get-ScoopRoot {
    <#
    .SYNOPSIS
    Returns Scoop's root folder, in Scoop's own lookup order: $env:SCOOP, then root_path in Scoop's config, then
    ~\scoop.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $configDir = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path -Path $HOME -ChildPath '.config' }
    $configFile = Join-Path -Path $configDir -ChildPath 'scoop\config.json'
    $configRoot = if (Test-Path -Path $configFile) {
        (Get-Content -Path $configFile -Raw | ConvertFrom-Json).root_path
    }
    @($env:SCOOP, $configRoot, (Join-Path -Path $HOME -ChildPath 'scoop')) |
        Where-Object -FilterScript { $_ } |
        Select-Object -First 1
}
