# Code page

`Winfiles/CodePage` in `dsc/modules/system/settings.dsc.yaml` makes UTF-8 (65001) the system code page, which is Settings' "Beta: Use Unicode UTF-8 for worldwide language support" ([Eleven Forum's guide](https://www.elevenforum.com/t/enable-or-disable-unicode-utf-8-for-worldwide-language-support-in-windows-11.38649/)). Legacy non-Unicode apps and consoles then read and write UTF-8.

- The setting is three string values, `ACP`, `OEMCP` and `MACCP`, under `HKLM\SYSTEM\CurrentControlSet\Control\Nls\CodePage`. Windows reads them at boot, so the resource compares them (what the next restart will use) with `GetACP` and `GetOEMCP` (what the running system uses). `test` is in the desired state only once both match. There is no API for the active Mac code page, so only the registry value is checked.
- Every operation reports `_restartRequired` while the active code pages aren't the wanted ones, so the run applies it with the features, WSL and the rename, and restarts once ([run/restarts.md](../run/restarts.md)). `winfiles.ps1 check` fails until that restart.
- `utf8: false` writes the code pages the system locale defaults to (`GetLocaleInfoEx` on the system default locale: 1252, 437 and 10000 for en-US) instead of a table of them, since they differ by locale ([reference](../reference/windows.md#utf-8-as-the-system-code-page)). A document that doesn't list the resource leaves the values as they are.
- It's a resource, not `Microsoft.Windows/RegistryList`, which could write the values but can't report a restart, so the run would never restart for it.

Trade-off: legacy apps that assume the old ANSI code page, and files they wrote in it, may show garbled text. Revisit if one does.
