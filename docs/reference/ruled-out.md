# Ruled out

Approaches that were tried or reasoned through and not taken, so they aren't tried again without a new reason. Each says why, and what would change the answer.

## Finding mise from install.cmd

`install.cmd` reaches the install through `Start-Clean.ps1` under 5.1, which reads `PATH` from the registry. These were ruled out (2026-11-16):

- **`install.cmd` starting `Invoke-Clean.ps1` under 5.1.** `-UseNewEnvironment` on 5.1 gives `USERNAME=SYSTEM` and no `USERPROFILE`, and quoting needs pwsh 7.3 (`docs/reference/windows.md`).
- **`install.cmd` calling `pwsh`.** Right after the bootstrap the only pwsh is mise's, and the terminal's `PATH` predates mise, so there is none to find.
- **Relying on the terminal's `PATH` for mise.** Same reason. This is why the launcher reads the registry.

Revisit if the bootstrap can leave mise's pwsh where a `.cmd` can find it.

## A scheduled task for the resume's UAC prompt

Reasoned 2026-11-16; nothing was built. The prompt comes from gsudo in the resumed `winfiles.ps1 install`. RunOnce can't avoid it, since it starts with the unelevated token, and only an elevated process can create a "run with highest privileges" task, which then starts elevated with no prompt.

- **A logon task running the whole resume elevated** doesn't work: `winfiles.ps1 home` would run elevated, and Scoop's installer refuses that.
- **What would work:** the first run's UAC step also registers an on-demand task (no trigger, highest privileges) that runs only the elevated steps. The unelevated RunOnce resume stays and calls `schtasks /run` where `winfiles.ps1 install` would call gsudo, waits, reads the result, and does the rest unelevated. The task is removed when the install finishes or fails.
- **Its costs:** the task's output can't reach the resume window as gsudo's does; a second path through `winfiles.ps1 install` for the resume only; and while the task exists, any unelevated process that can edit the repo's scripts gets admin. Running a copy from `C:\ProgramData\winfiles`, writable only by administrators, would close that, but the copy would drift from the repo.
- **A dedicated program** (reasoned 2026-11-22, with the C# port of the runner in mind, [dev/tooling.md](../dev/tooling.md#not-done-yet)) would answer all three: it could run from a copy in `C:\ProgramData`, check a content hash of the scripts before running them, and pass the output back over a pipe whose ACL admits only the caller. It would still leave the user-writable mise toolchain (pwsh, DSC) running elevated, which a hash of the repo doesn't cover.
- **Why not:** too much machinery for one prompt, which comes after a restart when someone is already at the machine. Unattended runs aren't a priority (2026-11-22).

Revisit if the resume has to run unattended.

## Rust or Go for the command runner

Reasoned 2026-11-22, when `just` was replaced by `winfiles.ps1`. A compiled runner was weighed for a later port. C# is closer to the repo's PowerShell (the same .NET types, and `System.Text.Json` reads `commands.jsonc` as it is) and has first-class Windows APIs for tokens, scheduled tasks and ACLs; Rust and Go would add a second ecosystem for no feature winfiles needs. Revisit if the C# port hits a wall.

## Modules that include each other

Ruled out 2026-11-21. A module's own Include resolves from the document passed to `--file`, so it works from its entry or on its own, never both. Two modules that include the same third one apply it twice, and the flattener refuses the repeated names (`docs/reference/dsc.md`, "Include paths"). Nesting would only work as a tree, and a module couldn't include what it depends on. Entries order modules with `dependsOn` instead. A shared layer that only includes modules would work; it's in `docs/config/layout.md`, "Not done yet".

## A copy loop for WSL distributions

Tried 2026-11-21 and reverted. One parameterised module with a `copy` loop over a list of distributions worked, but DSC deprecates `copy` and warns about it on every run (`docs/reference/dsc.md`, "copy loops"). Each user's distributions are written out instead. Revisit if DSC gains a replacement.

## A dialect of the documents

Documents that only work with winfiles' scripts (options, list merging, `lib.mkIf`, modules that include modules) would be shorter, but they would no longer mean what DSC says they mean, which breaks the three tests in `docs/architecture.md`. Revisit if the repeated module lists start to drift, or if DSC gains what the flat copy works around.

## Starting wsl.exe in a new console

`start /wait` in a new console worked around the inbox `wsl.exe` refusing a piped stdin, but opened a window and didn't pass on the exit code (`exit /b 7` came back as 0 on iris, 2026-11-18). `<con` is used instead (`docs/reference/wsl.md`).

## Microsoft.PowerShell/Profile

Its `get` is broken (`docs/reference/powershell.md`), so the profile stubs are written by `Winfiles/FileContentList`.

## Microsoft.Windows/Registry for the computer name

It skips the TCP/IP hostname and `Rename-Computer`'s validation (`docs/reference/windows.md`, "Renaming the computer").

## Class-based PowerShell resources

Reasoned 2026-11-21 from the DSC Community's [first class-based DSC v3 resource](https://dsccommunity.org/blog/your-first-class-based-microsoft-dsc-v3-resource/) (2025-07-28); nothing was built. A `[DscResource()]` class in a module on `PSModulePath`, with `Get`, `Test`, `Set` and optionally a static `Export`, runs through the `Microsoft.DSC/PowerShell` adapter as `<Module>/<Class>`, nested under the adapter or named directly.

- **For:** one class could also serve PSDSC, and its methods could be tested in-process.
- **Against:** the adapter has to find each resource through the PowerShell engine, slowly on a first run with nothing cached, on top of the discovery cost DSC already has (`docs/reference/dsc.md`, "Discovery"); `Write-Verbose`, `Write-Warning` and `Write-Debug` in a method broke DSC's JSON parsing (PowerShell/DSC#833, open as of the post); a changed class can't be reloaded in a session; and the exit codes and stderr messages the `Winfiles/*` resources rely on are the adapter's, not the resource's.

Command resources are used instead (`docs/dev/writing-resources.md`). Revisit if a resource is to be published for others, or the adapter's cost is measured and turns out small.

## runas /trustlevel as "unelevated"

`runas /trustlevel:0x20000` leaves the integrity level High, gives no exit code, and doesn't wait for the child (`docs/reference/windows.md`, "Dropping privilege from an elevated shell"). `gsudo -i Medium` is used instead.
