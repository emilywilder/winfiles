#Requires -Version 7.4
<#
.SYNOPSIS
Writes winfiles-rebuild, a script that runs this checkout's just recipes from any directory.

.DESCRIPTION
Like nixos-rebuild with a flake directory: the checkout's path is written into the script, so `winfiles-rebuild check`
is `just check` in the checkout. Rerun from another checkout to point it there. This never changes PATH: the folder has
to be on it already for the bare name to work. A file there that winfiles didn't write is left alone, and this fails.

.EXAMPLE
./scripts/Install-Rebuild.ps1 ~/bin
#>
$ErrorActionPreference = 'Stop'

$marker = '# Managed by winfiles'
$repo = Split-Path $PSScriptRoot
$directory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($args[0])
$path = Join-Path $directory 'winfiles-rebuild.ps1'

if ((Test-Path -LiteralPath $path) -and (Get-Content -LiteralPath $path -TotalCount 1) -notlike "$marker*") {
    [Console]::Error.WriteLine("$path exists and winfiles didn't write it. Move it away and rerun.")
    exit 1
}

$content = @"
$marker (just install-rebuild in the checkout below). Edits are lost when it's rerun.
`$repo = '$($repo -replace "'", "''")'
if (-not (Test-Path -LiteralPath "`$repo\justfile")) {
    [Console]::Error.WriteLine("No justfile in `$repo. Run 'just install-rebuild' from the winfiles checkout.")
    exit 1
}
& mise -C `$repo exec -- just --justfile "`$repo\justfile" @args
exit `$LASTEXITCODE

"@
New-Item -ItemType Directory -Force -Path $directory | Out-Null
Set-Content -LiteralPath $path -Value $content -NoNewline
Write-Host "Wrote $path, for the checkout at $repo"
