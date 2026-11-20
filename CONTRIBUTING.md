# Contributing to NeoSimulator

Build NeoSimulator from source, and check and document your changes. For using
the app and the SDK, see the
[documentation](https://lynnswap.github.io/NeoSimulator/documentation/).

## Requirements

- Apple Silicon Mac with macOS 26.4 or later
- Xcode 27 or later with Swift 6.4 or later; CI uses Xcode 27.2
- Python 3.10 or later for the scripts in `scripts`

## Workspace

Open `NeoSimulator.xcworkspace`. It contains the Swift package, whose sources are
in `Sources`, and `App/NeoSimulator.xcodeproj`, which uses Xcode's JSON
`project.xcproj` format. The project holds the application targets' entry points,
bundle resources, and identifiers, and the Objective-C guest-settings helper.

`NeoSimulatorKit` and `NeoSimulatorUI` are the supported SDK, so public API
belongs only in them. `NeoSimulatorApp` and `NeoSimulatorService` are library
products only because the application targets link them; their entry points are
`@_spi(AppBootstrap)`. The other targets are package-only.

A target may import only its direct dependencies. `NeoSimulatorNative`,
`NeoSimulatorDeviceIO`, `NeoSimulatorKit`, and `NeoSimulatorManager` may not import
AppKit or SwiftUI. When you change a target's dependencies, update both
`Package.swift` and the graph in `scripts/check-module-graph.py`. CI runs this
check, which compares the compiler's import pre-scan with the manifest:

```bash
scripts/check-module-graph.py
```

Format the Swift files you change. `swift-format` reads the repository's
`.swift-format` configuration:

```bash
xcrun swift-format format --in-place <files>
```

## Build and run

`scripts/build-local.sh` builds the app with the release build script and writes
it to `.build/local`. It does not replace the app in Applications.

```bash
scripts/build-local.sh
open .build/local/arm64/NeoSimulator.app
```

Builds are ad hoc signed by default. macOS ties Camera access for physical-device
screens, keyboard capture permission, and access to the logins saved in the keychain to the app's
signing requirement, so sign each update of a build you keep using with the same identity. Pass a certificate name or SHA-1
hash from your keychain, or set `CODE_SIGN_IDENTITY`:

```bash
scripts/build-local.sh --signing-identity 'Developer ID Application: Your Name (TEAMID)'
```

Debug builds, from Xcode or `xcodebuild`, are ad hoc signed as well. To sign them with your Apple Development
certificate, create `App/Configurations/Local.xcconfig` with your team ID. Git ignores the file:

```
CODE_SIGN_IDENTITY[config=Debug][sdk=macosx*] = Apple Development
DEVELOPMENT_TEAM[config=Debug] = TEAMID
```

## Test

Run the package, app-bundle, and release-script tests:

```bash
xcodebuild test -workspace NeoSimulator.xcworkspace -scheme NeoSimulatorKit -destination 'platform=macOS,arch=arm64'
scripts/test-app-bundle.sh
python3 -m unittest discover -s scripts/tests -v
```

Package tests use isolated defaults, process fixtures, and fake device
transports, so they need no app host or connected device. The app-bundle script
builds the **NeoSimulator** scheme and runs `NeoSimulatorLicenseTests`, which
check the generated dependency notices and the bundled `Credits.rtf`. The
release-script tests check renderer metadata, signing order, and entitlements.

When you change Kit or UI, also build the public API consumer, as CI does:

```bash
cd Examples/MinimalSimulatorApp
xcodebuild build -scheme MinimalSimulatorApp -destination 'platform=macOS,arch=arm64'
```

UI fixtures must work while the Mac is locked. Disable animations, and wait for
asynchronous work through explicit events or controlled deadlines; elapsed sleeps
and repeated task yields do not show that the work finished.

Unit and host tests do not establish compatibility with live simulators. When you
change a private interface, check the affected device and runtime in the app;
earlier checks do not cover every Xcode and runtime combination. Use
NeoSimulator.app for physical-device, VM, and Device Hub checks, because macOS
grants access to the requesting program and a standalone diagnostic has separate
permissions. You can also check simulators with `simctl`.

## Documentation

The published site combines the guide in `Documentation/NeoSimulator.docc` with
the API reference for Kit and UI, whose catalogs are in their target directories.
Keep installation in the README, app and SDK usage in the guide, API contracts in
doc comments, contributor procedures in this file, and release procedures in
`Documentation/Releasing.md`. Give each new public declaration in Kit or UI a doc
comment, and add each new public type to its
module catalog's topics.

```bash
scripts/build-documentation.sh
```

The script fails on DocC warnings and writes the site to `.build/documentation`
with the `NeoSimulator` hosting base path for GitHub Pages. It does not build the
application targets or load private frameworks. For a local preview, build
without a base path and serve the output:

```bash
scripts/build-documentation.sh ''
python3 -m http.server 8000 --directory .build/documentation
```

Then open `http://localhost:8000`.

Pull requests run the app and SDK checks. The documentation build and the
distribution-script checks run after merging to main.
