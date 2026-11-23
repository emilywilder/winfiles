# Install-Rebuild.ps1 writes into TestDrive: here, never into the real ~/bin
BeforeAll {
    . (Join-Path $PSScriptRoot '..\resources\Resource.ps1')

    function New-BinFolder {
        Join-Path $TestDrive "bin-$([guid]::NewGuid())"
    }

    function Invoke-Rebuild([string]$Directory) {
        Invoke-Script Install-Rebuild.ps1 $Directory
    }
}

Describe 'Install-Rebuild.ps1' {
    It 'writes winfiles-rebuild.ps1 for this checkout, creating the folder' {
        $bin = New-BinFolder
        $result = Invoke-Rebuild $bin
        $result.ExitCode | Should -Be 0
        $result.Stdout | Should -Be "Wrote $bin\winfiles-rebuild.ps1, for the checkout at $repo"
        $script = Get-Content -Raw "$bin\winfiles-rebuild.ps1"
        $script | Should -BeLike '# Managed by winfiles*'
        $script | Should -BeLike "*`$repo = '$repo'*"
    }

    # Checked by hand when it was written; read-only: `hosts` only lists the configurations
    It 'writes a script that runs commands from any directory' {
        $bin = New-BinFolder
        Invoke-Rebuild $bin | Out-Null
        $result = Invoke-Child $TestDrive @{} {
            pwsh -NoLogo -NoProfile -NonInteractive -File "$bin\winfiles-rebuild.ps1" hosts
        }
        $result.ExitCode | Should -Be 0
        $result.Stdout | Should -Contain 'iris.system'
    }

    It 'replaces a script it wrote before' {
        $bin = New-BinFolder
        New-Item -ItemType Directory $bin | Out-Null
        Set-Content "$bin\winfiles-rebuild.ps1" "# Managed by winfiles (an older version)`n'old'"
        (Invoke-Rebuild $bin).ExitCode | Should -Be 0
        Get-Content -Raw "$bin\winfiles-rebuild.ps1" | Should -BeLike "*`$repo = '$repo'*"
    }

    It "refuses to replace a file it didn't write, and exits 1" {
        $bin = New-BinFolder
        New-Item -ItemType Directory $bin | Out-Null
        Set-Content "$bin\winfiles-rebuild.ps1" "'mine'"
        $result = Invoke-Rebuild $bin
        $result.ExitCode | Should -Be 1
        $result.Stderr |
            Should -Be "$bin\winfiles-rebuild.ps1 exists and winfiles didn't write it. Move it away and rerun."
        Get-Content -Raw "$bin\winfiles-rebuild.ps1" | Should -Be "'mine'$([Environment]::NewLine)"
    }

    # Nothing is lost. It comes from Get-Content returning an empty array, which -notlike filters to nothing
    It 'replaces an empty file' {
        $bin = New-BinFolder
        New-Item -ItemType Directory $bin | Out-Null
        New-Item "$bin\winfiles-rebuild.ps1" | Out-Null
        (Invoke-Rebuild $bin).ExitCode | Should -Be 0
        Get-Content -Raw "$bin\winfiles-rebuild.ps1" | Should -BeLike '# Managed by winfiles*'
    }

    It 'quotes a checkout path with an apostrophe, and the script says when the checkout has moved' {
        $checkout = New-Item -ItemType Directory (Join-Path $TestDrive "it's a checkout\scripts")
        Copy-Item (Join-Path $repo 'scripts\Install-Rebuild.ps1') $checkout
        $bin = New-BinFolder
        $result = Invoke-Child $TestDrive @{} {
            pwsh -NoLogo -NoProfile -NonInteractive -File "$checkout\Install-Rebuild.ps1" $bin
        }
        $result.ExitCode | Should -Be 0
        # No winfiles.ps1 beside the copy, as after the checkout moves
        $run = Invoke-Child $TestDrive @{} {
            pwsh -NoLogo -NoProfile -NonInteractive -File "$bin\winfiles-rebuild.ps1" hosts
        }
        $run.ExitCode | Should -Be 1
        $run.Stderr |
            Should -Be ("No winfiles.ps1 in $(Split-Path $checkout). " +
                "Run './winfiles.ps1 install-rebuild' from the winfiles checkout.")
    }
}
