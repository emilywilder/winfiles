# A run inherits nothing

A run is the same from any terminal. These go through `scripts/Invoke-Clean.ps1`:
- `install.cmd`;
- `just system`, `home`, `check`, `manual` and `post-install`;
- `just test`.

`Invoke-Clean.ps1` starts the command under `mise exec`, with `Start-Process -UseNewEnvironment`. Windows builds that environment for the user from the registry and the logon session (`CreateEnvironmentBlock`). So even a caller's changed `USERNAME` or `USERPROFILE` doesn't reach a run, and no list of variables has to be kept.

So `just`, `pwsh`, `gsudo` and DSC are always `mise.toml`'s. Only the outer `just`, and the shell of that one recipe line, come from the caller; from `install.cmd`, which runs `winfiles.ps1` under mise's pwsh, everything is mise's. `just dsc` doesn't go through this, since it's for working on the configuration by hand.

## The details

- **Start-Clean.ps1.** `install.cmd` can't start `Invoke-Clean.ps1` directly. Right after the bootstrap, the only pwsh is mise's, and the bootstrap's terminal has a `PATH` from before mise was installed. So `Start-Clean.ps1`, under 5.1, reads the machine and user `PATH` from the registry, finds mise, and runs `mise exec -- pwsh Invoke-Clean.ps1 pwsh -File winfiles.ps1 --clean install ...`. `--clean` tells `winfiles.ps1` the environment is clean already, so it doesn't go through `Invoke-Clean.ps1` a second time. It keeps to 5.1 syntax, and passes no arguments with quotes inside, since 5.1 mangles them ([reference](../reference/windows.md#windows-powershell-51-passing-arguments)). Without a `mise` on `PATH`, it says so and exits 1. Other ways of finding mise are in [ruled-out.md](../reference/ruled-out.md#finding-mise-from-installcmd).
- **Other mise configuration.** Both `mise` calls list the configuration in effect (`mise config ls --json`). Every file but the repo's `mise.toml` is added to `MISE_IGNORED_CONFIG_PATHS`, with a warning naming it (`scripts/miseignore.ps1`). Otherwise a global config, or a `mise.toml` in a parent folder, would add its tools and env to every run ([reference](../reference/windows.md#mise-configuration-files)).
- **pwsh 7.3 or later.** `CreateEnvironmentBlock` arrived in 7.1, and quotes inside arguments pass correctly from 7.3 ([reference](../reference/windows.md#start-process--usenewenvironment)). An older pwsh gets an error and exit 1 from an explicit check, not from `#Requires`: a recipe line carries on past a failed `#Requires`, and `exit $LASTEXITCODE` then reports 0.
- **A second pwsh.** The command runs as `pwsh -ExecutionPolicy Bypass -EncodedCommand`. That's because `-UseNewEnvironment` ignores `-Environment`, which would otherwise restore `PSExecutionPolicyPreference`, and `Start-Process` joins arguments without quoting them. Bypass matters because mise's pwsh defaults to RemoteSigned, which refuses a script with a mark of the web, as a repo from a downloaded ZIP has ([reference](../reference/windows.md#remotesigned-and-the-mark-of-the-web)).

## Trade-offs

Timings are in [benchmarks](../benchmarks.md#a-clean-run).
- A variable set only in the calling shell, such as a proxy, doesn't reach a run; set it persistently if a run needs it. Revisit if mise or just gains a way to clear an environment.
- `Start-Clean.ps1` adds about 0.7s in front of `install.cmd`. Revisit if the bootstrap can leave mise's pwsh where a `.cmd` can find it.
- The second pwsh adds about 0.55s per recipe line. Its output also skips PowerShell's pipeline, so `$x = & ./scripts/Invoke-Clean.ps1 ...` captures nothing, though no command does this. Revisit if `-Environment` starts working alongside `-UseNewEnvironment`, or if a command needs to capture the output.
- Checking the mise configuration costs one more `mise` call, about 50ms per recipe.
