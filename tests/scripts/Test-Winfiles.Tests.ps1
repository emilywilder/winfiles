# Test-Winfiles.ps1 and Set-Winfiles.ps1 run dsc through dsclog.ps1 and Invoke-Dsc.ps1, here against the fake dsc
# (tests/fakes/bin/dsc.cmd) with canned results, and keep those results under a $HOME in TestDrive:. They take flat
# documents, as Invoke-Configuration.ps1 makes them, and refuse one with an Include.
BeforeAll {
    . (Join-Path $PSScriptRoot '..\resources\Resource.ps1')

    # A folder to run Test-Winfiles.ps1 or Set-Winfiles.ps1 from, with a small flat document at each of -Paths: the
    # fake dsc answers by file name, whatever the document holds
    function New-WorkFolder([string[]]$Paths) {
        $folder = New-Item -ItemType Directory (Join-Path $TestDrive "work-$([guid]::NewGuid())")
        foreach ($path in $Paths) {
            $file = Join-Path $folder $path
            $null = New-Item -ItemType Directory -Force (Split-Path $file)
            $schema = 'https://raw.githubusercontent.com/PowerShell/DSC/main/schemas/2023/08/config/document.json'
            Set-Content $file "`$schema: $schema`nresources:`n  - { type: Test/Thing, name: one, properties: {} }"
        }
        $folder.FullName
    }

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
            New-DscResult Winfiles.Scoop/Package git
        )
        $work = New-WorkFolder 'dsc/iris.system.dsc.yaml'
        $result = Invoke-Script Test-Winfiles.ps1 'dsc/iris.system.dsc.yaml' `
            -Environment $dsc.Environment -Directory $work
        $result.ExitCode | Should -Be 0
        $result.Stdout | Should -Contain 'dsc/iris.system.dsc.yaml: 2 of 2 in desired state'
        $result.Stdout | Should -Contain 'passed: all 2 resources are in desired state'
        (Get-FakeDscCalls $dsc)[0].args |
            Should -Be @('config', 'test', '--output-format', 'json', '--file', 'dsc/iris.system.dsc.yaml')
    }

    It "counts the resources inside Includes, and names what's wrong with each" {
        $dsc = New-FakeDsc
        Set-FakeDscResult $dsc home.dsc.yaml @(
            New-DscInclude packages @(
                New-DscResult Winfiles.Scoop/Package meld -Differs -Differing _exist `
                    -ActualState @{ name = 'meld'; _exist = $false }
                New-DscInclude nested @(
                    New-DscResult Winfiles.Scoop/Bucket extras -Differs -Differing _exist `
                        -ActualState @{ name = 'extras'; _exist = $false }
                )
            )
            New-DscResult Winfiles/FileContentList profile -Differs `
                -ActualState @{ outOfDate = @('C:\x\profile.ps1') }
            New-DscResult Microsoft.Windows/RegistryList settings -Differs -Differing registryEntries
            New-DscResult Winfiles/Scoop scoop
        )
        $result = Invoke-Script Test-Winfiles.ps1 'home.dsc.yaml' `
            -Environment $dsc.Environment -Directory (New-WorkFolder 'home.dsc.yaml')
        $result.ExitCode | Should -Be 1
        $result.Stdout | Should -Be @(
            'home.dsc.yaml: 1 of 5 in desired state'
            "  Winfiles.Scoop/Package 'meld': meld"
            "  Winfiles.Scoop/Bucket 'extras': extras"
            "  Winfiles/FileContentList 'profile': C:\x\profile.ps1"
            "  Microsoft.Windows/RegistryList 'settings': registryEntries"
            'failed: 4 of 5 resources are not in desired state, or dsc failed'
        )
    }

    It 'names a missing package by its id, and lists any other differing property' {
        $dsc = New-FakeDsc
        Set-FakeDscResult $dsc home.dsc.yaml @(
            New-DscResult Microsoft.WinGet/Package 'GitHub CLI' -Differs -Differing _exist `
                -ActualState @{ _exist = $false; id = 'GitHub.cli' }
            New-DscResult Winfiles.WinGet/Package Obsidian -Differs -Differing _exist `
                -ActualState @{ _exist = $false; id = 'Obsidian.Obsidian'; _scope = 'User' }
            New-DscResult Microsoft.WinGet/Package PowerShell -Differs -Differing version `
                -ActualState @{ _exist = $true; id = 'Microsoft.PowerShell' }
            New-DscResult Winfiles.Scoop/Package vscode -Differs -Differing bucket `
                -ActualState @{ _exist = $true; name = 'vscode'; bucket = 'main' }
        )
        $result = Invoke-Script Test-Winfiles.ps1 'home.dsc.yaml' `
            -Environment $dsc.Environment -Directory (New-WorkFolder 'home.dsc.yaml')
        $result.ExitCode | Should -Be 1
        $result.Stdout[1..4] | Should -Be @(
            "  Microsoft.WinGet/Package 'GitHub CLI': GitHub.cli"
            "  Winfiles.WinGet/Package 'Obsidian': Obsidian.Obsidian"
            "  Microsoft.WinGet/Package 'PowerShell': version"
            "  Winfiles.Scoop/Package 'vscode': bucket"
        )
    }

    # One of the cases checked by hand when Test-Winfiles.ps1 was written
    It 'still tests the next configuration when dsc fails on one, and exits 1' {
        $dsc = New-FakeDsc
        Set-FakeDscResult $dsc broken.dsc.yaml -NoOutput -ExitCode 2
        Set-FakeDscResult $dsc good.dsc.yaml @(New-DscResult Test/Thing one)
        $result = Invoke-Script Test-Winfiles.ps1 'broken.dsc.yaml', 'good.dsc.yaml' `
            -Environment $dsc.Environment -Directory (New-WorkFolder 'broken.dsc.yaml', 'good.dsc.yaml')
        $result.ExitCode | Should -Be 1
        $result.Stdout | Should -Contain 'broken.dsc.yaml: dsc failed with exit code 2'
        $result.Stdout | Should -Contain 'good.dsc.yaml: 1 of 1 in desired state'
    }

    It 'keeps what it says in the run log, with the time and phase, and leaves the phase out of the console' {
        $dsc = New-FakeDsc
        Set-FakeDscResult $dsc iris.system.dsc.yaml @(
            New-DscResult Test/Thing one -Differs -Differing A.One
        )
        $result = Invoke-Script Test-Winfiles.ps1 'dsc/iris.system.dsc.yaml' `
            -Environment $dsc.Environment -Directory (New-WorkFolder 'dsc/iris.system.dsc.yaml')
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
        Invoke-Script Test-Winfiles.ps1 'dsc/iris.system.dsc.yaml', 'dsc/emily@iris.home.dsc.yaml' `
            -Environment $dsc.Environment `
            -Directory (New-WorkFolder 'dsc/iris.system.dsc.yaml', 'dsc/emily@iris.home.dsc.yaml') |
            Out-Null
        $kept = Get-KeptResults $dsc
        $kept.Name | Should -HaveCount 2
        $kept.Name | Should -Match '^\d{8}-\d{6}-test-(iris\.system|emily@iris\.home)\.json$'
        $system = ($kept | Where-Object Name -Like '*-iris.system.json').FullName
        (Get-Content -Raw $system | ConvertFrom-Json).results[0].name | Should -Be 'one'
    }

    It "keeps nothing when dsc prints nothing" {
        $dsc = New-FakeDsc
        Set-FakeDscResult $dsc broken.dsc.yaml -NoOutput -ExitCode 2
        Invoke-Script Test-Winfiles.ps1 'broken.dsc.yaml' `
            -Environment $dsc.Environment -Directory (New-WorkFolder 'broken.dsc.yaml') | Out-Null
        Get-KeptResults $dsc | Should -BeNullOrEmpty
    }

    It 'refuses a document with an Include, naming what to run, still tests the next one, and exits 1' {
        $dsc = New-FakeDsc
        Set-FakeDscResult $dsc good.dsc.yaml @(New-DscResult Test/Thing one)
        $work = New-WorkFolder 'good.dsc.yaml'
        Set-Content (Join-Path $work 'entry.dsc.yaml') (
            ("resources:`n  - type: Microsoft.DSC/Include`n    name: Inner`n" +
            "    properties: { configurationFile: inner.dsc.yaml }"))
        $result = Invoke-Script Test-Winfiles.ps1 'entry.dsc.yaml', 'good.dsc.yaml' `
            -Environment $dsc.Environment -Directory $work
        $result.ExitCode | Should -Be 1
        $result.Stdout -join ' ' |
            Should -BeLike ("entry.dsc.yaml: it has 1 Include, which this script doesn't flatten: " +
                'run it through scripts/Invoke-Configuration.ps1*')
        $result.Stdout | Should -Contain 'good.dsc.yaml: 1 of 1 in desired state'
        @(Get-FakeDscCalls $dsc).Count | Should -Be 1
    }

    It "says which document doesn't exist, still tests the next one, and exits 1" {
        $dsc = New-FakeDsc
        Set-FakeDscResult $dsc good.dsc.yaml @(New-DscResult Test/Thing one)
        $result = Invoke-Script Test-Winfiles.ps1 'missing.dsc.yaml', 'good.dsc.yaml' `
            -Environment $dsc.Environment -Directory (New-WorkFolder 'good.dsc.yaml')
        $result.ExitCode | Should -Be 1
        $result.Stdout | Should -Contain "missing.dsc.yaml: missing.dsc.yaml doesn't exist"
        $result.Stdout | Should -Contain 'good.dsc.yaml: 1 of 1 in desired state'
        @(Get-FakeDscCalls $dsc).Count | Should -Be 1
    }

    # Invoke-Configuration.ps1 gives each batch a file to add its counts to, and says the one total itself
    It ('with -TotalsFile, appends its count and the number not in desired state, ' +
        'and leaves the total to its caller') {
        $dsc = New-FakeDsc
        Set-FakeDscResult $dsc a.dsc.yaml @(
            (New-DscResult Test/Thing one), (New-DscResult Test/Thing two -Differs -Differing x)
        )
        Set-FakeDscResult $dsc b.dsc.yaml @((New-DscResult Test/Thing three))
        $work = New-WorkFolder 'a.dsc.yaml', 'b.dsc.yaml'
        $totals = Join-Path $work 'totals.txt'
        $first = Invoke-Script Test-Winfiles.ps1 'a.dsc.yaml', '-TotalsFile', $totals `
            -Environment $dsc.Environment -Directory $work
        $first.ExitCode | Should -Be 1
        $first.Stdout | Should -Contain 'a.dsc.yaml: 1 of 2 in desired state'
        $first.Stdout -join "`n" | Should -Not -BeLike '*passed:*'
        $first.Stdout -join "`n" | Should -Not -BeLike '*failed:*'
        $second = Invoke-Script Test-Winfiles.ps1 'b.dsc.yaml', '-TotalsFile', $totals `
            -Environment $dsc.Environment -Directory $work
        $second.ExitCode | Should -Be 0
        Get-Content $totals | Should -Be @('2 1', '1 0')
    }

    It 'with -TotalsFile, adds nothing to the total for a document dsc failed on, and exits 1' {
        $dsc = New-FakeDsc
        Set-FakeDscResult $dsc broken.dsc.yaml -NoOutput -ExitCode 2
        $work = New-WorkFolder 'broken.dsc.yaml'
        $totals = Join-Path $work 'totals.txt'
        $result = Invoke-Script Test-Winfiles.ps1 'broken.dsc.yaml', '-TotalsFile', $totals `
            -Environment $dsc.Environment -Directory $work
        $result.ExitCode | Should -Be 1
        Get-Content $totals | Should -Be '0 0'
    }
}
Describe 'Set-Winfiles.ps1' {
    It 'logs a batch of Invoke-Configuration.ps1 under the apply phase, not under its file name' -ForEach @(
        @{ name = 'entry.1-elevated.dsc.yaml' }, @{ name = 'entry.2-user.dsc.yaml' }
    ) {
        $dsc = New-FakeDsc
        $work = New-WorkFolder $name
        Set-FakeDscResult $dsc $name @(New-DscResult Test/Thing one)
        Invoke-Script Set-Winfiles.ps1 $name -Environment $dsc.Environment -Directory $work | Out-Null
        $log = (Get-Content (Join-Path $dsc.Home '.local\state\winfiles\run.log')) -join "`n"
        $log | Should -BeLike "*[[]apply] applying $name*"
        $log | Should -BeLike '*[[]apply] done in *'
    }

    It "applies the document, keeps the result under the document's name and exits with dsc's exit code" {
        $dsc = New-FakeDsc
        $work = New-WorkFolder 'dsc/emily@iris.home.dsc.yaml'
        Set-FakeDscResult $dsc emily@iris.home.dsc.yaml @(New-DscResult Test/Thing one) -ExitCode 2
        $result = Invoke-Script Set-Winfiles.ps1 'dsc/emily@iris.home.dsc.yaml' `
            -Environment $dsc.Environment -Directory $work
        $result.ExitCode | Should -Be 2
        (Get-FakeDscCalls $dsc)[0].args |
            Should -Be @('config', 'set', '--output-format', 'json', '--file', 'dsc/emily@iris.home.dsc.yaml')
        (Get-KeptResults $dsc).Name | Should -Match '^\d{8}-\d{6}-set-emily@iris\.home\.json$'
    }

    It "doesn't run dsc when the document doesn't exist, and says why" {
        $dsc = New-FakeDsc
        $work = New-WorkFolder @()
        $result = Invoke-Script Set-Winfiles.ps1 'dsc/missing.system.dsc.yaml' `
            -Environment $dsc.Environment -Directory $work
        $result.ExitCode | Should -Be 1
        $result.Stdout -join ' ' |
            Should -BeLike "dsc/missing.system.dsc.yaml: dsc/missing.system.dsc.yaml doesn't exist*"
        Get-FakeDscCalls $dsc | Should -BeNullOrEmpty
        (Get-Content (Join-Path $dsc.Home '.local\state\winfiles\run.log'))[-1] |
            Should -BeLike "*[[]system] dsc/missing.system.dsc.yaml: dsc/missing.system.dsc.yaml doesn't exist*"
    }

    It "doesn't run dsc on a document with an Include, and names what to run instead" {
        $dsc = New-FakeDsc
        $work = New-WorkFolder @()
        Set-Content (Join-Path $work 'entry.dsc.yaml') (
            ("resources:`n" +
            "  - type: Microsoft.DSC/Include`n    name: A`n    properties: { configurationFile: a.dsc.yaml }`n" +
            "  - type: Microsoft.DSC/Include`n    name: B`n    properties: { configurationFile: b.dsc.yaml }"))
        $result = Invoke-Script Set-Winfiles.ps1 'entry.dsc.yaml' -Environment $dsc.Environment -Directory $work
        $result.ExitCode | Should -Be 1
        $result.Stdout -join ' ' |
            Should -BeLike ("entry.dsc.yaml: it has 2 Includes, which this script doesn't flatten: " +
                'run it through scripts/Invoke-Configuration.ps1*')
        Get-FakeDscCalls $dsc | Should -BeNullOrEmpty
    }
    It "doesn't print dsc's JSON" {
        $dsc = New-FakeDsc
        $work = New-WorkFolder 'doc.dsc.yaml'
        Set-FakeDscResult $dsc doc.dsc.yaml @(New-DscResult Test/Thing one)
        ((Invoke-Script Set-Winfiles.ps1 'doc.dsc.yaml' `
                -Environment $dsc.Environment -Directory $work).Stdout -join "`n") |
            Should -Not -BeLike '*{*'
    }

    It 'logs when it starts and finishes, named by the kind of document, without printing it' {
        $dsc = New-FakeDsc
        $work = New-WorkFolder 'dsc/emily@iris.home.dsc.yaml'
        Set-FakeDscResult $dsc emily@iris.home.dsc.yaml @(
            New-DscResult Test/Thing one
            New-DscInclude inner @(New-DscResult Test/Thing two) -Set
        )
        $result = Invoke-Script Set-Winfiles.ps1 'dsc/emily@iris.home.dsc.yaml' `
            -Environment $dsc.Environment -Directory $work
        $result.Stdout | Should -BeNullOrEmpty
        $log = @(Get-Content (Join-Path $dsc.Home '.local\state\winfiles\run.log'))
        $log[0] | Should -Match ' \[home\] applying dsc/emily@iris\.home\.dsc\.yaml$'
        $log[1] | Should -Match ' \[home\] done in \d+s, 2 resources$'
    }

    It 'names what a run left missing, and still exits 0' {
        $dsc = New-FakeDsc
        $work = New-WorkFolder 'dsc/iris.system.dsc.yaml'
        Set-FakeDscResult $dsc iris.system.dsc.yaml @(
            New-DscResult Winfiles/FileContentList profile -AfterState @{ outOfDate = @('C:\x\a.ps1') }
            New-DscResult Test/Thing fine
        )
        $result = Invoke-Script Set-Winfiles.ps1 'dsc/iris.system.dsc.yaml' `
            -Environment $dsc.Environment -Directory $work
        $result.ExitCode | Should -Be 0
        $result.Stdout[0] | Should -Match '^done in \d+s, 2 resources, 1 not fully applied'
        $result.Stdout[1] | Should -Be "  Winfiles/FileContentList 'profile': C:\x\a.ps1"
    }

    It 'names what the lists inside Includes left missing, through nested Includes' {
        $dsc = New-FakeDsc
        $work = New-WorkFolder 'dsc/emily@iris.home.dsc.yaml'
        Set-FakeDscResult $dsc emily@iris.home.dsc.yaml @(
            New-DscInclude packages @(
                New-DscResult Winfiles/FileContentList profiles `
                    -AfterState @{ outOfDate = @('C:\x\a.ps1', 'C:\x\b.ps1') }
                New-DscInclude nested @(
                    New-DscResult Winfiles/FileContentList configs `
                        -AfterState @{ outOfDate = @('C:\x\c.toml') }
                ) -Set
            ) -Set
            New-DscInclude settings @(New-DscResult Test/Thing fine) -Set
        )
        $result = Invoke-Script Set-Winfiles.ps1 'dsc/emily@iris.home.dsc.yaml' `
            -Environment $dsc.Environment -Directory $work
        $result.ExitCode | Should -Be 0
        $result.Stdout[0] | Should -Match '^done in \d+s, 3 resources, 2 not fully applied'
        $result.Stdout[1] | Should -Be "  Winfiles/FileContentList 'profiles': C:\x\a.ps1, C:\x\b.ps1"
        $result.Stdout[2] | Should -Be "  Winfiles/FileContentList 'configs': C:\x\c.toml"
    }

    It 'says which document dsc failed on, and keeps it in the run log' {
        $dsc = New-FakeDsc
        $work = New-WorkFolder 'dsc/hosts/vm/features.dsc.yaml'
        Set-FakeDscResult $dsc features.dsc.yaml -NoOutput -ExitCode 2
        $result = Invoke-Script Set-Winfiles.ps1 'dsc/hosts/vm/features.dsc.yaml' `
            -Environment $dsc.Environment -Directory $work
        $result.ExitCode | Should -Be 2
        $result.Stdout[0] |
            Should -Match '^dsc/hosts/vm/features\.dsc\.yaml: dsc failed with exit code 2 after \d+s$'
        (Get-Content (Join-Path $dsc.Home '.local\state\winfiles\run.log'))[-1] |
            Should -Match '\[features\] dsc/hosts/vm/features\.dsc\.yaml: dsc failed'
    }
}
