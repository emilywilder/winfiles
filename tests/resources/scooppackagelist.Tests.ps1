BeforeAll {
    . (Join-Path $PSScriptRoot 'Resource.ps1')

    function Invoke-List($Operation, $Fake, [hashtable]$Instance) {
        Invoke-Resource scooppackagelist $Operation $Instance $Fake.Environment
    }
}

Describe 'Winfiles/ScoopPackageList' {
    Context 'test' {
        It 'is in the desired state when every app and bucket is there' {
            $fake = New-FakeScoop -Installed git, extras/vscode -Buckets extras
            $result = Invoke-List test $fake @{ packages = @('git', 'extras/vscode'); buckets = @{ extras = '' } }
            $result.ExitCode | Should -Be 0
            $result.State._inDesiredState | Should -BeTrue
        }

        It 'lists a missing app and bucket' {
            $fake = New-FakeScoop -Installed git
            $result = Invoke-List test $fake @{ packages = @('git', 'meld'); buckets = @{ extras = '' } }
            $result.State._inDesiredState | Should -BeFalse
            $result.State.missing | Should -Be @('meld')
            $result.State.missingBuckets | Should -Be @('extras')
        }

        It 'counts an app installed from another bucket as missing' {
            $fake = New-FakeScoop -Installed main/vscode
            $result = Invoke-List test $fake @{ packages = @('extras/vscode') }
            $result.State.missing | Should -Be @('extras/vscode')
        }

        It 'reads install.json from older Scoop versions' {
            $fake = New-FakeScoop
            $current = New-Item -ItemType Directory (Join-Path $fake.Path 'apps\git\current')
            @{ bucket = 'main' } | ConvertTo-Json | Set-Content (Join-Path $current 'install.json')
            $result = Invoke-List test $fake @{ packages = @('main/git') }
            $result.State.missing | Should -BeNullOrEmpty
        }

        It "doesn't run Scoop" {
            $fake = New-FakeScoop
            Invoke-List test $fake @{ packages = @('git') } | Out-Null
            Get-FakeScoopCalls $fake | Should -BeNullOrEmpty
        }
    }

    Context 'set' {
        It 'adds missing buckets, then installs the missing apps in one call' {
            $fake = New-FakeScoop -Installed git
            $instance = @{ packages = @('git', 'extras/meld', 'tectonic'); buckets = @{ extras = 'https://example.invalid/extras' } }
            $result = Invoke-List set $fake $instance
            $result.ExitCode | Should -Be 0
            $result.State.missing | Should -BeNullOrEmpty
            $result.State.missingBuckets | Should -BeNullOrEmpty
            Get-FakeScoopCalls $fake | Should -Be @('bucket add extras https://example.invalid/extras', 'install extras/meld tectonic')
        }

        It "raises Scoop's Installing lines to warn" {
            $fake = New-FakeScoop
            $result = Invoke-List set $fake @{ packages = @('git') }
            ($result.Messages | Where-Object Level -eq warn).Text | Should -Be @("Installing 'git' (1.0.0) [64bit] from 'main' bucket")
        }

        # A single failure used to stop the whole list, and DSC stops the whole configuration on a non-zero exit
        It 'carries on past an app that fails, and still exits 0' {
            $fake = New-FakeScoop -Failing meld
            $result = Invoke-List set $fake @{ packages = @('git', 'meld', 'tectonic') }
            $result.ExitCode | Should -Be 0
            $result.State.missing | Should -Be @('meld')
            Test-Path (Join-Path $fake.Path 'apps\tectonic\current\scoop-install.json') | Should -BeTrue
            ($result.Messages | Where-Object Level -eq error).Text | Should -Be @('Failed to install meld')
        }

        It 'carries on past a bucket that fails' {
            $fake = New-FakeScoop -FailingBuckets extras
            $result = Invoke-List set $fake @{ packages = @('git'); buckets = @{ extras = ''; games = '' } }
            $result.ExitCode | Should -Be 0
            $result.State.missingBuckets | Should -Be @('extras')
            $result.State.missing | Should -BeNullOrEmpty
            ($result.Messages | Where-Object Level -eq error).Text | Should -Be @('Failed to install extras')
        }

        It 'exits 3 when Scoop is not installed' {
            $fake = New-FakeScoop -NoScoop
            $result = Invoke-List set $fake @{ packages = @('git') }
            $result.ExitCode | Should -Be 3
            ($result.Messages | Where-Object Level -eq error).Text | Should -BeLike 'Scoop is not installed at*'
        }

        It 'does nothing when everything is there, even without Scoop' {
            $fake = New-FakeScoop -NoScoop -Installed git
            $result = Invoke-List set $fake @{ packages = @('git') }
            $result.ExitCode | Should -Be 0
        }
    }
}
