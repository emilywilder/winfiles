# Set-RestartStage.ps1 against the fake dsc (tests/fakes/bin/dsc.cmd). What it asks of the machine at the end (a
# restart pending, from the registry) can't be mocked in a child process, so the exit code is 0 or 3010 depending on
# this machine, and these tests check only what doesn't depend on it: what it tells the person, which dsc operations it
# runs and in what order, and what it does when dsc or the document fails. Nothing here differs in a way that makes it
# restart this machine: the fake apply changes nothing, so no restart becomes pending that wasn't already.
BeforeAll {
    . (Join-Path $PSScriptRoot '..\resources\Resource.ps1')

    function New-WorkFolder([string[]]$Paths) {
        $folder = New-Item -ItemType Directory (Join-Path $TestDrive "work-$([guid]::NewGuid())")
        foreach ($path in $Paths) {
            Set-Content (Join-Path $folder $path) "`$schema: https://raw.githubusercontent.com/PowerShell/DSC/main/schemas/2023/08/config/document.json`nresources:`n  - { type: Test/Thing, name: one, properties: {} }"
        }
        $folder.FullName
    }

    function Get-Operations($Dsc) { @(Get-FakeDscCalls $Dsc | ForEach-Object { $_.args[1] }) }
}

Describe 'Set-RestartStage.ps1' {
    BeforeEach {
        $script:dsc = New-FakeDsc
    }

    It 'only tests a batch that is already in its desired state, and applies nothing' {
        Set-FakeDscResult $dsc batch.dsc.yaml @((New-DscResult Test/Thing one))
        $result = Invoke-Script Set-RestartStage.ps1 'batch.dsc.yaml' -Environment $dsc.Environment -Directory (New-WorkFolder 'batch.dsc.yaml')
        $result.ExitCode | Should -BeIn 0, 3010
        Get-Operations $dsc | Should -Be @('test')
    }

    It 'tests, then applies what differs, and tells the person which resource will need a restart before it does' {
        Set-FakeDscResult $dsc batch.dsc.yaml @((New-DscResult Winfiles/Wsl WSL -Differs -RestartSystem PC)) -Operation test
        Set-FakeDscResult $dsc batch.dsc.yaml @((New-DscResult Winfiles/Wsl WSL)) -Operation set
        $result = Invoke-Script Set-RestartStage.ps1 'batch.dsc.yaml' -Environment $dsc.Environment -Directory (New-WorkFolder 'batch.dsc.yaml')
        $result.ExitCode | Should -BeIn 0, 3010
        $result.Stdout | Should -Contain "a restart will be needed by: Winfiles/Wsl 'WSL'"
        Get-Operations $dsc | Should -Be @('test', 'set')
        $log = (Get-Content (Join-Path $dsc.Home '.local\state\winfiles\run.log')) -join "`n"
        $log | Should -BeLike "*[[]apply] a restart will be needed by: Winfiles/Wsl 'WSL'*"
    }

    It "stops with the apply's exit code when it fails, before looking at restarts" {
        Set-FakeDscResult $dsc batch.dsc.yaml @((New-DscResult Test/Thing one -Differs)) -Operation test
        Set-FakeDscResult $dsc batch.dsc.yaml -NoOutput -ExitCode 2 -Operation set
        $result = Invoke-Script Set-RestartStage.ps1 'batch.dsc.yaml' -Environment $dsc.Environment -Directory (New-WorkFolder 'batch.dsc.yaml')
        $result.ExitCode | Should -Be 2
        Get-Operations $dsc | Should -Be @('test', 'set')
    }

    It "exits with dsc's exit code and says so when the test fails, and applies nothing" {
        Set-FakeDscResult $dsc batch.dsc.yaml -NoOutput -ExitCode 2
        $result = Invoke-Script Set-RestartStage.ps1 'batch.dsc.yaml' -Environment $dsc.Environment -Directory (New-WorkFolder 'batch.dsc.yaml')
        $result.ExitCode | Should -Be 2
        $result.Stdout | Should -Contain 'batch.dsc.yaml: dsc failed with exit code 2'
        Get-Operations $dsc | Should -Be @('test')
    }

    It 'refuses a document with an Include, naming what to run, and runs no dsc' {
        $work = New-WorkFolder @()
        Set-Content (Join-Path $work 'entry.dsc.yaml') "resources:`n  - type: Microsoft.DSC/Include`n    name: Inner`n    properties: { configurationFile: inner.dsc.yaml }"
        $result = Invoke-Script Set-RestartStage.ps1 'entry.dsc.yaml' -Environment $dsc.Environment -Directory $work
        $result.ExitCode | Should -Be 1
        $result.Stdout -join ' ' | Should -BeLike "entry.dsc.yaml: it has 1 Include, which this script doesn't flatten: run it through scripts/Invoke-Configuration.ps1*"
        Get-FakeDscCalls $dsc | Should -BeNullOrEmpty
    }
}
