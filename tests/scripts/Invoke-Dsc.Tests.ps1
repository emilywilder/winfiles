# Invoke-Dsc.ps1 runs whichever dsc is first on PATH, here the fake one (tests/fakes/bin/dsc.cmd)
BeforeAll {
    . (Join-Path $PSScriptRoot '..\resources\Resource.ps1')
}

Describe 'Invoke-Dsc.ps1' {
    It "limits discovery to dsc's folder, App Installer's and dsc/resources" {
        $dsc = New-FakeDsc
        $result = Invoke-Script Invoke-Dsc.ps1 'resource', 'list' -Environment $dsc.Environment
        $result.ExitCode | Should -Be 0
        $folders = (Get-FakeDscCalls $dsc)[0].resourcePath -split ';'
        $folders[0] | Should -Be $dsc.Path
        $folders[-1] | Should -Be (Join-Path $repo 'dsc\resources')
        $appInstaller = (Get-AppxPackage Microsoft.DesktopAppInstaller | Sort-Object Version | Select-Object -Last 1).InstallLocation
        if ($appInstaller) { $folders | Should -Contain $appInstaller }
        $folders.Count | Should -BeLessOrEqual 3
    }

    It 'passes every argument through, spaces included' {
        $dsc = New-FakeDsc
        Invoke-Script Invoke-Dsc.ps1 'config', 'test', '--file', 'C:\some folder\doc.dsc.yaml' -Environment $dsc.Environment |
            Out-Null
        (Get-FakeDscCalls $dsc)[0].args | Should -Be @('config', 'test', '--file', 'C:\some folder\doc.dsc.yaml')
    }

    It "passes on dsc's output and exit code" {
        $dsc = New-FakeDsc
        Set-FakeDscResult $dsc doc.dsc.yaml @(New-DscResult Test/Thing one) -ExitCode 4
        $result = Invoke-Script Invoke-Dsc.ps1 'config', 'test', '--file', 'doc.dsc.yaml' -Environment $dsc.Environment
        $result.ExitCode | Should -Be 4
        ($result.Stdout -join "`n" | ConvertFrom-Json).results[0].name | Should -Be 'one'
    }

    It 'refuses the Store DSC without running it' {
        $dsc = New-FakeDsc -Store
        $result = Invoke-Script Invoke-Dsc.ps1 'config', 'get', '--file', 'doc.dsc.yaml' -Environment $dsc.Environment
        $result.ExitCode | Should -Be 1
        $result.Stderr -join "`n" | Should -BeLike "*Store DSC ($($dsc.Path)\dsc.cmd)*mise exec -- just dsc*"
        Test-Path (Join-Path $dsc.State 'calls.jsonl') | Should -BeFalse
    }

    It "warns when DSC's discovery extensions are back" {
        $dsc = New-FakeDsc -Extensions
        $result = Invoke-Script Invoke-Dsc.ps1 '--version' -Environment $dsc.Environment
        $result.ExitCode | Should -Be 0
        ($result.Stdout + $result.Stderr) -join "`n" | Should -BeLike "*discovery extensions are in $($dsc.Path)*mise install --force github:PowerShell/DSC*"
    }

    It "doesn't warn without them" {
        $dsc = New-FakeDsc
        $result = Invoke-Script Invoke-Dsc.ps1 '--version' -Environment $dsc.Environment
        ($result.Stdout + $result.Stderr) -join "`n" | Should -Not -BeLike '*discovery extensions*'
    }
}
