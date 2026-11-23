# Shared by Invoke-AsUser.ps1, Invoke-AsAdmin.ps1 and dsc/resources/scoop.ps1 (Winfiles.Scoop/Scoop), which
# dot-source it.


function Test-Elevated {
    <#
    .SYNOPSIS
    Tests whether this process holds an administrator's elevated token.

    .DESCRIPTION
    An unelevated shell and the child of `gsudo -i Medium` both answer false: their token has the Administrators
    group as deny-only (docs/reference/windows.md, "Dropping privilege from an elevated shell").
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
