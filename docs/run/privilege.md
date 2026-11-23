# Privilege

Which parts of a run are elevated, and how winfiles moves between levels. Which resources need which level is declared in the documents ([flat-configuration.md](flat-configuration.md#how-it-works)); this doc covers the processes.

## One prompt, at the start

The whole install is elevated once, at its start. `winfiles.ps1` runs itself again through `Invoke-AsAdmin.ps1`, as `winfiles.ps1 --run install <host> <user>`, which runs the steps with no further check of privilege. It does this after checking that the configurations exist, so a wrong host name never reaches the prompt. (`just install` does the same with a private recipe, `install-steps`, in a second `just`, until the justfile goes.) The restart then comes while someone is watching, and nothing after the prompt needs attention.

Plain `just system` and `just check` elevate the same way, around their whole run; `just home` never asks. `check` is elevated because the optional features need elevation even for `get`.

## Dropping back

`Invoke-AsUser.ps1` drops to unelevated with `gsudo -i Medium --direct`. That gives the same token as a normal unelevated shell, and keeps the caller's console, so DSC's progress bar still draws ([reference](../reference/windows.md#dropping-privilege-from-an-elevated-shell)). Each unelevated batch of a run goes through it; Scoop's installer, in the first one, refuses an elevated shell.

Both helpers use gsudo only when the shell's privilege differs from the one asked for. No command calls gsudo directly. Tests override them with `WINFILES_ELEVATED` and `WINFILES_GSUDO`. `Winfiles.Scoop/Scoop` reads `WINFILES_ELEVATED` too, through the same `Test-Elevated` (`scripts/privilege.ps1`), for its refusal to run Scoop's installer elevated.

## Trade-offs

- The elevated run is one more `just` and pwsh process deep, and mise, DSC's downloads and git clones run elevated for the whole install. Some files it creates, such as the flat copies, are owned by Administrators ([reference](../reference/windows.md#files-an-elevated-run-creates)). Revisit if either matters.
- gsudo's credential cache (`gsudo cache on`) isn't used: just runs each recipe line in its own process, and the cache's per-process scope hasn't been checked against that.

## Not done yet

- **How many UAC prompts `just system` and `just check` give from an unelevated shell.** `just install` gives one (checked in the VM); whether gsudo prompts once or per elevated batch from a plain terminal is unchecked.
