# A copy of the script in a repo in TestDrive, under Windows PowerShell 5.1 as the RunOnce entry starts it, with a fake
# install.cmd beside it that records its arguments and exits with $env:FAKE_EXIT, so nothing is installed. The restart
# check reads a key under HKCU of its own, and the network check a TcpListener on loopback, so neither depends on the machine.
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

    function Invoke-Resume([int]$FakeExit, [string[]]$Arguments = @(), [int]$Port) {
        $repoCopy = New-Item -ItemType Directory (Join-Path $TestDrive "repo-$([guid]::NewGuid())")
        $scripts = New-Item -ItemType Directory (Join-Path $repoCopy 'scripts')
        Copy-Item (Join-Path $repo 'scripts\Resume-Winfiles.ps1') $scripts
        $argumentsFile = Join-Path $repoCopy 'arguments.txt'
        Set-Content (Join-Path $repoCopy 'install.cmd') "@echo %*>`"%~dp0arguments.txt`"`r`n@cd>`"%~dp0cwd.txt`"`r`n@exit /b %FAKE_EXIT%"
        $scriptFile = Join-Path $scripts 'Resume-Winfiles.ps1'
        $result = Invoke-Child $TestDrive @{ FAKE_EXIT = "$FakeExit" } {
            & $powershell -NoProfile -ExecutionPolicy Bypass -File $scriptFile @Arguments -RebootPendingKey $key -SourceHost 127.0.0.1 -SourcePort $Port -WaitSeconds 0 2>&1
        }
        $ran = Test-Path $argumentsFile
        $result | Add-Member Ran $ran -PassThru |
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
        Copy-Item (Join-Path $repo 'scripts\Resume-Winfiles.ps1'), (Join-Path $repo 'scripts\Invoke-Install.ps1') $scripts
        Set-Content (Join-Path $scripts 'Start-Clean.ps1') 'exit [int]$env:FAKE_EXIT'
        # The real install.cmd's job, with the test's RunOnce key
        Set-Content (Join-Path $repoCopy 'install.cmd') "@powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0scripts\Invoke-Install.ps1`" -RunOnceKey $runOnce %*`r`n@exit /b %ERRORLEVEL%"
        $install = Join-Path $scripts 'Invoke-Install.ps1'
        $resume = Join-Path $scripts 'Resume-Winfiles.ps1'

        # The first run stops for a restart
        $first = Invoke-Child $TestDrive @{ FAKE_EXIT = '194' } {
            & $powershell -NoProfile -ExecutionPolicy Bypass -File $install -RunOnceKey $runOnce iris emily
        }
        $first.ExitCode | Should -Be 194
        $entry = (Get-ItemProperty $runOnce).winfiles
        $entry | Should -BeLike '*Resume-Winfiles.ps1" "iris" "emily"'

        # After the restart Windows deletes the value, then runs it. The resumed run stops for another restart
        Remove-ItemProperty $runOnce -Name winfiles
        $second = Invoke-Child $TestDrive @{ FAKE_EXIT = '194' } {
            & $powershell -NoProfile -ExecutionPolicy Bypass -File $resume iris emily @resumeArguments 2>&1
        }
        ($second.Stdout + $second.Stderr) -join "`n" | Should -BeLike '*install.cmd exited with code 194.*'
        (Get-ItemProperty $runOnce).winfiles | Should -Be $entry

        # After the next restart the run finishes
        Remove-ItemProperty $runOnce -Name winfiles
        $third = Invoke-Child $TestDrive @{ FAKE_EXIT = '0' } {
            & $powershell -NoProfile -ExecutionPolicy Bypass -File $resume iris emily @resumeArguments 2>&1
        }
        ($third.Stdout + $third.Stderr) -join "`n" | Should -BeLike '*The winfiles install finished.*'
        (Get-ItemProperty $runOnce -ErrorAction Ignore).winfiles | Should -BeNullOrEmpty
    }
}
