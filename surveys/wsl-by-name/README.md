# wsl-by-name

**Question:** does `Winfiles/WslDistribution` with no `source` install a distribution from wsl.exe's online list? It runs `wsl --install <name> --no-launch` and leaves out `--name`, because older Store (appx) entries refuse it. Until now it has only been tested against the fake `wsl.exe` (`docs/optional-goals.md`, "Check installing a distribution by name alone").

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

Not run yet.
