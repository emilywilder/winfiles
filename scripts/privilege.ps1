# Shared by Invoke-AsUser.ps1 and Invoke-AsAdmin.ps1, which dot-source it.
# Test-Elevated says whether this process holds an administrator's elevated token. An unelevated shell and the child of
# `gsudo -i Medium` both answer false: their token has the Administrators group as deny-only (docs/install.md,
# "Running an unelevated step from an elevated shell").
function Test-Elevated {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}
