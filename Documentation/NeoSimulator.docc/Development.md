# Development

Build NeoSimulator.app and its embedded renderer with Xcode.

## Workspace and builds

Use Xcode 27+ and Swift 6.4+. Open `NeoSimulator.xcworkspace`, which contains the
app project and its local Swift package dependency. The application project is
`App/NeoSimulator.xcodeproj`; its code, host tests, and `AppIcon.icon` are also in
`App/`. The root `Package.swift` defines **NeoSimulatorKit**, with library code in
`Sources/XcodeSimulatorHost` and package tests in `Tests/XcodeSimulatorHostTests`.
Its library product remains `XcodeSimulatorHost`.

`App/NeoSimulator` groups app code by domain: `DeviceBrowser`, `DeviceSettings`,
`DeviceInspector`, `RemoteDevice`, `Settings`, and `Simulator`. Most views, view
controllers, and models have separate files named for their types within each
domain. Related helper types can remain in the same file. Application launch, menus, and error presentation live in its `App/`
folder. Keyboard input, display layout, and device symbols belong to
`DeviceInput`, `DeviceDisplay`, and `DeviceAppearance`, respectively.

The `NeoSimulator` target builds the manager app. `NeoSimulatorRenderer` builds
the embedded renderer, whose entry point lives in
`App/NeoSimulatorRenderer/App/Launch`. Both targets compile the simulator
implementation needed by their process; each has its own application entry
point. Domain folders organize sources within these target boundaries.

The project uses Xcode's JSON `project.xcproj` format. Select **NeoSimulator** to
build the distributable app.

```bash
scripts/build-local.sh
open .build/local/arm64/NeoSimulator.app
```

For a local app you keep using, sign each update with the same identity to keep
its signing requirement stable across builds. macOS ties the manager's Camera
access for physical-device screens to that requirement. Pass a certificate name
or SHA-1 hash from your keychain:

```bash
scripts/build-local.sh --signing-identity 'Developer ID Application: Your Name (TEAMID)'
```

You can also set `CODE_SIGN_IDENTITY` explicitly. Without either option, local
and validation builds continue to use an ad-hoc signature.

The staging layout matches releases:

```text
arm64/NeoSimulator.app/
  Contents/Applications/NeoSimulatorRenderer.app/
  Contents/Resources/NeoSimulatorGuestSettings
```

The AppKit manager owns host selection, presents device screens, and launches
the embedded renderer when Neo is selected. Its main window uses
`NSSplitViewController` for the sidebar, device canvas, and device-settings
inspector. The manager loads one SimulatorKit UI toolkit, which stays loaded for
its process lifetime, and opens an in-process host with its own CoreSimulator
context for each Xcode whose simulators it shows. Each of those Xcode
installations also gets a separate headless renderer process, which owns guest
boot, restart, and shutdown. Devices using different Xcode versions can run
concurrently.

Source builds do not replace the app installed in Applications.

The manager and renderer resolve their private interfaces through ABIBridge.
`DeviceBrowser.swift` has previews using sample devices without connecting to
CoreSimulator.
The settings panes have independent previews in
`GeneralSettingsViewController.swift`, `DevicesSettingsViewController.swift`,
`CaptureSettingsViewController.swift`, and `ServiceProfilesSettingsViewController.swift`.
The background-services inspector has previews in `BackgroundServicesViewController.swift`.
They use sample catalogs and separate preferences domains. Debug builds allow
Xcode's preview process to run alongside the app and skip application startup
in preview processes.

AppKit controllers retain the observable models used by their views. The
background-services inspector uses an `NSOutlineView`, with a SwiftUI `Form`
for profile controls in a top-aligned split-view accessory. Profile settings
use an `NSSplitViewController` with an `NSTableView` for profile selection.
Their controllers retain the list views when switching to an unavailable-state view.
Both service lists use an `NSSearchField`, placed in a top-aligned accessory in
the device inspector and above the list in settings. Search filters categories
and service identifiers, expands matches, and restores the
previous disclosure state when cleared. The settings pane keeps its search when
switching profiles. `ObservationBridge` subscriptions update controls when model
properties change.

`DeviceBrowserState` saves pane visibility, inspector tabs, and selected device
identifiers in user defaults. Selection is restored as devices arrive in the
inventory, including simulators in custom device sets.

`BackgroundServicesModel` and `DeviceSettingsModel` own reads and accepted edits.
Their displayed snapshots are recomputed when those inputs change. Inspector
models own presentation state and send device commands through
`SimulatorManagerModel`, which owns the operation queue. `ServiceProfileStore`
owns observable profile instances and per-device overrides. Settings edit the
selected profile directly. Adding a profile selects its temporary name for inline
editing. Only saving a simulator's modified Default profile asks for a name in a
sheet. Saving captures accepted service changes without waiting for their application
to finish. Saving a profile does not apply it to other simulators.

Service profiles and device assignments are stored together in
`Application Support/<app bundle identifier>/ServiceProfiles.json`. Writes are
atomic. The first load migrates the former `BackgroundServiceProfiles` defaults
value only when the file is absent, and removes that value after a successful
write. A read failure preserves the existing data and prevents further writes
until loading succeeds. Profile order is the stored array order; dragging
profiles in settings changes that order in both settings and the inspector.
The built-in Default profile remains first and is not stored in the file.

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
Its `NeoSimulatorHostTests` target compiles the sources under test without either
application entry point. It runs without an app host so tests control defaults
registration and process state independently of app startup.
Release-script tests cover the embedded renderer's release metadata and the
signing order and entitlements of the helper, renderer, and manager.
These suites do not replace a live check of an affected private API and guest
runtime.

Device transport tests use fake dependencies and run without communicating
with simulators, physical devices, or VMs. Check physical devices, VMs, and
Device Hub settings live through NeoSimulator.app: macOS grants device and
Device Hub data access to the program that requests it, so a standalone test or
diagnostic program gets its own prompts and results. Simulators need no such
access and can also be checked with `simctl`.

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

`build-release.sh` builds the complete app, signs the simulator settings helper
ad hoc, and signs the renderer before its manager. The helper is stored in
Resources as simulator code, outside the locations for nested macOS code.
Its signature stays ad hoc even when the app uses Developer ID signing.
The manager's signature has
`com.apple.security.device.camera` from `App/NeoSimulator/NeoSimulator.entitlements`,
because the hardened runtime blocks AVFoundation capture of a connected
device's screen without it. The renderer is signed without entitlements. The
helper is signed with only its DYLD-environment and library-validation
exceptions; its simulator entitlements are embedded in the binary. The default
signature is ad hoc; `--signing-identity` or
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

After the version, notes, exact main commit, and publication plan of a public
release are approved:

```bash
python3 scripts/prepare_release.py start \
  --repo lynnswap/NeoSimulator \
  --version vX.Y.Z \
  --source-sha <approved-main-commit> \
  --notes-file <approved-release-notes>
```

This creates the approved version tag and a draft, then starts **Publish Release**.
The tag is available immediately. A matching tag and draft are reused when the
same command is retried; a conflicting tag is never moved. CI tests and builds the
arm64 DMG. The **release-signing** environment then requires approval before
Developer ID signing and notarization. Signing uses a temporary keychain,
keeps the simulator settings helper's ad hoc signature and signs the embedded
renderer before the outer app with Developer ID. It uses the same entitlements
as `build-release.sh` and verifies each signature and its entitlements.
The workflow notarizes and staples the DMG, checks both the app and DMG with
Gatekeeper, then uploads the
DMG, `release-info.json`, and `SHA256SUMS` to the same draft and publishes it.
Publication verifies that the tag still targets the tested commit. Failed checks
leave the tag and draft in place. Check Actions before repeating a start command
whose dispatch result is uncertain. A workflow started from an existing draft
also creates its tag during preparation, before build and validation.

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
