# Get-ManualInstaller.ps1 reads what's installed from the real Uninstall keys, without writing them, so the lists
# here name a program that's installed on this machine and ones that can't be. winget is the fake
# tests/fakes/bin/winget.cmd, which downloads nothing, and $HOME is a folder in TestDrive:, which holds the
# download folder.
BeforeAll {
    . (Join-Path $PSScriptRoot '..\resources\Resource.ps1')

    $uninstallKeys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $script:installedName = (Get-ItemProperty $uninstallKeys).DisplayName | Where-Object { $_ -match '^\w{4,}' } |
        Select-Object -First 1

    # A manual.yaml with the given entries, and a fake winget and $HOME. Pass .Environment to Invoke-Script
    function New-ManualList([object[]]$Entries, [int]$WingetExitCode = 0) {
        $folder = New-Item -ItemType Directory (Join-Path $TestDrive "manual-$([guid]::NewGuid())")
        $list = Join-Path $folder 'manual.yaml'
        # JSON is YAML too
        ConvertTo-Json -InputObject @($Entries) -Depth 3 | Set-Content $list
        $winget = New-Item -ItemType Directory (Join-Path $folder 'winget')
        if ($WingetExitCode) { Set-Content (Join-Path $winget 'exitcode.txt') $WingetExitCode -NoNewline }
        $userHome = New-Item -ItemType Directory (Join-Path $folder 'home')
        [pscustomobject]@{
            Path        = $list
            Home        = $userHome.FullName
            Winget      = $winget.FullName
            Environment = @{
                PATH                     = "$(Join-Path $fakes 'bin');$env:PATH"
                WINFILES_FAKE_WINGET_CLI = $winget.FullName
                USERPROFILE              = $userHome.FullName
            }
        }
    }

    function Get-WingetCalls($List) {
        $calls = Join-Path $List.Winget 'calls.txt'
        if (Test-Path $calls) { @(Get-Content $calls | ForEach-Object Trim) } else { @() }
    }

    function New-Missing([string]$Name) {
        @{ name = $Name; why = "Why $Name"; detect = "winfiles-test-$([guid]::NewGuid())"; winget = "Test.$Name" }
    }
}

Describe 'Get-ManualInstaller.ps1' {
    It 'has nothing to do for a host with no list' {
        $list = New-ManualList @()
        $missing = Join-Path $TestDrive 'nowhere\manual.yaml'
        $result = Invoke-Script Get-ManualInstaller.ps1 $missing -Environment $list.Environment
        $result.ExitCode | Should -Be 0
        $result.Stdout | Should -Be "Nothing to install by hand: there's no $missing"
    }

    It 'downloads nothing when everything is installed, matching part of the name in any case' {
        $list = New-ManualList @(@{
                name = 'Installed'; why = 'x'; detect = $installedName.Substring(0, 4).ToUpper()
                winget = 'Test.Installed'
            })
        $result = Invoke-Script Get-ManualInstaller.ps1 $list.Path -Environment $list.Environment
        $result.ExitCode | Should -Be 0
        $result.Stdout | Should -Be "All 1 programs in $($list.Path) are installed."
        Get-WingetCalls $list | Should -BeNullOrEmpty
    }

    It 'downloads what is missing, in order, into ~/.cache/winfiles/manual' {
        $installed = @{ name = 'Installed'; why = 'x'; detect = $installedName; winget = 'Test.Installed' }
        $list = New-ManualList @((New-Missing First), $installed, (New-Missing Second))
        $result = Invoke-Script Get-ManualInstaller.ps1 $list.Path -Environment $list.Environment
        $result.ExitCode | Should -Be 0
        $folder = Join-Path $list.Home '.cache/winfiles/manual'
        Test-Path $folder | Should -BeTrue
        $options = ("--exact --source winget --download-directory $folder --accept-package-agreements " +
            '--accept-source-agreements --disable-interactivity')
        Get-WingetCalls $list |
            Should -Be @("download --id Test.First $options", "download --id Test.Second $options")
        $result.Stdout | Should -Contain 'First is missing. Why First'
        $result.Stdout | Should -Not -Contain 'Installed is missing. x'
        $result.Stdout[-1] | Should -Be "Install them by hand, in the order above, from $folder"
    }

    It 'still tries the rest after a download fails, and exits 1' {
        $list = New-ManualList @((New-Missing First), (New-Missing Second)) -WingetExitCode 5
        $result = Invoke-Script Get-ManualInstaller.ps1 $list.Path -Environment $list.Environment
        $result.ExitCode | Should -Be 1
        Get-WingetCalls $list | Should -HaveCount 2
        $result.Stdout[-1] | Should -Be "Couldn't download: First, Second"
    }

    # On iris everything is installed, so this may download nothing
    It "reads iris's real list" {
        $list = New-ManualList @()
        $result = Invoke-Script Get-ManualInstaller.ps1 (Join-Path $repo 'dsc\hosts\iris\manual.yaml') `
            -Environment $list.Environment
        $result.ExitCode | Should -Be 0
        foreach ($call in Get-WingetCalls $list) {
            ($call -split ' ')[2] | Should -BeIn @('Corsair.iCUE.5', 'Blizzard.BattleNet', 'LyX.LyX')
        }
    }
}
