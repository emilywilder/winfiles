# A copy of the script in a repo in TestDrive, under Windows PowerShell 5.1 as the RunOnce entry starts it, with a fake
# install.cmd beside it that records its arguments and exits with $env:FAKE_EXIT, so nothing is installed. The restart
# check reads a key under HKCU of its own, and the network check a TcpListener on loopback, so neither depends on the machine.
# run.log goes under a USERPROFILE in TestDrive, never the real one. Each run gets an empty line on stdin for its
# "Press Enter" prompt.
BeforeAll {
    . (Join-Path $PSScriptRoot '..\resources\Resource.ps1')
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $key = "HKCU:\Software\winfiles-test-$([guid]::NewGuid())"

    # A port nothing listens on, for the source that can't be reached
    function Get-ClosedPort {
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $port = $listener.LocalEndpoint.Port
        $listener.Stop()
        $port
    }

    # An empty line is piped in, which presses Enter at its prompt: under 5.1, Read-Host reads redirected stdin
    function Invoke-Resume([int]$FakeExit, [string[]]$Arguments = @(), [int]$Port) {
        $repoCopy = New-Item -ItemType Directory (Join-Path $TestDrive "repo-$([guid]::NewGuid())")
        $scripts = New-Item -ItemType Directory (Join-Path $repoCopy 'scripts')
        Copy-Item (Join-Path $repo 'scripts\Resume-Winfiles.ps1'), (Join-Path $repo 'scripts\winlog.ps1'), (Join-Path $repo 'scripts\restart.ps1') $scripts
        $argumentsFile = Join-Path $repoCopy 'arguments.txt'
        Set-Content (Join-Path $repoCopy 'install.cmd') "@echo %*>`"%~dp0arguments.txt`"`r`n@cd>`"%~dp0cwd.txt`"`r`n@exit /b %FAKE_EXIT%"
        $scriptFile = Join-Path $scripts 'Resume-Winfiles.ps1'
        $userProfile = Join-Path $repoCopy 'home'
        $result = Invoke-Child $TestDrive @{ FAKE_EXIT = "$FakeExit"; USERPROFILE = $userProfile } {
            '' | & $powershell -NoProfile -ExecutionPolicy Bypass -File $scriptFile @Arguments -RebootPendingKey $key -SourceHost 127.0.0.1 -SourcePort $Port -WaitSeconds 0 2>&1
        }
        $ran = Test-Path $argumentsFile
        $log = Join-Path $userProfile '.local\state\winfiles\run.log'
        $result | Add-Member Ran $ran -PassThru |
            Add-Member Log @(if (Test-Path $log) { Get-Content $log }) -PassThru |
            Add-Member RepoCopy $repoCopy.FullName -PassThru |
            Add-Member Cwd ($ran ? (Get-Content (Join-Path $repoCopy 'cwd.txt')) : $null) -PassThru |
            Add-Member Passed ($ran ? (Get-Content $argumentsFile) : $null) -PassThru |
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

Describe 'Resume-Winfiles.ps1' {
    AfterEach {
        Remove-Item $key -ErrorAction Ignore
    }

    It 'runs install.cmd with the arguments it was given and reports that the install finished' {
        $result = Invoke-Resume 0 'iris', 'emily' $openPort
        $result.Passed | Should -Be 'iris emily'
        $result.Text | Should -BeLike '*The winfiles install finished.*'
        $result.Text | Should -Not -BeLike '*WARNING*'
    }

    It 'passes an argument with a space on as one argument' {
        (Invoke-Resume 0 'a b' $openPort).Passed | Should -Be '"a b"'
    }

    It 'moves to the repo first, since RunOnce starts it in System32' {
        # Invoke-Child starts in TestDrive, standing in for System32
        $result = Invoke-Resume 0 'iris' $openPort
        $result.Cwd | Should -Be $result.RepoCopy
    }

    It 'runs install.cmd with no arguments when it has none' {
        $result = Invoke-Resume 0 @() $openPort
        $result.Ran | Should -BeTrue
    }

    It 'warns with install.cmd''s exit code when it fails, without saying it finished' {
        $result = Invoke-Resume 5 'iris' $openPort
        $result.Text | Should -BeLike '*install.cmd exited with code 5.*'
        $result.Text | Should -Not -BeLike '*The winfiles install finished.*'
    }

    It 'stops before install.cmd when a restart is still pending' {
        New-Item $key | Out-Null
        $result = Invoke-Resume 0 'iris' $openPort
        $result.Ran | Should -BeFalse
        $result.Text | Should -BeLike '*Windows still has a restart pending*'
    }

    It 'goes ahead after the wait when the source can''t be reached' {
        $result = Invoke-Resume 0 'iris' $closedPort
        $result.Text | Should -BeLike "*Can't reach winget's source. Trying anyway.*"
        $result.Ran | Should -BeTrue
        $result.Text | Should -BeLike '*The winfiles install finished.*'
    }

    It 'doesn''t warn about the source when it can be reached' {
        (Invoke-Resume 0 'iris' $openPort).Text | Should -Not -BeLike "*Can't reach*"
    }

    It 'notes in the run log that it resumed, and install.cmd''s exit code' {
        $log = (Invoke-Resume 5 'iris', 'emily' $openPort).Log
        $log | Should -HaveCount 3
        $log[0] | Should -Match '^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d \[resume\] resumed after sign-in: install.cmd iris emily$'
        $log[1] | Should -Match '\[resume\] continuing: Enter pressed$'
        $log[2] | Should -Match '\[resume\] install.cmd exited with code 5$'
    }

    It 'waits for Enter before install.cmd, which asks for UAC' {
        $result = Invoke-Resume 0 'iris' $openPort
        $result.Text | Should -BeLike '*Press Enter to continue. It asks for UAC once, then runs by itself*'
        $result.Ran | Should -BeTrue
    }

    It 'doesn''t ask for Enter when a restart is still pending' {
        New-Item $key | Out-Null
        (Invoke-Resume 0 'iris' $openPort).Text | Should -Not -BeLike '*Press Enter*'
    }

    It 'notes in the run log that a restart is still pending' {
        New-Item $key | Out-Null
        (Invoke-Resume 0 'iris' $openPort).Log[-1] | Should -Match '\[resume\] stopped before install.cmd: Windows still has a restart pending'
    }

    It 'notes in the run log that the source couldn''t be reached' {
        (Invoke-Resume 0 'iris' $closedPort).Log -join "`n" | Should -Match "\[resume\] can't reach winget's source \(127\.0\.0\.1:$closedPort\) after 0s, trying anyway"
    }
}

# Both real scripts, chained as a second restart would: Windows deletes the RunOnce value before running it,
# the resume runs install.cmd, and Invoke-Install.ps1 writes the value again when that run stops for a restart too.
Describe 'a second restart in the same install' {
    BeforeAll {
        $runOnce = "HKCU:\Software\winfiles-test-chain-$([guid]::NewGuid())"
        $resumeArguments = @('-RebootPendingKey', "$runOnce-none", '-SourceHost', '127.0.0.1', '-SourcePort', $openPort, '-WaitSeconds', 0)
    }

    AfterEach {
        Remove-Item $runOnce -ErrorAction Ignore
    }

    It 'registers the resume again with the same arguments, and removes it once the install finishes' {
        $repoCopy = New-Item -ItemType Directory (Join-Path $TestDrive "chain-$([guid]::NewGuid())")
        $scripts = New-Item -ItemType Directory (Join-Path $repoCopy 'scripts')
        Copy-Item (Join-Path $repo 'scripts\Resume-Winfiles.ps1'), (Join-Path $repo 'scripts\Invoke-Install.ps1'), (Join-Path $repo 'scripts\winlog.ps1'), (Join-Path $repo 'scripts\restart.ps1') $scripts
        $userProfile = Join-Path $repoCopy 'home'
        Set-Content (Join-Path $scripts 'Start-Clean.ps1') 'exit [int]$env:FAKE_EXIT'
        # The real install.cmd's job, with the test's RunOnce key
        Set-Content (Join-Path $repoCopy 'install.cmd') "@powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0scripts\Invoke-Install.ps1`" -RunOnceKey $runOnce %*`r`n@exit /b %ERRORLEVEL%"
        $install = Join-Path $scripts 'Invoke-Install.ps1'
        $resume = Join-Path $scripts 'Resume-Winfiles.ps1'

        # The first run stops for a restart
        $first = Invoke-Child $TestDrive @{ FAKE_EXIT = '194'; USERPROFILE = $userProfile } {
            & $powershell -NoProfile -ExecutionPolicy Bypass -File $install -RunOnceKey $runOnce iris emily
        }
        $first.ExitCode | Should -Be 194
        $entry = (Get-ItemProperty $runOnce).winfiles
        $entry | Should -BeLike '*Resume-Winfiles.ps1" "iris" "emily"'

        # After the restart Windows deletes the value, then runs it. The resumed run stops for another restart
        Remove-ItemProperty $runOnce -Name winfiles
        $second = Invoke-Child $TestDrive @{ FAKE_EXIT = '194'; USERPROFILE = $userProfile } {
            '' | & $powershell -NoProfile -ExecutionPolicy Bypass -File $resume iris emily @resumeArguments 2>&1
        }
        ($second.Stdout + $second.Stderr) -join "`n" | Should -BeLike '*install.cmd exited with code 194.*'
        (Get-ItemProperty $runOnce).winfiles | Should -Be $entry

        # After the next restart the run finishes
        Remove-ItemProperty $runOnce -Name winfiles
        $third = Invoke-Child $TestDrive @{ FAKE_EXIT = '0'; USERPROFILE = $userProfile } {
            '' | & $powershell -NoProfile -ExecutionPolicy Bypass -File $resume iris emily @resumeArguments 2>&1
        }
        ($third.Stdout + $third.Stderr) -join "`n" | Should -BeLike '*The winfiles install finished.*'
        (Get-ItemProperty $runOnce -ErrorAction Ignore).winfiles | Should -BeNullOrEmpty

        # run.log tells the same story across both restarts
        $events = Get-Content (Join-Path $userProfile '.local\state\winfiles\run.log') | ForEach-Object { ($_ -split '\[resume\] ', 2)[1] }
        $events | Should -Be @(
            'registered the RunOnce entry, which continues the install at the next sign-in if it stops for a restart'
            'kept the RunOnce entry: the install stopped for a restart (exit code 194)'
            'resumed after sign-in: install.cmd iris emily'
            'continuing: Enter pressed'
            'registered the RunOnce entry, which continues the install at the next sign-in if it stops for a restart'
            'kept the RunOnce entry: the install stopped for a restart (exit code 194)'
            'install.cmd exited with code 194'
            'resumed after sign-in: install.cmd iris emily'
            'continuing: Enter pressed'
            'registered the RunOnce entry, which continues the install at the next sign-in if it stops for a restart'
            'removed the RunOnce entry: the install ended with exit code 0'
            'install.cmd exited with code 0'
        )
    }
}
