# Shared by the tests in this folder, which dot-source it in BeforeAll.
# Resources run the way DSC runs them: a child pwsh started with the command in the resource's manifest. What a
# resource talks to is replaced with fakes made of files (tests/fakes), never with mocks, so nothing here can reach
# the real winget or Scoop.
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$fakes = Join-Path $repo 'tests\fakes'

# Runs one operation of a Winfiles/* resource, with -Instance as JSON on stdin and the working directory DSC uses
# (the manifest's folder). -Environment is set for the child only. Returns the exit code, the state the resource
# printed, the messages it wrote as {"<level>": "<text>"} lines, and all of its stderr.
function Invoke-Resource {
    param(
        [string]$Name,
        [ValidateSet('get', 'test', 'set')]
        [string]$Operation,
        [hashtable]$Instance,
        [hashtable]$Environment = @{}
    )
    $resources = Join-Path $repo 'dsc\resources'
    $command = (Get-Content -Raw (Join-Path $resources "$Name.dsc.resource.json") | ConvertFrom-Json).$Operation
    $stderrFile = New-TemporaryFile
    $saved = @{}
    foreach ($variable in $Environment.Keys) {
        $saved[$variable] = [Environment]::GetEnvironmentVariable($variable)
        [Environment]::SetEnvironmentVariable($variable, $Environment[$variable])
    }
    Push-Location $resources
    try {
        $stdout = @($Instance | ConvertTo-Json -Compress -Depth 5 | & $command.executable @($command.args) 2> $stderrFile)
        $exitCode = $LASTEXITCODE
        $stderr = @(Get-Content $stderrFile)
    } finally {
        Pop-Location
        foreach ($variable in $saved.Keys) { [Environment]::SetEnvironmentVariable($variable, $saved[$variable]) }
        Remove-Item $stderrFile
    }

    $json = $stdout | Where-Object { $_ } | Select-Object -Last 1
    $messages = $stderr | Where-Object { $_ -match '^\{"\w+":' } | ForEach-Object {
        $property = @(($_ | ConvertFrom-Json).PSObject.Properties)[0]
        [pscustomobject]@{ Level = $property.Name; Text = $property.Value }
    }
    [pscustomobject]@{
        ExitCode = $exitCode
        State    = if ($json) { $json | ConvertFrom-Json }
        Messages = @($messages)
        Stderr   = $stderr
    }
}

# Runs a resource's script in this process instead, so Pester mocks reach what it calls. Only for a resource whose
# surroundings can't be replaced with files: registry keys and CIM classes it names itself, or executables it calls
# by name. Write-ResourceMessage writes straight to the console, so tests mock it to check messages.
# Returns the exit code and the state the resource printed.
function Invoke-ResourceScript {
    param(
        [string]$Name,
        [ValidateSet('get', 'test', 'set')]
        [string]$Operation,
        [hashtable]$Instance
    )
    $file = Join-Path $repo "dsc\resources\$Name.ps1"
    $saved = [Environment]::GetEnvironmentVariables()
    try {
        $stdout = @($Instance | ConvertTo-Json -Compress -Depth 5 | & $file $Operation)
        $exitCode = $LASTEXITCODE
    } finally {
        # A resource sets variables for its own process (WSL_UTF8, PATH), which here is the test's
        foreach ($variable in @([Environment]::GetEnvironmentVariables().Keys)) {
            if ($saved.Keys -notcontains $variable) { [Environment]::SetEnvironmentVariable($variable, [NullString]::Value) }
        }
        foreach ($variable in $saved.Keys) { [Environment]::SetEnvironmentVariable($variable, $saved[$variable]) }
    }
    $json = $stdout | Where-Object { $_ } | Select-Object -Last 1
    [pscustomobject]@{
        ExitCode = $exitCode
        State    = if ($json) { $json | ConvertFrom-Json }
    }
}

# A fake winget (tests/fakes/modules/Microsoft.WinGet.Client) with -Installed already installed from the winget
# source, -Failing ids whose install returns -Status, and -Unknown ids whose install throws. -Other ids are installed
# from another source. Pass .Environment to Invoke-Resource, and read what happened with Get-FakeWinGetState.
function New-FakeWinGet {
    param([string[]]$Installed = @(), [string[]]$Other = @(), [string[]]$Failing = @(), [string]$Status = 'InstallError',
        [string[]]$Unknown = @())
    $file = Join-Path $TestDrive "winget-$([guid]::NewGuid()).json"
    $failingStatus = @{}
    foreach ($id in $Failing) { $failingStatus[$id] = $Status }
    [ordered]@{
        installed = @($Installed | ForEach-Object { @{ Id = $_; Source = 'winget' } }) +
            @($Other | ForEach-Object { @{ Id = $_; Source = 'msstore' } })
        failing   = $failingStatus
        unknown   = $Unknown
        installs  = @()
    } | ConvertTo-Json -Depth 4 | Set-Content $file
    [pscustomobject]@{
        Path        = $file
        Environment = @{
            WINFILES_FAKE_WINGET = $file
            PSModulePath         = "$fakes\modules;$env:PSModulePath"
        }
    }
}

function Get-FakeWinGetState($Fake) {
    Get-Content -Raw $Fake.Path | ConvertFrom-Json
}

# Fails unless a child pwsh given $Fake's environment imports the fake Microsoft.WinGet.Client, so a change in how
# pwsh builds PSModulePath can't let a test install real packages
function Assert-FakeWinGetLoads($Fake) {
    $saved = $env:PSModulePath
    $env:PSModulePath = $Fake.Environment.PSModulePath
    try {
        $base = pwsh -NoLogo -NoProfile -NonInteractive -Command '(Import-Module Microsoft.WinGet.Client -PassThru).ModuleBase'
    } finally {
        $env:PSModulePath = $saved
    }
    if ($base -notlike "$fakes\*") { throw "A child pwsh loads Microsoft.WinGet.Client from $base, not the fake" }
}

# A fake Scoop root (tests/fakes/scoop.ps1 in place of Scoop itself) with -Installed apps ('name' or 'bucket/name')
# and -Buckets already there. -Failing apps and -FailingBuckets fail to install, and -NoScoop leaves Scoop out.
# Pass .Environment to Invoke-Resource, and read the calls Scoop got with Get-FakeScoopCalls.
function New-FakeScoop {
    param([string[]]$Installed = @(), [string[]]$Buckets = @(), [string[]]$Failing = @(), [string[]]$FailingBuckets = @(),
        [switch]$NoScoop)
    $root = New-Item -ItemType Directory (Join-Path $TestDrive "scoop-$([guid]::NewGuid())")
    if (-not $NoScoop) {
        $bin = New-Item -ItemType Directory (Join-Path $root 'apps\scoop\current\bin')
        Copy-Item (Join-Path $fakes 'scoop.ps1') $bin
    }
    @{ failing = $Failing; failingBuckets = $FailingBuckets } | ConvertTo-Json | Set-Content (Join-Path $root 'fake-scoop.json')
    foreach ($bucket in $Buckets) { New-Item -ItemType Directory (Join-Path $root "buckets\$bucket") | Out-Null }
    foreach ($app in $Installed) {
        $bucket, $name = if ($app -match '/') { $app -split '/', 2 } else { 'main', $app }
        $current = New-Item -ItemType Directory -Force (Join-Path $root "apps\$name\current")
        @{ bucket = $bucket } | ConvertTo-Json | Set-Content (Join-Path $current 'scoop-install.json')
    }
    [pscustomobject]@{
        Path        = $root.FullName
        Environment = @{ SCOOP = $root.FullName }
    }
}

function Get-FakeScoopCalls($Fake) {
    $calls = Join-Path $Fake.Path 'fake-scoop-calls.txt'
    if (Test-Path $calls) { @(Get-Content $calls) } else { @() }
}
