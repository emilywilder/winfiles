# Continuing after a restart

`install.cmd` picks the run up again at the next sign-in, through a per-user `RunOnce` entry, so a clean install doesn't wait for someone to notice the restart. A plain `winfiles.ps1 install` has to be rerun by hand. Why a run restarts is in [restarts.md](restarts.md).

## The RunOnce entry

`Invoke-Install.ps1` writes `HKCU\Software\Microsoft\Windows\CurrentVersion\RunOnce\winfiles` before it runs the install, because writing it afterwards would race the shutdown. When the run ends, it removes the entry, unless the exit code is 3010 or 194 (3010 cut to its low byte by `mise exec`, [reference](../reference/windows.md#mise-exec-and-exit-codes)). The value is:

```
cmd.exe /c start "winfiles" powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit -File scripts\Resume-Winfiles.ps1 <args>
```

- It opens whichever terminal Windows defaults to, so nothing depends on `wt.exe`, which the home configuration only installs later. `start` returns at once.
- Windows deletes a RunOnce value before running it, and the name has no `!`, so only a run that stops for a restart writes it back. Declining UAC, or any failure, ends the chain ([reference](../reference/windows.md#runonce)).
- A command over RunOnce's 260 characters only gets a warning, and the install goes ahead without the resume.

## Resume-Winfiles.ps1

It does these, in order:
1. Moves to the repo (RunOnce starts it in System32).
2. Stops before UAC if `RebootPending` is still set.
3. Waits for Enter.
4. Waits up to 60s for `cdn.winget.microsoft.com:443`, since Wi-Fi can still be connecting at sign-in.
5. Runs `install.cmd <args>` as a child, so the window stays open on the result. That run registers the entry again if it stops for another restart.

It waits for Enter because a sign-in doesn't mean someone is at the machine. The test VM signs in by itself, and Windows cancels a UAC prompt that nobody answers, which ends the chain ([reference](../reference/windows.md#an-unanswered-uac-prompt)).

Trade-off: the resume needs a key press after every restart, even when the person has just signed in themselves, and a restart put off with Ctrl+C can bring the window back days later. Revisit if the resume has to run unattended. Skipping its UAC prompt with a scheduled task was considered and not done ([ruled-out.md](../reference/ruled-out.md#a-scheduled-task-for-the-resumes-uac-prompt)).
