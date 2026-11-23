#Requires -Version 7
#Requires -RunAsAdministrator
#Requires -Modules Hyper-V

<#
.SYNOPSIS
    Copies this repo into a running test VM, for testing `winfiles.ps1 install` there.

.DESCRIPTION
    Packs the repo with `git archive` and copies it into the VM over
    PowerShell Direct, so the VM needs no network share or git. By default
    the archive is the working tree: committed files plus uncommitted changes
    to tracked files (`git stash create`, which leaves the stash and the
    working tree alone). Untracked files aren't included. -Ref packs a commit
    or branch instead.
    The copy replaces ~\src\winfiles in the VM, so files deleted from the
    repo don't linger there, and any changes made inside the VM are lost.
    Signs in with the local administrator that New-TestVm.ps1 -Unattended
    keeps in the VM's notes; for a VM installed by hand, pass -Credential.

.EXAMPLE
    gsudo pwsh -File .\scripts\Copy-RepoToTestVm.ps1 -Name winfiles-test

    Copies the working tree into winfiles-test.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    # The VM's name.
    [string]$Name = 'winfiles-test',

    # A commit or branch to pack; defaults to the working tree.
    [string]$Ref,

    # The VM's user, for a VM installed by hand.
    [pscredential]$Credential
)

$ErrorActionPreference = 'Stop'
try {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'testvm.ps1')

    $Credential = Get-RunningTestVmCredential -Name $Name -Credential $Credential

    $repo = Split-Path -Path $PSScriptRoot
    if ($Ref) {
        $label = $Ref
    } else {
        # Empty when there are no uncommitted changes
        $Ref = git -C $repo stash create
        if ($LASTEXITCODE) {
            throw 'git stash create failed'
        }
        if (-not $Ref) {
            $Ref = 'HEAD'
        }
        $label = 'the working tree'
    }
    if (-not $PSCmdlet.ShouldProcess("~\src\winfiles in $Name", "Replace with $label")) {
        exit 0
    }
    $zip = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath "winfiles-$Name.zip"
    git -C $repo archive --format=zip -o $zip $Ref
    if ($LASTEXITCODE) {
        throw "git archive $Ref failed"
    }

    $session = New-PSSession -VMName $Name -Credential $Credential
    try {
        $guestZip = Invoke-Command -Session $session -ScriptBlock {
            Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath 'winfiles.zip'
        }
        Copy-Item -Path $zip -Destination $guestZip -ToSession $session
        $destination = Invoke-Command -Session $session -ScriptBlock {
            $destination = Join-Path -Path $HOME -ChildPath 'src\winfiles'
            if (Test-Path -Path $destination) {
                Remove-Item -Path $destination -Recurse -Force
            }
            Expand-Archive -Path $using:guestZip -DestinationPath $destination
            Remove-Item -Path $using:guestZip
            $destination
        }
        Write-Host -Object "Copied $label ($Ref) to $destination in '$Name'."
    } finally {
        Remove-PSSession -Session $session
        Remove-Item -Path $zip -ErrorAction SilentlyContinue
    }
} catch {
    # Rethrown, so an error that only ends a statement still ends the script, with exit code 1
    $failure = $_
    throw $failure
} finally {
    $ErrorActionPreference = 'Continue'
}
