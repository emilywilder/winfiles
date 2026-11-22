BeforeAll {
    . (Join-Path $PSScriptRoot 'Resource.ps1')

    # The manifest returns stateAndDiff, so State is the first stdout line, not the last
    function Invoke-Package($Operation, $Fake, [hashtable]$Instance) {
        $run = Invoke-Resource scooppackage $Operation $Instance $Fake.Environment
        $run.State = $run.Stdout | Select-Object -First 1 | ConvertFrom-Json
        $run
    }

    # The second stdout line of a stateAndDiff result: the properties that differ or changed
    function Get-Diff($Result) {
        @($Result.Stdout[1] | ConvertFrom-Json)
    }
}

Describe 'Winfiles.Scoop/Package' {
    Context 'get' {
        It 'reports the bucket an installed app came from' {
            $fake = New-FakeScoop -Installed extras/meld
            $result = Invoke-Package get $fake @{ name = 'meld' }
            $result.ExitCode | Should -Be 0
            $result.State.bucket | Should -Be 'extras'
            $result.State._exist | Should -BeTrue
            $result.Stdout.Count | Should -Be 1
        }
    }

    Context 'test' {
        It 'is in the desired state when the app is installed from its bucket' {
            $fake = New-FakeScoop -Installed extras/meld
            $result = Invoke-Package test $fake @{ name = 'meld'; bucket = 'extras' }
            $result.ExitCode | Should -Be 0
            $result.State._inDesiredState | Should -BeTrue
            Get-Diff $result | Should -BeNullOrEmpty
        }

        It 'accepts any bucket when none is given' {
            $fake = New-FakeScoop -Installed extras/meld
            $result = Invoke-Package test $fake @{ name = 'meld' }
            $result.State._inDesiredState | Should -BeTrue
        }

        It 'reports a missing app as _exist' {
            $fake = New-FakeScoop
            $result = Invoke-Package test $fake @{ name = 'meld' }
            $result.State._inDesiredState | Should -BeFalse
            $result.State._exist | Should -BeFalse
            Get-Diff $result | Should -Be @('_exist')
        }

        It 'reports an app installed from another bucket as differing in bucket' {
            $fake = New-FakeScoop -Installed main/vscode
            $result = Invoke-Package test $fake @{ name = 'vscode'; bucket = 'extras' }
            $result.State._inDesiredState | Should -BeFalse
            $result.State.bucket | Should -Be 'main'
            Get-Diff $result | Should -Be @('bucket')
        }

        It 'reads install.json from older Scoop versions' {
            $fake = New-FakeScoop
            $current = New-Item -ItemType Directory (Join-Path $fake.Path 'apps\git\current')
            @{ bucket = 'main' } | ConvertTo-Json | Set-Content (Join-Path $current 'install.json')
            $result = Invoke-Package test $fake @{ name = 'git'; bucket = 'main' }
            $result.State._inDesiredState | Should -BeTrue
        }

        It "doesn't run Scoop" {
            $fake = New-FakeScoop
            Invoke-Package test $fake @{ name = 'git' } | Out-Null
            Get-FakeScoopCalls $fake | Should -BeNullOrEmpty
        }

        It 'exits 4 when asked for _exist false' {
            $fake = New-FakeScoop -Installed git
            $result = Invoke-Package test $fake @{ name = 'git'; _exist = $false }
            $result.ExitCode | Should -Be 4
        }
    }

    Context 'set' {
        It 'installs a missing app from its bucket, and reports _exist changed' {
            $fake = New-FakeScoop
            $result = Invoke-Package set $fake @{ name = 'meld'; bucket = 'extras' }
            $result.ExitCode | Should -Be 0
            $result.State._exist | Should -BeTrue
            $result.State.bucket | Should -Be 'extras'
            Get-Diff $result | Should -Be @('_exist')
            Get-FakeScoopCalls $fake | Should -Be @('install extras/meld')
        }

        It "keeps Scoop's output plain, with no messages" {
            $fake = New-FakeScoop
            $result = Invoke-Package set $fake @{ name = 'git' }
            $result.Messages | Should -BeNullOrEmpty
            $result.Stderr | Should -Contain "Installing 'git' (1.0.0) [64bit] from 'main' bucket"
        }

        It 'does nothing when the app is installed, even without Scoop' {
            $fake = New-FakeScoop -NoScoop -Installed git
            $result = Invoke-Package set $fake @{ name = 'git' }
            $result.ExitCode | Should -Be 0
            Get-Diff $result | Should -BeNullOrEmpty
        }

        It 'exits 2 naming an app that fails' {
            $fake = New-FakeScoop -Failing meld
            $result = Invoke-Package set $fake @{ name = 'meld'; bucket = 'extras' }
            $result.ExitCode | Should -Be 2
            ($result.Messages | Where-Object Level -EQ error).Text | Should -Be @('Failed to install extras/meld')
        }

        It 'exits 2 without running Scoop for an app installed from another bucket' {
            $fake = New-FakeScoop -Installed main/vscode
            $result = Invoke-Package set $fake @{ name = 'vscode'; bucket = 'extras' }
            $result.ExitCode | Should -Be 2
            ($result.Messages | Where-Object Level -EQ error).Text |
                Should -Be @('vscode is installed from main, not extras; scoop uninstall it first')
            Get-FakeScoopCalls $fake | Should -BeNullOrEmpty
        }

        It 'exits 3 when Scoop is not installed' {
            $fake = New-FakeScoop -NoScoop
            $result = Invoke-Package set $fake @{ name = 'git' }
            $result.ExitCode | Should -Be 3
            ($result.Messages | Where-Object Level -EQ error).Text | Should -BeLike 'Scoop is not installed at*'
        }
    }
}
