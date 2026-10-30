#Requires -Version 7
#Requires -RunAsAdministrator
#Requires -Modules Hyper-V
<#
.SYNOPSIS
    Opens a PowerShell session in a running test VM, or runs one command there.

.DESCRIPTION
    Connects over PowerShell Direct, signing in with the local administrator
    that New-TestVm.ps1 -Unattended keeps in the VM's notes; for a VM
    installed by hand, pass -Credential. Without -Command the session is
    interactive. With it, the command runs in ~\src\winfiles when that exists
    (where Copy-RepoToTestVm.ps1 puts the repo), and the script exits with
    the command's exit code.
    PowerShell Direct sessions run elevated with no UAC, so use them for
    read-only checks, not for the bootstrap: Scoop's installer refuses an
    elevated shell, and the gsudo prompt would never show.

.EXAMPLE
    gsudo pwsh -File .\scripts\Enter-TestVm.ps1 -Name winfiles-test -Command 'wsl -d NixOS -- uname -a'
#>
[CmdletBinding()]
param(
    [string]$Name = 'winfiles-test',
    [string]$Command,
    [pscredential]$Credential
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'testvm.ps1')

$vm = Get-VM -Name $Name
if ($vm.State -ne 'Running') { throw "VM '$Name' isn't running. Start it and wait for the desktop first." }
if (-not $Credential) { $Credential = Get-TestVmCredential $vm }

if (-not $Command) {
    Enter-PSSession -VMName $Name -Credential $Credential
    return
}

$session = New-PSSession -VMName $Name -Credential $Credential
try {
    Invoke-Command $session {
        $repo = Join-Path $HOME 'src\winfiles'
        if (Test-Path $repo) { Set-Location $repo }
        $global:LASTEXITCODE = 0
    }
    # Not -ErrorAction Stop: the command's own errors are output, its exit code is the result
    Invoke-Command $session ([scriptblock]::Create($Command)) -ErrorAction Continue
    $exitCode = Invoke-Command $session { $global:LASTEXITCODE }
} finally {
    Remove-PSSession $session
}
exit $exitCode
