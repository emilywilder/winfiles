# resume.ps1, and what restart.ps1 does with it when a run stops for a restart. The entry goes to a key of its
# own under HKCU (WINFILES_RUNONCE_KEY), never the real RunOnce, which would run a resume at the next sign-in, and
# run.log under a USERPROFILE in TestDrive. Nothing here can restart the computer: Restart-Windows runs in a child
# where functions named Restart-Computer and Start-Sleep stand in for the cmdlets, and a function comes before a
# cmdlet of the same name. The stand-in says it was called.
BeforeAll {
    . (Join-Path $PSScriptRoot '..\resources\Resource.ps1')
    $scripts = Join-Path $repo 'scripts'
    $key = "HKCU:\Software\winfiles-test-$([guid]::NewGuid())"
    $userProfile = Join-Path $TestDrive 'home'
    $log = Join-Path $userProfile '.local\state\winfiles\run.log'
    $saved = @{}
    foreach ($name in 'USERPROFILE', 'WINFILES_RUNONCE_KEY', 'WINFILES_RESUME') {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name)
    }
    $env:USERPROFILE = $userProfile
    $env:WINFILES_RUNONCE_KEY = $key
    . (Join-Path $scripts 'winlog.ps1')
    . (Join-Path $scripts 'resume.ps1')

    # What the entry holds: `winfiles.ps1 resume` through the launcher, in a window that opens in the repo
    function Get-ExpectedEntry([string[]]$Argument) {
        $launcher = Join-Path $scripts 'Start-Winfiles.ps1'
        $start = "cmd.exe /c start `"winfiles`" /D `"$repo`" powershell.exe -NoProfile -ExecutionPolicy Bypass"
        $entry = "$start -NoExit -File `"$launcher`" resume"
        foreach ($each in $Argument) { $entry += " `"$each`"" }
        $entry
    }

    # Runs a function of restart.ps1 in a child, since the ones that stop a run exit
    function Invoke-Restart([string]$Command, [string]$Resume) {
        $fakes = "function Restart-Computer { 'Restart-Computer was called' }; function Start-Sleep {}"
        $load = "$fakes; . '$scripts\winlog.ps1'; . '$scripts\restart.ps1'"
        Invoke-Child $TestDrive @{
            WINFILES_RESUME = $Resume; WINFILES_RUNONCE_KEY = $key; USERPROFILE = $userProfile
        } { pwsh -NoLogo -NoProfile -NonInteractive -Command "$load; $Command" }
    }
}

AfterAll {
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
}

Describe 'resume.ps1' {
    BeforeEach {
        $env:WINFILES_RESUME = $null
        Remove-Item $log -ErrorAction Ignore
    }

    AfterEach {
        Remove-Item $key -ErrorAction Ignore
    }

    Context 'Register-Resume' {
        It 'arms the entry with the arguments the run asked to resume with' {
            $env:WINFILES_RESUME = '["iris","emily"]'
            Register-Resume
            (Get-ItemProperty $key).winfiles | Should -Be (Get-ExpectedEntry 'iris', 'emily')
            (Get-Content $log) | Should -Match '\[resume\] registered the RunOnce entry'
        }

        It 'does nothing when the run asked for no resume' {
            Register-Resume
            Test-Path $key | Should -BeFalse
            Test-Path $log | Should -BeFalse
        }

        It 'does nothing under -WhatIf' {
            $env:WINFILES_RESUME = '["iris"]'
            Register-Resume -WhatIf
            Test-Path $key | Should -BeFalse
        }

        It 'replaces an entry that is there, and leaves the key''s other values alone' {
            New-Item $key | Out-Null
            New-ItemProperty $key -Name winfiles -Value old | Out-Null
            New-ItemProperty $key -Name other -Value keep | Out-Null
            $env:WINFILES_RESUME = '["vm"]'
            Register-Resume
            (Get-ItemProperty $key).winfiles | Should -Be (Get-ExpectedEntry 'vm')
            (Get-ItemProperty $key).other | Should -Be keep
        }

        It 'warns and arms nothing when the command is over RunOnce''s 260 characters' {
            $env:WINFILES_RESUME = ConvertTo-Json -InputObject @('x' * 300) -Compress
            Register-Resume -WarningVariable warning -WarningAction SilentlyContinue
            "$warning" | Should -BeLike '*too long for a RunOnce entry*'
            Test-Path $key | Should -BeFalse
            (Get-Content $log) |
                Should -Match '\[resume\] not registered: the RunOnce entry would be \d+ characters, over 260'
        }
    }

    Context 'Clear-Resume' {
        It 'removes an entry an earlier run left, and says so, but not the key''s other values' {
            New-Item $key | Out-Null
            New-ItemProperty $key -Name winfiles -Value old | Out-Null
            New-ItemProperty $key -Name other -Value keep | Out-Null
            Clear-Resume
            (Get-ItemProperty $key).winfiles | Should -BeNullOrEmpty
            (Get-ItemProperty $key).other | Should -Be keep
            (Get-Content $log) | Should -Match '\[resume\] removed the RunOnce entry an earlier run left$'
        }

        It 'does nothing, and says nothing, when there is no entry' {
            Clear-Resume
            Test-Path $log | Should -BeFalse
        }
    }

    Context 'a run that stops for a restart' {
        It 'arms the resume, says the run continues after sign-in, and exits 3010 (Exit-RestartPending)' {
            $result = Invoke-Restart 'Exit-RestartPending -Phase apply -Done "Applied. "' '["iris","emily"]'
            $result.ExitCode | Should -Be 3010
            (Get-ItemProperty $key).winfiles | Should -Be (Get-ExpectedEntry 'iris', 'emily')
            ($result.Stdout + $result.Stderr -join "`n") | Should -BeLike '*Applied. *continues after you sign in*'
        }

        It 'arms nothing, says to run the command again, and still exits 3010, when the run asked for no resume' {
            $result = Invoke-Restart 'Exit-RestartPending -Phase apply' $null
            $result.ExitCode | Should -Be 3010
            Test-Path $key | Should -BeFalse
            ($result.Stdout + $result.Stderr -join "`n") | Should -BeLike '*run the same command again*'
        }

        It 'restarts, after arming the resume, when the run asked for one (Restart-Windows)' {
            $result = Invoke-Restart 'Restart-Windows -Phase apply' '["iris"]'
            $result.ExitCode | Should -Be 3010
            $result.Stdout | Should -Contain 'Restart-Computer was called'
            (Get-ItemProperty $key).winfiles | Should -Be (Get-ExpectedEntry 'iris')
        }

        It 'never restarts, and stops for the person instead, when the run asked for no resume (Restart-Windows)' {
            $result = Invoke-Restart 'Restart-Windows -Phase apply -Done "Applied. "' $null
            $result.ExitCode | Should -Be 3010
            $result.Stdout | Should -Not -Contain 'Restart-Computer was called'
            Test-Path $key | Should -BeFalse
            ($result.Stdout + $result.Stderr -join "`n") | Should -BeLike '*Applied. *run the same command again*'
        }

        It 'arms nothing when -WhatIf stops it at the restart (Restart-Windows)' {
            $result = Invoke-Restart 'Restart-Windows -Phase apply -WhatIf' '["iris"]'
            $result.ExitCode | Should -Be 3010
            $result.Stdout | Should -Not -Contain 'Restart-Computer was called'
            Test-Path $key | Should -BeFalse
        }
    }
}
