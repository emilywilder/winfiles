#Requires -Version 7.4

<#
.SYNOPSIS
Installs each of the winget-paths survey's packages one way, and records how each install went.

.DESCRIPTION
winget-paths.Tests.ps1 starts this once per path, directly for the unelevated context or through UAC for the
elevated one, so the same code measures both and the prompt that starts it isn't timed. It expects the survey's
packages to be uninstalled (Clear-WinGetPath.ps1 runs first), installs them in turn, and rewrites -ResultFile after
each with every install's time, exit code, output, the scope it landed in and whether a UAC prompt appeared. Each
install times out after 15 minutes. One line per install goes to run.log (phase winget-paths). Refuses to run
outside a Hyper-V guest.

.EXAMPLE
mise exec -- pwsh -NoProfile -File ./surveys/winget-paths/Install-WinGetPathCase.ps1 -Path cli
-ResultFile ./cli.json

Installs the survey's packages with `winget install`, and writes the results to cli.json.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    # How to drive winget: the install command, the same with --scope user, Microsoft.WinGet/Package through DSC,
    # or Install-WinGetPackage.
    [Parameter(Mandatory)]
    [ValidateSet('cli', 'cli-user', 'dsc', 'com')]
    [string]$Path,

    # JSON file for the results.
    [Parameter(Mandatory)]
    [string]$ResultFile,

    # Put first on PATH, for dsc: an elevated process started through UAC gets the account's PATH, not mise's.
    [string]$DscDirectory
)

$ErrorActionPreference = 'Stop'
try {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'WinGetPaths.ps1')
    . (Join-Path -Path $PSScriptRoot -ChildPath '..\..\scripts\winlog.ps1')
    Assert-TestVm

    if ($DscDirectory) {
        $env:PATH = "$DscDirectory;$env:PATH"
    }
    $repo = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..')).Path
    $context = if (Test-Elevated) { 'elevated' } else { 'unelevated' }
    $timeout = [timespan]::FromMinutes(15)
    $sourceArgs = '--accept-source-agreements', '--disable-interactivity'
    $workPath = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath "winget-paths-$([guid]::NewGuid())"
    $work = New-Item -ItemType Directory -Path $workPath

    # The com path needs the module. A fresh VM doesn't have it until the system configuration runs, so save it
    # here
    $modules = Join-Path -Path $HOME -ChildPath '.cache\winfiles\winget-paths\modules'
    $needsModule = ($Path -eq 'com' -and -not (Get-Module -ListAvailable -Name Microsoft.WinGet.Client) -and
        -not (Test-Path -Path (Join-Path -Path $modules -ChildPath 'Microsoft.WinGet.Client')))
    if ($needsModule) {
        New-Item -ItemType Directory -Force -Path $modules | Out-Null
        Save-PSResource -Name Microsoft.WinGet.Client -Path $modules -Repository PSGallery -TrustRepository -Quiet
    }


    function Invoke-Watched {
        <#
        .SYNOPSIS
        Runs an executable with a timeout, watching for consent.exe, and returns its time, exit code and output.
        #>
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param(
            # The executable.
            [Parameter(Mandatory)]
            [string]$FilePath,

            # Its arguments.
            [Parameter(Mandatory)]
            [string[]]$ArgumentList
        )

        $out = Join-Path -Path $work -ChildPath "out-$([guid]::NewGuid()).txt"
        $err = "$out.err"
        $consentBefore = @(Get-Process -Name consent -ErrorAction Ignore).Id
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $start = @{
            FilePath               = $FilePath
            ArgumentList           = $ArgumentList
            NoNewWindow            = $true
            PassThru               = $true
            RedirectStandardOutput = $out
            RedirectStandardError  = $err
        }
        $process = Start-Process @start
        $uac = $false
        $timedOut = $false
        while (-not $timedOut -and -not $process.WaitForExit(1000)) {
            $newConsent = Get-Process -Name consent -ErrorAction Ignore |
                Where-Object -FilterScript { $_.Id -notin $consentBefore }
            if ($newConsent) {
                $uac = $true
            }
            if ($clock.Elapsed -gt $timeout) {
                $timedOut = $true
                & taskkill /PID $process.Id /T /F | Out-Null
            }
        }
        $clock.Stop()
        [pscustomobject]@{
            Seconds  = [math]::Round($clock.Elapsed.TotalSeconds, 1)
            ExitCode = if ($timedOut) { $null } else { $process.ExitCode }
            TimedOut = $timedOut
            Uac      = $uac
            Output   = @(Get-Content -Path $out, $err -ErrorAction Ignore |
                    Where-Object -FilterScript { $_.Trim() })
        }
    }


    function New-ChildScript {
        <#
        .SYNOPSIS
        Writes a script file for the child, so arguments don't go through Start-Process's quoting, and returns its
        quoted path.
        #>
        [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
        [OutputType([string])]
        param(
            # The script.
            [Parameter(Mandatory)]
            [string]$Text
        )

        $file = Join-Path -Path $work -ChildPath "child-$([guid]::NewGuid()).ps1"
        if ($PSCmdlet.ShouldProcess($file, 'Write the child script')) {
            Set-Content -Path $file -Value $Text
        }
        "`"$file`""
    }


    function Install-ByPath {
        <#
        .SYNOPSIS
        Installs a package the way -Path says, and returns how it went.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'The script asks ShouldProcess before each call')]
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param(
            # The package's id.
            [Parameter(Mandatory)]
            [string]$Id
        )

        $pwsh = (Get-Process -Id $PID).Path
        $install = '--id', $Id, '--exact', '--source', 'winget', '--silent', '--accept-package-agreements'
        $childArgs = '-NoLogo', '-NoProfile', '-NonInteractive', '-File'
        switch ($Path) {
            'cli' {
                Invoke-Watched -FilePath winget -ArgumentList (@('install') + $install + $sourceArgs)
            }
            'cli-user' {
                $userInstall = @('install') + $install + @('--scope', 'user') + $sourceArgs
                Invoke-Watched -FilePath winget -ArgumentList $userInstall
            }
            'dsc' {
                $settings = @{ id = $Id; source = 'winget'; acceptAgreements = $true }
                $instance = ConvertTo-Json -InputObject $settings -Compress
                $child = New-ChildScript -Text @"
& '$repo\scripts\Invoke-Dsc.ps1' resource set --resource Microsoft.WinGet/Package --input '$instance'
exit `$LASTEXITCODE
"@
                Invoke-Watched -FilePath $pwsh -ArgumentList ($childArgs + $child)
            }
            'com' {
                $child = New-ChildScript -Text @"
`$env:PSModulePath = '$modules;' + `$env:PSModulePath
Import-Module -Name Microsoft.WinGet.Client
`$version = (Get-Module -Name Microsoft.WinGet.Client).Version
try {
    `$result = Install-WinGetPackage -Id '$Id' -Source winget -MatchOption Equals -Mode Silent
    "status: `$(`$result.Status) `$(`$result.ExtendedErrorCode)"
    `$code = if (`$result.Status -eq 'Ok') { 0 } else { 1 }
} catch {
    "threw: `$(`$_.Exception.Message)"
    `$code = 2
}
`$modules = (Get-Process -Id `$PID).Modules
`$inProc = [bool](`$modules | Where-Object -Property ModuleName -EQ -Value WindowsPackageManager.dll)
"module: `$version, com: `$(if (`$inProc) { 'in-process' } else { 'out-of-process' })"
exit `$code
"@
                Invoke-Watched -FilePath $pwsh -ArgumentList ($childArgs + $child)
            }
        }
    }


    $results = [Collections.Generic.List[object]]::new()
    try {
        foreach ($package in Get-WinGetPathPackage) {
            $id = $package.Id
            $skipped = $Path -eq 'cli-user' -and -not $package.HasUser
            if ($skipped -or -not $PSCmdlet.ShouldProcess($id, "Install through $Path")) {
                continue
            }
            Write-Host -Object "$context $Path ${id}..."
            $run = Install-ByPath -Id $id
            if ($package.Stop) {
                Get-Process -Name $package.Stop -ErrorAction Ignore | Stop-Process -Force
            }
            # Squirrel installers (Element) register after they return: elevated, winget listed it in neither scope
            # at once
            $scope = $null
            if (-not $package.Bogus -and $run.ExitCode -eq 0) {
                $clock = [Diagnostics.Stopwatch]::StartNew()
                $scope = Get-InstalledScope -Id $id
                while (-not $scope -and $clock.Elapsed.TotalSeconds -lt 30) {
                    Start-Sleep -Seconds 3
                    $scope = Get-InstalledScope -Id $id
                }
            }
            $alsoScope = if ($package.Also) { Get-InstalledScope -Id $package.Also }

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
            ConvertTo-Json -InputObject $results.ToArray() -Depth 4 | Set-Content -Path $ResultFile
            $notes = '{0}{1}' -f ($run.Uac ? ', UAC prompt' : ''), ($run.TimedOut ? ', timed out' : '')
            Write-WinfilesLog -Phase winget-paths -Message ('{0} {1} {2}: {3}s, exit {4}, scope {5}{6}' -f
                $context, $Path, $id, $run.Seconds, $run.ExitCode, ($scope ?? 'none'), $notes)
        }
    } finally {
        Remove-Item -Path $work -Recurse -Force -ErrorAction Ignore
    }
} catch {
    # Rethrown, so an error that only ends a statement still ends the script, with exit code 1
    $failure = $_
    throw $failure
} finally {
    $ErrorActionPreference = 'Continue'
}
