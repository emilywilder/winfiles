# demos/ and surveys/

The two folders of things that run against real tools rather than fakes, and so stay out of `just test`. The Pester tests are in [testing.md](testing.md).

## demos/

Things run by hand to watch how something behaves, with nothing to pass or fail. Their recipes are in `demos/justfile`: run `just <recipe>` from `demos/`, or `just -f demos/justfile <recipe>` from the root. `demos/dsc-messages/` (`just dsc-messages <doc> [dsc args]`) shows how DSC displays lines a resource writes to stderr (levels, live output, Include nesting), and its README records the results per DSC version. Its stand-in resource `Test/SlowList` is outside `dsc/resources`, so `just dsc` never discovers it.

## surveys/

Things run to find out how winget, DSC, installers or Windows really behave, measured to settle a question rather than assumed. They're kept out of `tests/` because they run against the real tools, usually attended in the test VM, and only when there's a question to answer. A survey may use Pester (through `Invoke-Test.ps1`, from `surveys/justfile`) and assert what it recorded, so a rerun flags a change. Each survey's README records how to run it and what it found, with dates and versions; see `surveys/README.md`.
