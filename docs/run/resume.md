# Continuing after a restart

`winfiles.ps1 switch --restart`, which is what `install.cmd` runs, picks the run up again at the next sign-in, through a per-user `RunOnce` entry, so a clean install doesn't wait for someone to notice the restart. Why a run restarts is in [restarts.md](restarts.md). Without `--restart`, and after any other command, nothing is armed: the run never restarts Windows itself, and the person restarts and runs it again.

## Arming the entry

A command that is `resumable` in `commands.jsonc` names the flag that lets it continue after a restart: `switch`'s `--restart`. The entry is armed late, only by a run that is about to restart or ask for one:

1. **The run starts.** `winfiles.ps1` clears an entry an earlier run left (`Clear-Resume`), flag or not, since this run decides for itself whether to restart. It does that once, in the unelevated run that started it.
2. **The steps get the arguments.** With the flag, where the steps run (after any change of privilege), `winfiles.ps1` sets `WINFILES_RESUME` to the command's arguments as a JSON array, defaults included: a default such as the computer's name can change before the resume, with the rename that restarts. Without it (`switch` alone, `system`), nothing is armed, and `Restart-Windows` stops the run for the person instead of restarting ([restarts.md](restarts.md#what-counts-as-pending)).
3. **A run that stops for a restart arms it.** `Exit-RestartPending` and `Restart-Windows` in `scripts/restart.ps1` call `Register-Resume` (`scripts/resume.ps1`) before they exit 3010. `Restart-Windows` does it after its 10-second countdown and before `Restart-Computer`, so Ctrl+C leaves no entry, and the shutdown can't beat the write.

Windows deletes a RunOnce value before running it, and the name has no `!`, so a resume never removes its own entry, and one that fails isn't retried at every sign-in ([reference](../reference/windows.md#runonce)). Declining UAC, or any failure, ends the chain. The value is:

```
cmd.exe /c start "winfiles" /D <repo> powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit -File <repo>\scripts\Start-Winfiles.ps1 resume <args>
```

- It opens whichever terminal Windows defaults to, so nothing depends on `wt.exe`, which the home configuration only installs later. `start` returns at once, and `/D` leaves the window, which stays open (`-NoExit`), in the repo: RunOnce starts it in System32.
- `<args>` are `switch`'s host and user. The command line is the same one `install.cmd` goes through, so the resume finds mise, and runs in a clean environment, as an install does ([clean-environment.md](clean-environment.md)).
- A command over RunOnce's 260 characters only gets a warning and a line in `run.log`, and the install goes ahead without the resume.

## The resume command

`winfiles.ps1 resume <host> <user>` is two steps, in the order `commands.jsonc` gives:
1. **`wait-resume`** (`scripts/Wait-Resume.ps1`):
   1. Stops with 3010, before UAC, if `RebootPending` is still set.
   2. Waits for Enter.
   3. Waits up to 60s for `cdn.winget.microsoft.com:443`, since Wi-Fi can still be connecting at sign-in, then goes ahead anyway.
2. **`switch <host> <user> --restart`**, as `install.cmd` runs it. It arms the entry again if it stops for another restart.

It waits for Enter because a sign-in doesn't mean someone is at the machine. The test VM signs in by itself, and Windows cancels a UAC prompt that nobody answers, which ends the chain ([reference](../reference/windows.md#an-unanswered-uac-prompt)).

## Trade-offs

- Restarting and resuming is opt-in. `switch` on its own leaves the restart to the person, who runs it again afterwards; `install.cmd` passes `--restart`, since a fresh install is the run that needs a restart and has nothing open to lose. Revisit if day-to-day runs come to need restarts often.

- A restart the run doesn't start itself (Windows Update's, or the person's own) leaves no entry, unless the run stopped for it with 3010. Revisit if installs end that way.
- Arming is a duty of each way a run stops for a restart, which today is the two functions in `restart.ps1`. A new way to stop that doesn't call `Register-Resume` loses the resume without saying so; `tests/scripts/resume.Tests.ps1` covers the two there are.
- The entry is written by the elevated run, into the HKCU it sees. That is the signed-in user's, as gsudo's UAC elevation of the same account gives. Revisit if elevation ever uses another account.
- An entry armed for a restart that doesn't happen (the person closes the window and carries on) stays until the next `switch` clears it, or until the next restart brings the resume window back, which is what they were told to expect.
- A resume that fails says what the install says, and `run.log` has no line for its exit code: the old resume script wrote "install.cmd exited with code N". Revisit if a failure in the resume window is hard to read.
- The resume needs a key press after every restart, even when the person has just signed in themselves, and a restart put off after the countdown can bring the window back days later. Revisit if the resume has to run unattended. Skipping its UAC prompt with a scheduled task was considered and not done ([ruled-out.md](../reference/ruled-out.md#a-scheduled-task-for-the-resumes-uac-prompt)).
