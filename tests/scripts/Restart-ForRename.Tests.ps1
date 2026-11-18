# Restart-ForRename.ps1 reads the two computer-name keys and restarts Windows, so it runs in this process with mocks.
# The names are a hashtable from BeforeAll: a mock can't see variables set in BeforeEach.
BeforeAll {
    . (Join-Path $PSScriptRoot '..\resources\Resource.ps1')
    $script:file = Join-Path $repo 'scripts\Restart-ForRename.ps1'
    $script:fake = @{ Active = ''; Pending = ''; Warnings = @() }

    function Invoke-RestartForRename {
        $saved = $env:USERPROFILE
        # The run log goes under the profile, which is kept in TestDrive: so a test never writes the real one
        $env:USERPROFILE = $TestDrive
        try {
            & $file *> $null
            $LASTEXITCODE
        } finally {
            $env:USERPROFILE = $saved
        }
    }
}

Describe 'Restart-ForRename.ps1' {
    BeforeEach {
        $fake.Active = 'WINFILES-TEST'; $fake.Pending = 'WINFILES-TEST'; $fake.Warnings = @(); $fake.RestartFails = $false
        Mock Get-ItemProperty { [pscustomobject]@{ ComputerName = $fake.Active } } -ParameterFilter { $Path -like '*\ActiveComputerName' }
        Mock Get-ItemProperty { [pscustomobject]@{ ComputerName = $fake.Pending } } -ParameterFilter { $Path -notlike '*\ActiveComputerName' }
        Mock Write-Warning { $fake.Warnings += $Message }
        Mock Start-Sleep {}
        Mock Restart-Computer { if ($fake.RestartFails) { throw 'busy' } }
    }

    It 'does nothing when no rename is waiting, whatever the case' {
        $fake.Pending = 'winfiles-test'
        Invoke-RestartForRename | Should -Be 0
        Should -Invoke Restart-Computer -Times 0 -Exactly
    }

    It 'restarts after the countdown and exits 3010 when a rename is waiting' {
        $fake.Pending = 'VM-QUICK'
        Invoke-RestartForRename | Should -Be 3010
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 30 }
        Should -Invoke Restart-Computer -Times 1 -Exactly
        $fake.Warnings | Should -BeLike "*'VM-QUICK'*still 'WINFILES-TEST'*"
    }

    It 'still exits 3010, with a warning, when the restart fails' {
        $fake.Pending = 'VM-QUICK'; $fake.RestartFails = $true
        Invoke-RestartForRename | Should -Be 3010
        ($fake.Warnings -join "`n") | Should -BeLike '*Restarting failed*'
    }
}
