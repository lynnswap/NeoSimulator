# Development

Build and test the app, SDK, documentation, and release packages.

## Workspace and builds

Use Xcode 27+ and Swift 6.4+. Open `NeoSimulator.xcworkspace`, which contains
`App/NeoSimulator.xcodeproj` and the local Swift package.

Implementation lives under `Sources`:

| Module | Responsibility |
| --- | --- |
| `NeoSimulatorNative` | Framework loading and opaque native handles. |
| `NeoSimulatorDeviceIO` | Subprocesses, native request channels, CoreSimulator, and CoreDevice clients. |
| `NeoSimulatorKit` | Public device inventory, models, lifecycle, and sessions; no UI imports. |
| `NeoSimulatorPresentationAdapters` | Native display, input, and pasteboard bindings. |
| `NeoSimulatorUI` | Public AppKit screens, controllers, and views. |
| `NeoSimulatorHostSupport` | Host selection, preference transactions, inventory, and renderer ownership. |
| `NeoSimulatorApp` | Manager UI, inspectors, and app lifecycle. |
| `NeoSimulatorService` | Embedded renderer startup and owner monitoring. |

Kit, UI, App, and Service are library products; the other modules are package-only.
Tests import these modules. For SDK usage, see <doc:UsingTheSDK>.

Targets may import only direct dependencies. CI checks the compiler's import
pre-scan against the manifest and module graph:

```bash
scripts/check-module-graph.py
```

The Xcode application targets contain their entry points and bundle resources.
The manager also contains the LicenseList-backed Licenses pane, passed to the
app module as a view-controller factory. The Objective-C guest-settings helper
remains an Xcode target. Application identifiers and the embedded bundle layout
are defined in the app project.

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

The manager presents screens and starts one headless renderer per Xcode for
guest operations. See <doc:Architecture> for ownership and lifecycle.
Source builds do not replace the app in Applications.

The manager and renderer resolve their private interfaces through ABIBridge.
`DeviceBrowser.swift` has previews using sample devices without connecting to
CoreSimulator.
The settings panes have independent previews in
`GeneralSettingsViewController.swift`, `DevicesSettingsViewController.swift`,
`CaptureSettingsViewController.swift`, `ServiceProfilesSettingsViewController.swift`,
and `LicensesSettingsViewController.swift`.
The background-services inspector has previews in `BackgroundServicesViewController.swift`.
They use sample catalogs and separate preferences domains. Debug builds allow
Xcode's preview process to run alongside the app and skip application startup
in preview processes.

AppKit controllers retain observable models. `ObservationBridge` updates controls,
and `DeviceBrowserState` saves pane visibility, inspector tabs, and device selection.
`DeviceModel` owns device state; selection and inspector models own presentation.

`ServiceProfileStore` owns profile definitions, the default profile, and each device's
selection and overrides. A device resolves its profile by reference, so a later boot
uses the latest definition. Settings edit the selected profile directly. Saving a
modified All Services profile asks for a name and includes accepted changes still being
applied. Profile edits do not change running devices.

`SimulatorManagerModel` observes inventory boot transitions and CoreSimulator boot
dates, then submits automatic profile changes to each device's existing service queue.
Initial running devices are left alone, and a failed automatic change is reported
once rather than retried by every inventory refresh. This behavior belongs to the
manager and store, independent of inspector visibility.

Service profiles and device assignments are stored together in
`Application Support/<app bundle identifier>/ServiceProfiles.json`. Writes are
atomic. The first load migrates the former `BackgroundServiceProfiles` defaults
value only when the file is absent, and removes that value after a successful
write. A read failure preserves the existing data and prevents further writes
until loading succeeds. Profile order is the stored array order; dragging
profiles in settings changes that order in both settings and the inspector.
The built-in All Services profile remains first and is not stored in the file.
It is the initial default; devices inherit the selected default profile unless
they select a saved profile. Per-service overrides apply above either choice.

The Licenses pane uses LicenseList's generated dependency notices and license view,
with an AppKit split view and library list. The simslim notice is loaded from the
bundled `Credits.rtf`, since its code is ported rather than linked as a package.

## Tests

```bash
xcodebuild test -workspace NeoSimulator.xcworkspace -scheme NeoSimulatorKit -destination 'platform=macOS,arch=arm64'
scripts/test-app-bundle.sh
python3 -m unittest discover -s scripts/tests -v
```

Package tests use isolated defaults, process fixtures, and fake device transports;
they do not require an app host or connected devices. Capture tests control file
and GPU work through `CaptureLane` and `RemoteScreenCaptureStream.Lifecycle`.

The app-bundle script builds the NeoSimulator scheme and runs
`NeoSimulatorLicenseTests`. This separate target checks the LicenseList-generated
notices and bundled `Credits.rtf`.

Release-script tests check renderer metadata, signing order, and entitlements.
Changes to private APIs also need a live check on the affected runtime.

Use NeoSimulator.app for physical-device, VM, and Device Hub access checks:
macOS grants access to the requesting program, so standalone diagnostics have
separate permissions. Simulators can also be checked with `simctl`.

UI fixtures must work while the Mac is locked. Disable animations and
synchronize asynchronous work with explicit events or controlled deadlines;
elapsed sleeps and repeated task yields do not establish completion.

## Documentation

The published guide comes from `Documentation/NeoSimulator.docc`. Keep app
installation in README, SDK usage in <doc:UsingTheSDK>, and API contracts in doc comments.

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

Open `http://localhost:8000`. On pushes to main, the Documentation workflow builds
and deploys the guide to GitHub Pages. The repository's Pages source must be
**GitHub Actions**.

## DMG distribution

`build-release.sh` builds the app and signs the renderer before the manager.
The guest-settings helper stays ad hoc signed in Resources, with its simulator
entitlements embedded in the binary. Its macOS signing exceptions allow DYLD
environment variables and disable library validation. The manager has
`com.apple.security.device.camera` for physical-device capture; the renderer has
no entitlements.

Signing defaults to ad hoc. `--signing-identity` or `CODE_SIGN_IDENTITY` selects
a certificate and enables secure timestamping. `package-release.sh` creates the
DMG and verifies its files, signatures, architectures, and Finder layout.
Packaging requires Python 3.10+; CI uses 3.13. Local validation DMGs are not releases.

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

Use `--prerelease` for a prerelease. For a manual **Publish Release** run, its
**prerelease** checkbox must match the draft; a mismatch stops before tag creation.

The start command creates the tag and draft, then dispatches **Publish Release**.
Retries reuse a matching tag and draft; conflicting tags are never moved. Check
Actions before retrying an uncertain dispatch. Starting from an existing draft
also creates the tag before building.

CI tests and builds the arm64 DMG, then waits for **release-signing** approval.
It uses a temporary keychain for Developer ID signing and notarization, preserves
the helper's ad hoc signature, and verifies signatures and entitlements. After
stapling and Gatekeeper checks, it uploads the DMG, `release-info.json`, and
`SHA256SUMS`, verifies the tag still points to the tested commit, and publishes.
Failures leave the tag and draft available for retry.

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

In GitHub Actions, release apps and DMGs are built only when **Publish Release**
runs for a prerelease or release. Ordinary pushes to main run CI without producing release artifacts.
Updates are installed by replacing the app in Applications.
