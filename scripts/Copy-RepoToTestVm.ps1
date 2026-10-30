#Requires -Version 7
#Requires -RunAsAdministrator
#Requires -Modules Hyper-V
<#
.SYNOPSIS
    Copies this repo into a running test VM, for testing `just install` there.

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
#>
[CmdletBinding()]
param(
    [string]$Name = 'winfiles-test',
    # A commit or branch to pack; defaults to the working tree
    [string]$Ref,
    [pscredential]$Credential
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'testvm.ps1')

$vm = Get-VM -Name $Name
if ($vm.State -ne 'Running') { throw "VM '$Name' isn't running. Start it and wait for the desktop first." }
if (-not $Credential) { $Credential = Get-TestVmCredential $vm }

$repo = Split-Path $PSScriptRoot
if (-not $Ref) {
    # Empty when there are no uncommitted changes
    $Ref = git -C $repo stash create
    if ($LASTEXITCODE) { throw 'git stash create failed' }
    if (-not $Ref) { $Ref = 'HEAD' }
    $label = 'the working tree'
} else {
    $label = $Ref
}
$zip = Join-Path ([IO.Path]::GetTempPath()) "winfiles-$Name.zip"
git -C $repo archive --format=zip -o $zip $Ref
if ($LASTEXITCODE) { throw "git archive $Ref failed" }

$session = New-PSSession -VMName $Name -Credential $Credential
try {
    $guestZip = Invoke-Command $session { Join-Path ([IO.Path]::GetTempPath()) 'winfiles.zip' }
    Copy-Item $zip -Destination $guestZip -ToSession $session
    $destination = Invoke-Command $session {
        $destination = Join-Path $HOME 'src\winfiles'
        if (Test-Path $destination) { Remove-Item $destination -Recurse -Force }
        Expand-Archive $using:guestZip -DestinationPath $destination
        Remove-Item $using:guestZip
        $destination
    }
    Write-Host "Copied $label ($Ref) to $destination in '$Name'."
} finally {
    Remove-PSSession $session
    Remove-Item $zip -ErrorAction SilentlyContinue
}
