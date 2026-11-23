# demos/ and surveys/

The two folders of things that run against real tools rather than fakes, and so stay out of `winfiles.ps1 test`. The Pester tests are in [testing.md](testing.md).

Both are development utilities, not part of winfiles. `winfiles.ps1` has no commands for them, and nothing in winfiles depends on them. Each is run from its own folder, by running its scripts directly as its README shows. They may borrow winfiles' scripts (`scripts/Invoke-Test.ps1` for the pinned Pester, `scripts/winlog.ps1` for `run.log`), but not the other way round. Trade-off: no listing or `help` for them, and each README carries its own run lines. Revisit if they grow enough to need a runner of their own.

## demos/

Things run by hand to watch how something behaves, with nothing to pass or fail. `demos/dsc-messages/` (`dsc-messages/Invoke-DscMessage.ps1 <doc> [dsc args]`, from `demos/`) shows how DSC displays lines a resource writes to stderr (levels, live output, Include nesting), and its README records the results per DSC version. Its stand-in resource `Test/SlowList` is outside `dsc/resources`, so `winfiles.ps1 dsc` never discovers it.

## surveys/

Things run to find out how winget, DSC, installers or Windows really behave, measured to settle a question rather than assumed. They're kept out of `tests/` because they run against the real tools, usually attended in the test VM, and only when there's a question to answer. A survey may use Pester (through `scripts/Invoke-Test.ps1`, which pins it) and assert what it recorded, so a rerun flags a change. Each survey's README records how to run it and what it found, with dates and versions; see `surveys/README.md`.
