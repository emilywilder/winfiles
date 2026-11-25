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

    It 'reads each folder or file in turn, and skips one that does not exist' {
        $hostFolder = New-HostFolder @{ 'a.dsc.yaml' = "# post-install: From the host`nkey: 1" }
        $userFolder = New-HostFolder @{ 'u@h.home.dsc.yaml' = "# post-install: From the user`nkey: 1" }
        $userEntry = Join-Path $userFolder 'u@h.home.dsc.yaml'
        $result = Show-PostInstall $hostFolder, (Join-Path $TestDrive 'missing.dsc.yaml'), $userEntry
        $result.ExitCode | Should -Be 0
        $result.Stdout | Should -Be @('', 'Still to do by hand:', '', 'From the host', '', 'From the user')
    }

    It 'reads the documents a file includes, at any depth, rooted in its folder, each once' {
        # Each Include as YAML lines, as in the entries
        $include = {
            param($Path)
            "  - type: Microsoft.DSC/Include`n    properties:`n      configurationFile: $Path`n"
        }
        $includes = (& $include 'sub/a.dsc.yaml') + (& $include "'sub/b.dsc.yaml'")
        $entry = "# post-install: From the entry`nresources:`n$includes"
        $folder = New-HostFolder @{ 'entry.dsc.yaml' = $entry }
        $sub = New-Item -ItemType Directory (Join-Path $folder 'sub')
        # Nested paths resolve from the entry's folder, as DSC does: b is reached from the entry and from a
        $a = "# post-install: From a`nresources:`n" + (& $include 'sub/b.dsc.yaml')
        [IO.File]::WriteAllText((Join-Path $sub 'a.dsc.yaml'), $a)
        [IO.File]::WriteAllText((Join-Path $sub 'b.dsc.yaml'), "# post-install: From b`nkey: 1")
        $result = Show-PostInstall (Join-Path $folder 'entry.dsc.yaml')
        $result.ExitCode | Should -Be 0
        $result.Stdout | Should -Be @('', 'Still to do by hand:', '', 'From the entry', '', 'From a', '', 'From b')
    }

    It "reads a folder's subfolders" {
        $folder = New-HostFolder @{ 'manual.yaml' = "# post-install: From the top`n- name: x" }
        $sub = New-Item -ItemType Directory (Join-Path $folder 'system')
        [IO.File]::WriteAllText((Join-Path $sub 'a.dsc.yaml'), "# post-install: From below`nkey: 1")
        $result = Show-PostInstall $folder
        $result.ExitCode | Should -Be 0
        $result.Stdout | Should -Contain 'From the top'
        $result.Stdout | Should -Contain 'From below'
    }

    It 'reads a document that two of the paths reach once, whatever the case of its name' {
        $include = ("resources:`n  - type: Microsoft.DSC/Include`n    properties:`n" +
            "      configurationFile: `"SHARED.dsc.yaml`"`n")
        $folder = New-HostFolder @{
            'one.dsc.yaml'    = $include
            'two.dsc.yaml'    = $include
            'shared.dsc.yaml' = "# post-install: Shared`nkey: 1"
        }
        $paths = 'one.dsc.yaml', 'two.dsc.yaml', 'shared.dsc.yaml' | ForEach-Object { Join-Path $folder $_ }
        (Show-PostInstall $paths).Stdout | Should -Be @('', 'Still to do by hand:', '', 'Shared')
    }

    It 'skips an included document that does not exist, and reads the rest' {
        $entry = ("# post-install: From the entry`nresources:`n" +
            "  - type: Microsoft.DSC/Include`n    properties:`n      configurationFile: missing.dsc.yaml`n")
        $folder = New-HostFolder @{ 'entry.dsc.yaml' = $entry }
        $result = Show-PostInstall (Join-Path $folder 'entry.dsc.yaml')
        $result.ExitCode | Should -Be 0
        $result.Stdout | Should -Be @('', 'Still to do by hand:', '', 'From the entry')
    }

    It 'follows an Include <Case>' -ForEach @(
        @{
            Case = 'in a file with CRLF line endings'
            Yaml = ("resources:`r`n  - type: Microsoft.DSC/Include`r`n    properties:`r`n" +
                "      configurationFile: a.dsc.yaml`r`n")
        }
        @{
            Case = 'with a comment after its path'
            Yaml = ("resources:`n  - type: Microsoft.DSC/Include`n    properties:`n" +
                "      configurationFile: a.dsc.yaml # why`n")
        }
        @{
            Case = 'written inline'
            Yaml = ("resources:`n" +
                '  - { type: Microsoft.DSC/Include, properties: { configurationFile: a.dsc.yaml } }')
        }
    ) {
        $folder = New-HostFolder @{ 'entry.dsc.yaml' = $Yaml; 'a.dsc.yaml' = "# post-install: From a`nkey: 1" }
        $result = Show-PostInstall (Join-Path $folder 'entry.dsc.yaml')
        $result.ExitCode | Should -Be 0
        $result.Stdout | Should -Be @('', 'Still to do by hand:', '', 'From a')
    }

    It 'follows only Includes, not other text that names a configurationFile' {
        $entry = @'
# A commented-out Include:
#      configurationFile: a.dsc.yaml
resources:
  - type: Test/Thing
    properties:
      configurationFile: a.dsc.yaml
  - type: Microsoft.DSC.Transitional/PowerShellScript
    properties:
      setScript: |
        configurationFile: a.dsc.yaml
'@
        $folder = New-HostFolder @{ 'entry.dsc.yaml' = $entry; 'a.dsc.yaml' = "# post-install: From a`nkey: 1" }
        $result = Show-PostInstall (Join-Path $folder 'entry.dsc.yaml')
        $result.ExitCode | Should -Be 0
        $result.Stdout | Should -BeNullOrEmpty
    }

    It "fails on a file that isn't YAML, rather than leave its notes out" {
        $folder = New-HostFolder @{ 'entry.dsc.yaml' = "resources: [`n" }
        (Show-PostInstall (Join-Path $folder 'entry.dsc.yaml')).ExitCode | Should -Not -Be 0
    }

    It "prints emily@iris's NixOS note" {
        (Show-PostInstall (Join-Path $repo 'dsc\emily@iris.home.dsc.yaml')).Stdout -join "`n" |
            Should -BeLike '*owned by the NixOS*wsl -d NixOS -- passwd*'
    }

    # Checked by hand when the script was written: `winfiles.ps1 post-install vm` printed nothing
    It 'prints nothing for a host with no notes, like vm' {
        $paths = (Join-Path $repo 'dsc\hosts\vm\manual.yaml'), (Join-Path $repo 'dsc\vm.system.dsc.yaml')
        $result = Show-PostInstall $paths
        $result.ExitCode | Should -Be 0
        $result.Stdout | Should -BeNullOrEmpty
    }

    # The note is in dsc/modules/system/remote-desktop.dsc.yaml, which only iris's entry includes
    It "prints iris's Remote Desktop note, from a module its entry includes" {
        (Show-PostInstall (Join-Path $repo 'dsc\iris.system.dsc.yaml')).Stdout -join "`n" |
            Should -BeLike "*Remote Desktop rejects a Microsoft account's password*doesn't cover this.*"
    }
}
