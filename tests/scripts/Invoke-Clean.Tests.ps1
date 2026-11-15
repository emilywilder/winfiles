# Only the choice of mise configuration to ignore (miseignore.ps1), run in this process: Invoke-Clean.ps1 itself
# rebuilds its environment from the registry, so a test couldn't point it at fakes
BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\scripts\miseignore.ps1')
    $own = 'C:\src\winfiles\mise.toml'

    function ConvertTo-Listing([string[]]$Paths) {
        ConvertTo-Json -InputObject @($Paths | ForEach-Object { @{ path = $_; tools = @(); override = $false } })
    }
}

Describe 'Get-MiseIgnoredConfig' {
    It 'ignores nothing when only the repo''s mise.toml is in effect' {
        $result = Get-MiseIgnoredConfig (ConvertTo-Listing $own) $own '' -WarningVariable warnings
        $result | Should -BeNullOrEmpty
        $warnings | Should -BeNullOrEmpty
    }

    It 'ignores every other file, separated by '';'', with a warning for each' {
        $global = 'C:\Users\me\.config\mise\config.toml'
        $local = 'C:\src\winfiles\mise.local.toml'
        $result = Get-MiseIgnoredConfig (ConvertTo-Listing $local, $own, $global) $own '' -WarningVariable warnings
        $result | Should -Be "$local;$global"
        $warnings.Message | Should -Be @(
            "Ignoring mise configuration outside this repo's mise.toml: $local"
            "Ignoring mise configuration outside this repo's mise.toml: $global"
        )
    }

    It 'compares paths without regard to case, as Windows does' {
        $result = Get-MiseIgnoredConfig (ConvertTo-Listing $own.ToUpper()) $own '' -WarningVariable warnings
        $result | Should -BeNullOrEmpty
        $warnings | Should -BeNullOrEmpty
    }

    It 'keeps what the user already ignores' {
        $parent = 'C:\src\mise.toml'
        Get-MiseIgnoredConfig (ConvertTo-Listing $own, $parent) $own 'C:\old.toml' 3>$null | Should -Be "C:\old.toml;$parent"
        Get-MiseIgnoredConfig (ConvertTo-Listing $own) $own 'C:\old.toml' | Should -Be 'C:\old.toml'
    }

    # mise config ls fails when mise is too old for min_version; mise exec then says so itself
    It 'leaves the setting alone without a listing' {
        Get-MiseIgnoredConfig '' $own 'C:\old.toml' | Should -Be 'C:\old.toml'
    }
}
