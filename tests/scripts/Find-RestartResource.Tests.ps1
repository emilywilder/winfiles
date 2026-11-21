# Find-RestartResource.ps1 against the fake dsc (tests/fakes/bin/dsc.cmd) with canned `test` results, which name the
# resources that report _restartRequired the way DSC 3.3.0 does (executionInformation). It takes a flat batch, as
# Invoke-Configuration.ps1 makes them, and refuses a document with an Include.
BeforeAll {
    . (Join-Path $PSScriptRoot '..\resources\Resource.ps1')

    function New-WorkFolder([string[]]$Paths) {
        $folder = New-Item -ItemType Directory (Join-Path $TestDrive "work-$([guid]::NewGuid())")
        foreach ($path in $Paths) {
            $schema = 'https://raw.githubusercontent.com/PowerShell/DSC/main/schemas/2023/08/config/document.json'
            Set-Content (Join-Path $folder $path) (
                "`$schema: $schema`nresources:`n  - { type: Test/Thing, name: one, properties: {} }")
        }
        $folder.FullName
    }

    function Get-Log($Dsc) { (Get-Content (Join-Path $Dsc.Home '.local\state\winfiles\run.log')) -join "`n" }
}

Describe 'Find-RestartResource.ps1' {
    BeforeEach {
        $script:dsc = New-FakeDsc
    }

    It 'prints one winfiles-restart line, as -First takes it, for each resource that reports a restart, and exits 0' {
        Set-FakeDscResult $dsc batch.dsc.yaml @(
            (New-DscResult Winfiles/Wsl WSL -Differs -RestartSystem PC)
            (New-DscResult Test/Thing quiet)
            (New-DscResult Winfiles/ComputerName 'Computer Name' -Differs -RestartSystem PC)
        )
        $result = Invoke-Script Find-RestartResource.ps1 'batch.dsc.yaml' `
            -Environment $dsc.Environment -Directory (New-WorkFolder 'batch.dsc.yaml')
        $result.ExitCode | Should -Be 0
        $result.Stdout |
            Should -Be @('winfiles-restart: Winfiles/Wsl|WSL', 'winfiles-restart: Winfiles/ComputerName|Computer Name')
        # It only tests: a restart is found before anything is applied
        @(Get-FakeDscCalls $dsc | ForEach-Object { $_.args[1] }) | Should -Be @('test')
        Get-Log $dsc | Should -BeLike "*[[]apply] batch.dsc.yaml: Winfiles/Wsl 'WSL' will need a restart*"
    }

    It 'prints nothing and exits 0 when nothing reports a restart, even when things differ' {
        Set-FakeDscResult $dsc batch.dsc.yaml @((New-DscResult Test/Thing one -Differs -Differing x))
        $result = Invoke-Script Find-RestartResource.ps1 'batch.dsc.yaml' `
            -Environment $dsc.Environment -Directory (New-WorkFolder 'batch.dsc.yaml')
        $result.ExitCode | Should -Be 0
        $result.Stdout | Should -BeNullOrEmpty
    }

    It 'finds a resource inside an Include result' {
        Set-FakeDscResult $dsc batch.dsc.yaml @(
            (New-DscInclude inner @((New-DscResult Winfiles/Wsl WSL -Differs -RestartSystem PC)))
        )
        $result = Invoke-Script Find-RestartResource.ps1 'batch.dsc.yaml' `
            -Environment $dsc.Environment -Directory (New-WorkFolder 'batch.dsc.yaml')
        $result.Stdout | Should -Be @('winfiles-restart: Winfiles/Wsl|WSL')
    }

    It "exits 0 and prints nothing when dsc prints nothing for the document" {
        $result = Invoke-Script Find-RestartResource.ps1 'batch.dsc.yaml' `
            -Environment $dsc.Environment -Directory (New-WorkFolder 'batch.dsc.yaml')
        $result.ExitCode | Should -Be 0
        $result.Stdout | Should -BeNullOrEmpty
    }

    It "exits with dsc's exit code and says so when the test fails, in the run log too" {
        Set-FakeDscResult $dsc batch.dsc.yaml -NoOutput -ExitCode 2
        $result = Invoke-Script Find-RestartResource.ps1 'batch.dsc.yaml' `
            -Environment $dsc.Environment -Directory (New-WorkFolder 'batch.dsc.yaml')
        $result.ExitCode | Should -Be 2
        $result.Stdout | Should -Be @('batch.dsc.yaml: dsc failed with exit code 2')
        Get-Log $dsc | Should -BeLike '*[[]apply] batch.dsc.yaml: dsc failed with exit code 2*'
    }

    It 'refuses a document with an Include, naming what to run, and runs no dsc' {
        $work = New-WorkFolder @()
        Set-Content (Join-Path $work 'entry.dsc.yaml') (
            "resources:`n  - type: Microsoft.DSC/Include`n    name: Inner`n" +
            "    properties: { configurationFile: inner.dsc.yaml }")
        $result = Invoke-Script Find-RestartResource.ps1 'entry.dsc.yaml' `
            -Environment $dsc.Environment -Directory $work
        $result.ExitCode | Should -Be 1
        $result.Stdout -join ' ' |
            Should -BeLike ("entry.dsc.yaml: it has 1 Include, which this script doesn't flatten: " +
                'run it through scripts/Invoke-Configuration.ps1*')
        Get-FakeDscCalls $dsc | Should -BeNullOrEmpty
    }
}
