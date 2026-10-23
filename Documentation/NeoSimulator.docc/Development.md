# Development

Build the CLI with SwiftPM and the app with Xcode.

## Workspace and builds

Use Xcode 27+ and Swift 6.4+. Open `NeoSimulator.xcworkspace`, which contains the
app project and Swift package. The project uses Xcode's JSON `project.xcproj`
format. Select **NeoSimulator** for the app, **xcode-simulator-host** for the CLI,
or **XcodeSimulatorHostTests** for package tests.

```bash
scripts/build-local.sh
.build/local/arm64/bin/xcode-simulator-host --help
```

The staging layout matches releases:

```text
arm64/
  bin/xcode-simulator-host
  libexec/xcode-simulator-host/NeoSimulator.app
```

The CLI locates the app relative to its executable. `build-local.sh` stages both
under `.build/local`; it does not install them into PATH. Run the staged CLI
with `use legacy` or `use neo` when ready to change host settings.

`NeoSimulatorBuildInfoTool` and its build plugin provide version information.
The app's private interfaces are resolved through ABIBridge. `DeviceBrowser.swift`
has previews using sample devices without connecting to CoreSimulator.

## Tests

```bash
swift test
scripts/test-input-focus.sh
```

The first command matches package CI and covers CLI arguments, host switching,
preference transactions, recovery, installation inspection, signatures, and
build metadata using isolated fixtures.

The host script runs `xcodebuild test` with the NeoSimulator scheme and
`platform=macOS,arch=arm64`. It covers native input focus, runtime lookups,
device-browser behavior, cancellation, capture/import failures, and other host
contracts without booting or connecting to simulators. Neither suite replaces
a live check of an affected private API and guest runtime.

## Documentation

The article catalog in `Documentation/NeoSimulator.docc` is the source for the
published guide. Keep installation essentials in README; put user tasks here
and non-obvious ABI or lifetime constraints next to the code that needs them.

```bash
scripts/build-documentation.sh
```

This builds `.build/documentation` with DocC, fails on warnings, and uses the
`NeoSimulator` hosting base path for GitHub Pages. It compiles articles directly,
so it does not build the app or load private frameworks. For a local preview at
the server root:

```bash
scripts/build-documentation.sh ''
python3 -m http.server 8000 --directory .build/documentation
```

Open `http://localhost:8000`. The Documentation workflow checks pull requests
and deploys pushes to main to GitHub Pages. Manual runs deploy only from main.
The repository's Pages source must be **GitHub Actions**.

## Distribution

`build-release.sh` builds the CLI and app, `package-release.sh` creates the
archive and installer, and `verify-release-assets.sh` checks the archive,
signatures, versions, and installation behavior. The Release workflow accepts
a version, runs CI, and prepares a draft release for manual publication.
It does not publish from an ordinary main-branch push.
