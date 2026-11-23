# Installed by hand

`dsc/hosts/<host>/manual.yaml` lists what a host needs that can't be installed unattended, each with why. `winfiles.ps1 manual [host]` (`scripts/Get-ManualInstaller.ps1`):
- finds what's missing from the display names in the Uninstall registry keys;
- downloads it to `~/.cache/winfiles/manual` with `winget download`, which checks the manifest's hash;
- never runs an installer.

It's outside DSC, so `winfiles.ps1 check` still means what winfiles can apply by itself. An entry can move to an ordinary list if its installer turns out to work unattended. The list is read with `yq`, since PowerShell has no YAML parser. The list goes with the host, so a new host has to copy entries such as LyX and Battle.net that would otherwise belong to shared modules.

The TeX engine is Tectonic, from Scoop, in `modules/home/productivity.dsc.yaml`, and LyX works with it ([reference](../reference/apps.md#lyx-and-tectonic)). Trade-off: a small engine winfiles can install unattended, rather than a full distribution it can't. Revisit if something needs a full LaTeX distribution.
