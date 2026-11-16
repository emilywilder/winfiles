# Bootstrap and install

How a machine goes from a fresh Windows 11 install to its configuration: `bootstrap.cmd`, `just install` and what each step does.

Bootstrap on a fresh Windows 11 install, from an unelevated terminal in the repo:

```powershell
.\bootstrap.cmd iris   # rerun after the restart just install asks for
```

`bootstrap.cmd` only runs `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Install-Winfiles.ps1 <args>` and passes on its exit code: a `.cmd` runs whatever the execution policy, which blocks `.ps1` scripts on a fresh install, and the policy is bypassed for that one process, never changed. `.gitattributes` keeps it CRLF, since cmd.exe misreads batch files with LF line endings. Its arguments go to the script unchanged, so `-HostName` is positional (`bootstrap.cmd iris`).
`scripts/Install-Winfiles.ps1` runs under Windows PowerShell 5.1, since nothing else is installed yet, and refuses an elevated shell. `-HostName` picks the host configuration; without it, `just` uses the computer name, which a new install usually doesn't match. Each step skips what's already done:

```powershell
winget install --id Microsoft.AppInstaller --exact --source winget --accept-package-agreements   # treats 0x8A15002B, already current, as success
winget install --id jdx.mise --exact --source winget --accept-package-agreements   # unless mise is installed
$env:Path = <machine Path>;<user Path>                       # this process only, so mise is found without a new terminal
mise trust; mise install                                     # mise.toml provides just, pwsh, gsudo and DSC
mise exec -- just install <host>                             # everything below, in order; the script exits with its code
```

`--source winget` keeps winget away from the `msstore` source, which on a fresh install stops to ask you to accept its terms (and sends your region).
`--accept-package-agreements` accepts mise's licence without a prompt. winget still asks for UAC to install the Visual C++ runtime that `jdx.mise` depends on.
App Installer comes first because a new Windows image can ship one too old for the rest. With 1.26.509 (winget 1.11, seen in the test VM 2026-11-02, on an image that hadn't been through Windows Update) the WinGet module fails when elevated (`Failed to create instance: 0x800706BA`), though not unelevated, and `Microsoft.WinGet/Source` removes `msstore`, then fails to add it back. Upgrading unelevated takes no prompt, and winget 1.29 fixes both. Only the bootstrap does this, so on an old image run the bootstrap rather than `just install`.
Reloading `PATH` from the registry only changes the script's own process, which the `PATH` constraint allows. It can't help in the middle of `just install`: a process started before Scoop was installed never sees its shims.

`just install [host] [user]` defaults to the computer name and username, and fails before any change when there's no configuration for them. It runs these, in this order. Each one skips what's already done:

```powershell
gsudo --direct mise exec -- just dsc-set-features <host> wsl-install dsc-set-system <host> # `just system`: one UAC prompt, same console
                                                             #   dsc-set-features: scripts/Set-Winfiles.ps1 dsc/hosts/<host>/features.dsc.yaml
                                                             #   wsl-install: wsl --install --no-distribution; exits 3010 while a restart is pending
                                                             #   dsc-set-system: scripts/Set-Winfiles.ps1 dsc/<host>.system.dsc.yaml
mise exec -- pwsh -File ./scripts/Set-Winfiles.ps1 dsc/<user>@<host>.home.dsc.yaml   # `just home`: unelevated; installs Scoop itself first
mise exec -- pwsh -File ./scripts/Test-Winfiles.ps1 dsc/<host>.system.dsc.yaml dsc/<user>@<host>.home.dsc.yaml   # `just check`: lists what's missing; exits 1 if anything is
mise exec -- pwsh -File ./scripts/Show-PostInstall.ps1 dsc/hosts/<host>   # `just post-install`: prints what's still to do by hand
```

A step winfiles can't do goes in a YAML comment in `dsc/hosts/<host>/` that starts with `# post-install: ` and runs to the end of that block of comment lines. `just post-install` prints these, so the text lives once, beside the setting it's about. So far that's iris's Remote Desktop, which rejected the Microsoft account's password until the account had signed in with it at the sign-in screen, with "only allow Windows Hello sign-in" off for that sign-in (seen 2026-11-04; it kept working with the setting back on). `just install` runs it last, so a stop for a restart or a failed `just check` hides the notes until the run that gets through. Trade-off: nothing can tell whether a note has been done, so they print on every `just install`, even on a set-up machine; revisit if they start being ignored.

A run inherits nothing from the shell that starts it, so it's the same from any terminal. `just system`, `just home` and `just check` each go through `scripts/Invoke-Clean.ps1`, which rebuilds the environment for its own process: Windows' per-session variables are kept, everything else comes from the machine and user values in the registry (`PATH` included), and it then runs the command under `mise exec`. So `just`, `pwsh`, `gsudo` and DSC are always `mise.toml`'s, even when the run starts from plain `just install`, and only the outer `just` and the shell of that one recipe line come from the caller. Neither mise nor just can clear an environment, which is why this is a script. Trade-off: a variable set only in the calling shell, such as a proxy, doesn't reach a run; set it persistently if a run needs it. Revisit if mise or just gains a way to do this. `just dsc` isn't part of this: it's for working on the configuration by hand.

A package that fails to install doesn't stop the run: the list logs an `ERROR`, moves on and exits 0, and so does DSC, so the later lists and resources still apply. `just check` then gives `just install`, and the bootstrap, a failing exit code. Any other failure still stops the run where it happens, before `just check`. Each `set` and `check` also writes DSC's JSON results to `~/.local/state/winfiles/dsc/<time>-<set|test>-<document>.json`, which hold each resource's duration; nothing removes them. They're outside the repo because `just test-vm-copy` replaces the repo, and `just dsc` on its own doesn't write them. Trade-offs: `check` adds about 80s to the end of a run (measured on iris), for one list of what's missing; and `just system` and `just home` on their own exit 0 after a failed package, showing only the `ERROR` line, so run `just check` after them. Revisit if `check` becomes slow enough to skip, or if a failed package gets missed.

The elevated steps come first and share one gsudo call, so each run asks for UAC once, at the start, and the restart comes while someone is watching. Run on its own, `just wsl-install` elevates itself in a separate window instead. Nothing after the UAC prompt needs attention. `wsl-install` and `system` are `[no-exit-message]`, so a stop for a restart shows only the script's warning, not just's red "recipe failed" lines; a `dsc-set-features` or `dsc-set-system` failure is still reported by the inner just. Enabling a feature leaves `RebootPending` set, so `wsl-install` stops the run then, before any installer. gsudo's credential cache (`gsudo cache on`) isn't used: just runs each recipe line in its own process, and the cache's per-process scope hasn't been checked against that.
