# Installed by hand

`dsc/hosts/<host>/manual.yaml` lists what a host needs that can't be installed unattended, each with why. `winfiles.ps1 manual [host]` (`scripts/Get-ManualInstaller.ps1`):
- finds what's missing from the display names in the Uninstall registry keys;
- downloads it to `~/.cache/winfiles/manual` with `winget download`, which checks the manifest's hash;
- never runs an installer.

It's outside DSC, so `winfiles.ps1 check` still means what winfiles can apply by itself. An entry can move to an ordinary list if its installer turns out to work unattended. The list is read with `yq`, since PowerShell has no YAML parser. The list goes with the host and can't be included like a document, so a new host has to copy the entries it wants, such as LyX and Battle.net, even if it includes another host's package documents. `vm` has no list.

The TeX engine is Tectonic, from Scoop, in `hosts/iris/home/packages-productivity.dsc.yaml`, and LyX works with it ([reference](../reference/apps.md#lyx-and-tectonic)). Trade-off: a small engine winfiles can install unattended, rather than a full distribution it can't. Revisit if something needs a full LaTeX distribution.
