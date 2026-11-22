# A stand-in for dsc.exe, behind dsc.cmd, for the scripts that run dsc (Invoke-Dsc.ps1 and what calls it).
# It answers `config <operation> ... --file <document>` from the folder named by $env:WINFILES_FAKE_DSC:
#   <document name>.<operation>.json  printed for that operation (test, set), if there is one
#   <document name>.json      printed on stdout, as dsc prints its result
#   <document name>.exitcode  the exit code, 0 without it; <document name>.<operation>.exitcode for one operation
# where the document name is the --file argument's leaf. Every call is appended to calls.jsonl there, with its
# arguments and the DSC_RESOURCE_PATH it got.
$state = $env:WINFILES_FAKE_DSC
if (-not $state) { throw 'Fake dsc run without WINFILES_FAKE_DSC' }

$call = [ordered]@{ args = $args; resourcePath = $env:DSC_RESOURCE_PATH }
Add-Content (Join-Path $state 'calls.jsonl') ($call | ConvertTo-Json -Compress)

$fileIndex = [array]::IndexOf($args, '--file')
if ($fileIndex -lt 0) { exit 0 }
$document = Split-Path -Leaf $args[$fileIndex + 1]
$operation = $args[1]
$json = Join-Path $state "$document.json"
$exitCode = Join-Path $state "$document.exitcode"
if (Test-Path (Join-Path $state "$document.$operation.json")) {
    $json = Join-Path $state "$document.$operation.json"
}
if (Test-Path (Join-Path $state "$document.$operation.exitcode")) {
    $exitCode = Join-Path $state "$document.$operation.exitcode"
}
if (Test-Path $json) { Get-Content -Raw $json }
exit $(if (Test-Path $exitCode) { [int](Get-Content $exitCode) } else { 0 })
