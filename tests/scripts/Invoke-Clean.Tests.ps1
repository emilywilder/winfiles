# Only the choice of mise configuration to ignore (miseignore.ps1), run in this process: Invoke-Clean.ps1 itself
# rebuilds its environment from the registry, so a test couldn't point it at fakes
BeforeAll {
    . (Join-Path $PSScriptRoot '..\resources\Resource.ps1')
    . (Join-Path $PSScriptRoot '..\..\scripts\miseignore.ps1')
    $own = 'C:\src\winfiles\mise.toml'
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

    function ConvertTo-Listing([string[]]$Paths) {
        ConvertTo-Json -InputObject @($Paths | ForEach-Object { @{ path = $_; tools = @(); override = $false } })
    }

    # Get-MiseIgnoredConfig under Windows PowerShell 5.1, as install.cmd runs Invoke-Clean.ps1. The listing and the
    # setting go through the environment, away from -Command's quoting. Its warnings land on stdout as 'WARNING: ...'
    function Invoke-MiseIgnore51([string]$Listing, [string]$Ignored) {
        $command = ". '$repo\scripts\miseignore.ps1'; " +
            "'result=' + (Get-MiseIgnoredConfig `$env:WINFILES_TEST_LISTING '$own' `$env:WINFILES_TEST_IGNORED)"
        $run = Invoke-Child $TestDrive @{ WINFILES_TEST_LISTING = $Listing; WINFILES_TEST_IGNORED = $Ignored } {
            & $powershell -NoProfile -NonInteractive -Command $command
        }
        [pscustomobject]@{
            ExitCode = $run.ExitCode
            Result   = ($run.Stdout | Where-Object { $_ -like 'result=*' }) -replace '^result='
            Warnings = @($run.Stdout | Where-Object { $_ -like 'WARNING: *' }) -replace '^WARNING: '
        }
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

# 5.1's ConvertFrom-Json writes an array as one object, and its comparisons and joins differ in places from pwsh 7's
Describe 'Get-MiseIgnoredConfig under Windows PowerShell 5.1' {
    It 'ignores nothing when only the repo''s mise.toml is in effect, whatever its case' {
        $result = Invoke-MiseIgnore51 (ConvertTo-Listing $own.ToUpper()) ''
        $result.ExitCode | Should -Be 0
        $result.Result | Should -BeNullOrEmpty
        $result.Warnings | Should -BeNullOrEmpty
    }

    It 'ignores a single other file, with a warning' {
        $global = 'C:\Users\me\.config\mise\config.toml'
        $result = Invoke-MiseIgnore51 (ConvertTo-Listing $own, $global) ''
        $result.Result | Should -Be $global
        $result.Warnings | Should -Be "Ignoring mise configuration outside this repo's mise.toml: $global"
    }

    It 'adds every other file to what the user already ignores, separated by '';''' {
        $local = 'C:\src\winfiles\mise.local.toml'
        $parent = 'C:\src\mise.toml'
        $result = Invoke-MiseIgnore51 (ConvertTo-Listing $local, $own, $parent) 'C:\old.toml'
        $result.Result | Should -Be "C:\old.toml;$local;$parent"
        $result.Warnings | Should -HaveCount 2
    }
}

# Invoke-Clean.ps1 compares each listed path with Join-Path's, so a different spelling from mise (forward slashes, a
# \\?\ prefix) would make it ignore the repo's own mise.toml and lose its tools
Describe 'mise config ls --json' {
    It 'lists the repo''s mise.toml at the path Invoke-Clean.ps1 compares with' {
        $run = Invoke-Child $repo @{} { mise config ls --json }
        $run.ExitCode | Should -Be 0
        $paths = @(($run.Stdout -join "`n" | ConvertFrom-Json).path)
        $paths | Should -Contain (Join-Path $repo 'mise.toml')
    }
}
