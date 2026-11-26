# Privilege

Which parts of a run are elevated, and how winfiles moves between levels. Which resources need which level is declared in the documents ([flat-configuration.md](flat-configuration.md#how-it-works)); this doc covers the processes.

## One prompt, at the start

The whole of a `switch` is elevated once, at its start. `winfiles.ps1` runs itself again through `Invoke-AsAdmin.ps1`, as `winfiles.ps1 --run switch <host> <user>`, which runs the steps with no further check of privilege. It does this after checking that the configurations exist, so a wrong host name never reaches the prompt. A restart then comes, or is asked for, while someone is watching, and nothing after the prompt needs attention.

Plain `winfiles.ps1 system` and `winfiles.ps1 check` elevate the same way, around their whole run, so from an unelevated shell they ask once too (`check` on iris, 2026-11-22); `winfiles.ps1 home` never asks. `check` is elevated because the optional features need elevation even for `get`.

## Dropping back

`Invoke-AsUser.ps1` drops to unelevated with `gsudo -i Medium --direct`. That gives the same token as a normal unelevated shell, and keeps the caller's console, so DSC's progress bar still draws ([reference](../reference/windows.md#dropping-privilege-from-an-elevated-shell)). Each unelevated batch of a run goes through it; Scoop's installer, in the first one, refuses an elevated shell.

Both helpers use gsudo only when the shell's privilege differs from the one asked for. No command calls gsudo directly. Tests override them with `WINFILES_ELEVATED` and `WINFILES_GSUDO`. `Winfiles.Scoop/Scoop` reads `WINFILES_ELEVATED` too, through the same `Test-Elevated` (`scripts/privilege.ps1`), for its refusal to run Scoop's installer elevated.

## Trade-offs

- The elevated run is one more `winfiles.ps1` process deep, and mise, DSC's downloads and git clones run elevated for the whole install. Some files it creates, such as the flat copies, are owned by Administrators ([reference](../reference/windows.md#files-an-elevated-run-creates)). Revisit if either matters.
- gsudo's credential cache (`gsudo cache on`) isn't used: a run elevates once, in one process, so the cache would save no prompt. Revisit if a run comes to need more than one.
