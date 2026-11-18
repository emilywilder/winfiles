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
    -Unelevated runs the command as the VM's user without elevation, through
    a scheduled task (Windows PowerShell 5.1, Medium integrity, in the user's
    signed-in session), so bootstrap.cmd and install.cmd can be started from
    here. Its UAC prompts still show on the VM's desktop and wait for a click,
    and the resume after a restart still needs a sign-in and Enter there. The
    script exits 3010 when the VM stops answering, as it does for a restart.

.EXAMPLE
    gsudo pwsh -File .\scripts\Enter-TestVm.ps1 -Name winfiles-test -Command 'wsl -d NixOS -- uname -a'

.EXAMPLE
    gsudo pwsh -File .\scripts\Enter-TestVm.ps1 -Name winfiles-test -Unelevated -Command '.\install.cmd vm-quick'
#>
[CmdletBinding()]
param(
    [string]$Name = 'winfiles-test',
    [string]$Command,
    [pscredential]$Credential,
    [switch]$Unelevated
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'testvm.ps1')

$Credential = Get-RunningTestVmCredential $Name $Credential

if ($Unelevated) {
    if (-not $Command) { throw '-Unelevated needs a -Command: an interactive session is always elevated.' }
    exit (Invoke-TestVmUnelevated $Name $Credential $Command)
}

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
