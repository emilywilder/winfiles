# Continuing after a restart

`install.cmd` picks the run up again at the next sign-in, through a per-user `RunOnce` entry, so a clean install doesn't wait for someone to notice the restart. Why a run restarts is in [restarts.md](restarts.md). After any other command, run it again by hand.

## Arming the entry

A command that is `resumable` in `commands.jsonc` (`install`) continues after a restart. The entry is armed late, only by a run that is about to restart or ask for one:

1. **The run starts.** `winfiles.ps1` clears an entry an earlier run left (`Clear-Resume`), since this run decides for itself whether to restart. It does that once, in the unelevated run that started it.
2. **The steps get the arguments.** Where the steps run (after any change of privilege), `winfiles.ps1` sets `WINFILES_RESUME` to the command's arguments as a JSON array, defaults included: a default such as the computer's name can change before the resume, with the rename that restarts. Without it (`winfiles.ps1 system`), nothing is armed.
3. **A run that stops for a restart arms it.** `Exit-RestartPending` and `Restart-Windows` in `scripts/restart.ps1` call `Register-Resume` (`scripts/resume.ps1`) before they exit 3010. `Restart-Windows` does it after its 10-second countdown and before `Restart-Computer`, so Ctrl+C leaves no entry, and the shutdown can't beat the write.

Windows deletes a RunOnce value before running it, and the name has no `!`, so a resume never removes its own entry, and one that fails isn't retried at every sign-in ([reference](../reference/windows.md#runonce)). Declining UAC, or any failure, ends the chain. The value is:

```
cmd.exe /c start "winfiles" powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit -File scripts\Resume-Winfiles.ps1 <args>
```

- It opens whichever terminal Windows defaults to, so nothing depends on `wt.exe`, which the home configuration only installs later. `start` returns at once.
- A command over RunOnce's 260 characters only gets a warning and a line in `run.log`, and the install goes ahead without the resume.

## Resume-Winfiles.ps1

It does these, in order:
1. Moves to the repo (RunOnce starts it in System32).
2. Stops before UAC if `RebootPending` is still set.
3. Waits for Enter.
4. Waits up to 60s for `cdn.winget.microsoft.com:443`, since Wi-Fi can still be connecting at sign-in.
5. Runs `install.cmd <args>` as a child, so the window stays open on the result. That run arms the entry again if it stops for another restart.

It waits for Enter because a sign-in doesn't mean someone is at the machine. The test VM signs in by itself, and Windows cancels a UAC prompt that nobody answers, which ends the chain ([reference](../reference/windows.md#an-unanswered-uac-prompt)).

## Trade-offs

- A restart the run doesn't start itself (Windows Update's, or the person's own) leaves no entry, unless the run stopped for it with 3010. Revisit if installs end that way.
- Arming is a duty of each way a run stops for a restart, which today is the two functions in `restart.ps1`. A new way to stop that doesn't call `Register-Resume` loses the resume without saying so; `tests/scripts/resume.Tests.ps1` covers the two there are.
- The entry is written by the elevated run, into the HKCU it sees. That is the signed-in user's, as gsudo's UAC elevation of the same account gives. Revisit if elevation ever uses another account.
- An entry armed for a restart that doesn't happen (the person closes the window and carries on) stays until the next `install` clears it, or until the next restart brings the resume window back, which is what they were told to expect.
- The resume needs a key press after every restart, even when the person has just signed in themselves, and a restart put off after the countdown can bring the window back days later. Revisit if the resume has to run unattended. Skipping its UAC prompt with a scheduled task was considered and not done ([ruled-out.md](../reference/ruled-out.md#a-scheduled-task-for-the-resumes-uac-prompt)).
