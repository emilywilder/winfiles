BeforeAll {
    . (Join-Path $PSScriptRoot '..\resources\Resource.ps1')

    # A host folder holding the given files (name → content)
    function New-HostFolder([hashtable]$Files) {
        $folder = New-Item -ItemType Directory (Join-Path $TestDrive "host-$([guid]::NewGuid())")
        foreach ($name in $Files.Keys) { [IO.File]::WriteAllText((Join-Path $folder $name), $Files[$name]) }
        $folder.FullName
    }

    function Show-PostInstall([string[]]$Folder) {
        Invoke-Script Show-PostInstall.ps1 $Folder
    }
}

Describe 'Show-PostInstall.ps1' {
    It "prints each note's block of comment lines, without the comment marks" {
        $folder = New-HostFolder @{
            'settings.dsc.yaml' = @"
# A comment that isn't a note
# post-install: Turn off the thing
# in Settings, then sign out.
#
#   Indented text keeps its indent.
parameters:
  key:
    # post-install: A second note, indented in the YAML.
    type: string
"@
        }
        $result = Show-PostInstall $folder
        $result.ExitCode | Should -Be 0
        $result.Stdout | Should -Be @(
            ''
            'Still to do by hand:'
            ''
            'Turn off the thing'
            'in Settings, then sign out.'
            ''
            '  Indented text keeps its indent.'
            ''
            'A second note, indented in the YAML.'
        )
    }

    It 'reads CRLF files the same' {
        $folder = New-HostFolder @{ 'a.dsc.yaml' = "# post-install: One`r`n# two`r`nkey: value`r`n" }
        (Show-PostInstall $folder).Stdout | Should -Be @('', 'Still to do by hand:', '', 'One', 'two')
    }

    It 'collects notes from every YAML file, manual.yaml included' {
        $folder = New-HostFolder @{
            'a.dsc.yaml'  = "# post-install: From a`nkey: 1"
            'manual.yaml' = "# post-install: From manual`n- name: x"
        }
        (Show-PostInstall $folder).Stdout | Should -Contain 'From a'
        (Show-PostInstall $folder).Stdout | Should -Contain 'From manual'
    }

    It 'ignores other files, and a note that needs its space' {
        $folder = New-HostFolder @{
            'notes.md'   = '# post-install: Not YAML'
            'a.dsc.yaml' = "#post-install: No space`n# post-installation: Another word`nkey: 1"
        }
        $result = Show-PostInstall $folder
        $result.ExitCode | Should -Be 0
        $result.Stdout | Should -BeNullOrEmpty
    }

    It 'reads each folder in turn, and skips one that does not exist' {
        $hostFolder = New-HostFolder @{ 'a.dsc.yaml' = "# post-install: From the host`nkey: 1" }
        $userFolder = New-HostFolder @{ 'wsl.dsc.yaml' = "# post-install: From the user`nkey: 1" }
        $result = Show-PostInstall $hostFolder, (Join-Path $TestDrive 'missing'), $userFolder
        $result.ExitCode | Should -Be 0
        $result.Stdout | Should -Be @('', 'Still to do by hand:', '', 'From the host', '', 'From the user')
    }

    It "prints emily@iris's NixOS note" {
        (Show-PostInstall (Join-Path $repo 'dsc\users\emily@iris')).Stdout -join "`n" |
            Should -BeLike '*owned by the NixOS*wsl -d NixOS -- passwd*'
    }

    # Checked by hand when the script was written: `just post-install vm` printed nothing
    It 'prints nothing for a host with no notes, like vm' {
        $result = Show-PostInstall (Join-Path $repo 'dsc\hosts\vm')
        $result.ExitCode | Should -Be 0
        $result.Stdout | Should -BeNullOrEmpty
    }

    It "prints iris's Remote Desktop note" {
        (Show-PostInstall (Join-Path $repo 'dsc\hosts\iris')).Stdout -join "`n" |
            Should -BeLike "*Remote Desktop rejects a Microsoft account's password*doesn't cover this.*"
    }
}
