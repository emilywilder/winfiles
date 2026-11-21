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

    Runs uname in the VM's NixOS distribution.

.EXAMPLE
    gsudo pwsh -File .\scripts\Enter-TestVm.ps1 -Name winfiles-test -Unelevated -Command '.\install.cmd vm-quick'

    Starts the vm-quick install as the VM's user.
#>
[CmdletBinding()]
param(
    # The VM's name.
    [string]$Name = 'winfiles-test',

    # A command to run instead of opening an interactive session.
    [string]$Command,

    # The VM's user, for a VM installed by hand.
    [pscredential]$Credential,

    # Run the command as the VM's user without elevation, through a scheduled task.
    [switch]$Unelevated
)

$ErrorActionPreference = 'Stop'
try {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'testvm.ps1')

    $Credential = Get-RunningTestVmCredential -Name $Name -Credential $Credential

    if ($Unelevated) {
        if (-not $Command) {
            throw '-Unelevated needs a -Command: an interactive session is always elevated.'
        }
        exit (Invoke-TestVmUnelevated -Name $Name -Credential $Credential -Command $Command)
    }

    if ($Command) {
        $session = New-PSSession -VMName $Name -Credential $Credential
        try {
            Invoke-Command -Session $session -ScriptBlock {
                $repo = Join-Path -Path $HOME -ChildPath 'src\winfiles'
                if (Test-Path -Path $repo) {
                    Set-Location -Path $repo
                }
                $Global:LASTEXITCODE = 0
            }
            # Not -ErrorAction Stop: the command's own errors are output, its exit code is the result
            Invoke-Command -Session $session -ScriptBlock ([scriptblock]::Create($Command)) -ErrorAction Continue
            $exitCode = Invoke-Command -Session $session -ScriptBlock { $Global:LASTEXITCODE }
        } finally {
            Remove-PSSession -Session $session
        }
        exit $exitCode
    }
    Enter-PSSession -VMName $Name -Credential $Credential
} catch {
    # Rethrown, so an error that only ends a statement still ends the script, with exit code 1
    $failure = $_
    throw $failure
} finally {
    $ErrorActionPreference = 'Continue'
}
