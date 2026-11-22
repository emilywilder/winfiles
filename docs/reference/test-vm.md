# The test VM

How the test VM behaves, and what full runs in it have confirmed. How to use it is in `docs/dev/test-vm.md`; timings of the runs are in `docs/benchmarks.md`.

## PowerShell Direct

A PowerShell Direct session is elevated (High, four enabled privileges, administrator) and non-interactive (session 0). So `bootstrap.cmd` refuses to run there ("This is an elevated shell"), Scoop's installer would refuse, and a gsudo prompt would never show.

A scheduled task in the VM for its user, with Interactive logon and run level Limited, gives a Medium-integrity process in the signed-in session, even a disconnected one. UAC prompts from it still show on the VM's desktop and wait for a click, and the resume still needs someone to sign in and press Enter. So it saves the typing and returns the output, but doesn't make a run unattended. It's `just test-vm-unelevated`.

- Checked: 2026-11-18, `winfiles-test` from `updated`, build 26300.

## Windows Sandbox

Windows Sandbox doesn't expose virtualization to its guest, so WSL 2 can't run there, and it has no Store or winget. So clean installs are tested in a Hyper-V VM with nested virtualization instead.

## Automatic sign-in and the blank password

A VM made with `New-TestVm.ps1 -Unattended` signs in by itself at every boot. So after a restart, the resume window opens with nobody necessarily watching (`docs/reference/windows.md`, "An unanswered UAC prompt").

Its local administrator has a blank password. The specialize pass sets `LimitBlankPasswordUse` to 0, which by default limits blank passwords to the console. With that:
- a basic `vmconnect` session opens on the desktop;
- an enhanced session signs in with one click on **Sign in**;
- PowerShell Direct needs no password;
- a restart comes back by itself in either kind of session.

Checked 2026-10-29 on build 26300. It replaced a generated password kept in the VM's notes, which every sign-in through an enhanced session made you type. A blank-password administrator that accepts remote sign-ins is acceptable only because the VM is a throwaway behind the Default Switch's NAT; never do this on a real machine.

## Other VM details

- The VM's notes record the administrator as `Local administrator: <user> / `, with nothing after the slash. `scripts/testvm.ps1` reads them for the PowerShell Direct scripts.
- The screen is fixed at 1920×1080 for basic `vmconnect` sessions. An enhanced session (Remote Desktop over VMBus, with a shared clipboard) sizes it to the window.
- The VM has no sleep states (`powercfg /a`), so it never asks to sign in on wake.
- Setup rejects a computer name longer than 15 characters at first boot, so `New-TestVm.ps1` checks it up front. Pass `-ComputerName` for a longer `-Name`.
- The VM stays unactivated, which doesn't affect winfiles.

## Following logs in the VM

How `just test-vm-log` (`scripts/Watch-TestVmLog.ps1`) copes with the logs it follows. Most of this is covered by `tests/scripts/Watch-TestVmLog.Tests.ps1`, which runs the watch scriptblock under `powershell.exe` against scratch logs, without a VM.

- **Encodings.** The bootstrap's lines are written by Windows PowerShell 5.1 (ANSI), and the install's by pwsh (UTF-8 without a mark). `run.log` is read as UTF-8, which is only right while the lines stay ASCII. For other files, the encoding comes from the byte order mark: UTF-16 either way, or UTF-8 with or without one.
- **Large files.** The watch keeps a byte offset per file, so a large MSI log isn't reread. A file that existed before the start shows its last `-Tail` lines, read from its last 64KB only.
- **Directory listings lag.** A listing can lag behind a writer that keeps its handle open, so each followed file is opened on every poll.
- **Wildcard paths.** winget's `DiagOutputDir` has a wildcard in the middle of its path. That makes `Get-ChildItem` list the matching folder itself rather than its files, so the path is resolved first. This was missed while every test passed a literal folder; the watch showed nothing in a real run (2026-11-16), and a test now covers it.
- **5.1 in the guest.** The watch scriptblock runs under 5.1 in the VM, and PowerShell Direct sends only the scriptblock, so the functions it uses are defined inside it.
- **Reconnecting.** Once following, a guest restart reconnects and prints a green `Reconnected to '<name>', following again.`; a stopped VM ends it with a warning. The reconnect was seen working on 2026-11-16. Not yet checked in a real run: the colours, and a paused VM. A paused VM isn't `Running`, so the watch either warns "VM '...' stopped (state: Paused)." and exits, or hangs with nothing printed, since the heartbeat runs in the guest. Restart `just test-vm-log` after resuming a VM.
- **UAC.** It asks for UAC, because `Get-VM` is denied otherwise (on iris, the user isn't in Hyper-V Administrators).
- **Not yet checked in a real run** (as of 2026-11-16): that `run.log` is where the signed-in administrator's `~` points in the VM.

## What full runs have confirmed

What winfiles' own install chain did in real runs, which Pester can't show. All from the `updated` checkpoint, `vm-quick` unless stated.

- 2026-11-16: the RunOnce entry fired at sign-in and the install continued. The restart's exit code reached `Invoke-Install.ps1` through `just`, `mise exec` and `Invoke-Clean.ps1` as 194. The resume window started in the repo.
- 2026-11-16: two restarts in one install. One-shot hooks were added to the VM's copy of the scripts, because a clean install restarts only once. A resumed run that hit a second restart was resumed again, the last one finished, RunOnce was empty afterwards, and `just check` passed.
- 2026-11-16: `Start-Clean.ps1` found mise both in the bootstrap's terminal and in the resume window after the restart.
- 2026-11-18: `just install` elevated once per start (two `asking for UAC` lines in `run.log`: the first start and the resume), with the restart and resume working through the second `just`. `home` installed Alpine through the `gsudo -i Medium` hop. RunOnce was removed with exit code 0.
- 2026-11-18: a WSL at 2.3.26 was found below 2.4.4 and updated to 3.0.5 by `Winfiles.Wsl/Wsl`. The install went on to a green `check`.
- 2026-11-18: the rename was pending (`pendingName` `VM-QUICK`, `activeName` `WINFILES-TEST`) until the restart, and `check` found it in its desired state afterwards.
- 2026-11-19: through the batches, the discovery test found `Winfiles.Wsl/Wsl` and `Winfiles/ComputerName`. The batches were made again as `elevated/restart x3, elevated x11, user x14`, with the features pulled in through `dependsOn`. One UAC prompt for the run, and `check` passed with all 28 resources.
- 2026-11-19, `vm`: the same through the batches, 57 elevated and 53 user resources. The user batch stopped once on winget's `0x80071130` (`docs/reference/winget.md`); the rerun passed with all 110.
- 2026-11-22, commit 5735f69: the first run through `winfiles.ps1` (`install.cmd` → `Start-Clean.ps1` → `winfiles.ps1 --clean install`). The bootstrap's `winfiles.ps1 hosts` check passed. One UAC prompt per start, each running `winfiles.ps1 --run install vm-quick emily`; the restart stage, the RunOnce resume, both batches and the `gsudo -i Medium` hop worked as under `just`, and `check` passed with all 35 resources. RunOnce was removed with exit code 0. The first start's `kept the RunOnce entry` line is missing: the restart, 10 seconds after the stage finished, came before `Invoke-Install.ps1` wrote it, so this run doesn't show which exit code reached it. The entry was written before the run, and fired.
- Not yet seen: the check after an ordinary elevated batch finding a restart pending; `iris` through the batches; the restart's exit code reaching `Invoke-Install.ps1` through `winfiles.ps1`.
