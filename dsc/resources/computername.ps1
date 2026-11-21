# Implements Winfiles/ComputerName (see computername.dsc.resource.json).
# DSC pipes the instance as JSON on stdin; the operation is the first argument. Only JSON goes to stdout.
# Microsoft.Windows/Registry was ruled out: the name lives in several places (the registry, the TCP/IP hostname,
# the NetBIOS name), and Rename-Computer is what keeps them in step and validates the name. DSC 3.3.0 has no
# computer resource of its own.
# A rename only takes effect at the next restart. Windows keeps the name it's using in ActiveComputerName and the
# one it will use in ComputerName. test is in the desired state only once the first matches, so a rename waiting
# for its restart still reports false. set renames only when the second differs, so running it again while the rename
# waits changes nothing, and warns instead, since a resource can't restart Windows.
# Every operation tells DSC about the restart through _restartRequired, a top-level property DSC 3.3.0 collects into
# the result's executionInformation.restartRequired (checked 2026-11-18: under _metadata.Microsoft.DSC it's ignored
# with a warning). get says so while a rename waits. test and set say so while the active name isn't the wanted one,
# which includes before the rename is made, so a test run shows ahead of time that set will need a restart. DSC only
# reports it: it doesn't restart, so the install does (docs/run/restarts.md).
param(
    [ValidateSet('get', 'test', 'set')]
    [string]$Operation
)

. (Join-Path $PSScriptRoot 'common.ps1')
# A trap only covers the scope that declares it, so common.ps1 can't hold this one
trap { Write-ResourceMessage error "$_"; exit 1 }
$desired = $input | Read-ResourceInput

# What these read is the registry, which the tests can't replace with files, so they're functions to mock
function Get-ActiveComputerName {
    (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName').ComputerName
}

function Get-PendingComputerName {
    (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName').ComputerName
}

# What Rename-Computer accepts for a workgroup computer's NetBIOS name
function Test-ComputerName([string]$Name) {
    $Name -match '^(?!\d+$)[A-Za-z0-9][A-Za-z0-9-]{0,14}$'
}

function Get-State {
    $active, $pending = (Get-ActiveComputerName), (Get-PendingComputerName)
    [ordered]@{
        name        = $desired.name
        activeName  = $active
        pendingName = $pending
    }
}

$failed = $false
if ($Operation -eq 'set' -and (Get-PendingComputerName) -ine $desired.name) {
    if (-not (Test-ComputerName $desired.name)) {
        Write-ResourceMessage error ("'$($desired.name)' isn't a valid computer name: " +
            'use 1 to 15 letters, digits and hyphens, not only digits')
        $failed = $true
    } else {
        try {
            # -WarningAction: Rename-Computer warns "The changes will take effect after you restart", and pwsh
            # writes warnings to stdout, ahead of the JSON, which DSC then can't parse (seen 2026-11-18 in the
            # test VM: "JSON: expected value at line 1 column 1"). set warns about the restart itself, below
            Rename-Computer -NewName $desired.name -Force -WarningAction SilentlyContinue -ErrorAction Stop
        } catch {
            Write-ResourceMessage error "Renaming the computer to '$($desired.name)' failed: $_"
            $failed = $true
        }
    }
}

$state = Get-State
# A name Windows would refuse can't be reached by a restart, so it asks for none
$restart = if ($Operation -eq 'get') { $state.activeName -ine $state.pendingName }
    else { -not $failed -and (Test-ComputerName $desired.name) -and $state.activeName -ine $desired.name }
if ($restart) { $state['_restartRequired'] = @(@{ system = $state.activeName }) }
if ($Operation -eq 'test') { $state['_inDesiredState'] = $state.activeName -ieq $desired.name }
if ($Operation -eq 'set' -and -not $failed -and $restart) {
    Write-ResourceMessage warn ("The computer will be named '$($state.pendingName)' after the next restart; " +
        "it's still '$($state.activeName)'")
}
$state | ConvertTo-Json -Compress -Depth 3

# The manifest ends its command with `exit $LASTEXITCODE`, so always exit explicitly
if ($failed) { exit 2 }
exit 0
