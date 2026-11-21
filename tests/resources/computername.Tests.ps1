# Winfiles/ComputerName names its registry keys and Rename-Computer itself, so it runs in this process with mocks
# (Invoke-ResourceScript). The two keys are a hashtable: Rename-Computer changes the pending name only, as Windows
# does until the restart. Nothing here can rename the real computer.
BeforeAll {
    . (Join-Path $PSScriptRoot 'Resource.ps1')

    # A stand-in to mock: the script defines the real one when it dot-sources common.ps1, and the mock still wins
    function Write-ResourceMessage([string]$Level, [string]$Text) {}

    # Mutated, never replaced, so the mocks see the same table the tests change
    $names = @{ Active = ''; Pending = '' }

    function Set-FakeNames([string]$Active, [string]$Pending = $Active) {
        $names.Active, $names.Pending = $Active, $Pending
    }

    function Invoke-ComputerName($Operation, [string]$Name) {
        Invoke-ResourceScript computername $Operation @{ name = $Name }
    }
}

Describe 'Winfiles/ComputerName' {
    BeforeEach {
        Set-FakeNames 'DESKTOP-ABC123'
        Mock Write-ResourceMessage {}
        Mock Get-ItemProperty {
            $key = if ($Path -like '*\ActiveComputerName') { 'Active' } else { 'Pending' }
            [pscustomobject]@{ ComputerName = $names[$key] }
        }
        Mock Rename-Computer { $names.Pending = $NewName }
    }

    Context 'test' {
        It 'reports a different name' {
            $result = Invoke-ComputerName test iris
            $result.ExitCode | Should -Be 0
            $result.State._inDesiredState | Should -BeFalse
            $result.State.activeName | Should -Be 'DESKTOP-ABC123'
            Should -Not -Invoke Rename-Computer
        }

        # What lets a run know before it applies anything that set will need a restart
        It 'tells DSC a restart will be needed when the name differs, before anything is renamed' {
            $result = Invoke-ComputerName test iris
            @($result.State._restartRequired) | Should -HaveCount 1
            $result.State._restartRequired[0].system | Should -Be 'DESKTOP-ABC123'
            Assert-RestartRequiredSchema $result.State
            Should -Not -Invoke Rename-Computer
        }

        It 'asks for no restart for a name Windows would refuse, since set will fail' {
            (Invoke-ComputerName test 'a_b').State.Keys | Should -Not -Contain '_restartRequired'
        }

        It 'ignores case' {
            Set-FakeNames 'IRIS'
            $result = Invoke-ComputerName test iris
            $result.State._inDesiredState | Should -BeTrue
            $result.State.Keys | Should -Not -Contain '_restartRequired'
        }

        # Windows applies the rename at the restart, so until then the computer still has the old name
        It 'reports a rename that waits for a restart as not yet in the desired state' {
            Set-FakeNames 'DESKTOP-ABC123' 'iris'
            $result = Invoke-ComputerName test iris
            $result.State._inDesiredState | Should -BeFalse
            $result.State._restartRequired[0].system | Should -Be 'DESKTOP-ABC123'
        }
    }

    Context 'get' {
        It 'reports a restart only while a rename waits' {
            (Invoke-ComputerName get iris).State.Keys | Should -Not -Contain '_restartRequired'
            Set-FakeNames 'DESKTOP-ABC123' 'iris'
            (Invoke-ComputerName get iris).State._restartRequired[0].system | Should -Be 'DESKTOP-ABC123'
        }
    }

    Context 'set' {
        It 'renames the computer and warns that it takes a restart' {
            $result = Invoke-ComputerName set iris
            $result.ExitCode | Should -Be 0
            $result.State.pendingName | Should -Be 'iris'
            $result.State._restartRequired[0].system | Should -Be 'DESKTOP-ABC123'
            Should -Invoke Rename-Computer -Times 1 -ParameterFilter { $NewName -eq 'iris' }
            Should -Invoke Write-ResourceMessage -ParameterFilter {
                $Level -eq 'warn' -and $Text -like "*'iris'*next restart*"
            }
        }

        It 'leaves a computer that already has the name alone, whatever the case' {
            Set-FakeNames 'IRIS'
            $result = Invoke-ComputerName set iris
            $result.ExitCode | Should -Be 0
            Should -Not -Invoke Rename-Computer
            Should -Not -Invoke Write-ResourceMessage
        }

        It "doesn't rename again while the rename is waiting" {
            Set-FakeNames 'DESKTOP-ABC123' 'iris'
            (Invoke-ComputerName set iris).ExitCode | Should -Be 0
            Should -Not -Invoke Rename-Computer
        }

        It 'refuses a name Windows would reject, and exits 2' {
            foreach ($name in 'a_b', 'sixteen-chars-xx', '12345', '-iris', 'iris.local') {
                (Invoke-ComputerName set $name).ExitCode | Should -Be 2 -Because $name
            }
            Should -Not -Invoke Rename-Computer
            Should -Invoke Write-ResourceMessage -ParameterFilter {
                $Level -eq 'error' -and $Text -like "*isn't a valid computer name*"
            }
        }

        It 'reports a rename Windows refuses, and exits 2' {
            Mock Rename-Computer { throw 'Access is denied' }
            $result = Invoke-ComputerName set iris
            $result.ExitCode | Should -Be 2
            $names.Pending | Should -Be 'DESKTOP-ABC123'
            Should -Invoke Write-ResourceMessage -ParameterFilter {
                $Level -eq 'error' -and $Text -like '*Access is denied*'
            }
        }
    }
}
