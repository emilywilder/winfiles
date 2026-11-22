# Shared by the Winfiles.Scoop/Scoop, Winfiles.Scoop/Package and Winfiles.Scoop/Bucket scripts and Show-ScoopNote.ps1,
# which dot-source it.


function Get-ScoopRoot {
    <#
    .SYNOPSIS
    Returns Scoop's root folder, in Scoop's own lookup order: $env:SCOOP, then root_path in Scoop's config, then
    ~\scoop.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $configDir = $env:XDG_CONFIG_HOME
    if (-not $configDir) {
        $configDir = Join-Path -Path $HOME -ChildPath '.config'
    }
    $configFile = Join-Path -Path $configDir -ChildPath 'scoop\config.json'
    $configRoot = if (Test-Path -Path $configFile) {
        (Get-Content -Path $configFile -Raw | ConvertFrom-Json).root_path
    }
    @($env:SCOOP, $configRoot, (Join-Path -Path $HOME -ChildPath 'scoop')) |
        Where-Object -FilterScript { $_ } |
        Select-Object -First 1
}
