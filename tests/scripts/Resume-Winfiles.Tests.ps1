# A copy of the script in a repo in TestDrive, under Windows PowerShell 5.1 as the RunOnce entry starts it, with a
# fake install.cmd beside it that records its arguments and exits with $env:FAKE_EXIT, so nothing is installed. The
# restart check reads a key under HKCU of its own, and the network check a TcpListener on loopback, so neither
# depends on the machine. run.log goes under a USERPROFILE in TestDrive, never the real one. Each run gets an empty
# line on stdin for its "Press Enter" prompt.
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
        Copy-Item -Destination $scripts -Path @(
            'Resume-Winfiles.ps1', 'winlog.ps1', 'restart.ps1', 'resume.ps1' | ForEach-Object { Join-Path $repo "scripts\$_" })
        $argumentsFile = Join-Path $repoCopy 'arguments.txt'
        Set-Content (Join-Path $repoCopy 'install.cmd') (
            "@echo %*>`"%~dp0arguments.txt`"`r`n@cd>`"%~dp0cwd.txt`"`r`n@exit /b %FAKE_EXIT%")
        $scriptFile = Join-Path $scripts 'Resume-Winfiles.ps1'
        $userProfile = Join-Path $repoCopy 'home'
        $result = Invoke-Child $TestDrive @{ FAKE_EXIT = "$FakeExit"; USERPROFILE = $userProfile } {
            '' | & $powershell -NoProfile -ExecutionPolicy Bypass -File $scriptFile @Arguments `
                -RebootPendingKey $key `
                -SourceHost 127.0.0.1 -SourcePort $Port -WaitSeconds 0 2>&1
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
        $log[0] |
            Should -Match ('^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d \[resume\] ' +
                'resumed after sign-in: install.cmd iris emily$')
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
        (Invoke-Resume 0 'iris' $openPort).Log[-1] |
            Should -Match '\[resume\] stopped before install.cmd: Windows still has a restart pending'
    }

    It 'notes in the run log that the source couldn''t be reached' {
        (Invoke-Resume 0 'iris' $closedPort).Log -join "`n" | Should -Match (
            "\[resume\] can't reach winget's source \(127\.0\.0\.1:$closedPort\) after 0s, trying anyway")
    }
}


# The resume across restarts, with the real Resume-Winfiles.ps1, resume.ps1 and restart.ps1 and a fake install in
# place of winfiles.ps1: what it does around an install is clearing the entry an earlier run left, putting its
# arguments in WINFILES_RESUME as the runner does, and stopping for a restart through restart.ps1 when $env:FAKE_EXIT
# is 3010. Windows deletes the RunOnce value before running it, which the test does between runs.
Describe 'a second restart in the same install' {
    BeforeAll {
        $runOnce = "HKCU:\Software\winfiles-test-chain-$([guid]::NewGuid())"
        $resumeArguments = @(
            '-RebootPendingKey', "$runOnce-none", '-SourceHost', '127.0.0.1', '-SourcePort', $openPort,
            '-WaitSeconds', 0
        )
    }

    AfterEach {
        Remove-Item $runOnce -ErrorAction Ignore
    }

    It 'arms the resume again with the same arguments, and leaves none once the install finishes' {
        $repoCopy = New-Item -ItemType Directory (Join-Path $TestDrive "chain-$([guid]::NewGuid())")
        $scripts = New-Item -ItemType Directory (Join-Path $repoCopy 'scripts')
        Copy-Item -Destination $scripts -Path @(
            'Resume-Winfiles.ps1', 'winlog.ps1', 'restart.ps1', 'resume.ps1' |
                ForEach-Object { Join-Path $repo "scripts\$_" })
        $userProfile = Join-Path $repoCopy 'home'
        Set-Content (Join-Path $scripts 'Install.ps1') @'
. (Join-Path $PSScriptRoot 'winlog.ps1')
. (Join-Path $PSScriptRoot 'restart.ps1')
Clear-Resume
$env:WINFILES_RESUME = ConvertTo-Json -InputObject @($args) -Compress
if ($env:FAKE_EXIT -eq '3010') { Exit-RestartPending -Phase apply }
exit [int]$env:FAKE_EXIT
'@
        Set-Content (Join-Path $repoCopy 'install.cmd') (
            "@pwsh -NoLogo -NoProfile -File `"%~dp0scripts\Install.ps1`" %*`r`n@exit /b %ERRORLEVEL%")
        $installCmd = Join-Path $repoCopy 'install.cmd'
        $resume = Join-Path $scripts 'Resume-Winfiles.ps1'
        $environment = @{ USERPROFILE = $userProfile; WINFILES_RUNONCE_KEY = $runOnce }

        # The first run stops for a restart
        $first = Invoke-Child $TestDrive ($environment + @{ FAKE_EXIT = '3010' }) { & $installCmd iris emily }
        $first.ExitCode | Should -Be 3010
        $entry = (Get-ItemProperty $runOnce).winfiles
        $entry | Should -BeLike '*Resume-Winfiles.ps1" "iris" "emily"'

        # After the restart Windows deletes the value, then runs it. The resumed run stops for another restart
        Remove-ItemProperty $runOnce -Name winfiles
        $second = Invoke-Child $TestDrive ($environment + @{ FAKE_EXIT = '3010' }) {
            '' | & $powershell -NoProfile -ExecutionPolicy Bypass -File $resume iris emily @resumeArguments 2>&1
        }
        ($second.Stdout + $second.Stderr) -join "`n" | Should -BeLike '*install.cmd exited with code 3010.*'
        (Get-ItemProperty $runOnce).winfiles | Should -Be $entry

        # After the next restart the run finishes
        Remove-ItemProperty $runOnce -Name winfiles
        $third = Invoke-Child $TestDrive ($environment + @{ FAKE_EXIT = '0' }) {
            '' | & $powershell -NoProfile -ExecutionPolicy Bypass -File $resume iris emily @resumeArguments 2>&1
        }
        ($third.Stdout + $third.Stderr) -join "`n" | Should -BeLike '*The winfiles install finished.*'
        (Get-ItemProperty $runOnce -ErrorAction Ignore).winfiles | Should -BeNullOrEmpty

        # run.log tells the same story across both restarts
        $events = Get-Content (Join-Path $userProfile '.local\state\winfiles\run.log') |
            Where-Object { $_ -match '\[resume\] ' } |
            ForEach-Object { ($_ -split '\[resume\] ', 2)[1] }
        $registered = 'registered the RunOnce entry, which continues the install at the next sign-in'
        $events | Should -Be @(
            $registered
            'resumed after sign-in: install.cmd iris emily'
            'continuing: Enter pressed'
            $registered
            'install.cmd exited with code 3010'
            'resumed after sign-in: install.cmd iris emily'
            'continuing: Enter pressed'
            'install.cmd exited with code 0'
        )
    }
}
