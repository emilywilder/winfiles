# A stand-in for winget.exe, behind winget.cmd, for Get-ManualInstaller.ps1 and Winfiles.WinGet/Package. It answers from
# the folder named by $env:WINFILES_FAKE_WINGET_CLI, and downloads and installs nothing:
#   calls.txt      every call's arguments, one line each
#   exitcode.txt   what download, install and `dscv3 package --set` exit with, 0 without it
#   installed.txt  the ids installed, one per line. install adds its --id when it exits 0, and `dscv3 package` reads it,
#                  and its --set adds or removes the instance's id
#   dscv3.jsonl    the JSON each `dscv3 package` call got on stdin
# `dscv3 package` prints what winget 1.29.380's did (checked 2026-11-17): the state, then for --test and --set the
# differing properties
$state = $env:WINFILES_FAKE_WINGET_CLI
if (-not $state) { throw 'Fake winget run without WINFILES_FAKE_WINGET_CLI' }
Add-Content (Join-Path $state 'calls.txt') ($args -join ' ')
$exitCodeFile = Join-Path $state 'exitcode.txt'
$exitCode = if (Test-Path $exitCodeFile) { [int](Get-Content $exitCodeFile) } else { 0 }
$installedFile = Join-Path $state 'installed.txt'
$installed = [Collections.Generic.List[string]]@(if (Test-Path $installedFile) { Get-Content $installedFile })

switch ($args[0]) {
    'install' {
        if ($exitCode -eq 0) { Add-Content $installedFile $args[[array]::IndexOf($args, '--id') + 1] }
        exit $exitCode
    }
    'dscv3' {
        $json = [Console]::In.ReadToEnd().Trim()
        Add-Content (Join-Path $state 'dscv3.jsonl') $json
        $desired = $json | ConvertFrom-Json
        $wantExist = $desired._exist -ne $false
        $operation = $args[2]
        if ($operation -eq '--set' -and $exitCode -ne 0) { exit $exitCode }
        if ($operation -eq '--set' -and $wantExist -ne $installed.Contains($desired.id)) {
            if ($wantExist) { $installed.Add($desired.id) } else { $installed.Remove($desired.id) | Out-Null }
            Set-Content $installedFile $installed
            $changed = $true
        }
        $exist = $installed.Contains($desired.id)
        $result = [ordered]@{ _exist = $exist }
        if ($operation -eq '--test') { $result._inDesiredState = $exist -eq $wantExist }
        $result.id = $desired.id
        if ($desired.source) { $result.source = $desired.source }
        $result | ConvertTo-Json -Compress
        switch ($operation) {
            '--test' { if ($exist -eq $wantExist) { '[]' } else { '["_exist"]' } }
            '--set' { if ($changed) { '["_exist"]' } else { '[]' } }
        }
        exit 0
    }
    default { exit $exitCode }
}
