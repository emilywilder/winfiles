# Surveys

Things we run to gather information: how the tools winfiles drives (winget, DSC, installers, Windows) really behave, measured on purpose rather than assumed. A survey's findings feed decisions recorded in `docs/`, such as a `Trade-off: ... Revisit if ...` entry. Its README records what was run, when, on which versions, and what came out.

How they differ from the rest of the repo:
- **Not `tests/`.** Those check winfiles' own code against fakes on every change, on any machine, through `winfiles.ps1 test`. Surveys run by hand when there's a question to answer, against the real tools, and `winfiles.ps1 test` never runs them. A survey may use Pester for structure, and may assert behaviour it has recorded, so that a rerun flags when a tool changes. Those assertions check the tool, not winfiles.
- **Not `demos/`.** Those are visual checks of something to watch, with nothing recorded beyond their README.
- **Usually in the test VM, attended.** A survey that changes the machine refuses to run anywhere else.

Surveys are development utilities, not part of winfiles: `winfiles.ps1` has no commands for them, and nothing in winfiles depends on them. Each survey's README says how to run its scripts, from this folder. They may use winfiles' scripts, such as `scripts/Invoke-Test.ps1` for the pinned Pester. On a fresh install, `pwsh` and `dsc` are only reachable through mise, so put `mise exec --` in front: `mise exec -- pwsh -NoProfile -File <survey>/<script>.ps1`.

| Survey | Question |
|---|---|
| [`winget-paths/`](winget-paths/README.md) | How do `winget install`, `Microsoft.WinGet/Package` and `Install-WinGetPackage` differ when installing the same packages: time, scope, UAC, failures and dependencies? |
| [`wsl-by-name/`](wsl-by-name/README.md) | Does `Winfiles.Wsl/Distribution` with no `source` install a distribution from wsl.exe's online list? |
