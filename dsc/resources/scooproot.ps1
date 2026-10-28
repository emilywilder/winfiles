# Shared by the Winfiles/Scoop and Winfiles/ScoopPackageList scripts, which dot-source it.
# Same lookup order as Scoop: $env:SCOOP, then root_path in Scoop's config, then ~\scoop
function Get-ScoopRoot {
    $configDir = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME '.config' }
    $configFile = Join-Path $configDir 'scoop\config.json'
    $configRoot = if (Test-Path $configFile) { (Get-Content -Raw $configFile | ConvertFrom-Json).root_path }
    @($env:SCOOP, $configRoot, (Join-Path $HOME 'scoop')) | Where-Object { $_ } | Select-Object -First 1
}
