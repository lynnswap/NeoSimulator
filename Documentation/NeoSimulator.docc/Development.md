# Development

Build NeoSimulator.app and its embedded renderer with Xcode.

## Workspace and builds

Use Xcode 27+ and Swift 6.4+. Open `NeoSimulator.xcworkspace`, which contains the
app project and host-switching package. The project uses Xcode's JSON
`project.xcproj` format. Select **NeoSimulator** to build the distributable app.

```bash
scripts/build-local.sh
open .build/local/arm64/NeoSimulator.app
```

For a local app you keep using, sign each update with the same identity to keep
its signing requirement stable across builds. Pass a certificate name or SHA-1
hash from your keychain:

```bash
scripts/build-local.sh --signing-identity 'Developer ID Application: Your Name (TEAMID)'
```

You can also set `CODE_SIGN_IDENTITY` explicitly. Without either option, local
and validation builds continue to use an ad-hoc signature.

The staging layout matches releases:

```text
arm64/NeoSimulator.app/
  Contents/Applications/NeoSimulatorRenderer.app/
```

The AppKit manager owns host selection and launches the embedded renderer when
Neo is selected. Its main window uses `NSSplitViewController` for the sidebar,
device canvas, and device-settings inspector. Each Xcode installation gets a
separate renderer because its Apple
frameworks remain loaded for the process lifetime. Devices using different
Xcode versions can run concurrently.

Source builds do not replace the app installed in Applications.

The renderer's private interfaces are resolved through ABIBridge.
`DeviceBrowser.swift` has previews using sample devices without connecting to
CoreSimulator.

## Tests

```bash
xcodebuild test -workspace Tools/PackageTests.xcworkspace -scheme XcodeSimulatorHost -destination 'platform=macOS,arch=arm64'
scripts/test-input-focus.sh
python3 -m unittest discover -s scripts/tests -v
```

Package tests cover host switching, preference transactions, recovery,
installation inspection, and signatures using isolated fixtures.
The host script runs `xcodebuild test` with the NeoSimulator scheme and covers
native input focus, runtime lookups, device-browser behavior, cancellation,
capture/import failures, and other renderer contracts without booting devices.
Release-script tests cover the embedded renderer's release metadata.
These suites do not replace a live check of an affected private API and guest
runtime.

Device transport tests use fake dependencies and run without communicating
with simulators, physical devices, or VMs. Run live device checks through
NeoSimulator.app so macOS attributes device access to the application. Do not
connect to devices from standalone test or diagnostic programs.

UI fixtures must work while the Mac is locked. Disable animations and
synchronize asynchronous work with explicit events or controlled deadlines;
elapsed sleeps and repeated task yields do not establish completion.

## Documentation

The article catalog in `Documentation/NeoSimulator.docc` is the source for the
published guide. Keep installation essentials in README and user tasks here.

```bash
scripts/build-documentation.sh
```

This builds `.build/documentation` with DocC, fails on warnings, and uses the
`NeoSimulator` hosting base path for GitHub Pages. It compiles articles directly,
so it does not build the app or load private frameworks. For a local preview:

```bash
scripts/build-documentation.sh ''
python3 -m http.server 8000 --directory .build/documentation
```

Open `http://localhost:8000`. The Documentation workflow checks pull requests
and deploys main to GitHub Pages. Manual runs deploy only from main. The
repository's Pages source must be **GitHub Actions**.

## DMG distribution

`build-release.sh` builds the complete app and signs the renderer before its
manager. Its default signature is ad hoc; `--signing-identity` or
`CODE_SIGN_IDENTITY` selects a certificate and enables secure timestamping. `package-release.sh` creates a drag-to-Applications DMG and
checks that the app's files, signature, architectures, and Finder layout survive
packaging. DMG tooling requires Python 3.10 or later; CI uses Python 3.13.
Local and validation DMGs are not public releases.

```bash
python3.13 -m venv .build/release-tools
.build/release-tools/bin/pip install -r scripts/release-requirements.txt
scripts/build-release.sh --version v0.0.0-validation --dist-root dist
PATH="$PWD/.build/release-tools/bin:$PATH" \
  scripts/package-release.sh --version v0.0.0-validation --dist-root dist
```

Public releases follow the same approval and signing flow as CodexReviewMonitor.
After the version, notes, exact main commit, and publication plan are approved:

```bash
python3 scripts/prepare_release.py start \
  --repo lynnswap/NeoSimulator \
  --version vX.Y.Z \
  --source-sha <approved-main-commit> \
  --notes-file <approved-release-notes>
```

This creates a draft and starts **Publish Release**. CI tests and builds the
arm64 DMG. The **release-signing** environment then requires approval before
Developer ID signing and notarization. Signing uses a temporary keychain,
signs the embedded renderer before the outer app, and verifies both signatures.
The workflow notarizes and staples the DMG, checks Gatekeeper, then uploads the
DMG, `release-info.json`, and `SHA256SUMS` to the same draft and publishes it.
The release tag is created at publication and must target the tested commit.

Configure the `release-signing` environment with required reviewers and these
values before the first public release:

| Kind | Name |
| --- | --- |
| Secret | `DEVELOPER_ID_P12_BASE64` |
| Secret | `DEVELOPER_ID_P12_PASSWORD` |
| Secret | `NOTARY_API_PRIVATE_KEY` |
| Variable | `APPLE_TEAM_ID` |
| Variable | `NOTARY_API_KEY_ID` |
| Variable | `NOTARY_API_ISSUER_ID` |

Ordinary pushes to main produce validation artifacts and do not publish a
release. Updates are installed by replacing the app in Applications.
