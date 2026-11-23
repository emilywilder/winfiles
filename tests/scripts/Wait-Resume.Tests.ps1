# Wait-Resume.ps1 in a child pwsh, as `winfiles.ps1 resume` runs it. The restart check reads a key under HKCU of
# its own, and the network check a TcpListener on loopback, so neither depends on the machine. run.log goes under a
# USERPROFILE in TestDrive, never the real one. Each run gets an empty line on stdin for its "Press Enter"
# prompt.
BeforeAll {
    . (Join-Path $PSScriptRoot '..\resources\Resource.ps1')
    $script = Join-Path $repo 'scripts\Wait-Resume.ps1'
    $key = "HKCU:\Software\winfiles-test-$([guid]::NewGuid())"

    # A port nothing listens on, for the source that can't be reached
    function Get-ClosedPort {
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $port = $listener.LocalEndpoint.Port
        $listener.Stop()
        $port
    }

    # No -NonInteractive, which Read-Host refuses
    function Invoke-Wait([int]$Port) {
        $userProfile = Join-Path $TestDrive "home-$([guid]::NewGuid())"
        $result = Invoke-Child $TestDrive @{ USERPROFILE = $userProfile } {
            '' | pwsh -NoLogo -NoProfile -File $script -RebootPendingKey $key -SourceHost 127.0.0.1 `
                -SourcePort $Port -WaitSeconds 0 2>&1
        }
        $log = Join-Path $userProfile '.local\state\winfiles\run.log'
        $result | Add-Member Log @(if (Test-Path $log) { Get-Content $log }) -PassThru |
            Add-Member Text (($result.Stdout + $result.Stderr) -join "`n") -PassThru
    }

    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $openPort = $listener.LocalEndpoint.Port
    $closedPort = Get-ClosedPort
}

AfterAll {
    $listener.Stop()
}

Describe 'Wait-Resume.ps1' {
    AfterEach {
        Remove-Item $key -ErrorAction Ignore
    }

    It 'waits for Enter before the install, which asks for UAC, then exits 0' {
        $result = Invoke-Wait $openPort
        $result.ExitCode | Should -Be 0
        $result.Text | Should -BeLike '*Press Enter to continue. It asks for UAC once, then runs by itself*'
        $result.Text | Should -Not -BeLike '*WARNING*'
    }

    It 'stops with 3010, without asking for Enter, when a restart is still pending' {
        New-Item $key | Out-Null
        $result = Invoke-Wait $openPort
        $result.ExitCode | Should -Be 3010
        $result.Text | Should -BeLike '*Windows still has a restart pending*'
        $result.Text | Should -Not -BeLike '*Press Enter*'
    }

    It 'goes ahead after the wait when the source can''t be reached' {
        $result = Invoke-Wait $closedPort
        $result.ExitCode | Should -Be 0
        $result.Text | Should -BeLike "*Can't reach winget's source. Trying anyway.*"
    }

    It 'doesn''t warn about the source when it can be reached' {
        (Invoke-Wait $openPort).Text | Should -Not -BeLike "*Can't reach*"
    }

    It 'notes in the run log that Enter was pressed' {
        $log = (Invoke-Wait $openPort).Log
        $log | Should -HaveCount 1
        $log[0] | Should -Match '^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d \[resume\] continuing: Enter pressed$'
    }

    It 'notes in the run log that a restart is still pending' {
        New-Item $key | Out-Null
        (Invoke-Wait $openPort).Log[-1] |
            Should -Match '\[resume\] stopped before the install: Windows still has a restart pending'
    }

    It 'notes in the run log that the source couldn''t be reached' {
        (Invoke-Wait $closedPort).Log -join "`n" | Should -Match (
            "\[resume\] can't reach winget's source \(127\.0\.0\.1:$closedPort\) after 0s, trying anyway")
    }
}
