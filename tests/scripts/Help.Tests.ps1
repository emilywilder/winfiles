# Get-Help only reads a script's comment-based help when a blank line separates it from the #Requires lines above.
# Without one it silently falls back to the syntax, so this checks every script that has help, new ones included.
BeforeDiscovery {
    $repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $scripts = Get-ChildItem (Join-Path $repo 'scripts') -Filter *.ps1 |
        Where-Object { Select-String -Path $_ -Pattern '^\.SYNOPSIS$' -Quiet } |
        ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }
}

Describe 'Comment-based help in scripts/' {
    It "Get-Help reads <Name>'s synopsis" -ForEach $scripts {
        $lines = Get-Content $Path
        $synopsis = $lines[[array]::IndexOf($lines, '.SYNOPSIS') + 1].Trim()
        # Without the help, Synopsis is the script's name or syntax
        @((Get-Help $Path).Synopsis -split '\r?\n')[0].Trim() | Should -Be $synopsis
    }
}
