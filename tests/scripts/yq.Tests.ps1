# Invoke-Yq (scripts/yq.ps1) with the real yq (from mise.toml) on small documents: its output as one string, its
# stdin form, its failure, and the console's output encoding, which it sets for the call and puts back after. The
# UTF-8 reading itself is checked end to end in Get-ManualInstaller.Tests.ps1, which fails under `chcp 437` without
# it.
BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\scripts\yq.ps1')
}

Describe 'Invoke-Yq' {
    It 'returns several lines of output as one string joined with newlines' {
        $result = Invoke-Yq -Arguments '-o', 'json', '-I=0', '.[]' -InputText "- a`n- b"
        $result | Should -BeOfType [string]
        $result | Should -Be "`"a`"`n`"b`""
    }

    It 'reads a file named in its arguments' {
        $file = Join-Path $TestDrive 'doc.yaml'
        Set-Content -Path $file -Value "name: winfiles`ncount: 2"
        (Invoke-Yq -Arguments '-o', 'json', '.', $file | ConvertFrom-Json).count | Should -Be 2
    }

    It 'gives -InputText to yq as stdin, even when it is empty' {
        Invoke-Yq -Arguments '.a', '-' -InputText 'a: 1' | Should -Be '1'
        { Invoke-Yq -Arguments '.' -InputText '' } | Should -Not -Throw
    }

    It 'throws, naming the exit code, when yq fails' {
        { Invoke-Yq -Arguments '.' -InputText 'a: [unclosed' 2>$null } |
            Should -Throw -ExpectedMessage '*failed with exit code*'
    }

    It 'puts the console''s output encoding back after a success and after a failure' {
        $before = [Console]::OutputEncoding
        try {
            [Console]::OutputEncoding = [Text.Encoding]::GetEncoding(437)
            $set = [Console]::OutputEncoding
            Invoke-Yq -Arguments '.' -InputText 'a: 1' | Out-Null
            [Console]::OutputEncoding.CodePage | Should -Be $set.CodePage
            { Invoke-Yq -Arguments '.' -InputText 'a: [unclosed' 2>$null } | Should -Throw
            [Console]::OutputEncoding.CodePage | Should -Be $set.CodePage
        } catch [System.IO.IOException] {
            Set-ItResult -Skipped -Because 'there is no console whose encoding can be set'
        } finally {
            try { [Console]::OutputEncoding = $before } catch { Write-Verbose -Message 'No console to restore' }
        }
    }

    It 'reads non-ASCII text as written, whatever the console''s code page' {
        $before = [Console]::OutputEncoding
        try {
            [Console]::OutputEncoding = [Text.Encoding]::GetEncoding(437)
        } catch {
            Set-ItResult -Skipped -Because 'there is no console whose encoding can be set'
            return
        }
        try {
            $text = "caf$([char]0xE9) $([char]0x2014) done"
            Invoke-Yq -Arguments '.a', '-' -InputText "a: $text" | Should -Be $text
        } finally {
            [Console]::OutputEncoding = $before
        }
    }
}
