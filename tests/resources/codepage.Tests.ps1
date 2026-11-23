# Winfiles/CodePage names its registry key and asks Windows for the code pages itself, so it runs in this process
# with mocks (Invoke-ResourceScript). The registry values are a hashtable that Set-ItemProperty changes, and the
# active code pages don't change with them, as Windows does until the restart. Nothing here can change the real
# machine.
BeforeAll {
    . (Join-Path $PSScriptRoot 'Resource.ps1')

    # Stand-ins to mock: the script defines the real ones when it runs, and the mocks still win
    function Write-ResourceMessage([string]$Level, [string]$Text) {}
    function Get-ActiveCodePage {}
    function Get-LocaleCodePage {}

    # Mutated, never replaced, so the mocks see the same tables the tests change
    $registry = @{}
    $active = @{}

    function Set-FakeCodePages(
        [int]$Ansi, [int]$Oem, [int]$Mac, [int]$ActiveAnsi = $Ansi, [int]$ActiveOem = $Oem
    ) {
        $registry.Clear()
        $registry.ACP, $registry.OEMCP, $registry.MACCP = [string]$Ansi, [string]$Oem, [string]$Mac
        $active.ACP, $active.OEMCP = $ActiveAnsi, $ActiveOem
    }

    function Invoke-CodePage($Operation, [bool]$Utf8, [switch]$WhatIf) {
        Invoke-ResourceScript codepage $Operation @{ utf8 = $Utf8 } -WhatIf:$WhatIf
    }
}

Describe 'Winfiles/CodePage' {
    BeforeEach {
        Set-FakeCodePages 1252 437 10000
        Mock Write-ResourceMessage {}
        Mock Get-ActiveCodePage { @{ ACP = $active.ACP; OEMCP = $active.OEMCP } }
        Mock Get-LocaleCodePage { @{ ACP = 1252; OEMCP = 437; MACCP = 10000 } }
        Mock Get-ItemProperty { [pscustomobject]$registry }
        Mock Set-ItemProperty { $registry[$Name] = $Value }
    }

    Context 'test' {
        It 'reports code pages that are not UTF-8, and writes nothing' {
            $result = Invoke-CodePage test $true
            $result.ExitCode | Should -Be 0
            $result.State._inDesiredState | Should -BeFalse
            $result.State.activeAnsiCodePage | Should -Be 1252
            Should -Not -Invoke Set-ItemProperty
        }

        # What lets a run know before it applies anything that set will need a restart
        It 'tells DSC a restart will be needed when the active code pages differ, before anything is written' {
            $result = Invoke-CodePage test $true
            @($result.State._restartRequired) | Should -HaveCount 1
            Assert-RestartRequiredSchema $result.State
        }

        It 'is in the desired state once UTF-8 is active' {
            Set-FakeCodePages 65001 65001 65001
            $result = Invoke-CodePage test $true
            $result.State._inDesiredState | Should -BeTrue
            $result.State.Keys | Should -Not -Contain '_restartRequired'
        }

        # Windows reads the registry at boot, so until then the running system still uses the old code pages
        It 'reports values that wait for a restart as not yet in the desired state' {
            Set-FakeCodePages 65001 65001 65001 -ActiveAnsi 1252 -ActiveOem 437
            $result = Invoke-CodePage test $true
            $result.State._inDesiredState | Should -BeFalse
            $result.State._restartRequired | Should -Not -BeNullOrEmpty
        }

        It 'reports one registry value that is not UTF-8 as not in the desired state' {
            Set-FakeCodePages 65001 65001 10000
            (Invoke-CodePage test $true).State._inDesiredState | Should -BeFalse
        }

        It 'is in the desired state for utf8 false when the locale defaults are active' {
            $result = Invoke-CodePage test $false
            $result.State._inDesiredState | Should -BeTrue
            $result.State.Keys | Should -Not -Contain '_restartRequired'
        }

        It 'reports UTF-8 as not wanted for utf8 false' {
            Set-FakeCodePages 65001 65001 65001
            $result = Invoke-CodePage test $false
            $result.State._inDesiredState | Should -BeFalse
            $result.State._restartRequired | Should -Not -BeNullOrEmpty
        }
    }

    Context 'get' {
        It 'reports utf8 from the registry, and a restart only while the active code pages differ from it' {
            $result = Invoke-CodePage get $true
            $result.State.utf8 | Should -BeFalse
            $result.State.Keys | Should -Not -Contain '_restartRequired'

            Set-FakeCodePages 65001 65001 65001 -ActiveAnsi 1252 -ActiveOem 437
            $result = Invoke-CodePage get $false
            $result.State.utf8 | Should -BeTrue
            $result.State.pendingAnsiCodePage | Should -Be 65001
            $result.State._restartRequired | Should -Not -BeNullOrEmpty
        }

        It 'reports a value that is not a number as null' {
            $registry.ACP = 'abc'
            (Invoke-CodePage get $true).State.pendingAnsiCodePage | Should -BeNullOrEmpty
        }
    }

    Context 'set' {
        It 'writes UTF-8 as text to the three values and warns that it takes a restart' {
            $result = Invoke-CodePage set $true
            $result.ExitCode | Should -Be 0
            $registry.ACP | Should -BeExactly '65001'
            $registry.OEMCP | Should -BeExactly '65001'
            $registry.MACCP | Should -BeExactly '65001'
            Should -Invoke Set-ItemProperty -Times 3 -ParameterFilter { $Type -eq 'String' }
            $result.State.pendingAnsiCodePage | Should -Be 65001
            $result.State.activeAnsiCodePage | Should -Be 1252
            Assert-RestartRequiredSchema $result.State
            Should -Invoke Write-ResourceMessage -ParameterFilter {
                $Level -eq 'warn' -and $Text -like '*next restart*'
            }
        }

        It 'writes only the values that differ' {
            Set-FakeCodePages 65001 437 65001
            (Invoke-CodePage set $true).ExitCode | Should -Be 0
            Should -Invoke Set-ItemProperty -Times 1 -ParameterFilter { $Name -eq 'OEMCP' -and $Value -eq '65001' }
        }

        It 'leaves a machine that already uses UTF-8 alone' {
            Set-FakeCodePages 65001 65001 65001
            $result = Invoke-CodePage set $true
            $result.ExitCode | Should -Be 0
            Should -Not -Invoke Set-ItemProperty
            Should -Not -Invoke Write-ResourceMessage
        }

        It "doesn't write again while the restart is waiting, but still warns" {
            Set-FakeCodePages 65001 65001 65001 -ActiveAnsi 1252 -ActiveOem 437
            (Invoke-CodePage set $true).ExitCode | Should -Be 0
            Should -Not -Invoke Set-ItemProperty
            Should -Invoke Write-ResourceMessage -ParameterFilter { $Level -eq 'warn' }
        }

        It 'writes the locale defaults for utf8 false' {
            Set-FakeCodePages 65001 65001 65001 -ActiveAnsi 65001 -ActiveOem 65001
            $result = Invoke-CodePage set $false
            $result.ExitCode | Should -Be 0
            $registry.ACP | Should -BeExactly '1252'
            $registry.OEMCP | Should -BeExactly '437'
            $registry.MACCP | Should -BeExactly '10000'
            $result.State._restartRequired | Should -Not -BeNullOrEmpty
        }

        It 'changes nothing with -WhatIf' {
            (Invoke-CodePage set $true -WhatIf).ExitCode | Should -Be 0
            Should -Not -Invoke Set-ItemProperty
            $registry.ACP | Should -BeExactly '1252'
        }

        It 'reports a registry write Windows refuses, and exits 2' {
            Mock Set-ItemProperty { throw 'Access is denied' }
            $result = Invoke-CodePage set $true
            $result.ExitCode | Should -Be 2
            Should -Invoke Write-ResourceMessage -ParameterFilter {
                $Level -eq 'error' -and $Text -like '*Access is denied*'
            }
        }
    }

    It 'refuses a utf8 that is not true or false, and exits 2' {
        $result = Invoke-ResourceScript codepage test @{ utf8 = 'yes' }
        $result.ExitCode | Should -Be 2
        Should -Invoke Write-ResourceMessage -ParameterFilter { $Level -eq 'error' -and $Text -like "*'utf8'*" }
    }
}
