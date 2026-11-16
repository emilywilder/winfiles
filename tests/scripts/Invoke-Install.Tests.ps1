# A copy of the script in a repo in TestDrive, under Windows PowerShell 5.1 as install.cmd runs it, with a fake
# Start-Clean.ps1 beside it that records its arguments and exits with $env:FAKE_EXIT, so nothing is installed. The RunOnce entry
# goes to a key of its own under HKCU, never the real RunOnce, which would run a resume at the next sign-in.
BeforeAll {
    . (Join-Path $PSScriptRoot '..\resources\Resource.ps1')
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $key = "HKCU:\Software\winfiles-test-$([guid]::NewGuid())"

    function Invoke-Install([int]$FakeExit, [string[]]$Arguments = @()) {
        $scripts = New-Item -ItemType Directory (Join-Path $TestDrive "repo-$([guid]::NewGuid())\scripts")
        Copy-Item (Join-Path $repo 'scripts\Invoke-Install.ps1') $scripts
        $argumentsFile = Join-Path $scripts 'arguments.txt'
        Set-Content (Join-Path $scripts 'Start-Clean.ps1') 'Set-Content (Join-Path $PSScriptRoot ''arguments.txt'') ($args -join '' ''); exit [int]$env:FAKE_EXIT'
        $scriptFile = Join-Path $scripts 'Invoke-Install.ps1'
        $result = Invoke-Child $TestDrive @{ FAKE_EXIT = "$FakeExit" } {
            & $powershell -NoProfile -ExecutionPolicy Bypass -File $scriptFile @Arguments -RunOnceKey $key
        }
        $result | Add-Member Passed (Get-Content $argumentsFile) -PassThru | Add-Member Scripts $scripts -PassThru
    }
}

Describe 'Invoke-Install.ps1' {
    AfterEach {
        Remove-Item $key -ErrorAction Ignore
    }

    It 'runs just install through Start-Clean.ps1 with its arguments, and passes the exit code back' {
        $result = Invoke-Install 1 'iris', 'emily'
        $result.Passed | Should -Be 'just install iris emily'
        $result.ExitCode | Should -Be 1
    }

    It 'removes the entry after a run that finished' {
        (Invoke-Install 0 'iris').ExitCode | Should -Be 0
        (Get-ItemProperty $key -ErrorAction Ignore).winfiles | Should -BeNullOrEmpty
    }

    It 'removes the entry after a failure, so a failure doesn''t resume' {
        (Invoke-Install 1 'iris').ExitCode | Should -Be 1
        (Get-ItemProperty $key -ErrorAction Ignore).winfiles | Should -BeNullOrEmpty
    }

    It 'removes an entry left by an earlier run when this one finishes' {
        New-Item $key | Out-Null
        New-ItemProperty $key -Name winfiles -Value 'old' | Out-Null
        Invoke-Install 0 | Out-Null
        (Get-ItemProperty $key).winfiles | Should -BeNullOrEmpty
    }

    It 'keeps the entry when the run stops for a restart (<code>)' -ForEach @(@{ code = 3010 }, @{ code = 194 }) {
        $result = Invoke-Install $code 'iris', 'emily'
        $result.ExitCode | Should -Be $code
        $value = (Get-ItemProperty $key).winfiles
        $resume = Join-Path $result.Scripts 'Resume-Winfiles.ps1'
        $value | Should -Be "cmd.exe /c start `"winfiles`" powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit -File `"$resume`" `"iris`" `"emily`""
    }

    It 'warns and goes ahead when the command is over RunOnce''s 260 characters' {
        $result = Invoke-Install 3010 (@('x' * 300))
        $result.ExitCode | Should -Be 3010
        $result.Stdout -join "`n" | Should -BeLike '*too long for a RunOnce entry*'
        (Get-ItemProperty $key -ErrorAction Ignore).winfiles | Should -BeNullOrEmpty
        $result.Passed | Should -Be "just install $('x' * 300)"
    }
}
