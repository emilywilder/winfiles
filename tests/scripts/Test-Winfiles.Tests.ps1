# Test-Winfiles.ps1 and Set-Winfiles.ps1 run dsc through dsclog.ps1 and Invoke-Dsc.ps1, here against the fake dsc
# (tests/fakes/bin/dsc.cmd) with canned results, and keep those results under a $HOME in TestDrive:.
BeforeAll {
    . (Join-Path $PSScriptRoot '..\resources\Resource.ps1')

    function Get-KeptResults($Dsc) {
        $folder = Join-Path $Dsc.Home '.local\state\winfiles\dsc'
        if (Test-Path $folder) { @(Get-ChildItem $folder) } else { @() }
    }
}

Describe 'Test-Winfiles.ps1' {
    It 'reports every resource in its desired state, and exits 0' {
        $dsc = New-FakeDsc
        Set-FakeDscResult $dsc iris.system.dsc.yaml @(
            New-DscResult Microsoft.Windows/RegistryList settings
            New-DscResult Winfiles/ScoopPackageList base
        )
        $result = Invoke-Script Test-Winfiles.ps1 'dsc/iris.system.dsc.yaml' -Environment $dsc.Environment
        $result.ExitCode | Should -Be 0
        $result.Stdout | Should -Contain 'dsc/iris.system.dsc.yaml: 2 of 2 in desired state'
        $result.Stdout | Should -Contain 'passed: all 2 resources are in desired state'
        (Get-FakeDscCalls $dsc)[0].args | Should -Be @('config', 'test', '--output-format', 'json', '--file', 'dsc/iris.system.dsc.yaml')
    }

    It "counts the resources inside Includes, and names what's missing from each list" {
        $dsc = New-FakeDsc
        Set-FakeDscResult $dsc home.dsc.yaml @(
            New-DscInclude packages @(
                New-DscResult Winfiles/ScoopPackageList base -Differs -ActualState @{ missing = @('A.One', 'B.Two') }
                New-DscInclude nested @(
                    New-DscResult Winfiles/ScoopPackageList dev -Differs -ActualState @{ missing = @('meld'); missingBuckets = @('extras') }
                )
            )
            New-DscResult Winfiles/FileContentList profile -Differs -ActualState @{ outOfDate = @('C:\x\profile.ps1') }
            New-DscResult Microsoft.Windows/RegistryList settings -Differs -Differing registryEntries
            New-DscResult Winfiles/Scoop scoop
        )
        $result = Invoke-Script Test-Winfiles.ps1 'home.dsc.yaml' -Environment $dsc.Environment
        $result.ExitCode | Should -Be 1
        $result.Stdout | Should -Be @(
            'home.dsc.yaml: 1 of 5 in desired state'
            "  Winfiles/ScoopPackageList 'base': A.One, B.Two"
            "  Winfiles/ScoopPackageList 'dev': meld, extras"
            "  Winfiles/FileContentList 'profile': C:\x\profile.ps1"
            "  Microsoft.Windows/RegistryList 'settings': registryEntries"
            'failed: 4 of 5 resources are not in desired state, or dsc failed'
        )
    }

    It 'names a missing package by its id, and lists any other differing property' {
        $dsc = New-FakeDsc
        Set-FakeDscResult $dsc home.dsc.yaml @(
            New-DscResult Microsoft.WinGet/Package 'GitHub CLI' -Differs -Differing _exist -ActualState @{ _exist = $false; id = 'GitHub.cli' }
            New-DscResult Winfiles.WinGet/Package Obsidian -Differs -Differing _exist -ActualState @{ _exist = $false; id = 'Obsidian.Obsidian'; _scope = 'User' }
            New-DscResult Microsoft.WinGet/Package PowerShell -Differs -Differing version -ActualState @{ _exist = $true; id = 'Microsoft.PowerShell' }
        )
        $result = Invoke-Script Test-Winfiles.ps1 'home.dsc.yaml' -Environment $dsc.Environment
        $result.ExitCode | Should -Be 1
        $result.Stdout[1..3] | Should -Be @(
            "  Microsoft.WinGet/Package 'GitHub CLI': GitHub.cli"
            "  Winfiles.WinGet/Package 'Obsidian': Obsidian.Obsidian"
            "  Microsoft.WinGet/Package 'PowerShell': version"
        )
    }

    # One of the cases checked by hand when Test-Winfiles.ps1 was written
    It 'still tests the next configuration when dsc fails on one, and exits 1' {
        $dsc = New-FakeDsc
        Set-FakeDscResult $dsc broken.dsc.yaml -NoOutput -ExitCode 2
        Set-FakeDscResult $dsc good.dsc.yaml @(New-DscResult Test/Thing one)
        $result = Invoke-Script Test-Winfiles.ps1 'broken.dsc.yaml', 'good.dsc.yaml' -Environment $dsc.Environment
        $result.ExitCode | Should -Be 1
        $result.Stdout | Should -Contain 'broken.dsc.yaml: dsc failed with exit code 2'
        $result.Stdout | Should -Contain 'good.dsc.yaml: 1 of 1 in desired state'
    }

    It 'keeps what it says in the run log, with the time and phase, and leaves the phase out of the console' {
        $dsc = New-FakeDsc
        Set-FakeDscResult $dsc iris.system.dsc.yaml @(New-DscResult Test/Thing one -Differs -ActualState @{ missing = @('A.One') })
        $result = Invoke-Script Test-Winfiles.ps1 'dsc/iris.system.dsc.yaml' -Environment $dsc.Environment
        $result.Stdout | Should -Not -BeLike '*[[]check]*'
        $log = Get-Content (Join-Path $dsc.Home '.local\state\winfiles\run.log')
        $log | Should -Match '^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d \[check\] '
        ($log -join "`n") | Should -BeLike '*testing 1 configuration*'
        ($log -join "`n") | Should -BeLike "*[[]check]   Test/Thing 'one': A.One*"
    }

    It 'keeps each result in ~/.local/state/winfiles/dsc, named by time, operation and document' {
        $dsc = New-FakeDsc
        Set-FakeDscResult $dsc iris.system.dsc.yaml @(New-DscResult Test/Thing one)
        Set-FakeDscResult $dsc emily@iris.home.dsc.yaml @(New-DscResult Test/Thing two)
        Invoke-Script Test-Winfiles.ps1 'dsc/iris.system.dsc.yaml', 'dsc/emily@iris.home.dsc.yaml' -Environment $dsc.Environment |
            Out-Null
        $kept = Get-KeptResults $dsc
        $kept.Name | Should -HaveCount 2
        $kept.Name | Should -Match '^\d{8}-\d{6}-test-(iris\.system|emily@iris\.home)\.json$'
        (Get-Content -Raw ($kept | Where-Object Name -like '*-iris.system.json').FullName | ConvertFrom-Json).results[0].name |
            Should -Be 'one'
    }

    It "keeps nothing when dsc prints nothing" {
        $dsc = New-FakeDsc
        Set-FakeDscResult $dsc broken.dsc.yaml -NoOutput -ExitCode 2
        Invoke-Script Test-Winfiles.ps1 'broken.dsc.yaml' -Environment $dsc.Environment | Out-Null
        Get-KeptResults $dsc | Should -BeNullOrEmpty
    }
}

Describe 'Set-Winfiles.ps1' {
    It "applies the document, keeps the result and exits with dsc's exit code" {
        $dsc = New-FakeDsc
        Set-FakeDscResult $dsc emily@iris.home.dsc.yaml @(New-DscResult Test/Thing one) -ExitCode 2
        $result = Invoke-Script Set-Winfiles.ps1 'dsc/emily@iris.home.dsc.yaml' -Environment $dsc.Environment
        $result.ExitCode | Should -Be 2
        (Get-FakeDscCalls $dsc)[0].args | Should -Be @('config', 'set', '--output-format', 'json', '--file', 'dsc/emily@iris.home.dsc.yaml')
        (Get-KeptResults $dsc).Name | Should -Match '^\d{8}-\d{6}-set-emily@iris\.home\.json$'
    }

    It "doesn't print dsc's JSON" {
        $dsc = New-FakeDsc
        Set-FakeDscResult $dsc doc.dsc.yaml @(New-DscResult Test/Thing one)
        (Invoke-Script Set-Winfiles.ps1 'doc.dsc.yaml' -Environment $dsc.Environment).Stdout -join "`n" | Should -Not -BeLike '*{*'
    }

    It 'logs when it starts and finishes, named by the kind of document, without printing it' {
        $dsc = New-FakeDsc
        Set-FakeDscResult $dsc emily@iris.home.dsc.yaml @(New-DscResult Test/Thing one; New-DscInclude inner @(New-DscResult Test/Thing two) -Set)
        $result = Invoke-Script Set-Winfiles.ps1 'dsc/emily@iris.home.dsc.yaml' -Environment $dsc.Environment
        $result.Stdout | Should -BeNullOrEmpty
        $log = @(Get-Content (Join-Path $dsc.Home '.local\state\winfiles\run.log'))
        $log[0] | Should -Match ' \[home\] applying dsc/emily@iris\.home\.dsc\.yaml$'
        $log[1] | Should -Match ' \[home\] done in \d+s, 2 resources$'
    }

    It 'names what a run left missing, and still exits 0' {
        $dsc = New-FakeDsc
        Set-FakeDscResult $dsc iris.system.dsc.yaml @(
            New-DscResult Winfiles/ScoopPackageList base -AfterState @{ missing = @('A.One') }
            New-DscResult Test/Thing fine
        )
        $result = Invoke-Script Set-Winfiles.ps1 'dsc/iris.system.dsc.yaml' -Environment $dsc.Environment
        $result.ExitCode | Should -Be 0
        $result.Stdout[0] | Should -Match '^done in \d+s, 2 resources, 1 not fully applied'
        $result.Stdout[1] | Should -Be "  Winfiles/ScoopPackageList 'base': A.One"
    }

    It 'names what the lists inside Includes left missing, through nested Includes' {
        $dsc = New-FakeDsc
        Set-FakeDscResult $dsc emily@iris.home.dsc.yaml @(
            New-DscInclude packages @(
                New-DscResult Winfiles/ScoopPackageList apps -AfterState @{ missing = @('jq', 'extras/everything') }
                New-DscInclude nested @(
                    New-DscResult Winfiles/ScoopPackageList buckets -AfterState @{ missing = @(); missingBuckets = @('extras') }
                ) -Set
            ) -Set
            New-DscInclude settings @(New-DscResult Test/Thing fine) -Set
        )
        $result = Invoke-Script Set-Winfiles.ps1 'dsc/emily@iris.home.dsc.yaml' -Environment $dsc.Environment
        $result.ExitCode | Should -Be 0
        $result.Stdout[0] | Should -Match '^done in \d+s, 3 resources, 2 not fully applied'
        $result.Stdout[1] | Should -Be "  Winfiles/ScoopPackageList 'apps': jq, extras/everything"
        $result.Stdout[2] | Should -Be "  Winfiles/ScoopPackageList 'buckets': extras"
    }

    It 'says which document dsc failed on, and keeps it in the run log' {
        $dsc = New-FakeDsc
        Set-FakeDscResult $dsc features.dsc.yaml -NoOutput -ExitCode 2
        $result = Invoke-Script Set-Winfiles.ps1 'dsc/hosts/vm/features.dsc.yaml' -Environment $dsc.Environment
        $result.ExitCode | Should -Be 2
        $result.Stdout[0] | Should -Match '^dsc/hosts/vm/features\.dsc\.yaml: dsc failed with exit code 2 after \d+s$'
        (Get-Content (Join-Path $dsc.Home '.local\state\winfiles\run.log'))[-1] | Should -Match '\[features\] dsc/hosts/vm/features\.dsc\.yaml: dsc failed'
    }
}
