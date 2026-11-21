# winlog.ps1 is dot-sourced by the scripts that report progress; here with USERPROFILE pointed at TestDrive:
BeforeAll {
    $script:profileBefore = $env:USERPROFILE
    $env:USERPROFILE = Join-Path $TestDrive 'home'
    . (Join-Path $PSScriptRoot '..\..\scripts\winlog.ps1')
}

AfterAll {
    $env:USERPROFILE = $script:profileBefore
}

Describe 'Write-WinfilesLog' {
    It 'appends the time, phase and message to run.log, and prints nothing' {
        $output = Write-WinfilesLog install 'started' 6>&1
        $output | Should -BeNullOrEmpty
        Write-WinfilesLog install 'finished'
        $log = @(Get-Content (Join-Path $env:USERPROFILE '.local\state\winfiles\run.log'))
        $log | Should -HaveCount 2
        $log[0] | Should -Match '^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d \[install\] started$'
        $log[1] | Should -Match ' \[install\] finished$'
    }

    It "doesn't stop a run when the file can't be written" {
        $blocked = Join-Path $TestDrive 'blocked'
        Set-Content $blocked 'a file where the folder should be'
        $env:USERPROFILE = $blocked
        try { { Write-WinfilesLog install 'started' } | Should -Not -Throw }
        finally { $env:USERPROFILE = Join-Path $TestDrive 'home' }
    }
}
