# Implements Winfiles/FileContentList (see filecontentlist.dsc.resource.json).
# DSC pipes the instance as JSON on stdin; the operation is the first argument. Only JSON goes to stdout.
# Microsoft.WinGet/UserSettingsFile was ruled out: it only manages winget's settings.json, and DSC 3.3.0 has
# no general file resource. Comparing ignores line endings and trailing whitespace, which a YAML block can't
# preserve. set keeps a .bak copy of a file it replaces.
param(
    [ValidateSet('get', 'test', 'set')]
    [string]$Operation
)

. (Join-Path $PSScriptRoot 'common.ps1')
# A trap only covers the scope that declares it, so common.ps1 can't hold this one
trap { Write-ResourceMessage error "$_"; exit 1 }
$desired = $input | Read-ResourceInput
$files = @($desired.files)

function Resolve-FilePath($File) {
    $path = [Environment]::ExpandEnvironmentVariables($File.path)
    if ($File.specialFolder) { Join-Path ([Environment]::GetFolderPath($File.specialFolder)) $path } else { $path }
}

function Format-Text($Text) {
    (("$Text" -split '\r?\n' | ForEach-Object TrimEnd) -join "`n").TrimEnd()
}

function Get-OutOfDateFiles {
    foreach ($file in $files) {
        $path = Resolve-FilePath $file
        $upToDate = (Test-Path -LiteralPath $path -PathType Leaf) -and
            ((Format-Text (Get-Content -LiteralPath $path -Raw)) -eq (Format-Text $file.content))
        if (-not $upToDate) { $path }
    }
}

# @() at each call: PowerShell unrolls function output, so 0 or 1 results wouldn't stay arrays
$outOfDate = @(Get-OutOfDateFiles)

if ($Operation -eq 'set' -and $outOfDate) {
    foreach ($file in $files) {
        $path = Resolve-FilePath $file
        if ($path -notin $outOfDate) { continue }
        if (Test-Path -LiteralPath $path) {
            Copy-Item -LiteralPath $path "$path.$(Get-Date -Format yyyyMMddHHmmss).bak"
        }
        New-Item -ItemType Directory -Force -Path (Split-Path $path) | Out-Null
        Set-Content -LiteralPath $path -Value $file.content -NoNewline
    }
    $outOfDate = @(Get-OutOfDateFiles)
    foreach ($path in $outOfDate) { Write-ResourceMessage error "$path still differs after writing it" }
}

$state = [ordered]@{
    files     = $files
    outOfDate = $outOfDate
}
if ($Operation -eq 'test') { $state['_inDesiredState'] = $outOfDate.Count -eq 0 }
$state | ConvertTo-Json -Compress -Depth 3

# The manifest ends its command with `exit $LASTEXITCODE`, so always exit explicitly
if ($outOfDate -and $Operation -eq 'set') { exit 2 }
exit 0
