# Benchmarks

Timings behind the trade-offs in the other docs. Each row gives the date, the machine, the commit where known, and how many samples. A single run is not a benchmark: it's a sample, and install times vary with downloads. Add rows from runs that happen anyway, rather than running things just for timings.

## A clean run

What `Invoke-Clean.ps1` and `Start-Clean.ps1` cost in front of a command (`docs/install.md`, "A run inherits nothing").

| Date | Machine | What | Result | Samples |
|---|---|---|---|---|
| 2026-11-16 | iris, load controlled | A trivial command through `Start-Clean.ps1` vs `Invoke-Clean.ps1` alone | median 2227ms vs 1571ms (about 0.7s) | 8 |
| 2026-11-16 | iris | Windows PowerShell 5.1 start-up | about 380ms | |
| | iris | The second pwsh (`-EncodedCommand`) per recipe line | 0.15s before, 0.7s after (about 0.55s) | 4 |
| | | `mise config ls --json` per recipe | about 50ms | |

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
| not recorded | iris | What `check` adds to the end of `just install` | about 80s | |
| 2026-11-17 | iris | `config test` through Includes vs the flat copy: system | 75s vs 62s | 1 |
| 2026-11-17 | iris | the same, home | 88s vs 73s | 1 |
| 2026-11-18 | iris, load not controlled | `just check iris emily`, 118 resources, entries vs flat | 153s vs 136s | 1 |

## Finding what needs a restart

The extra test of the elevated batches before the first `set` (`docs/install.md`, "What needs a restart").

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

The `gsudo returned ... after 159s` line of the second 2026-11-18 `vm-quick` run is the whole elevated run after the resume.
