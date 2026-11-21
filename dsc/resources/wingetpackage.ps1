# Implements Winfiles.WinGet/Package (see wingetpackage.dsc.resource.json): Microsoft.WinGet/Package plus a stop-gap
# _scope, until App Installer's resource has the canonical one PowerShell/DSC#828 proposes (docs/config/winget.md).
# DSC pipes the instance as JSON on stdin; the operation is the first argument. Only JSON goes to stdout.
# Everything but _scope goes to `winget dscv3 package`, as App Installer's manifest calls it, and its output comes back
# with _scope added, so winget decides the state, and get and test ignore the scope a package is installed in. Only set
# uses _scope: `winget dscv3` takes no scope, so a package that isn't installed is first installed with
# `winget install --scope`, and `winget dscv3 package --set` then finds it there.
param(
    [ValidateSet('get', 'test', 'set')]
    [string]$Operation
)

. (Join-Path $PSScriptRoot 'common.ps1')
# For the run log (`just test-vm-log`): DSC prints a resource's messages to the console only, so a failure that isn't also
# written here is missing from the log of the run it stopped (found 2026-11-19 in a test VM run)
. (Join-Path $PSScriptRoot '..\..\scripts\winlog.ps1')
# A trap only covers the scope that declares it, so common.ps1 can't hold this one
trap { Write-ResourceMessage error "$_"; Write-WinfilesLog winget "$_"; exit 1 }
$desired = $input | Read-ResourceInput
$scope = $desired._scope
$desired.PSObject.Properties.Remove('_scope')
$upstream = $desired | ConvertTo-Json -Compress

# Runs `winget dscv3 package --<operation>` with the instance without _scope. Its stdout is the state, then for test
# and set the differing properties; its stderr goes straight to DSC's
# An error DSC shows, and the run log keeps. winget's own reason is on its stderr, which goes to DSC's, and in winget's log
function Write-Failure([string]$Text) {
    Write-ResourceMessage error $Text
    Write-WinfilesLog winget $Text
}

function Invoke-WinGetDsc([string]$Operation) {
    $output = @($upstream | winget dscv3 package "--$Operation")
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = @($output | Where-Object { "$_".Trim() }) }
}

if ($Operation -eq 'set' -and $scope -and $desired._exist -ne $false) {
    $before = Invoke-WinGetDsc get
    if ($before.ExitCode -ne 0) {
        Write-Failure ("winget dscv3 package --get {0} failed (0x{1:X8})" -f $desired.id, $before.ExitCode)
        exit $before.ExitCode
    }
    if (-not ($before.Lines[0] | ConvertFrom-Json)._exist) {
        # --exact matches the id's case, where matchOption's default ignores it: the documents spell ids as winget does
        if ($desired.matchOption -and $desired.matchOption -notlike 'equals*') {
            throw "_scope needs matchOption equals or equalsCaseInsensitive, not $($desired.matchOption)"
        }
        $arguments = @('install', '--id', $desired.id, '--exact', '--scope', "$scope".ToLower(), '--disable-interactivity')
        if ($desired.source) { $arguments += '--source', $desired.source }
        if ($desired.version) { $arguments += '--version', $desired.version }
        switch ($desired.installMode ?? 'silent') {
            'silent' { $arguments += '--silent' }
            'interactive' { $arguments += '--interactive' }
        }
        if ($desired.acceptAgreements) { $arguments += '--accept-package-agreements', '--accept-source-agreements' }
        # winget's progress goes to stderr, which DSC logs at trace
        $output = @(& winget @arguments 2>&1 | ForEach-Object { [Console]::Error.WriteLine($_); "$_" })
        if ($LASTEXITCODE -ne 0) {
            $last = $output | Where-Object { $_.Trim() } | Select-Object -Last 1
            Write-Failure ("winget install --scope {0} {1} failed (0x{2:X8}): {3}" -f "$scope".ToLower(), $desired.id, $LASTEXITCODE, $last)
            exit 2
        }
        $installedHere = $true
    }
}

$run = Invoke-WinGetDsc $Operation
if ($run.ExitCode -ne 0) {
    Write-Failure ("winget dscv3 package --{0} {1} failed (0x{2:X8})" -f $Operation, $desired.id, $run.ExitCode)
}
for ($i = 0; $i -lt $run.Lines.Count; $i++) {
    if ($i -eq 0 -and $scope) {
        $state = $run.Lines[0] | ConvertFrom-Json
        $state | Add-Member _scope $scope
        $state | ConvertTo-Json -Compress
    } elseif ($i -eq 1 -and $installedHere) {
        # winget dscv3 set found it installed and reports no change, but this set did change _exist
        $changed = @($run.Lines[1] | ConvertFrom-Json)
        if ($changed -notcontains '_exist') { $changed = @('_exist') + $changed }
        ConvertTo-Json -InputObject $changed -Compress
    } else {
        $run.Lines[$i]
    }
}

# The manifest ends its command with `exit $LASTEXITCODE`, so always exit explicitly
exit $run.ExitCode
