# Contributing to NeoSimulator

## Report a bug

In [GitHub Issues](https://github.com/lynnswap/NeoSimulator/issues), check for an existing report. Include
steps to reproduce, the expected and actual behavior, and your NeoSimulator, Xcode, and macOS versions.
For device issues, also give the model and runtime or device OS version.

## Build and test a change

Use an Apple silicon Mac with macOS 26.4 or later and Xcode 27 or later (Swift 6.4+).
Install the runtime you want to test, open `NeoSimulator.xcworkspace`, and run the **NeoSimulator** scheme.

Run the relevant tests in the **NeoSimulatorKit** scheme. If you change how the app
interacts with a device or Xcode, try the affected operation in NeoSimulator.app.
For DocC changes, run `scripts/build-documentation.sh`.

## Open a pull request

Keep the PR focused on one change. Describe the problem it solves and how you tested it.
