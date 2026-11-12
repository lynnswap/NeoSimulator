# Contributing to NeoSimulator

Build NeoSimulator from source, check and document your changes, and publish
releases. For using the app and the SDK, see the
[documentation](https://lynnswap.github.io/NeoSimulator/documentation/).

## Requirements

- Apple Silicon Mac with macOS 26.4 or later
- Xcode 27 or later with Swift 6.4 or later; CI uses Xcode 27.2
- Python 3.10 or later for DMG packaging; CI uses 3.13

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
screens and keyboard capture permission to the app's signing requirement, so sign each update of
a build you keep using with the same identity. Pass a certificate name or SHA-1
hash from your keychain, or set `CODE_SIGN_IDENTITY`:

```bash
scripts/build-local.sh --signing-identity 'Developer ID Application: Your Name (TEAMID)'
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
doc comments, and contributor procedures in this file. Give each new public
declaration in Kit or UI a doc comment, and add each new public type to its
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

The Documentation workflow builds and deploys the site to GitHub Pages on pushes
to main, so the repository's Pages source must be **GitHub Actions**. Pull requests
run the app and SDK checks; documentation builds and distribution-script validation
run after merging to main. Release checks also validate the distribution scripts.

## Releases

### Build a validation DMG

Local DMGs are for validation and are not releases. Packaging uses the pinned
tools in `scripts/release-requirements.txt`:

```bash
python3.13 -m venv .build/release-tools
.build/release-tools/bin/pip install -r scripts/release-requirements.txt
scripts/build-release.sh --version v0.0.0-validation --dist-root dist
PATH="$PWD/.build/release-tools/bin:$PATH" \
  scripts/package-release.sh --version v0.0.0-validation --dist-root dist
```

`build-release.sh` signs ad hoc unless you pass `--signing-identity` or set
`CODE_SIGN_IDENTITY`, which also enables secure timestamps. `package-release.sh`
creates the DMG and verifies its files, signatures, architectures, and Finder
layout.

The manager's only entitlement is `com.apple.security.device.camera`, for
physical-device capture, and the renderer has none. The guest-settings helper in
`Resources` stays ad hoc signed, even in releases, with its simulator entitlements
embedded in the binary. Its macOS signing exceptions allow DYLD environment
variables and disable library validation.

### Publish a release

Start a public release only after its version, notes, exact main commit, and
publication plan are approved:

```bash
python3 scripts/prepare_release.py start \
  --repo lynnswap/NeoSimulator \
  --version vX.Y.Z \
  --source-sha <approved-main-commit> \
  --notes-file <approved-release-notes>
```

Add `--prerelease` for a prerelease. The command creates the tag and a draft
release, then dispatches the **Publish Release** workflow. A retry reuses a
matching tag and draft and never moves a conflicting tag. Check Actions before
retrying a dispatch whose result is uncertain. Starting from an existing draft
also creates the tag before building. If you run **Publish Release** manually,
its **prerelease** checkbox must match the draft; a mismatch stops the run before
it creates the tag.

The workflow runs CI and builds the arm64 DMG, then waits for approval of the
`release-signing` environment. It signs with Developer ID and notarizes using a
temporary keychain, keeps the helper's ad hoc signature, and verifies signatures
and entitlements. After stapling and Gatekeeper checks, it uploads the DMG,
`release-info.json`, and `SHA256SUMS`, checks that the tag still points to the
tested commit, and publishes the release. A failure leaves the tag and draft for
a retry.

Only **Publish Release** builds release apps and DMGs. Pushes to main run CI
without producing release artifacts.

### Configure release signing

Before the first public release, give the `release-signing` environment required
reviewers and these values:

| Kind | Name |
| --- | --- |
| Secret | `DEVELOPER_ID_P12_BASE64` |
| Secret | `DEVELOPER_ID_P12_PASSWORD` |
| Secret | `NOTARY_API_PRIVATE_KEY` |
| Variable | `APPLE_TEAM_ID` |
| Variable | `NOTARY_API_KEY_ID` |
| Variable | `NOTARY_API_ISSUER_ID` |
