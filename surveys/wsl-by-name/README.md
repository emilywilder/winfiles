# wsl-by-name

**Question:** does `Winfiles.Wsl/Distribution` with no `source` install a distribution from wsl.exe's online list? It runs `wsl --install <name> --no-launch` and leaves out `--name`, because older Store (appx) entries refuse it. Until now it has only been tested against the fake `wsl.exe`. The result is recorded in `docs/reference/wsl.md`, "Versions and install by name".

## Run

In a test VM where WSL is already set up (after `.\install.cmd vm-quick`), unelevated, from `~\src\winfiles`:

```powershell
wsl --list --online                                                          # Debian is listed
mise exec -- just dsc config test --file surveys/wsl-by-name/wsl-by-name.dsc.yaml   # expect _inDesiredState false
mise exec -- just dsc config set  --file surveys/wsl-by-name/wsl-by-name.dsc.yaml   # installs, no launch
mise exec -- just dsc config test --file surveys/wsl-by-name/wsl-by-name.dsc.yaml   # expect true
wsl --list --verbose                                                         # Debian registered, WSL 2, default unchanged
```

To repeat it: `wsl --unregister Debian`.

Look for: whether `set` exits 0; that the name it registers under is `Debian`, so the second `test` matches it; whether `wsl --install` opens a window or asks for anything despite `--no-launch`; and the time it takes.

## Findings

Run 2026-11-21 in the test VM, DSC 3.3.0, Debian from the online list: reported as completed successfully. `set` installed it by name alone, with no `--name`, and the following `test` found it in the desired state. Whether `wsl --install` opened a window, and how long it took, weren't recorded; note them on the next run.

Only Debian was tried, a modern `.wsl` entry. An older Store (appx) entry in the list hasn't been.
