# Winfiles/FileContentList only reads and writes files, so it runs as DSC runs it, against real files in TestDrive:.
BeforeAll {
    . (Join-Path $PSScriptRoot 'Resource.ps1')

    function Invoke-List($Operation, [object[]]$Files, [hashtable]$Environment = @{}) {
        Invoke-Resource filecontentlist $Operation @{ files = $Files } $Environment
    }

    # A path in TestDrive: no other test uses
    function New-TestPath([string]$Leaf = 'file.txt') {
        Join-Path $TestDrive "$([guid]::NewGuid())\$Leaf"
    }

    function Get-Backup([string]$Path) {
        @(Get-ChildItem (Split-Path $Path) -Filter "$(Split-Path -Leaf $Path).*.bak")
    }
}

Describe 'Winfiles/FileContentList' {
    Context 'test' {
        It 'lists a missing file' {
            $path = New-TestPath
            $result = Invoke-List test @(@{ path = $path; content = 'hello' })
            $result.ExitCode | Should -Be 0
            $result.State._inDesiredState | Should -BeFalse
            $result.State.outOfDate | Should -Be @($path)
            Test-Path $path | Should -BeFalse
        }

        It 'lists a file with different content' {
            $path = New-TestPath
            New-Item -Force $path -Value 'goodbye' | Out-Null
            $result = Invoke-List test @(@{ path = $path; content = 'hello' })
            $result.State.outOfDate | Should -Be @($path)
            Get-Content -Raw $path | Should -Be 'goodbye'
        }

        # A YAML block can't preserve either
        It 'ignores line endings and trailing whitespace' {
            $path = New-TestPath
            New-Item -Force $path -Value "# Managed by winfiles  `r`nline two`t`r`n`r`n" | Out-Null
            $result = Invoke-List test @(@{ path = $path; content = "# Managed by winfiles`nline two`n" })
            $result.State._inDesiredState | Should -BeTrue
        }

        It "doesn't ignore leading whitespace" {
            $path = New-TestPath
            New-Item -Force $path -Value '  indented' | Out-Null
            (Invoke-List test @(@{ path = $path; content = 'indented' })).State._inDesiredState | Should -BeFalse
        }

        It 'lists a folder where the file should be' {
            $path = New-TestPath
            New-Item -ItemType Directory $path | Out-Null
            (Invoke-List test @(@{ path = $path; content = 'hello' })).State.outOfDate | Should -Be @($path)
        }

        It 'lists only the files that differ' {
            $same, $missing = (New-TestPath same.txt), (New-TestPath missing.txt)
            New-Item -Force $same -Value 'same' | Out-Null
            $result = Invoke-List test @(@{ path = $same; content = 'same' }, @{ path = $missing; content = 'new' })
            $result.State.outOfDate | Should -Be @($missing)
        }

        It 'expands variables in the path' {
            $folder = Split-Path (New-TestPath)
            New-Item -ItemType Directory $folder | Out-Null
            New-Item "$folder\file.txt" -Value 'hello' | Out-Null
            $files = @(@{ path = '%WINFILES_TEST_DIR%\file.txt'; content = 'hello' })
            $result = Invoke-List test $files @{ WINFILES_TEST_DIR = $folder }
            $result.State._inDesiredState | Should -BeTrue
            $result.State.files[0].path | Should -Be '%WINFILES_TEST_DIR%\file.txt'
        }

        # Only test: set would write into the real folder
        It 'puts a path with specialFolder under that folder' {
            $leaf = "winfiles-test-$([guid]::NewGuid()).txt"
            $result = Invoke-List test @(@{ path = $leaf; specialFolder = 'MyDocuments'; content = 'hello' })
            $result.State.outOfDate | Should -Be @(Join-Path ([Environment]::GetFolderPath('MyDocuments')) $leaf)
        }
    }

    Context 'set' {
        It 'writes a missing file and its folders, exactly as given' {
            $path = New-TestPath 'a\b\file.txt'
            $result = Invoke-List set @(@{ path = $path; content = "line one`nline two" })
            $result.ExitCode | Should -Be 0
            $result.State.outOfDate | Should -BeNullOrEmpty
            Get-Content -Raw $path | Should -Be "line one`nline two"
            Get-Backup $path | Should -BeNullOrEmpty
        }

        It 'replaces a file with different content, keeping a .bak of it' {
            $path = New-TestPath
            New-Item -Force $path -Value 'old content' | Out-Null
            $result = Invoke-List set @(@{ path = $path; content = 'new content' })
            $result.ExitCode | Should -Be 0
            Get-Content -Raw $path | Should -Be 'new content'
            $backup = Get-Backup $path
            $backup.Count | Should -Be 1
            $backup[0].Name | Should -Match '^file\.txt\.\d{14}\.bak$'
            Get-Content -Raw $backup[0].FullName | Should -Be 'old content'
        }

        It "leaves a file that's up to date alone, line endings included" {
            $path = New-TestPath
            New-Item -Force $path -Value "hello`r`n" | Out-Null
            $before = (Get-Item $path).LastWriteTimeUtc
            $result = Invoke-List set @(@{ path = $path; content = 'hello' })
            $result.ExitCode | Should -Be 0
            Get-Content -Raw $path | Should -Be "hello`r`n"
            (Get-Item $path).LastWriteTimeUtc | Should -Be $before
            Get-Backup $path | Should -BeNullOrEmpty
        }

        It 'writes only the files that differ' {
            $same, $changed = (New-TestPath same.txt), (New-TestPath changed.txt)
            New-Item -Force $same -Value "same`r`n" | Out-Null
            New-Item -Force $changed -Value 'old' | Out-Null
            $result = Invoke-List set @(@{ path = $same; content = 'same' }, @{ path = $changed; content = 'new' })
            $result.State.outOfDate | Should -BeNullOrEmpty
            Get-Content -Raw $same | Should -Be "same`r`n"
            Get-Content -Raw $changed | Should -Be 'new'
        }

        It 'reports a file it cannot write, and exits 1' {
            $path = New-TestPath
            $file = New-Item -Force $path -Value 'old'
            $file.Attributes = 'ReadOnly'
            try {
                $result = Invoke-List set @(@{ path = $path; content = 'new' })
            } finally {
                $file.Attributes = 'Normal'
            }
            $result.ExitCode | Should -Be 1
            $result.Messages.Level | Should -Be @('error')
            $result.Messages[0].Text | Should -BeLike "*$(Split-Path -Leaf $path)*"
            Get-Content -Raw $path | Should -Be 'old'
        }
    }
}
