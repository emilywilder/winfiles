# What a run says

What a run does when something fails, and where it records what happened: the console, DSC's results and `run.log`.

## Failures

- **A failure stops the run** where it happens, before `check`. A resource that fails exits non-zero, DSC stops the batch, and `Set-Winfiles.ps1` names the batch.
- **A winget package that fails** stops its batch, with winget's code in the error. Each winget package is a resource of its own, so one bad id can't hide the ids after it.

`winfiles.ps1` prints nothing of its own when a script fails, and exits with its code. A stop for a restart shows only the script's warning, and `Set-Winfiles.ps1` prints a failure itself, so a line from the runner would only repeat it.

Trade-off: `check` adds about 80s to a run on iris ([benchmarks](../benchmarks.md#check)), for one list of what's missing. Revisit if `check` becomes slow enough to skip.

## DSC's results

Each `set` and `check` writes DSC's JSON results, with each resource's duration, to `~/.local/state/winfiles/dsc/<time>-<set|test>-<document>.json`. They're outside the repo because `winfiles.ps1 test-vm-copy` replaces the repo. Nothing removes them, and `winfiles.ps1 dsc` doesn't write them.

## The console and run.log

The console gets only what the person needs: failures, warnings, what a `set` left missing, and `check`'s results. Progress goes only to `~/.local/state/winfiles/run.log`, through `Write-WinfilesLog` (`scripts/winlog.ps1`, 5.1-compatible), as timed `[phase] message` lines. `winfiles.ps1 test-vm-log` follows it. It's the one record of a whole install across its restarts, and nothing removes it.

| Phase | Written by | What |
|---|---|---|
| `bootstrap` | `Initialize-Winfiles.ps1` | its steps, then "done" |
| `install` | `winfiles.ps1` (`log` in `commands.jsonc`) | `started`; `finished` only when the configurations and `check` all passed |
| `apply`, `system`, `home`, `restart` | `Invoke-Configuration.ps1`, `Find-RestartResource.ps1`, `Set-RestartStage.ps1`, `Set-Winfiles.ps1`, `restart.ps1` | what will need a restart, "applying <document>", "done in 3m12s, 41 resources", what a list left missing, "dsc failed with exit code N", the restart |
| `check` | `Test-Winfiles.ps1` | the totals |
| `privilege` | `Invoke-AsAdmin.ps1`, `Invoke-AsUser.ps1` | "asking for UAC" before a prompt; gsudo's exit code and time after it |
| `resume` | `Invoke-Install.ps1`, `Resume-Winfiles.ps1` | the RunOnce entry registered, kept or removed; resumed after sign-in, Enter pressed, winget's source not reached, the exit code |
| `wsl`, `winget` | `Winfiles.Wsl/Wsl`, `Winfiles.WinGet/Package` | `wsl.exe`'s arguments, output and exit code; a failed winget call's package id, operation and HRESULT |

Reading the log:
- **Only the log says an install finished;** the console doesn't. Revisit if someone running `install.cmd` by hand wants that line.
- **No "kept" line after a restart.** When the run restarts Windows itself, the shutdown ends `Invoke-Install.ps1` before the run returns. So a restart line is followed straight by "resumed after sign-in", and the last "asking for UAC" before it has no line for gsudo's exit code.
- **Counts come from DSC's JSON.** An Include's `set` result nests its resources under `afterState`, unlike `test`, so `dsclog.ps1` reads both shapes ([reference](../reference/dsc.md#include-result-shapes)).

What dsc prints on stderr, including its `ERROR` line for a failed resource, goes to the console only, since capturing stderr would lose the progress bar ([reference](../reference/dsc.md#the-progress-bar)). So a resource that can fail has to write its own failure to the log. `Winfiles.Wsl/Wsl` and `Winfiles.WinGet/Package` do; the Scoop, file and registry resources don't yet.

Trade-off: the events come from the scripts around DSC, not from inside it, so the log shows nothing between "applying" and "done" for a long `home`. Revisit with resource-level events (below).

## Not done yet

- **Other resources writing their failures to `run.log`.** The Scoop resources, the file list and the registry resources don't. Do it when one of their failures is as hard to find as the winget one was.
- **Resource-level events** at the default level (which document, which package or distribution is installing) and the full output at a `debug` level. Researched 2026-11-16 from the code and `demos/dsc-messages`, not tried. Today no resource says anything at the default `warn` level unless it fails, and the progress bar names the resource it's on ([reference](../reference/dsc.md#resource-messages-and-levels), [reference/winget.md](../reference/winget.md)).
  - The way to try: run `set` with `-l info --trace-format json`, have `Set-Winfiles.ps1` read stderr and show only winfiles' events and DSC's "Invoking set" lines, and pass everything through at `debug`.
  - Risks to settle first: redirecting stderr may stop the progress bar, which needs stderr to be a console; the parser has to cope with the `PID <dsc>: ` prefix; and `Invoke-Clean.ps1` clears the environment and `install.cmd` passes only `host user`, so a `debug` switch needs a route of its own.
  - Fallback: keep the `warn` labels and have resources write to `run.log` themselves. mise isn't worth events.

  Worth doing when a real `install` shows which gaps get in the way.
