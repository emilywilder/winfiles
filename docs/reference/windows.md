# Windows, PowerShell and the run's tools

How Windows, Windows PowerShell 5.1, pwsh, mise, gsudo and (until 2026-11-22, when winfiles stopped using it) just behaved when checked, and what in winfiles relies on it.

## cmd.exe and LF line endings

cmd.exe misreads batch files with LF line endings, so `.gitattributes` keeps every `.cmd` CRLF, and a test checks it. A `.cmd` runs whatever the execution policy, which blocks `.ps1` scripts on a fresh install.

## Start-Process -UseNewEnvironment

- pwsh builds the new environment with `CreateEnvironmentBlock` from 7.1 (read in the source), from the registry and the logon session. So a caller's changed `USERNAME` or `USERPROFILE` doesn't reach the child.
- On 5.1 the same switch gives `USERNAME=SYSTEM` and no `USERPROFILE`.
- Quotes inside arguments pass correctly from pwsh 7.3.
- `-UseNewEnvironment` ignores `-Environment`, and `Start-Process` joins arguments without quoting them.

Used by: `Invoke-Clean.ps1`, which needs pwsh 7.3 and runs the command through `pwsh -ExecutionPolicy Bypass -EncodedCommand`.

## Windows PowerShell 5.1 passing arguments

- 5.1 mangles double quotes inside arguments it passes to another program, such as pwsh.
- A 5.1 script that takes pass-through arguments (`ValueFromRemainingArguments`) and another parameter needs `[CmdletBinding(PositionalBinding = $false)]`. Without it, 5.1 binds positional arguments to the other parameters first: `Invoke-Install.ps1`'s host (the script is gone) went to `-RunOnceKey` and created a file named after the host (found 2026-11-16).

## RemoteSigned and the mark of the web

mise's pwsh defaults to RemoteSigned, which refuses a script with a mark of the web, as a repo from a downloaded ZIP would have.

- Checked: 2026-11-04, with a marked script.
- Used by: `Invoke-Clean.ps1` runs its command with `-ExecutionPolicy Bypass`.

## mise exec and exit codes

`mise exec` cuts a child's exit code to its low byte: a child that exits 3010 gives 194 (`mise exec -- pwsh -c 'exit 3010'`). `Invoke-Clean.ps1` passes it on unchanged, and so does `winfiles.ps1` (`tests/scripts/Commands.Tests.ps1`).

- Checked: 2026-11-16, then through `just`, with a throwaway justfile that nested a recipe the way `install` called `system`. gsudo wasn't in that path; that it passes the code on is known from test VM runs.
- Used by: `Invoke-Configuration.ps1` takes both as a stop for a restart, since a restart that crosses `Invoke-AsAdmin.ps1` reaches it as 194 from an unelevated shell and as 3010 from an elevated one.

A scheduled task's result `0x40010004` came out of `just` as 4 (2026-11-18), for the same reason. `scripts/testvm.ps1` reports it as the restart it was, for `winfiles.ps1 test-vm-unelevated`.

## ConvertFrom-Json and comments

pwsh's `ConvertFrom-Json` skips `//` and `/* */` comments, so a JSONC file reads without a parser of its own.

- Checked: 2026-11-22, on iris, with pwsh 7.7.0, both the one on `PATH` and mise's.
- Used by: `scripts/commands.ps1`, which reads `commands.jsonc`.

## mise configuration files

- Without `MISE_IGNORED_CONFIG_PATHS`, the global `~\.config\mise\config.toml`, a `mise.local.toml`, or a `mise.toml` in a parent folder adds its tools and env to a run. A global config's tools were even installed (checked 2026-11-15).
- The variable takes a `;`-separated list. `,` doesn't work.

Used by: `scripts/miseignore.ps1`.

## RunOnce

- Windows deletes a RunOnce value before running it. A name starting with `!` would make it delete the value only after the command succeeds; winfiles' doesn't use `!`.
- RunOnce commands are limited to 260 characters.
- RunOnce starts the command in `C:\Windows\System32` (checked 2026-11-16, test VM).
- HKCU and HKLM RunOnce both start with the unelevated token.
- Not checked: whether Explorer waits for RunOnce commands before finishing startup.

Used by: `scripts/resume.ps1`.

## An unanswered UAC prompt

Windows cancels a UAC prompt that nobody answers. gsudo then reports `The operation was canceled by the user.`, and `install.cmd` exited 231.

- Seen: 2026-11-17, test VM, when a resumed run asked for UAC straight after the automatic sign-in.
- Used by: the resume waits for Enter before it starts the install.

## Dropping privilege from an elevated shell

Three ways for an elevated pwsh to start an unelevated child. Checked 2026-11-18 on iris (Windows 11 10.0.26300, UAC on, signed in at the console), with probe scripts that weren't kept:

| | `runas /trustlevel:0x20000 <command>` | Scheduled task, Interactive logon, run level Limited | `gsudo -i Medium --direct <command>` (gsudo 2.6.1) |
|---|---|---|---|
| Integrity level | High, like the elevated parent | Medium, like a normal shell | Medium, like a normal shell |
| `IsInRole(Administrator)` | false | false | false |
| Administrators SID | deny-only | deny-only | deny-only |
| Enabled privileges | 1 | 1 | 1 |
| Write to HKLM / HKCU | no / yes | no / yes | no / yes |
| User, session, `%USERPROFILE%` | the parent's | the parent's | the parent's |
| Exit code back to the caller | no | yes (`LastTaskResult`) | yes |
| Waits for the child | no (returned after about 1.6s) | poll `Get-ScheduledTask` until `Ready` | yes |
| Output | none | none: a task has no console | on the parent's console |
| Cost | about 1.6s | about 1.6–2.6s with register and unregister | about 2s for a trivial pwsh child |

- `runas /trustlevel` strips the elevated token's power but leaves the integrity level High, so integrity checks, UIPI, COM and Explorer may treat the child differently from a normal unelevated process.
- The Limited task gets the user's own filtered token from the logon session, but has no console. A handoff built on it would register a uniquely named task, run `pwsh -File <script>` hidden, poll until `Ready`, read `LastTaskResult`, and unregister it in a `finally`.
- `gsudo -i Medium --direct` gives the same token as a normal shell by every measure above and keeps the caller's console, so DSC's progress bar still draws.

In the test VM over PowerShell Direct (elevated, session 0, 2026-11-18, gsudo 2.6.1, winget 1.29.380), `gsudo -i Medium --direct powershell.exe ...` gave a Medium, non-administrator child. In it, Scoop's installer ran, `scoop install git` installed 7zip and git with the Scoop folder owned by the user, and `winget install --id GitHub.cli --scope user` succeeded.

Not checked: the token's elevation type against a normal shell's; running with nobody signed in or from a remote session; who owns files the child creates outside `~\scoop`.

Used by: `Invoke-AsUser.ps1` (gsudo); the Limited task, for `winfiles.ps1 test-vm-unelevated` (`docs/reference/test-vm.md`).

## A param() block on the privilege helpers

With a `param()` block, a command's own `-Out` argument was matched to PowerShell's `-OutVariable` and `-OutBuffer` and failed as ambiguous. So `Invoke-AsAdmin.ps1` and `Invoke-AsUser.ps1` have no `param()`.

- Found: 2026-11-18, running `Invoke-Clean.ps1` to `gsudo -i Medium` from an elevated pwsh.

## Installers and a pending restart

Some installers refuse to run while `Component Based Servicing\RebootPending` is set, whatever set it. `Microsoft.DotNet.Framework.DeveloperPack.4.6` has a "RebootPending = 0" bundle condition (seen in the test VM, 2026-10-29). Windows Update sets the same key, so a run stops for a restart Windows Update is waiting on.

## Restart-Computer on a locked screen

Without `-Force`, `Restart-Computer` fails on a locked screen with "The machine is locked and cannot be shut down without the force option". An app with unsaved work can also stop it.

- Seen: 2026-11-15, test VM, whose screen locked while a run was left unattended.
- Used by: `scripts/restart.ps1` warns "Restarting failed (...)" and still exits 3010.

## Renaming the computer

Windows applies a rename at the next restart: `ComputerName` holds the pending name and `ActiveComputerName` the current one. `Microsoft.Windows/Registry` could write the names, but it would skip the TCP/IP hostname and the validation that `Rename-Computer` does. DSC 3.3.0 has no computer resource that was found.

- Used by: `Winfiles/ComputerName`.

## Files an elevated run creates

The flat copies written by an elevated run (`~/.local/state/winfiles/flat`) are owned by Administrators, while `~/.local/state/winfiles` and `run.log` belong to the user. An unelevated `check` could still rewrite its copies there.

- Seen: 2026-11-18, test VM.
