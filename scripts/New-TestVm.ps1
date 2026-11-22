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
    unattend.xml that answers OOBE and creates a local administrator with a
    blank password, recorded in the VM's notes. Blank passwords are allowed
    beyond the console, so an enhanced session and PowerShell Direct need no
    password either; only for a throwaway VM. The VM signs in automatically
    at every boot, so the bootstrap's restart needs no attention.
    Skips when a VM with that name already exists; it never changes or
    removes an existing VM. It doesn't start the VM.

.EXAMPLE
    gsudo pwsh -File .\scripts\New-TestVm.ps1 -IsoPath "$HOME\Downloads\Win11_26H2_English_x64.iso" -Unattended

    Creates winfiles-test from the ISO, installed and signed in without Windows Setup.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    # The Windows 11 x64 installation ISO.
    [Parameter(Mandatory)]
    [string]$IsoPath,

    # The VM's name.
    [string]$Name = 'winfiles-test',

    # The VM's processors.
    [int]$ProcessorCount = 4,

    # The VM's memory, which is static.
    [long]$MemoryBytes = 8GB,

    # The VHDX's size. Dynamically expanding, so it only takes what the guest writes.
    [long]$DiskBytes = 128GB,

    # The virtual switch for the VM's network adapter.
    [string]$SwitchName = 'Default Switch',

    # Apply the image and answer OOBE instead of booting Windows Setup.
    [switch]$Unattended,

    # -Unattended only: the image to apply.
    [string]$Edition = 'Windows 11 Pro',

    # -Unattended only: the local administrator to create.
    [string]$UserName = $env:USERNAME,

    # -Unattended only; defaults to -Name.
    [string]$ComputerName
)

$ErrorActionPreference = 'Stop'
try {
    function Get-UnattendXml {
        <#
        .SYNOPSIS
        Returns the unattend.xml that answers OOBE and creates a local administrator, whose password is blank.
        #>
        [CmdletBinding()]
        [OutputType([string])]
        param(
            # The computer's name.
            [Parameter(Mandatory)]
            [string]$ComputerName,

            # The image's UI language.
            [Parameter(Mandatory)]
            [string]$UILanguage,

            # The local administrator's name.
            [Parameter(Mandatory)]
            [string]$UserName
        )

        $component = ('processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" ' +
            'versionScope="nonSxS"')
        $allowBlankPassword =
        'reg.exe add HKLM\SYSTEM\CurrentControlSet\Control\Lsa /v LimitBlankPasswordUse /t REG_DWORD /d 0 /f'
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
    <component name="Microsoft-Windows-Deployment" $component>
      <RunSynchronous>
        <!-- By default a blank password only signs in at the console; an enhanced session is Remote Desktop -->
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Path>$allowBlankPassword</Path>
        </RunSynchronousCommand>
      </RunSynchronous>
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
            <Password><Value></Value><PlainText>true</PlainText></Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
      <AutoLogon>
        <Enabled>true</Enabled>
        <!-- Winlogon counts this down and turns AutoLogon off at 0; this many sign-ins never runs out -->
        <LogonCount>9999999</LogonCount>
        <Username>$user</Username>
        <Password><Value></Value><PlainText>true</PlainText></Password>
      </AutoLogon>
    </component>
  </settings>
</unattend>
"@
    }


    function New-WindowsVhd {
        <#
        .SYNOPSIS
        Makes a bootable VHDX: partitions it for UEFI (EFI, MSR, Windows), applies the edition and writes
        unattend.xml.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'The script asks ShouldProcess for the whole VM before calling this')]
        [CmdletBinding()]
        param(
            # The Windows ISO.
            [Parameter(Mandatory)]
            [string]$Iso,

            # Where to create the VHDX.
            [Parameter(Mandatory)]
            [string]$VhdPath,

            # The VHDX's size.
            [Parameter(Mandatory)]
            [long]$SizeBytes,

            # The edition to apply, by its image name.
            [Parameter(Mandatory)]
            [string]$Edition,

            # The computer's name.
            [Parameter(Mandatory)]
            [string]$ComputerName,

            # The local administrator's name.
            [Parameter(Mandatory)]
            [string]$UserName
        )

        $isoImage = Mount-DiskImage -ImagePath $Iso -Access ReadOnly -StorageType ISO -PassThru
        $vhdMounted = $false
        try {
            $isoRoot = "$(($isoImage | Get-Volume).DriveLetter):\sources"
            $wim = @("$isoRoot\install.wim", "$isoRoot\install.esd") |
                Where-Object -FilterScript { Test-Path -Path $_ } |
                Select-Object -First 1
            if (-not $wim) {
                throw "No install.wim or install.esd in $isoRoot"
            }
            $image = Get-WindowsImage -ImagePath $wim | Where-Object -Property ImageName -EQ -Value $Edition
            if (-not $image) {
                throw "No '$Edition' in $wim; it has: $((Get-WindowsImage -ImagePath $wim).ImageName -join ', ')"
            }
            $uiLanguage = (Get-WindowsImage -ImagePath $wim -Index $image.ImageIndex).Languages[0]

            New-VHD -Path $VhdPath -SizeBytes $SizeBytes -Dynamic | Out-Null
            $disk = Mount-VHD -Path $VhdPath -Passthru | Get-Disk
            $vhdMounted = $true
            Initialize-Disk -Number $disk.Number -PartitionStyle GPT
            $efiPartition = @{
                DiskNumber        = $disk.Number
                Size              = 260MB
                GptType           = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
                AssignDriveLetter = $true
            }
            $efi = New-Partition @efiPartition
            $efi | Format-Volume -FileSystem FAT32 -NewFileSystemLabel System | Out-Null
            $msrPartition = @{
                DiskNumber = $disk.Number
                Size       = 16MB
                GptType    = '{e3c9e316-0b5c-4db8-817d-f92df00215ae}'
            }
            New-Partition @msrPartition | Out-Null
            $os = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter
            $os | Format-Volume -FileSystem NTFS -NewFileSystemLabel Windows | Out-Null
            $efiRoot = "$($efi.DriveLetter):\"
            $osRoot = "$($os.DriveLetter):\"

            Write-Host -Object "Applying '$Edition' from $wim (this takes a few minutes)..."
            Expand-WindowsImage -ImagePath $wim -Index $image.ImageIndex -ApplyPath $osRoot | Out-Null
            $windows = Join-Path -Path $osRoot -ChildPath 'Windows'
            & bcdboot.exe $windows /s $efiRoot.TrimEnd('\') /f UEFI | Out-Host
            if ($LASTEXITCODE -ne 0) {
                throw "bcdboot exited with code $LASTEXITCODE"
            }

            $pantherPath = Join-Path -Path $osRoot -ChildPath 'Windows\Panther'
            $panther = New-Item -ItemType Directory -Force -Path $pantherPath
            Get-UnattendXml -ComputerName $ComputerName -UILanguage $uiLanguage -UserName $UserName |
                Set-Content -Encoding utf8NoBOM -Path (Join-Path -Path $panther -ChildPath 'unattend.xml')
        } catch {
            $failure = $_
            if ($vhdMounted) {
                Dismount-VHD -Path $VhdPath
                $vhdMounted = $false
            }
            Remove-Item -LiteralPath $VhdPath -ErrorAction SilentlyContinue
            throw $failure
        } finally {
            if ($vhdMounted) {
                Dismount-VHD -Path $VhdPath
            }
            $isoImage | Dismount-DiskImage | Out-Null
        }
    }


    if (Get-VM -Name $Name -ErrorAction SilentlyContinue) {
        Write-Host -Object "VM '$Name' already exists. Skipping..."
        exit 0
    }

    $iso = (Resolve-Path -LiteralPath $IsoPath).ProviderPath
    $vhdPath = Join-Path -Path (Get-VMHost).VirtualHardDiskPath -ChildPath "$Name.vhdx"
    if (Test-Path -LiteralPath $vhdPath) {
        throw "$vhdPath already exists but no VM '$Name' uses it. Remove it or pick another -Name."
    }
    if (-not $PSCmdlet.ShouldProcess($Name, 'Create a test VM')) {
        exit 0
    }

    if ($Unattended) {
        if (-not $ComputerName) {
            $ComputerName = $Name
        }
        # Setup rejects anything else, but only at first boot, in the specialize pass
        if ($ComputerName -notmatch '^(?![0-9]+$)[A-Za-z0-9-]{1,15}$') {
            throw ("'$ComputerName' isn't a valid computer name " +
                '(at most 15 letters, digits and hyphens, not all digits). Pass -ComputerName.')
        }
        $vhd = @{
            Iso          = $iso
            VhdPath      = $vhdPath
            SizeBytes    = $DiskBytes
            Edition      = $Edition
            ComputerName = $ComputerName
            UserName     = $UserName
        }
        New-WindowsVhd @vhd
    }

    Write-Host -Object "Creating VM '$Name'..."
    $newVm = @{ Name = $Name; Generation = 2; MemoryStartupBytes = $MemoryBytes; SwitchName = $SwitchName }
    $vm = if ($Unattended) {
        New-VM @newVm -VHDPath $vhdPath
    } else {
        New-VM @newVm -NewVHDPath $vhdPath -NewVHDSizeBytes $DiskBytes
    }
    $settings = @{
        ProcessorCount              = $ProcessorCount
        StaticMemory                = $true
        AutomaticCheckpointsEnabled = $false
        AutomaticStopAction         = 'ShutDown'
    }
    $vm | Set-VM @settings
    $vm | Set-VMProcessor -ExposeVirtualizationExtensions $true
    # For basic sessions, the VM's own console; its default screen is small. An enhanced session sizes it to the
    # window
    $vm | Set-VMVideo -ResolutionType Single -HorizontalResolution 1920 -VerticalResolution 1080

    # Windows 11 checks for Secure Boot and a TPM
    $vm | Set-VMKeyProtector -NewLocalKeyProtector
    $vm | Enable-VMTPM

    $secureBoot = @{ EnableSecureBoot = 'On'; SecureBootTemplate = 'MicrosoftWindows' }
    if ($Unattended) {
        # Read by testvm.ps1; the password after the slash is empty
        $vm | Set-VM -Notes "winfiles test VM. Local administrator: $UserName / "
        $vm | Set-VMFirmware @secureBoot -FirstBootDevice ($vm | Get-VMHardDiskDrive)
    } else {
        $dvd = $vm | Add-VMDvdDrive -Path $iso -Passthru
        $vm | Set-VMFirmware @secureBoot -FirstBootDevice $dvd
    }

    Write-Host -Object "Created VM '$Name' ($vhdPath)."
    if ($Unattended) {
        Write-Host -Object "Local administrator: $UserName, with a blank password"
    }
    $boot = if ($Unattended) {
        'start it there; it signs in by itself'
    } else {
        'start it there and press a key to boot from the DVD'
    }
    Write-Host -Object @"
Next:
  vmconnect localhost $Name    # $boot
  # after Windows setup, with the VM shut down:
  Checkpoint-VM -Name $Name -SnapshotName clean
  # to return to a clean install:
  Restore-VMCheckpoint -VMName $Name -Name clean -Confirm:`$false
"@
} catch {
    # Rethrown, so an error that only ends a statement still ends the script, with exit code 1
    $failure = $_
    throw $failure
} finally {
    $ErrorActionPreference = 'Continue'
}
