# Benchmarks

Timings behind the trade-offs in the other docs. Each row gives the date, the machine, the commit where known, and how many samples. A single run is not a benchmark: it's a sample, and install times vary with downloads. Add rows from runs that happen anyway, rather than running things just for timings.

## A clean run

What `Invoke-Clean.ps1` and `Start-Clean.ps1` cost in front of a command (`docs/run/clean-environment.md`).

| Date | Machine | What | Result | Samples |
|---|---|---|---|---|
| 2026-11-16 | iris, load controlled | A trivial command through `Start-Clean.ps1` vs `Invoke-Clean.ps1` alone | median 2227ms vs 1571ms (about 0.7s) | 8 |
| 2026-11-16 | iris | Windows PowerShell 5.1 start-up | about 380ms | |
| | iris | The second pwsh (`-EncodedCommand`) per line of a `just` recipe | 0.15s before, 0.7s after (about 0.55s) | 4 |
| | | `mise config ls --json` per `just` recipe | about 50ms | |

## DSC discovery

Measured 2026-10-28 on iris, behind the choice of mise's DSC without its discovery extensions (`docs/dev/tooling.md`). Flat runs start one `dsc` per batch; through Includes, each Include started another.

| What | Result |
|---|---|
| The PowerShell discovery extension, per `dsc` process (found nothing) | about 0.8s |
| The Appx discovery extension, per `dsc` process | about 2.5s |
| A whole-composition `test`, mise's 3.3.0 without the extensions | about 34s |
| The same, Store 3.2.3 | about 41s |
| The same, 3.3.0 with the extensions | about 91s |

## Commands without the profile

A line of a `just` recipe in pwsh with the user's profile cost about 5s on iris, against 0.47s without it (date not recorded). The commands run with `-NoProfile`.

## Changing privilege

Checked 2026-11-18 on iris, from an elevated pwsh, with trivial children (`docs/reference/windows.md`).

| Route | Cost |
|---|---|
| `runas /trustlevel` | about 1.6s (returns before the child finishes) |
| Scheduled task, Limited, with register and unregister | about 1.6–2.6s |
| `gsudo -i Medium --direct` | about 2s |

## check

| Date | Machine | What | Result | Samples |
|---|---|---|---|---|
| not recorded | iris | What `check` adds to the end of `just install` (before `winfiles.ps1`) | about 80s | |
| 2026-11-17 | iris | `config test` through Includes vs the flat copy: system | 75s vs 62s | 1 |
| 2026-11-17 | iris | the same, home | 88s vs 73s | 1 |
| 2026-11-18 | iris, load not controlled | `just check iris emily` (before `winfiles.ps1`), 118 resources, entries vs flat | 153s vs 136s | 1 |

## Tests

What a test costs, by how it runs (`docs/dev/testing.md`).

| How | Cost per test |
|---|---|
| A resource in a child pwsh (`Invoke-Resource`) | about 0.6s |
| A resource in the test's process with Pester mocks | about 0.1s |
| A script calling the fake `dsc` (cmd, pwsh, and `Invoke-Dsc.ps1`'s `Get-AppxPackage`) | about 2s |

## Per-package resources

One `winget dscv3` process per package (`docs/config/winget.md`), against the old lists, which checked all their packages with one listing for about 1.75s. 2026-11-17.

| Machine | What | Result | Samples |
|---|---|---|---|
| iris | `Microsoft.WinGet/Package`, per package in `config test` | median 0.79s | 49 |
| iris | `Winfiles.WinGet/Package`, per package (a pwsh start on top) | median 1.34s | 40 |
| iris | `config test`, system document, lists vs per-package | 46–47s vs 73s | |
| iris | `config test`, home document, lists vs per-package | 34s vs 76s | |
| iris | `just check`, lists vs per-package | about 85s vs about 150s | |
| test VM, `vm` | `config test` of the two documents in a clean install | 35s and 37s | 1 |

## Other

| Date | Machine | What | Result |
|---|---|---|---|
| 2026-11-16 | iris | DSC's WMI adapter discovery, per try | about 35s |
| 2026-11-18 | test VM | `wsl --update` from 2.3.26 to 3.0.5 | about 40s |

## Finding what needs a restart

The extra test of the elevated batches before the first `set` (`docs/run/restarts.md`).

| Date | Machine | Elevated resources | Discovery | Commit |
|---|---|---|---|---|
| 2026-11-19 | test VM, `vm-quick` | 14 | about 12s | |
| 2026-11-19 | test VM, `vm-quick` | 14 | 11s | fd61099 |
| 2026-11-19 | test VM, `vm` | 57 | 24s | |

## Clean installs in the test VM

All from the `updated` checkpoint. The bootstrap and the first start, up to the restart, are left out unless stated. "Restart" is the stage applied before the restart; the other columns are after it.

| Date | Host | Commit | Restart | Elevated | User | check | Notes |
|---|---|---|---|---|---|---|---|
| 2026-11-17 | vm-quick | c6f5d9d | | 43s | 1m39s | 16s | through Includes, before the flat copy |
| 2026-11-18 | vm-quick | | 51s | 45s | 1m30s | | restart document (since replaced); about 6 min from the bootstrap to the end |
| 2026-11-18 | vm-quick | e32adb5 | | 56s | 1m54s | 11s | first run through the flat copy; PowerShell's MSIX 36.6s (vs 21.7s), Scoop's Core list 50s (vs 30s) |
| 2026-11-18 | vm-quick | | | 1m04s | 14m57s | | network outage during Scoop; three Scoop lists failed, a rerun passed |
| 2026-11-19 | vm-quick | | 52s | 46s | 1m42s | 15s | first run through the batches; a missed UAC prompt split the run |
| 2026-11-19 | vm-quick | fd61099 | 44s | 42s | 1m18s | 16s | 147s from the resumed `install-steps` to the end |
| 2026-11-19 | vm | | 42s | 12m31s | 7m07s, then 16m41s | 54s | the user batch stopped on winget `0x80071130`; the rerun's elevated batch took 45s, already applied |
| 2026-11-22 | vm-quick | 5735f69 | 48s | 44s | 2m04s | 14s | first run through `winfiles.ps1`: 195s from the resumed `--run install` to the end; 6m38s from the bootstrap to the end, 34s of it waiting for Enter |

Two earlier clean installs, from the bootstrap's start, with App Installer 1.29.380 and DSC 3.3.0, right after the move to per-package winget resources (2026-11-17):

| Host | Total | Breakdown | check |
|---|---|---|---|
| vm-quick | resumed run 2m49s | features 2s, system 43s, home 1m39s, check 16s | 25/25 |
| vm | 46m53s | bootstrap 84s; first start 2m46s (2m of it the WSL check); 88s waiting for Enter; resumed run 39m18s (features 2s, system 13m27s, home 24m27s, check 1m12s) | 107/107 |

The slowest packages in that `vm` run were Ollama (192s), LibreOffice (95s), LM Studio (88s), GOG Galaxy (85s) and PowerToys (68s). The last full `vm` install before it (2026-11-02, with the package lists) took 1h36m, 28m of it one LibreWolf download.

The `gsudo returned ... after 159s` line of the second 2026-11-18 `vm-quick` run is the whole elevated run after the resume.
