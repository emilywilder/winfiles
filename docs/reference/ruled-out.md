# Ruled out

Approaches that were tried or reasoned through and not taken, so they aren't tried again without a new reason. Each says why, and what would change the answer.

## Finding mise from install.cmd

`install.cmd` reaches the install through `Start-Clean.ps1` under 5.1, which reads `PATH` from the registry. These were ruled out (2026-11-16):

- **`install.cmd` starting `Invoke-Clean.ps1` under 5.1.** `-UseNewEnvironment` on 5.1 gives `USERNAME=SYSTEM` and no `USERPROFILE`, and quoting needs pwsh 7.3 (`docs/reference/windows.md`).
- **`install.cmd` calling `pwsh`.** Right after the bootstrap the only pwsh is mise's, and the terminal's `PATH` predates mise, so there is none to find.
- **Relying on the terminal's `PATH` for mise.** Same reason. This is why the launcher reads the registry.

Revisit if the bootstrap can leave mise's pwsh where a `.cmd` can find it.

## A scheduled task for the resume's UAC prompt

Reasoned 2026-11-16; nothing was built. The prompt comes from gsudo in the resumed `just install`. RunOnce can't avoid it, since it starts with the unelevated token, and only an elevated process can create a "run with highest privileges" task, which then starts elevated with no prompt.

- **A logon task running the whole resume elevated** doesn't work: `just home` would run elevated, and Scoop's installer refuses that.
- **What would work:** the first run's UAC step also registers an on-demand task (no trigger, highest privileges) that runs only the elevated steps. The unelevated RunOnce resume stays and calls `schtasks /run` where `just install` would call gsudo, waits, reads the result, and does the rest unelevated. The task is removed when the install finishes or fails.
- **Its costs:** the task's output can't reach the resume window as gsudo's does; a second path through `just install` for the resume only; and while the task exists, any unelevated process that can edit the repo's scripts gets admin. Running a copy from `C:\ProgramData\winfiles`, writable only by administrators, would close that, but the copy would drift from the repo.
- **Why not:** too much machinery for one prompt, which comes after a restart when someone is already at the machine.

Revisit if the resume has to run unattended.

## runas /trustlevel as "unelevated"

`runas /trustlevel:0x20000` leaves the integrity level High, gives no exit code, and doesn't wait for the child (`docs/reference/windows.md`, "Dropping privilege from an elevated shell"). `gsudo -i Medium` is used instead.
