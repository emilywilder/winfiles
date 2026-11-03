# Shared by Set-Winfiles.ps1 and Test-Winfiles.ps1, which dot-source it.
# Runs `dsc config <operation>` on a document and returns its JSON, keeping a copy in ~/.local/state/winfiles/dsc,
# outside the repo because Copy-RepoToTestVm.ps1 replaces the repo. DSC's own messages still go to the console.
# $LASTEXITCODE is left as dsc's. The JSON has each resource's duration, the only record of how long a run took.
function Invoke-DscLogged {
    param([string]$Operation, [string]$File)
    $json = & (Join-Path $PSScriptRoot 'Invoke-Dsc.ps1') config $Operation --output-format json --file $File
    $exitCode = $LASTEXITCODE
    if ($json) {
        $folder = New-Item -ItemType Directory -Force (Join-Path $HOME '.local\state\winfiles\dsc')
        $document = (Split-Path $File -Leaf) -replace '\.dsc\.yaml$'
        $json | Set-Content (Join-Path $folder ('{0:yyyyMMdd-HHmmss}-{1}-{2}.json' -f (Get-Date), $Operation, $document))
    }
    $global:LASTEXITCODE = $exitCode
    $json
}
