# bootstrap.cmd from a copy of the repo in TestDrive with no mise.toml or mise.lock, so Initialize-Winfiles.ps1's
# checks always fail and nothing past them (App Installer, mise, the tools) can run. What the checks find is
# covered by Initialize-Winfiles.Tests.ps1; this only covers the way in.
BeforeAll {
    . (Join-Path $PSScriptRoot '..\resources\Resource.ps1')
}

Describe 'bootstrap.cmd' {
    It 'starts the Initialize-Winfiles.ps1 beside it from any folder, and passes its exit code back' {
        $copy = New-Item -ItemType Directory (Join-Path $TestDrive 'repo\scripts')
        Copy-Item (Join-Path $repo 'scripts\Initialize-Winfiles.ps1') $copy
        Copy-Item (Join-Path $repo 'bootstrap.cmd') $copy.Parent.FullName
        $bootstrapCmd = Join-Path $copy.Parent.FullName 'bootstrap.cmd'
        $result = Invoke-Child $TestDrive @{} { & $bootstrapCmd }
        $result.ExitCode | Should -Be 1
        $result.Stdout | Should -Contain ("  - mise.toml is missing from $($copy.Parent.FullName). " +
            'Run this from a complete copy of the repo.')
    }
}

# cmd.exe misreads a batch file with LF line endings, so each one in the repo root needs a .gitattributes entry
Describe 'Batch files in the repo root' {
    BeforeDiscovery {
        $root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $batchFiles = Get-ChildItem $root -Filter *.cmd |
            ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }
    }

    It '<Name> is checked out with CRLF line endings' -ForEach $batchFiles {
        git -C $repo check-attr eol -- $Name | Should -Be "${Name}: eol: crlf"
        $text = [IO.File]::ReadAllText($Path)
        $text -replace "`r`n" | Should -Not -Match "`n"
    }
}
