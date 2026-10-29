#Requires -Version 7
#Requires -RunAsAdministrator
#Requires -Modules Hyper-V, Dism, Storage
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
    By default the VM boots the ISO and you go through Windows Setup.
    With -Unattended, Setup is skipped: the edition is applied from the ISO
    straight to the VHDX, made bootable with bcdboot, and given an
    unattend.xml that answers OOBE and creates a local administrator. The
    password is generated, printed, and kept in the VM's notes. The VM signs
    in automatically at every boot, so the bootstrap's restart needs no
    attention.
    Skips when a VM with that name already exists; it never changes or
    removes an existing VM. It doesn't start the VM.

.PARAMETER IsoPath
    The Windows 11 x64 installation ISO.

.PARAMETER Unattended
    Apply the image and answer OOBE instead of booting Windows Setup.

.EXAMPLE
    gsudo pwsh -File .\scripts\New-TestVm.ps1 -IsoPath "$HOME\Downloads\Win11_26H2_English_x64.iso" -Unattended
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
    [string]$SwitchName = 'Default Switch',
    [switch]$Unattended,
    # -Unattended only: the image to apply, and the local administrator to create
    [string]$Edition = 'Windows 11 Pro',
    [string]$UserName = $env:USERNAME,
    # -Unattended only; defaults to -Name
    [string]$ComputerName
)

$ErrorActionPreference = 'Stop'

function New-Password {
    # Letters and digits only, so it needs no escaping in XML
    $chars = [char[]]'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    -join (1..20 | ForEach-Object { $chars[[Security.Cryptography.RandomNumberGenerator]::GetInt32($chars.Length)] })
}

function Get-UnattendXml {
    param([string]$ComputerName, [string]$UILanguage, [string]$UserName, [string]$Password)
    $component = 'processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"'
    $computer = [Security.SecurityElement]::Escape($ComputerName)
    $user = [Security.SecurityElement]::Escape($UserName)
    $locale = (Get-Culture).Name
    @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" $component>
      <ComputerName>$computer</ComputerName>
      <TimeZone>$((Get-TimeZone).Id)</TimeZone>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" $component>
      <InputLocale>$locale</InputLocale>
      <SystemLocale>$((Get-WinSystemLocale).Name)</SystemLocale>
      <UILanguage>$UILanguage</UILanguage>
      <UserLocale>$locale</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" $component>
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Name>$user</Name>
            <Group>Administrators</Group>
            <Password><Value>$Password</Value><PlainText>true</PlainText></Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
      <AutoLogon>
        <Enabled>true</Enabled>
        <!-- Winlogon counts this down and turns AutoLogon off at 0; this many sign-ins never runs out -->
        <LogonCount>9999999</LogonCount>
        <Username>$user</Username>
        <Password><Value>$Password</Value><PlainText>true</PlainText></Password>
      </AutoLogon>
    </component>
  </settings>
</unattend>
"@
}

function New-WindowsVhd {
    # Partitions the VHDX for UEFI (EFI, MSR, Windows), applies the edition and writes unattend.xml
    param([string]$Iso, [string]$VhdPath, [long]$SizeBytes, [string]$Edition, [string]$ComputerName,
        [string]$UserName, [string]$Password)
    $isoImage = Mount-DiskImage -ImagePath $Iso -Access ReadOnly -StorageType ISO -PassThru
    $vhdMounted = $false
    try {
        $isoRoot = "$(($isoImage | Get-Volume).DriveLetter):\sources"
        $wim = @("$isoRoot\install.wim", "$isoRoot\install.esd") | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $wim) { throw "No install.wim or install.esd in $isoRoot" }
        $image = Get-WindowsImage -ImagePath $wim | Where-Object ImageName -EQ $Edition
        if (-not $image) {
            throw "No '$Edition' in $wim; it has: $((Get-WindowsImage -ImagePath $wim).ImageName -join ', ')"
        }
        $uiLanguage = (Get-WindowsImage -ImagePath $wim -Index $image.ImageIndex).Languages[0]

        New-VHD -Path $VhdPath -SizeBytes $SizeBytes -Dynamic | Out-Null
        $disk = Mount-VHD -Path $VhdPath -Passthru | Get-Disk
        $vhdMounted = $true
        Initialize-Disk -Number $disk.Number -PartitionStyle GPT
        $efi = New-Partition -DiskNumber $disk.Number -Size 260MB -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' -AssignDriveLetter
        $efi | Format-Volume -FileSystem FAT32 -NewFileSystemLabel System | Out-Null
        New-Partition -DiskNumber $disk.Number -Size 16MB -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}' | Out-Null
        $os = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter
        $os | Format-Volume -FileSystem NTFS -NewFileSystemLabel Windows | Out-Null
        $efiRoot = "$($efi.DriveLetter):\"
        $osRoot = "$($os.DriveLetter):\"

        Write-Host "Applying '$Edition' from $wim (this takes a few minutes)..."
        Expand-WindowsImage -ImagePath $wim -Index $image.ImageIndex -ApplyPath $osRoot | Out-Null
        & bcdboot.exe (Join-Path $osRoot 'Windows') /s $efiRoot.TrimEnd('\') /f UEFI | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "bcdboot exited with code $LASTEXITCODE" }

        $panther = New-Item -ItemType Directory -Force (Join-Path $osRoot 'Windows\Panther')
        Get-UnattendXml -ComputerName $ComputerName -UILanguage $uiLanguage -UserName $UserName -Password $Password |
            Set-Content -Encoding utf8NoBOM (Join-Path $panther 'unattend.xml')
    } catch {
        if ($vhdMounted) { Dismount-VHD -Path $VhdPath; $vhdMounted = $false }
        Remove-Item -LiteralPath $VhdPath -ErrorAction SilentlyContinue
        throw
    } finally {
        if ($vhdMounted) { Dismount-VHD -Path $VhdPath }
        $isoImage | Dismount-DiskImage | Out-Null
    }
}

if (Get-VM -Name $Name -ErrorAction SilentlyContinue) {
    Write-Host "VM '$Name' already exists. Skipping..."
    return
}

$iso = (Resolve-Path -LiteralPath $IsoPath).ProviderPath
$vhdPath = Join-Path (Get-VMHost).VirtualHardDiskPath "$Name.vhdx"
if (Test-Path -LiteralPath $vhdPath) {
    throw "$vhdPath already exists but no VM '$Name' uses it. Remove it or pick another -Name."
}

if ($Unattended) {
    if (-not $ComputerName) { $ComputerName = $Name }
    # Setup rejects anything else, but only at first boot, in the specialize pass
    if ($ComputerName -notmatch '^(?![0-9]+$)[A-Za-z0-9-]{1,15}$') {
        throw "'$ComputerName' isn't a valid computer name (at most 15 letters, digits and hyphens, not all digits). Pass -ComputerName."
    }
    $password = New-Password
    New-WindowsVhd -Iso $iso -VhdPath $vhdPath -SizeBytes $DiskBytes -Edition $Edition -ComputerName $ComputerName `
        -UserName $UserName -Password $password
}

Write-Host "Creating VM '$Name'..."
$vm = if ($Unattended) {
    New-VM -Name $Name -Generation 2 -MemoryStartupBytes $MemoryBytes -SwitchName $SwitchName -VHDPath $vhdPath
} else {
    New-VM -Name $Name -Generation 2 -MemoryStartupBytes $MemoryBytes -SwitchName $SwitchName `
        -NewVHDPath $vhdPath -NewVHDSizeBytes $DiskBytes
}
$vm | Set-VM -ProcessorCount $ProcessorCount -StaticMemory -AutomaticCheckpointsEnabled $false `
    -AutomaticStopAction ShutDown
$vm | Set-VMProcessor -ExposeVirtualizationExtensions $true
# Tests run in a basic session, the VM's own console as on a real machine; its default screen is small
$vm | Set-VMVideo -ResolutionType Single -HorizontalResolution 1920 -VerticalResolution 1080

# Windows 11 checks for Secure Boot and a TPM
$vm | Set-VMKeyProtector -NewLocalKeyProtector
$vm | Enable-VMTPM

if ($Unattended) {
    $vm | Set-VM -Notes "winfiles test VM. Local administrator: $UserName / $password"
    $vm | Set-VMFirmware -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows `
        -FirstBootDevice ($vm | Get-VMHardDiskDrive)
} else {
    $dvd = $vm | Add-VMDvdDrive -Path $iso -Passthru
    $vm | Set-VMFirmware -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows -FirstBootDevice $dvd
}

Write-Host "Created VM '$Name' ($vhdPath)."
if ($Unattended) {
    Write-Host "Local administrator: $UserName / $password (also in the VM's notes: (Get-VM $Name).Notes)"
}
$boot = if ($Unattended) { 'start it there; it signs in by itself' } else { 'start it there and press a key to boot from the DVD' }
Write-Host @"
Next:
  vmconnect localhost $Name    # $boot
  # after Windows setup, with the VM shut down:
  Checkpoint-VM -Name $Name -SnapshotName clean
  # to return to a clean install:
  Restore-VMCheckpoint -VMName $Name -Name clean -Confirm:`$false
"@
