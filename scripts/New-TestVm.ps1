#Requires -Version 7
#Requires -RunAsAdministrator
#Requires -Modules Hyper-V
<#
.SYNOPSIS
    Creates a Hyper-V VM with nested virtualization, for testing `just install`
    on a clean Windows 11.

.DESCRIPTION
    Windows Sandbox can't run WSL2: it doesn't expose virtualization to its
    guest. This VM does (ExposeVirtualizationExtensions), so the whole
    bootstrap can run in it, the WSL restart included.
    The VM is Generation 2 with Secure Boot and a virtual TPM, as Windows 11
    setup requires. Memory is static because nested virtualization doesn't
    work with dynamic memory. Automatic checkpoints are off, so the only
    checkpoints are the ones you take.
    Skips when a VM with that name already exists; it never changes or
    removes an existing VM. It doesn't start the VM.

.PARAMETER IsoPath
    The Windows 11 x64 installation ISO.

.EXAMPLE
    gsudo pwsh -File .\scripts\New-TestVm.ps1 -IsoPath "$HOME\Downloads\Win11_26H2_English_x64.iso"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$IsoPath,
    [string]$Name = 'winfiles-test',
    [int]$ProcessorCount = 4,
    [long]$MemoryBytes = 8GB,
    # Dynamically expanding, so it only takes what the guest writes
    [long]$DiskBytes = 128GB,
    [string]$SwitchName = 'Default Switch'
)

$ErrorActionPreference = 'Stop'

if (Get-VM -Name $Name -ErrorAction SilentlyContinue) {
    Write-Host "VM '$Name' already exists. Skipping..."
    return
}

$iso = (Resolve-Path -LiteralPath $IsoPath).ProviderPath
$vhdPath = Join-Path (Get-VMHost).VirtualHardDiskPath "$Name.vhdx"

Write-Host "Creating VM '$Name'..."
$vm = New-VM -Name $Name -Generation 2 -MemoryStartupBytes $MemoryBytes -SwitchName $SwitchName `
    -NewVHDPath $vhdPath -NewVHDSizeBytes $DiskBytes
$vm | Set-VM -ProcessorCount $ProcessorCount -StaticMemory -AutomaticCheckpointsEnabled $false `
    -AutomaticStopAction ShutDown
$vm | Set-VMProcessor -ExposeVirtualizationExtensions $true

# Windows 11 setup checks for Secure Boot and a TPM
$vm | Set-VMKeyProtector -NewLocalKeyProtector
$vm | Enable-VMTPM

$dvd = $vm | Add-VMDvdDrive -Path $iso -Passthru
$vm | Set-VMFirmware -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows -FirstBootDevice $dvd

Write-Host "Created VM '$Name' ($vhdPath)."
Write-Host @"
Next:
  vmconnect localhost $Name    # start it there and press a key to boot from the DVD
  # after Windows setup, with the VM shut down:
  Checkpoint-VM -Name $Name -SnapshotName clean
  # to return to a clean install:
  Restore-VMCheckpoint -VMName $Name -Name clean -Confirm:`$false
"@
