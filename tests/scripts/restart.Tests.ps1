# restart.ps1 is dot-sourced by the scripts that stop or restart Windows; here with fakes for the two things it reads,
# the servicing key and the computer's two names. Nothing here can restart the real computer.
BeforeAll {
    $script:profileBefore = $env:USERPROFILE
    $env:USERPROFILE = Join-Path $TestDrive 'home'
    . (Join-Path $PSScriptRoot '..\..\scripts\winlog.ps1')
    . (Join-Path $PSScriptRoot '..\..\scripts\restart.ps1')

    # Mutated, never replaced, so the mocks see the same table the tests change
    $fake = @{ Servicing = $false; Active = 'IRIS'; Pending = 'IRIS' }
}

AfterAll {
    $env:USERPROFILE = $script:profileBefore
}

Describe 'Get-RestartReason' {
    BeforeEach {
        $fake.Servicing = $false
        $fake.Active = $fake.Pending = 'IRIS'
        Mock Test-Path { $fake.Servicing }
        Mock Get-ItemProperty {
            $key = if ($Path -like '*\ActiveComputerName') { 'Active' } else { 'Pending' }
            [pscustomobject]@{ ComputerName = $fake[$key] }
        }
    }

    It 'finds nothing on a machine that needs no restart' {
        Get-RestartReason | Should -BeNullOrEmpty
        Test-BlockingRestartPending | Should -BeFalse
    }

    It 'names a pending servicing restart, which blocks' {
        $fake.Servicing = $true
        $reasons = @(Get-RestartReason)
        $reasons | Should -HaveCount 1
        $reasons[0].Name | Should -Be 'component servicing'
        $reasons[0].Blocking | Should -BeTrue
        Test-BlockingRestartPending | Should -BeTrue
    }

    It 'names a rename that is waiting for a restart, which can wait' {
        $fake.Pending = 'vm'
        $reasons = @(Get-RestartReason)
        $reasons | Should -HaveCount 1
        $reasons[0].Name | Should -Be 'computer rename'
        $reasons[0].Blocking | Should -BeFalse
        Test-BlockingRestartPending | Should -BeFalse
    }

    It 'ignores the case of the names' {
        $fake.Pending = 'iris'
        Get-RestartReason | Should -BeNullOrEmpty
    }

    It 'lists every reason, blocking or not' {
        $fake.Servicing = $true
        $fake.Pending = 'vm'
        @(Get-RestartReason).Name | Should -Be 'component servicing', 'computer rename'
        Test-BlockingRestartPending | Should -BeTrue
    }
}
