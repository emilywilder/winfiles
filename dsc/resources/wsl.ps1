# Implements Winfiles/Wsl (see wsl.dsc.resource.json): the WSL package and Virtual Machine Platform, which scripts/Install-Wsl.ps1
# did before it was replaced by this. DSC pipes the instance as JSON on stdin; the operation is the first argument. Only JSON goes to stdout.
# `wsl --install --no-distribution` installs the WSL package and enables Virtual Machine Platform in one step (the
# winget package doesn't enable the feature). Enabling the feature needs a restart, which only the install can do, so
# the resource never restarts Windows: it reports `_restartRequired` to DSC (DSC 3.3.0 collects it into the result's
# executionInformation.restartRequired) and exits 0, since DSC stops the whole configuration on a non-zero exit.
# get says so while a restart is pending. test also says so while Virtual Machine Platform is off, since enabling it
# leaves one pending, so a run can know ahead of time that set will need a restart. A WSL that only needs installing
# or updating, with the feature already on, isn't predicted to: the machine shows it afterwards (restart.ps1).
# The checks are the ones Winfiles/WslDistribution makes before installing a distribution (wsldistribution.ps1).
# A restart pending for another reason, Windows Update's say, counts too: installers refuse to run then, so the
# machine isn't in the desired state until it's restarted.
param(
    [ValidateSet('get', 'test', 'set')]
    [string]$Operation
)

. (Join-Path $PSScriptRoot 'common.ps1')
# A trap only covers the scope that declares it, so common.ps1 can't hold this one
trap { Write-ResourceMessage error "$_"; exit 1 }
$desired = $input | Read-ResourceInput
# The first WSL with --from-file and --name, which Winfiles/WslDistribution uses
$minimum = [version]($desired.minimumVersion ?? '2.4.4')

# wsl.exe writes UTF-16 unless told otherwise
$env:WSL_UTF8 = '1'

# Right after `wsl --install` the feature already reads as enabled (InstallState 1, RestartNeeded false on build
# 26300); only the servicing key shows that the restart is still to come
function Test-RestartPending {
    Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
}

# CIM reads the feature without elevation, unlike Microsoft.Windows/OptionalFeatureList. The vmcompute service would be
# a cheaper query, but it doesn't exist until after the restart (checked 2026-11-17 in the test VM)
function Test-VirtualMachinePlatform {
    (Get-CimInstance Win32_OptionalFeature -Filter "Name='VirtualMachinePlatform'").InstallState -eq 1
}

# WSL 2 runs in the hypervisor that Virtual Machine Platform starts at boot. With virtualization off in the firmware,
# or not passed through to a VM, the feature still reads as enabled and WSL as installed, and only installing a
# distribution fails
function Test-Hypervisor {
    [bool](Get-CimInstance Win32_ComputerSystem).HypervisorPresent
}

# The installed WSL's version, or nothing: the file version of the package's own wsl.exe, and nothing is run. The
# inbox wsl.exe in System32, on a machine without the WSL package, waits 60s for a key press that would install it
# (seen on a fresh install, 2026-11-17). A WSL installed elsewhere, such as a Store package, has only its registration
# in AppxAllUserStore, named <name>_<version>_<arch>__<publisher>; read from the registry rather than Get-AppxPackage,
# which needs elevation for -AllUsers
function Get-WslVersion {
    $wsl = Join-Path $env:ProgramFiles 'WSL\wsl.exe'
    if (Test-Path -Path $wsl) {
        if ("$((Get-Item -LiteralPath $wsl).VersionInfo.ProductVersion)" -match '^(\d+\.\d+\.\d+)') { [version]$Matches[1] }
        return
    }
    $store = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Applications'
    $package = Get-ChildItem -Path $store -Name -ErrorAction SilentlyContinue |
        Where-Object { $_ -like 'MicrosoftCorporationII.WindowsSubsystemForLinux_*' } | Select-Object -First 1
    if ($package -and $package -match '_(\d+\.\d+\.\d+)(\.\d+)?_') { [version]$Matches[1] }
}

# S-1-16-12288 is the High mandatory level, which an elevated token has. whoami.exe, not the .NET principal, so a test
# can mock it
function Test-Elevated {
    [bool](& whoami.exe /groups | Select-String -SimpleMatch 'S-1-16-12288')
}

function Get-State {
    $version = Get-WslVersion
    [ordered]@{
        minimumVersion         = "$minimum"
        version                = if ($version) { "$version" }
        virtualMachinePlatform = [bool](Test-VirtualMachinePlatform)
        hypervisor             = Test-Hypervisor
        restartPending         = [bool](Test-RestartPending)
    }
}

# Installed and enabled, whether or not Windows has been restarted since
function Test-Ready($State) {
    $State.virtualMachinePlatform -and $State.version -and [version]$State.version -ge $minimum
}

# Sends wsl.exe output to stderr so stdout stays JSON; returns its exit code
function Invoke-Wsl([string[]]$WslArgs) {
    & wsl.exe @WslArgs 2>&1 | ForEach-Object { [Console]::Error.WriteLine($_) }
    $LASTEXITCODE
}

# A failed wsl.exe is reported, and the rest of the set isn't tried. Windows Installer's codes for success are 3010,
# with a restart required, and 1641, with the restart already started
function Invoke-WslChecked([string[]]$WslArgs) {
    $exitCode = Invoke-Wsl $WslArgs
    if ($exitCode -eq 1641) {
        Write-ResourceMessage warn "wsl.exe $WslArgs has started a restart"
    } elseif ($exitCode -notin 0, 3010) {
        Write-ResourceMessage error "wsl.exe $WslArgs exited with code $exitCode"
        return $false
    }
    $true
}

$state = Get-State
$failed = $false
if ($Operation -eq 'set' -and -not (Test-Ready $state)) {
    if (-not (Test-Elevated)) {
        Write-ResourceMessage error 'Installing WSL needs elevation'
        $failed = $true
    } else {
        # `wsl --install` isn't known to update an older WSL package, so update it explicitly. The inbox wsl.exe has no version
        if ($state.version -and [version]$state.version -lt $minimum) { $failed = -not (Invoke-WslChecked '--update') }
        if (-not $failed -and (-not $state.version -or -not $state.virtualMachinePlatform)) {
            $failed = -not (Invoke-WslChecked '--install', '--no-distribution')
        }
        $state = Get-State
        if (-not $failed -and -not $state.restartPending -and -not (Test-Ready $state)) {
            $found = if ($state.version) { "WSL $($state.version)" } else { 'only the inbox WSL' }
            $feature = if ($state.virtualMachinePlatform) { 'enabled' } else { 'not enabled' }
            Write-ResourceMessage error "wsl.exe finished, but WSL still isn't ready, and no restart is pending: this machine has $found ($minimum or later is needed), and Virtual Machine Platform is $feature"
            $failed = $true
        }
    }
}
# Only after the restart can the hypervisor be judged: until then it isn't running, and restarting is the fix
$noHypervisor = (Test-Ready $state) -and -not $state.restartPending -and -not $state.hypervisor
if ($Operation -eq 'set' -and -not $failed -and $noHypervisor) {
    Write-ResourceMessage error 'Virtual Machine Platform is enabled, but no hypervisor is running, so WSL 2 can''t start, and restarting again won''t help. Turn on virtualization (Intel VT-x or AMD-V) in the BIOS/UEFI settings; in a Hyper-V VM, turn on nested virtualization (Set-VMProcessor -ExposeVirtualizationExtensions $true) while the VM is off'
    $failed = $true
}

$restart = $state.restartPending -or ($Operation -eq 'test' -and -not $state.virtualMachinePlatform)
if ($restart) { $state['_restartRequired'] = @(@{ system = $env:COMPUTERNAME }) }
if ($Operation -eq 'test') {
    $state['_inDesiredState'] = [bool](Test-Ready $state) -and -not $state.restartPending -and -not $noHypervisor
}
if ($Operation -eq 'set' -and -not $failed -and $state.restartPending) {
    Write-ResourceMessage warn 'Windows has a restart pending. Restart before anything else is installed'
}
$state | ConvertTo-Json -Compress -Depth 3

# The manifest ends its command with `exit $LASTEXITCODE`, so always exit explicitly
if ($failed) { exit 2 }
exit 0