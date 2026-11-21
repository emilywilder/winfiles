#Requires -Version 7.4

<#
.SYNOPSIS
Installs each of the winget-paths survey's packages one way, and records how each install went.

.DESCRIPTION
winget-paths.Tests.ps1 starts this once per path, directly for the unelevated context or through UAC for the elevated
one, so the same code measures both and the prompt that starts it isn't timed. It expects the survey's packages to be
uninstalled (Clear-WinGetPath.ps1 runs first), installs them in turn, and rewrites -ResultFile after each with every
install's time, exit code, output, the scope it landed in and whether a UAC prompt appeared. Each install times out
after 15 minutes. One line per install goes to run.log (phase winget-paths). Refuses to run outside a Hyper-V guest.

.EXAMPLE
mise exec -- pwsh -NoProfile -File ./surveys/winget-paths/Install-WinGetPathCase.ps1 -Path cli -ResultFile ./cli.json
#>
param(
    # How to drive winget: the install command, the same with --scope user, Microsoft.WinGet/Package through DSC, or
    # Install-WinGetPackage
    [Parameter(Mandatory)]
    [ValidateSet('cli', 'cli-user', 'dsc', 'com')]
    [string]$Path,

    # JSON file for the results
    [Parameter(Mandatory)]
    [string]$ResultFile,

    # Put first on PATH, for dsc: an elevated process started through UAC gets the account's PATH, not mise's
    [string]$DscDirectory
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'WinGetPaths.ps1')
. (Join-Path $PSScriptRoot '..\..\scripts\winlog.ps1')
Assert-TestVm

if ($DscDirectory) { $env:PATH = "$DscDirectory;$env:PATH" }
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$context = if (Test-Elevated) { 'elevated' } else { 'unelevated' }
$timeout = [timespan]::FromMinutes(15)
$sourceArgs = '--accept-source-agreements', '--disable-interactivity'
$work = New-Item -ItemType Directory (Join-Path ([IO.Path]::GetTempPath()) "winget-paths-$([guid]::NewGuid())")

# The com path needs the module. A fresh VM doesn't have it until the system configuration runs, so save it here
$modules = Join-Path $HOME '.cache\winfiles\winget-paths\modules'
if ($Path -eq 'com' -and -not (Get-Module -ListAvailable Microsoft.WinGet.Client) -and
    -not (Test-Path (Join-Path $modules 'Microsoft.WinGet.Client'))) {
    New-Item -ItemType Directory -Force $modules | Out-Null
    Save-PSResource -Name Microsoft.WinGet.Client -Path $modules -Repository PSGallery -TrustRepository -Quiet
}

# Runs an executable with a timeout, watching for consent.exe. Returns its time, exit code and output
function Invoke-Watched([string]$FilePath, [string[]]$ArgumentList) {
    $out = Join-Path $work "out-$([guid]::NewGuid()).txt"
    $err = "$out.err"
    $consentBefore = @(Get-Process consent -ErrorAction Ignore).Id
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $process = Start-Process $FilePath $ArgumentList -NoNewWindow -PassThru `
        -RedirectStandardOutput $out -RedirectStandardError $err
    $uac = $false
    $timedOut = $false
    while (-not $process.WaitForExit(1000)) {
        if (Get-Process consent -ErrorAction Ignore | Where-Object Id -notin $consentBefore) { $uac = $true }
        if ($clock.Elapsed -gt $timeout) {
            $timedOut = $true
            & taskkill /PID $process.Id /T /F | Out-Null
            break
        }
    }
    $clock.Stop()
    [pscustomobject]@{
        Seconds  = [math]::Round($clock.Elapsed.TotalSeconds, 1)
        ExitCode = if ($timedOut) { $null } else { $process.ExitCode }
        TimedOut = $timedOut
        Uac      = $uac
        Output   = @(Get-Content $out, $err -ErrorAction Ignore | Where-Object { $_.Trim() })
    }
}

# A script file for the child, so arguments don't go through Start-Process's quoting
function New-ChildScript([string]$Text) {
    $file = Join-Path $work "child-$([guid]::NewGuid()).ps1"
    Set-Content $file $Text
    "`"$file`""
}

function Install-ByPath([string]$Id) {
    $pwsh = (Get-Process -Id $PID).Path
    $install = '--id', $Id, '--exact', '--source', 'winget', '--silent', '--accept-package-agreements'
    switch ($Path) {
        'cli' { Invoke-Watched winget (@('install') + $install + $sourceArgs) }
        'cli-user' { Invoke-Watched winget (@('install') + $install + @('--scope', 'user') + $sourceArgs) }
        'dsc' {
            $instance = @{ id = $Id; source = 'winget'; acceptAgreements = $true } | ConvertTo-Json -Compress
            $child = New-ChildScript @"
& '$repo\scripts\Invoke-Dsc.ps1' resource set --resource Microsoft.WinGet/Package --input '$instance'
exit `$LASTEXITCODE
"@
            Invoke-Watched $pwsh '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $child
        }
        'com' {
            $child = New-ChildScript @"
`$env:PSModulePath = '$modules;' + `$env:PSModulePath
Import-Module Microsoft.WinGet.Client
`$version = (Get-Module Microsoft.WinGet.Client).Version
try {
    `$result = Install-WinGetPackage -Id '$Id' -Source winget -MatchOption Equals -Mode Silent
    "status: `$(`$result.Status) `$(`$result.ExtendedErrorCode)"
    `$code = if (`$result.Status -eq 'Ok') { 0 } else { 1 }
} catch {
    "threw: `$(`$_.Exception.Message)"
    `$code = 2
}
`$inProc = [bool]((Get-Process -Id `$PID).Modules | Where-Object ModuleName -eq WindowsPackageManager.dll)
"module: `$version, com: `$(if (`$inProc) { 'in-process' } else { 'out-of-process' })"
exit `$code
"@
            Invoke-Watched $pwsh '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $child
        }
    }
}

$results = [Collections.Generic.List[object]]::new()
try {
    foreach ($package in Get-WinGetPathPackage) {
        if ($Path -eq 'cli-user' -and -not $package.HasUser) { continue }
        $id = $package.Id
        Write-Host "$context $Path ${id}..."
        $run = Install-ByPath $id
        if ($package.Stop) { Get-Process $package.Stop -ErrorAction Ignore | Stop-Process -Force }
        # Squirrel installers (Element) register after they return: elevated, winget listed it in neither scope at once
        $scope = $null
        if (-not $package.Bogus -and $run.ExitCode -eq 0) {
            $clock = [Diagnostics.Stopwatch]::StartNew()
            while (-not ($scope = Get-InstalledScope $id) -and $clock.Elapsed.TotalSeconds -lt 30) { Start-Sleep 3 }
        }
        $alsoScope = if ($package.Also) { Get-InstalledScope $package.Also }

        $results.Add([pscustomobject][ordered]@{
            path      = $Path
            case      = $package.Case
            id        = $id
            context   = $context
            seconds   = $run.Seconds
            exitCode  = $run.ExitCode
            timedOut  = $run.TimedOut
            uac       = $run.Uac
            scope     = $scope
            alsoScope = $alsoScope
            output    = @($run.Output | Select-Object -Last 40)
        })
        # Rewritten after each install, so an interrupted run keeps what it measured
        ConvertTo-Json -InputObject $results.ToArray() -Depth 4 | Set-Content $ResultFile
        Write-WinfilesLog winget-paths ('{0} {1} {2}: {3}s, exit {4}, scope {5}{6}{7}' -f
            $context, $Path, $id, $run.Seconds,
            $run.ExitCode, ($scope ?? 'none'), ($run.Uac ? ', UAC prompt' : ''), ($run.TimedOut ? ', timed out' : ''))
    }
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction Ignore
}
