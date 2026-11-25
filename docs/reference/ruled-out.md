# Ruled out

Approaches that were tried or reasoned through and not taken, so they aren't tried again without a new reason. Each says why, and what would change the answer.

## Finding mise from install.cmd

`install.cmd` reaches the install through `Start-Winfiles.ps1` under 5.1, which reads `PATH` from the registry. These were ruled out (2026-11-16):

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

## mise tasks for the command runner

Tried 2026-11-15 for the install chain, before `winfiles.ps1`, so that the bootstrap wouldn't need `just` (commit 0296919, branch `mise-tasks-trial`). On iris, with nothing applied, arguments and defaults worked, and steps in a `run` array ran in order and stopped at a failure. gsudo under `mise run`, the restart path and a whole install were never tried.

- **Shell:** the default, `cmd /c`, carries on after a failing line, so each task set pwsh.
- **Exit codes:** `mise run` cuts them to the low byte, as `mise exec` does (3010 gives 194).
- **Output:** a failed task prints `ERROR task failed`, a stop for a restart included.
- **Repetition:** each task set its shell, each host value was lowercased where used, and the `Invoke-Clean.ps1` wrapper was repeated. The runner handles the clean environment and privilege from fields in `commands.jsonc` ([dev/tooling.md](../dev/tooling.md#commands)).

Checked: 2026-11-25, iris, mise 2026.11.13, a scratch config (the shell, exit codes, the error line, stopping at a failed step).

Revisit if mise tasks can check requirements, clean the environment and elevate once for a whole run, and first test whether configuration outside the repo reaches the outer `mise run`.

## A module that includes what it depends on

Reasoned 2026-11-24, when modules were allowed to include modules. In Nix, `base` and `dev` could each import `runtimes`, and Nix would merge it once. DSC runs a document each time it's included, so `set` would apply `runtimes` twice, and the flattener refuses an entry that reaches a document twice. So a document that several others need is included once, by the entry, which orders them after it with `dependsOn` (iris's `packages-runtimes.dsc.yaml`). Since 2026-11-25 only entries include at all ([config/layout.md](../config/layout.md)). Revisit if DSC gains a way to include a document once.

## Shared layers of Includes

Tried 2026-11-24, gone by 2026-11-25. As with Nix's `imports`, `core` and `default` documents under `modules/system` and `modules/home`, and a `wsl-host`, only included other modules, so `iris` and `vm` didn't each repeat a module list. A layer ran only from an entry, not on its own. A `dependsOn` on a layer was coarser than one on the module inside it: iris's hardware software waited for all of the system `default`, not only its runtimes. Run by hand, an entry also lost resource messages below `trace` through the two levels (`docs/reference/dsc.md`, "Resource messages and levels"). Now only entries include ([config/layout.md](../config/layout.md#entries)). Revisit if the module lists drift apart.

## List resources for a host's items

Reasoned 2026-11-25, while splitting `dsc/` into modules and hosts. One parameterised module could install any host's packages or distributions if a list parameter (`wingetPackages: [...]`) were passed through `parametersContent` to a resource that takes an array, as `Winfiles/FileContentList` does for files. It keeps to plain DSC and avoids `copy`, but a reader who knows DSC and not winfiles would have to learn the list resources and follow data through parameters to see what a host installs. Each item is written out as its own resource in the host's documents instead ([config/layout.md](../config/layout.md#modules)). Revisit if DSC gains a supported loop.

## A copy loop for WSL distributions

Tried 2026-11-21 and reverted. One parameterised module with a `copy` loop over a list of distributions worked, but DSC deprecates `copy` and warns about it on every run (`docs/reference/dsc.md`, "copy loops"). Each user's distributions are written out instead. Revisit if DSC gains a replacement.

## A dialect of the documents

Documents that only work with winfiles' scripts (options, list merging, `lib.mkIf`, imports merged once) would be shorter, but they would no longer mean what DSC says they mean, which breaks the three tests in `docs/architecture.md`. Revisit if DSC gains what the flat copy works around.

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
