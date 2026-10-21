# NeoSimulator design

## Consumer contract

```console
xcode-simulator-host status [--verbose] [--legacy-xcode /path/to/Xcode_26.app]
xcode-simulator-host use neo
xcode-simulator-host use legacy [--legacy-xcode /path/to/Xcode_26.app]
xcode-simulator-host use device-hub
xcode-simulator-host restore [--force]
```

- `status` is read-only. Compact output reports only the route used by the next
  Xcode Run. `--verbose` adds Neo and Legacy availability,
  compatibility-checked components, preferences, restoration state, and
  running processes.
- `use neo` selects the direct CoreSimulator route and launches the packaged
  host with the selected Xcode 27+ installation.
- `use legacy` selects the same CoreSimulator route and launches Apple's
  `Simulator.app` from a validated Xcode 26 installation. The highest validated
  `/Applications/Xcode*.app` candidate is used unless `--legacy-xcode` is set.
- `use device-hub` closes Neo and validated legacy Simulator processes before
  restoring Xcode's default Device Hub route.
- `restore` restores the exact preference state captured before the first
  mutation. If that route uses Device Hub, it closes both direct-route UI hosts
  first. A restored CoreSimulator route does not imply a Neo or Legacy choice.
- `restore --force` is the explicit recovery path for a conflicting Boolean
  live state.

Xcode is resolved from `DEVELOPER_DIR` or `xcode-select -p`. Xcode 27 is the
minimum generation. Later versions are supported when they satisfy the same
verified private contract.

## Why two direct-route hosts

Xcode 27 no longer supplies Simulator.app, while Device Hub is not an acceptable
display host for workflows that require CoreSimulator without continuous
pasteboard synchronization and other device-management behavior. Xcode Previews
demonstrates that SimulatorKit can render and interact with a CoreSimulator
screen directly.

Neo is the self-contained Xcode 27+ path: the package ships a narrow AppKit
companion instead of embedding DeviceKit or launching Device Hub. Legacy is the
compatibility path for users who already have Xcode 26: it reuses Apple's full
`Simulator.app` while the selected Xcode 27+ installation remains the Build &
Run owner.

```text
Xcode Build & Run
  -> CoreSimulator session
  -> NeoSimulator.app
       -> CoreSimulator device-set membership
       -> IDEPlaygroundSimulator display factory
       -> SimulatorKit SimDisplayView
       -> AppKit window, header, menus
       -> typed HID and device-tool actions
```

## Package and distribution topology

```text
NeoSimulator repository and distribution
├── NeoSimulator (Swift package)
│   ├── xcode-simulator-host (executable product)
│   ├── XcodeSimulatorHost (executable target and module)
│   └── XcodeSimulatorHostTests
└── NeoSimulator.xcworkspace
    └── NeoSimulator (AppKit application target)
```

The release archive preserves this layout:

```text
bin/xcode-simulator-host
libexec/xcode-simulator-host/NeoSimulator.app
```

The CLI resolves the app relative to its own real executable path. The installer
first resolves a symlinked bindir to its physical directory, then stages and
verifies both artifacts, installs the app first, commits the CLI last, and
restores the previous pair if installation fails. Rollback derives whether an
old artifact moved from the presence of its same-filesystem backup path, so a
signal cannot land between a move and a separate bookkeeping update.

## Owner map

| Responsibility | Owner |
| --- | --- |
| Parse CLI commands | ArgumentParser command types |
| Execute fixed system commands | `SystemCommandRunner` |
| Read and mutate the two preferences | `DefaultsStore` |
| Persist original and pending state | `ReceiptStore` |
| Validate Xcode 27+ and private components | `InstallationInspector` |
| Serialize route and process transitions | `HostModeController` |
| Observe and terminate exact app identities | `WorkspaceClient` |
| Observe booted iOS simulator membership | `HostApplication` |
| Load and validate the private runtime | `SimulatorRuntime` |
| Own one device's display, HID client, tools, and operations | `DeviceSession` |
| Present one device window | `DeviceWindowController` |
| Define commands, their availability, and state | `DeviceCommand` |
| Build and validate active-window menus | `MenuController` |
| Run device tool subprocesses | `DeviceToolRunner` |
| Clipboard synchronization | deliberately no owner |

The active simulator for a menu command is derived from `NSApp.keyWindow` each
time. Device selection is not mirrored in a second state store.

## Compatibility gates

Every mode first validates the selected Xcode 27+ application, its exact Device
Hub, and both managed preference surfaces. Host-specific validation then runs
before receipt recovery, process termination, or preference mutation.

Neo additionally requires:

- selected-Xcode SimulatorKit and IDEPlaygroundSimulator frameworks with
  matching `DTXcode` generation and intact Apple signatures;
- installed CoreSimulator and CoreDevice frameworks whose `DTXcode` generation
  matches the selected Xcode;
- exactly one numeric `EXPECTED_VERSION` literal in each selected-Xcode
  `simctl` and `devicectl` wrapper;
- exact equality between those expected versions and the installed framework
  versions;
- intact Apple-signed direct `simctl` and `devicectl` executables with their
  expected identifiers;
- an intact Apple-signed simulator CoreDevice plugin whose version matches
  CoreSimulator and whose generation matches Xcode;
- no DeviceKit or Device Hub load-path fragments in direct `devicectl` or the
  simulator CoreDevice plugin;
- the packaged companion app at the exact relative path, with its expected
  bundle identifier and executable.

After those provenance checks, the gate executes the exact packaged companion
in non-UI `--validate-runtime` mode. `SimulatorRuntime` then performs the same
framework loads, ABIBridge lookups of every private message and Swift member,
and loaded-image checks used by the GUI process, without creating an
application, CoreSimulator device set, or display session. This keeps the runtime contract in one owner while still
rejecting a changed Xcode before preference mutation.

Wrappers and direct private tools are inspected but never executed by the gate.
This prevents their mismatch path from implicitly running
`xcodebuild -runFirstLaunch`.

An unknown later Xcode that changes a private symbol or component version is
unavailable. It is never guessed compatible and never falls back to Device Hub.

Selecting a Legacy installation to launch validates:

- an outer `com.apple.dt.Xcode` application whose version is exactly generation
  26 and whose application signature is intact and Apple-anchored;
- its nested `Contents/Developer/Applications/Simulator.app` bundle identifier,
  executable, version metadata, generation-26 `DTXcode`, and Apple application
  signature.

An already-running legacy Simulator is validated separately for termination.
The same Simulator bundle metadata, executable, and Apple application signature
checks apply, along with the supported Xcode 26 directory layout and parent
metadata. Its parent Xcode is not used as a launch source by termination, so
unrelated resources outside `Simulator.app` do not block switching hosts.
The workspace client rechecks the running process's bundle identifier and exact
normalized bundle URL before sending a termination request.

An explicitly selected legacy Xcode may live outside `/Applications`. A copied
or substituted `Simulator.app` outside the supported Xcode 26 layout is never
managed. Full parent-Xcode integrity remains required when selecting that
installation to launch.

## Managed preferences

```text
domain: com.apple.dt.Xcode
key:    DVTiPhoneSimulatorAlwaysLaunchInCoreSimulatorSession

domain: com.apple.dt.Devices
key:    disableAutoStartLiveDeviceView
```

Each value is `absent`, `false`, or `true`. Any other type is a configuration
error. The live adapter uses `defaults`; direct CFPreferences access cannot
reliably observe the Device Hub container domain from this process.

The preferences encode only two routes: CoreSimulator and Device Hub. Neo and
Legacy are separate process strategies for the same CoreSimulator state. The
receipt consequently stores only original, expected, and pending preference
states; persisting a Neo/Legacy choice there would create a second source of
truth for process lifecycle.

## Preference transaction

The first mutation stores a receipt under the user's Application Support
directory. It records the original tri-state values, last verified state,
selected Xcode version/build, and an optional pending `before -> target`
mutation. Later switches preserve the original state.

For a route transition, `HostModeController`:

1. acquires an exclusive operation lock;
2. validates every required component;
3. closes validated UI hosts that conflict with the requested host;
4. reads the current preference state;
5. records the pending transition;
6. verifies full state before and after each individual preference write;
7. finalizes the receipt;
8. applies target-specific process lifecycle work while still holding the lock.

If a write fails, the controller restores the immediately preceding state when
that state can still be proven. A different live state is treated as an
external conflict and is not overwritten.

An intermediate state that could be either an interrupted first write or an
external change is intentionally ambiguous. Normal `use` and `restore` leave it
untouched; only `restore --force` gives the saved original state precedence.

Compact `status` takes an optimistic read before state exists and retries under
the existing lock if the state directory appears concurrently. Once state
exists, status always uses that lock and never performs recovery or mutation.

## Process lifecycle

### Select Neo

1. Validate the selected Xcode, packaged NeoSimulator app, private frameworks,
   tools, plugin, and runtime contract.
2. Validate each running legacy Simulator's application signature and exact
   Xcode 26 location for termination.
3. Reject receipt conflicts, then close those legacy Simulators and restart the
   exact Neo bundle.
4. Commit the CoreSimulator preference state if it is not already active.
5. Terminate only Device Hub instances whose resolved bundle URL matches the
   selected Xcode; failure stops before Neo is opened.
6. Reverify the managed state and launch Neo with
   `--xcode <selected Xcode.app>`.

Every `use neo` restarts Neo. This makes Xcode 27-to-28 selection changes
deterministic and avoids retaining frameworks from a previous selection.

### Select Legacy

1. Validate the selected Xcode 27+, the requested or discovered Xcode 26, and
   its nested `Simulator.app`.
2. Validate every running legacy Simulator by its actual bundle URL.
3. Reject receipt conflicts, then close Neo and all validated legacy Simulator
   instances.
4. Commit the same CoreSimulator preference state used by Neo if needed.
5. Terminate the exact selected-Xcode Device Hub; failure stops before
   Simulator is opened.
6. Reverify the managed state and open the exact validated `Simulator.app`.

Neo-to-Legacy and Legacy-to-Neo switches still execute this process lifecycle
when the preference route is already CoreSimulator. “No preference change” is
not treated as “already using this host.”

### Select Device Hub or restore

`use device-hub` closes the exact Neo bundle and every validated legacy
Simulator before committing the Device Hub preference state. Failure to close a
managed direct-route host stops the transition before mutation.

`restore` closes both host types only when the saved original route is Device
Hub. When the original is CoreSimulator, the receipt has no authority to guess
whether Neo or Legacy should run.

### Runtime host conflicts

Neo refuses to connect if Device Hub (`com.apple.dt.Devices`) or legacy
Simulator (`com.apple.iphonesimulator`) is already running. It observes
application launches while active. If either appears, it cancels device
operations, disconnects every display, and exits. It never kills the competing
host or falls back to it.

## Standalone display lifecycle

The host connects to the selected Xcode's CoreSimulator service context and
subscribes to the default device set. It creates sessions only for booted iOS
devices.

A session discovers the default integrated `SimDeviceScreen`; screen ID zero is
not assumed. It creates a connected `SimDisplayView`, enables device chrome,
creates one `SimDeviceLegacyHIDClient`, and installs the view in a resizable
transparent AppKit window. Shutdown removes the session. Closing a window
shuts the device down, as Simulator.app does with `DetachOnWindowClose` off;
a close that keeps the device running suppresses reopening until the device
leaves the booted state. File ▸ Close Window… (or Control-closing) asks with
Simulator.app's sheet, and Quit NeoSimulator… asks the same for quitting. A
shutdown on close abandons a restart in progress. Launch follows
`AttachBootedOnStart`, then, when no window was attached, starts
`CurrentDeviceUDID` or Simulator.app's fallback: the last iPhone in
CoreSimulator's order, or the first device.

The header and window shell follow the owner behavior found in Simulator.app:
DarkAqua, transparent titlebar, native traffic lights, device chrome, render
scaling during resize, and shadow invalidation. Simulator.app itself is an
analysis source only and is not a runtime dependency.

## Commands and menus

The first parity set contains only commands with an available, validated owner:

- File: New Simulator…, Open Simulator, Save Screen, Close Window, Close Window…;
- Device: Restart, Erase All Content and Settings…, Shut Down, Rotate
  Left/Right, Orientation, Rotate Device Automatically, Home,
  Lock, Side Button (watchOS devices only, so hidden until Neo hosts them),
  Action Button, Siri, Shake, App Switcher, Trigger Screenshot;
- I/O: Toggle Software Keyboard, Increase Volume, Decrease Volume;
- Features: Authorize Apple Pay, Toggle Appearance;
- Debug: Show Parallel Testing Devices;
- Window: standard minimize/zoom/full screen, Show Device Bezels, Stay on Top,
  Fit Screen, Simulators, Bring All to Front.

File ▸ Open Simulator follows Simulator.app's menu delegate: CoreSimulator's
available-device order, a submenu per runtime (none for a single runtime), the
device name with its `descriptiveName` as the Option alternate, and markers on
for booting or booted devices with a visible window and mixed without one. Neo
lists iOS devices only, because it hosts no other platform yet. File ▸ New
Simulator… rebuilds Simulator.app's creation form: every supported device type
and available runtime in CoreSimulator's order, selection corrected to the first
compatible choice, the device type's name as the default name, and `simctl
create` without booting. Its Paired Apple Watch page waits for watchOS hosting.
Window ▸ Simulators is NeoSimulator's own device list; Simulator.app has no such
window.

Parallel testing devices come from a second device set, opened with
`SimServiceContext.deviceSetWithPath:error:` at `TestingDeviceSetPath` or
`~/Library/Developer/XCTestDevices`, never at the default set's path. Neo does
not create a missing set; it watches the parent directory until Xcode creates
it. While Debug ▸ Show Parallel Testing Devices (`ShowTestingDevices`, on by
default) is on, booted devices of both sets get windows; turning it off closes
the testing devices' windows without shutting them down, and turning it on
attaches every booted testing device again. `simctl` reaches a testing device
with `--set`; `devicectl` does not, so rotation and orientation commands are
hidden for it.

Hardware inputs send Indigo HID messages to the connected screen's
`buttonTarget` through `SimDeviceLegacyHIDClient`: button messages for Home,
Lock, Software Keyboard, Side Button, Action Button, Siri, and Authorize Apple
Pay, and consumer-page usages for Trigger Screenshot and volume. Each command
follows Simulator.app's timing: the staccato Action Button is released after
0.5 seconds, and App Switcher presses Home twice 150 ms apart. The session
reports the first failed event of a command, including a delivery failure
SimulatorKit reports later. Closing the window cancels pending steps and
releases a held button first. Commands are shown only for the device family or
`SimDevice` feature Simulator.app requires. Shake uses a
fail-loud CoreSimulator Darwin-notification call. Appearance uses the current
and target UI style selectors.

Rotation uses direct Apple `devicectl`. On initial attachment and after each
relative rotation or Device ▸ Orientation choice, the session reads the
versioned JSON orientation result and sets `SimDisplayView.deviceRotation` from
that actual value; no local counter is the orientation source of truth. The
physical orientation drives the Orientation checkmark, and the last upright
orientation drives the display angle, so Face Up and Face Down keep it. A device
turned counterclockwise (landscape left) is shown at +90°, matching
SimulatorKit's touch mapping and Simulator.app.

Rotate Device Automatically stores Simulator.app's
`RotateWindowWhenSignaledByGuest` key in the app's standard defaults.
SimulatorKit's display view reads that key and sets `deviceRotation` itself
when the guest changes its interface orientation. Each connection registers for
`SimDeviceScreen` property events (`register(types:queue:handler:)` with
`.properties`). When the preference is on and the guest's interface orientation
(`SimScreenProperties.uiOrientation`) changes, the session shows the display at
that orientation's angle and the window refits. Other property changes, such as
the backlight, keep the window size. A window opened while the preference is on
also starts at the guest's interface orientation. Releasing the registration on
disconnect ends the events. The Orientation checkmark keeps showing the physical
orientation that `devicectl` reports, which a guest-initiated rotation does not
change. Save Screen uses direct Apple `simctl` and a
same-directory temporary PNG. The file is signature-checked and then atomically
renamed, so cancellation or failure preserves an existing destination.
Device-tool operations are single-flight, drain both output pipes, have a
bounded timeout, and are cancelled when their window closes.

The following are intentionally absent:

- continuous, send, receive, or automatic pasteboard synchronization;
- Copy Screen, Edit menu clipboard commands, and Services;
- global keyboard, pointer, or game-controller capture;
- Device Manager, external-display, CarPlay, audio-routing, FaceTime, GPU, and
  internal debug menus;
- platform-specific watchOS, tvOS, and visionOS commands;
- commands whose remaining private implementation silently discards failure.

See [Simulator.app analysis](SimulatorAppAnalysis.md) for the complete menu
inventory and classification.

## Failure semantics

The executable follows BSD `sysexits` categories:

| Code | Meaning |
| ---: | --- |
| 0 | success or documented no-op |
| 64 | invalid invocation |
| 69 | unavailable Xcode, host, framework, symbol, tool, or plugin |
| 70 | internal invariant failure |
| 73 | receipt or lock cannot be created |
| 74 | preference or state I/O failed |
| 75 | another operation holds the lock or a managed app does not terminate |
| 78 | malformed configuration, receipt conflict, or external state conflict |

Preference commit followed by Device Hub termination or requested-host launch
failure is reported as partial success; the receipt remains available for
`restore`. A failure to close Neo or a validated legacy Simulator before
selecting Device Hub happens before preference mutation.

Neo launch is successful only after the new process writes its private
startup result following runtime creation, device-set subscription, activation,
and any initial booted-device window creation. LaunchServices returning an
application object is not itself a successful startup.

Legacy launch requires LaunchServices to return the same validated Simulator
bundle URL and identifier. A substituted application is terminated and reported
as a configuration failure.

Optional menu-operation failures are shown on the active simulator window and
do not change the route or launch Device Hub.

## Validation

Unit tests use fake commands, temporary Xcode/framework/plugin fixtures, and
isolated receipt directories. They cover tri-state transactions, interrupted
recovery, conflicts, idempotence, same-route Neo/Legacy switching, exact process
identity, Xcode 26/27/28 gates, wrapper parsing, generation/version mismatch,
signatures, forbidden linkage, exported runtime symbols, and read-only status
behavior.

Release verification builds the SwiftPM CLI and the workspace app target, checks
bundle versions, architectures, and signatures, verifies the exact archive file
set, installs over a synthetic previous version, and compares installed CLI/app
files with the archive.

Live validation additionally covers framebuffer/touch/accessibility, focused
keyboard input, Home, Software Keyboard, resize, menu rotation, screenshot PNG,
Device Hub absence, and loaded-image provenance.

## Non-goals

- Modifying, replacing, re-signing, or deleting Xcode or Device Hub.
- Preventing another user or application from executing Device Hub at the OS
  policy layer.
- Claiming undocumented behavior is supported by Apple.
- Guessing compatibility when a later Xcode changes private contracts.
- Reproducing every platform- or entitlement-specific Simulator.app feature in
  the first release.
