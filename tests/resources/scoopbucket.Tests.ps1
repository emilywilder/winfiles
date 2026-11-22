BeforeAll {
    . (Join-Path $PSScriptRoot 'Resource.ps1')

    # The manifest returns stateAndDiff, so State is the first stdout line, not the last
    function Invoke-Bucket($Operation, $Fake, [hashtable]$Instance) {
        $run = Invoke-Resource scoopbucket $Operation $Instance $Fake.Environment
        $run.State = $run.Stdout | Select-Object -First 1 | ConvertFrom-Json
        $run
    }

    # The second stdout line of a stateAndDiff result: the properties that differ or changed
    function Get-Diff($Result) {
        @($Result.Stdout[1] | ConvertFrom-Json)
    }
}

Describe 'Winfiles.Scoop/Bucket' {
    Context 'test' {
        It 'is in the desired state when the bucket is there' {
            $fake = New-FakeScoop -Buckets extras
            $result = Invoke-Bucket test $fake @{ name = 'extras'; source = 'https://example.invalid/extras' }
            $result.ExitCode | Should -Be 0
            $result.State._inDesiredState | Should -BeTrue
            Get-Diff $result | Should -BeNullOrEmpty
        }

        It 'reports a missing bucket as _exist, without running Scoop' {
            $fake = New-FakeScoop
            $result = Invoke-Bucket test $fake @{ name = 'extras' }
            $result.State._inDesiredState | Should -BeFalse
            Get-Diff $result | Should -Be @('_exist')
            Get-FakeScoopCalls $fake | Should -BeNullOrEmpty
        }
    }

    Context 'set' {
        It 'adds a missing bucket from its source' {
            $fake = New-FakeScoop
            $result = Invoke-Bucket set $fake @{ name = 'extras'; source = 'https://example.invalid/extras' }
            $result.ExitCode | Should -Be 0
            $result.State._exist | Should -BeTrue
            Get-Diff $result | Should -Be @('_exist')
            Get-FakeScoopCalls $fake | Should -Be @('bucket add extras https://example.invalid/extras')
        }

        It 'adds a known bucket by name alone' {
            $fake = New-FakeScoop
            Invoke-Bucket set $fake @{ name = 'extras'; source = '' } | Out-Null
            Get-FakeScoopCalls $fake | Should -Be @('bucket add extras')
        }

        It 'does nothing when the bucket is there' {
            $fake = New-FakeScoop -NoScoop -Buckets extras
            $result = Invoke-Bucket set $fake @{ name = 'extras' }
            $result.ExitCode | Should -Be 0
            Get-Diff $result | Should -BeNullOrEmpty
        }

        It 'exits 2 naming a bucket that fails' {
            $fake = New-FakeScoop -FailingBuckets extras
            $result = Invoke-Bucket set $fake @{ name = 'extras' }
            $result.ExitCode | Should -Be 2
            ($result.Messages | Where-Object Level -EQ error).Text | Should -Be @('Failed to add the extras bucket')
        }

        It 'exits 3 when Scoop is not installed' {
            $fake = New-FakeScoop -NoScoop
            $result = Invoke-Bucket set $fake @{ name = 'extras' }
            $result.ExitCode | Should -Be 3
        }

        It 'exits 4 when asked for _exist false' {
            $fake = New-FakeScoop -Buckets extras
            $result = Invoke-Bucket set $fake @{ name = 'extras'; _exist = $false }
            $result.ExitCode | Should -Be 4
        }
    }
}
