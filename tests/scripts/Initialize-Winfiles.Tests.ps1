# Only the checks the bootstrap makes before changing anything. Every test runs a copy of the script in a repo in
# TestDrive: with no mise.toml or mise.lock beside it, so a check always fails, and nothing past the checks (App
# Installer, mise, the tools) can run, on this machine or anywhere. Under Windows PowerShell 5.1, as bootstrap.cmd runs it.
BeforeAll {
    . (Join-Path $PSScriptRoot '..\resources\Resource.ps1')
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)

    function Invoke-Bootstrap([hashtable]$Environment = @{}) {
        $copy = New-Item -ItemType Directory (Join-Path $TestDrive "repo-$([guid]::NewGuid())\scripts")
        Copy-Item (Join-Path $repo 'scripts\Initialize-Winfiles.ps1') $copy
        $scriptFile = Join-Path $copy 'Initialize-Winfiles.ps1'
        Invoke-Child $TestDrive $Environment { & $powershell -NoProfile -ExecutionPolicy Bypass -File $scriptFile }
    }
}

Describe 'Initialize-Winfiles.ps1' {
    It 'lists every missing file, then stops before changing anything' {
        $result = Invoke-Bootstrap
        $result.ExitCode | Should -Be 1
        ($result.Stdout | Where-Object { $_ -like '  - mise.toml is missing from *' }) | Should -HaveCount 1
        ($result.Stdout | Where-Object { $_ -like '  - mise.lock is missing from *' }) | Should -HaveCount 1
        $result.Stderr -join "`n" | Should -BeLike '*Nothing was changed. Fix the problems above, then run this again.*'
        $result.Stdout | Should -Not -Contain 'Updating App Installer with winget...'
        $result.Stdout | Should -Not -Contain 'The bootstrap will:'
    }

    It 'refuses a machine that isn''t x64' {
        $result = Invoke-Bootstrap @{ PROCESSOR_ARCHITECTURE = 'ARM64'; PROCESSOR_ARCHITEW6432 = $null }
        $result.ExitCode | Should -Be 1
        $result.Stdout | Should -Contain '  - This is a ARM64 machine. winfiles needs x64: mise.lock only has windows-x64 downloads.'
    }

    It 'accepts x64 under a 32-bit PowerShell' {
        $result = Invoke-Bootstrap @{ PROCESSOR_ARCHITECTURE = 'x86'; PROCESSOR_ARCHITEW6432 = 'AMD64' }
        $result.Stdout -join "`n" | Should -Not -BeLike '*winfiles needs x64*'
    }

    It 'says where to get winget when it isn''t found' {
        $result = Invoke-Bootstrap @{ PATH = Join-Path $env:SystemRoot 'System32' }
        $result.ExitCode | Should -Be 1
        $result.Stdout | Should -Contain '  - winget wasn''t found. It comes with App Installer: install or update App Installer from the Microsoft Store, then run this again.'
    }

    It 'passes the checks it can on this machine' {
        $stdout = (Invoke-Bootstrap).Stdout -join "`n"
        $stdout | Should -Not -BeLike '*winfiles needs x64*'
        $stdout | Should -Not -BeLike '*needs Windows 11*'
        $stdout | Should -Not -BeLike '*winget wasn''t found*'
    }

    It 'refuses an elevated shell' -Skip:(-not $isAdmin) {
        $result = Invoke-Bootstrap
        $result.ExitCode | Should -Be 1
        $result.Stdout -join "`n" | Should -BeLike '*This is an elevated shell*'
    }

    It 'accepts an unelevated shell' -Skip:$isAdmin {
        (Invoke-Bootstrap).Stdout -join "`n" | Should -Not -BeLike '*This is an elevated shell*'
    }
}
