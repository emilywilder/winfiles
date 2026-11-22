# Assert-RestartRequiredSchema (Resource.ps1) is what keeps a resource's `_restartRequired` in the shape DSC
# collects, so it has to fail on the shapes DSC 3.3.0 only warns about
BeforeAll {
    . (Join-Path $PSScriptRoot 'Resource.ps1')
}

Describe 'Assert-RestartRequiredSchema' {
    It 'accepts a system, a service and a process' {
        Assert-RestartRequiredSchema ([pscustomobject]@{
                _restartRequired = @(
                    @{ system = 'PC' }, @{ service = 'sshd' }, @{ process = @{ name = 'explorer.exe'; id = 1234 } }
                )
            })
    }

    It 'rejects <Name>' -ForEach @(
        @{ Name = 'an unknown kind'; Entry = @{ computer = 'PC' } }
        @{ Name = 'two kinds in one entry'; Entry = @{ system = 'PC'; service = 'sshd' } }
        @{ Name = 'a system that is not text'; Entry = @{ system = 1 } }
        @{ Name = 'a process without an id'; Entry = @{ process = @{ name = 'explorer.exe' } } }
    ) {
        { Assert-RestartRequiredSchema ([pscustomobject]@{ _restartRequired = @($Entry) }) } | Should -Throw
    }

    It 'rejects a state with no restart' {
        { Assert-RestartRequiredSchema ([pscustomobject]@{}) } | Should -Throw
    }
}
