# Shared by the scripts that sign in to a test VM over PowerShell Direct, which dot-source it.
# Reads the local administrator that New-TestVm.ps1 -Unattended keeps in the VM's notes:
# "... Local administrator: <user> / <password>", where the password may be empty
function Get-TestVmCredential {
    param([Microsoft.HyperV.PowerShell.VirtualMachine]$VM)
    if ($VM.Notes -notmatch 'Local administrator: (\S+) / (\S*)') {
        throw "VM '$($VM.Name)' has no administrator in its notes (not made with -Unattended?). Pass -Credential."
    }
    $password = if ($Matches[2]) { ConvertTo-SecureString $Matches[2] -AsPlainText -Force } else { [securestring]::new() }
    [pscredential]::new($Matches[1], $password)
}
