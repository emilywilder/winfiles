# dsclog.ps1's readers of a dsc result, on the shapes DSC 3.3.0 gives them (tests/resources/Resource.ps1 builds them): a
# resource inside an Include after a `test` and after a `set`, and a resource on its own. Get-RestartReport is what
# Set-RestartStage.ps1 tells the person before anything is applied, so the shapes it must see through are pinned here.
BeforeAll {
    . (Join-Path $PSScriptRoot '..\resources\Resource.ps1')
    . (Join-Path $PSScriptRoot '..\..\scripts\dsclog.ps1')

    # What the fake dsc prints is JSON, so read it back the way the scripts do
    function ConvertTo-Results([object[]]$Results) { @($Results | ConvertTo-Json -Depth 20 | ConvertFrom-Json) }
}

Describe 'Get-ResourceResult' {
    It 'returns a resource that is not in an Include as it is' {
        $results = ConvertTo-Results (New-DscResult Test/Thing one), (New-DscResult Test/Thing two)
        @(Get-ResourceResult $results).name | Should -Be 'one', 'two'
    }

    It 'returns the resources inside an Include after a test' {
        $results = ConvertTo-Results (New-DscInclude Group (New-DscResult Test/Thing one), (New-DscResult Test/Thing two))
        @(Get-ResourceResult $results).name | Should -Be 'one', 'two'
    }

    It 'returns the resources inside an Include after a set' {
        $results = ConvertTo-Results (New-DscInclude Group -Set (New-DscResult Test/Thing one), (New-DscResult Test/Thing two))
        @(Get-ResourceResult $results).name | Should -Be 'one', 'two'
    }

    It 'returns nothing for no results' {
        Get-ResourceResult @() | Should -BeNullOrEmpty
    }
}

Describe 'Get-RestartReport' {
    It 'reports the type, name and system of a resource that asks for a restart' {
        $results = ConvertTo-Results (New-DscResult Winfiles/Wsl WSL -Differs -RestartSystem IRIS)
        $report = @(Get-RestartReport $results)
        $report | Should -HaveCount 1
        $report[0].Type | Should -Be 'Winfiles/Wsl'
        $report[0].Name | Should -Be 'WSL'
        $report[0].System | Should -Be 'IRIS'
    }

    It 'finds a restart a resource reports inside an Include, where the Include itself reports none' {
        $results = ConvertTo-Results (New-DscInclude WSL (New-DscResult Winfiles/Wsl WSL -Differs -RestartSystem IRIS))
        @(Get-RestartReport $results).Name | Should -Be 'WSL'
    }

    It 'finds a restart in the result of a set' {
        $results = ConvertTo-Results (New-DscInclude WSL -Set (New-DscResult Winfiles/Wsl WSL -RestartSystem IRIS))
        @(Get-RestartReport $results).Name | Should -Be 'WSL'
    }

    It 'reports only the resources that ask' {
        $results = ConvertTo-Results (New-DscInclude Features (New-DscResult Test/Thing quiet)), (New-DscInclude WSL (New-DscResult Winfiles/Wsl WSL -RestartSystem IRIS))
        @(Get-RestartReport $results).Name | Should -Be 'WSL'
    }

    It 'reports nothing when no resource asks, or when a resource has no execution information' {
        Get-RestartReport (ConvertTo-Results (New-DscResult Test/Thing one)) | Should -BeNullOrEmpty
        Get-RestartReport @() | Should -BeNullOrEmpty
    }
}

Describe 'Get-ResourceProblem' {
    It 'names what a list resource says is missing, out of date or in a missing bucket' {
        $resource = ConvertTo-Results (New-DscResult Winfiles/Thing list -Differs -ActualState @{ missing = @('a'); outOfDate = @('b'); missingBuckets = @('c') })
        Get-ResourceProblem $resource[0] actualState | Should -Be 'a', 'c', 'b'
    }

    It 'falls back on differingProperties' {
        $resource = ConvertTo-Results (New-DscResult Test/Thing one -Differs -Differing 'enabled')
        Get-ResourceProblem $resource[0] actualState | Should -Be 'enabled'
    }

    It 'reports a package that is not installed by its id' {
        $resource = ConvertTo-Results (New-DscResult Microsoft.WinGet/Package pkg -Differs -ActualState @{ id = 'Foo.Bar' } -Differing '_exist')
        Get-ResourceProblem $resource[0] actualState | Should -Be 'Foo.Bar'
    }
}
