# The test VM

How the test VM behaves, and what full runs in it have confirmed. How to use it is in `docs/testing.md`; timings of the runs are in `docs/benchmarks.md`.

## PowerShell Direct

A PowerShell Direct session is elevated (High, four enabled privileges, administrator) and non-interactive (session 0). So `bootstrap.cmd` refuses to run there ("This is an elevated shell"), Scoop's installer would refuse, and a gsudo prompt would never show.

A scheduled task in the VM for its user, with Interactive logon and run level Limited, gives a Medium-integrity process in the signed-in session, even a disconnected one. UAC prompts from it still show on the VM's desktop and wait for a click, and the resume still needs someone to sign in and press Enter. So it saves the typing and returns the output, but doesn't make a run unattended. It's `just test-vm-unelevated`.

- Checked: 2026-11-18, `winfiles-test` from `updated`, build 26300.

## Automatic sign-in

A VM made with `New-TestVm.ps1 -Unattended` signs in by itself at every boot. So after a restart, the resume window opens with nobody necessarily watching (`docs/reference/windows.md`, "An unanswered UAC prompt").

## What full runs have confirmed

What winfiles' own install chain did in real runs, which Pester can't show. All from the `updated` checkpoint, `vm-quick` unless stated.

- 2026-11-16: the RunOnce entry fired at sign-in and the install continued. The restart's exit code reached `Invoke-Install.ps1` through `just`, `mise exec` and `Invoke-Clean.ps1` as 194. The resume window started in the repo.
- 2026-11-16: two restarts in one install. One-shot hooks were added to the VM's copy of the scripts, because a clean install restarts only once. A resumed run that hit a second restart was resumed again, the last one finished, RunOnce was empty afterwards, and `just check` passed.
- 2026-11-16: `Start-Clean.ps1` found mise both in the bootstrap's terminal and in the resume window after the restart.
- 2026-11-18: `just install` elevated once per start (two `asking for UAC` lines in `run.log`: the first start and the resume), with the restart and resume working through the second `just`. `home` installed Alpine through the `gsudo -i Medium` hop. RunOnce was removed with exit code 0.
- 2026-11-18: a WSL at 2.3.26 was found below 2.4.4 and updated to 3.0.5 by `Winfiles/Wsl`. The install went on to a green `check`.
- 2026-11-18: the rename was pending (`pendingName` `VM-QUICK`, `activeName` `WINFILES-TEST`) until the restart, and `check` found it in its desired state afterwards.
- 2026-11-19: through the batches, the discovery test found `Winfiles/Wsl` and `Winfiles/ComputerName`. The batches were made again as `elevated/restart x3, elevated x11, user x14`, with the features pulled in through `dependsOn`. One UAC prompt for the run, and `check` passed with all 28 resources.
- 2026-11-19, `vm`: the same through the batches, 57 elevated and 53 user resources. The user batch stopped once on winget's `0x80071130` (`docs/reference/winget.md`); the rerun passed with all 110.
- Not yet seen: the check after an ordinary elevated batch finding a restart pending; `iris` through the batches.
