# xcode-simulator-host design

## Consumer contract

```console
xcode-simulator-host status [--verbose]
xcode-simulator-host use legacy
xcode-simulator-host use device-hub
xcode-simulator-host restore [--force]
```

- `status` is read-only. Compact output reports only the route used by the next
  Xcode Run. `--verbose` adds installations, compatibility-checked components,
  preferences, restoration state, and running processes.
- `use legacy` selects the direct CoreSimulator route, closes an existing
  standalone host, commits the managed preferences, normally closes the exact
  Device Hub from the selected Xcode, and launches the packaged host with that
  Xcode's path.
- `use device-hub` normally closes the exact packaged host before restoring
  Xcode's default Device Hub route.
- `restore` restores the exact preference state captured before the first
  mutation. If that route uses Device Hub, it closes the standalone host first.
- `restore --force` is the explicit recovery path for a conflicting Boolean
  live state.

Xcode is resolved from `DEVELOPER_DIR` or `xcode-select -p`. Xcode 27 is the
minimum generation. Later versions are supported when they satisfy the same
verified private contract.

## Why a companion host

Xcode 27 no longer supplies Simulator.app, while Device Hub is not an acceptable
legacy-mode host because it also owns continuous pasteboard synchronization and
other device-management behavior. Xcode Previews demonstrates that SimulatorKit
can render and interact with a CoreSimulator screen directly.

The package therefore ships a narrow AppKit companion instead of embedding
DeviceKit or launching Device Hub.

```text
Xcode Build & Run
  -> CoreSimulator session
  -> XcodeSimulatorLegacyHost.app
       -> CoreSimulator device-set membership
       -> IDEPlaygroundSimulator display factory
       -> SimulatorKit SimDisplayView
       -> AppKit window, header, menus
       -> typed HID and device-tool actions
```

## Package and distribution topology

```text
xcode-simulator-host (CLI executable)
XcodeSimulatorLegacyHost (AppKit executable)
XcodeSimulatorHostTests
```

The release archive preserves this layout:

```text
bin/xcode-simulator-host
libexec/xcode-simulator-host/XcodeSimulatorLegacyHost.app
```

The CLI resolves the app relative to its own real executable path. The installer
stages and verifies both artifacts, installs the app first, commits the CLI last,
and restores the previous pair if installation fails.

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
| Observe booted iOS simulator membership | `XSHLegacyHostApplication` |
| Load and validate the private runtime | `XSHPrivateRuntime` |
| Own one display, HID client, and window | `XSHDeviceWindowController` |
| Build and validate active-window menus | `XSHMenuController` |
| Run screenshot and rotation operations | `XSHDeviceToolRunner` |
| Clipboard synchronization | deliberately no owner |

The active simulator for a menu command is derived from `NSApp.keyWindow` each
time. Device selection is not mirrored in a second state store.

## Compatibility gate

Legacy support requires all of the following before receipt recovery, process
termination, or preference mutation:

- selected Xcode bundle identifier `com.apple.dt.Xcode`, version 27 or later,
  and intact Apple signature;
- Device Hub bundle and the two verified preference-key surfaces;
- selected-Xcode SimulatorKit and IDEPlaygroundSimulator frameworks with the
  required classes, selectors, Swift thunks, matching `DTXcode` generation, and
  intact Apple signatures;
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

Wrappers and direct tools are inspected but never executed by the gate. This
prevents their mismatch path from implicitly running `xcodebuild -runFirstLaunch`.

An unknown later Xcode that changes a private symbol or component version is
unavailable. It is never guessed compatible and never falls back to Device Hub.

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

## Preference transaction

The first mutation stores a receipt under the user's Application Support
directory. It records the original tri-state values, last verified state,
selected Xcode version/build, and an optional pending `before -> target`
mutation. Later switches preserve the original state.

For a route transition, `HostModeController`:

1. acquires an exclusive operation lock;
2. validates every required component;
3. closes the existing standalone host when the target or selected Xcode
   requires a restart;
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

### Enter legacy mode

1. Validate Xcode, the companion, private frameworks, tools, and plugin.
2. Normally terminate the exact packaged companion if it is already running.
3. Commit the CoreSimulator-only preference state.
4. Normally terminate only Device Hub instances whose resolved bundle URL
   matches the selected Xcode.
5. Reverify the managed state.
6. Launch the exact packaged app with `--xcode <selected Xcode.app>`.

Every `use legacy` restarts the companion. This makes Xcode 27-to-28 selection
changes deterministic and avoids retaining frameworks from a previous Xcode.

### Leave legacy mode

The exact companion is normally terminated before preferences are changed to a
Device Hub route. Failure to close it stops the transition before mutation.

### Device Hub conflict

The companion refuses to connect if a process with bundle identifier
`com.apple.dt.Devices` already exists. It observes application launches while
active. If Device Hub appears, it cancels device operations, disconnects every
display, and exits. It never kills Device Hub or falls back to it.

## Standalone display lifecycle

The host connects to the selected Xcode's CoreSimulator service context and
subscribes to the default device set. It creates sessions only for booted iOS
devices.

A session discovers the default integrated `SimDeviceScreen`; screen ID zero is
not assumed. It creates a connected `SimDisplayView`, enables device chrome,
creates one `SimDeviceLegacyHIDClient`, and installs the view in a resizable
transparent AppKit window. Shutdown removes the session. Closing a window
suppresses reopening until that device leaves the booted state.

The header and window shell follow the owner behavior found in Simulator.app:
DarkAqua, transparent titlebar, native traffic lights, device chrome, render
scaling during resize, and shadow invalidation. Simulator.app itself is an
analysis source only and is not a runtime dependency.

## Commands and menus

The first parity set contains only commands with an available, validated owner:

- File: Save Screen, Close Window;
- Device: Rotate Left/Right, Home, Lock, Shake;
- I/O: Toggle Software Keyboard;
- Features: Toggle Appearance;
- Window: standard minimize/zoom/full screen, Show Device Bezels, Stay on Top,
  Fit Screen, Bring All to Front.

Home, Lock, and Software Keyboard use typed HID button messages. Shake uses a
fail-loud CoreSimulator Darwin-notification call. Appearance uses the current
and target UI style selectors.

Rotation uses direct Apple `devicectl`. Save Screen uses direct Apple `simctl`
and a same-directory temporary PNG. The file is signature-checked and then
atomically renamed, so cancellation or failure preserves an existing
destination. Device-tool operations are single-flight, drain both output pipes,
have a bounded timeout, and are cancelled when their window closes.

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

Preference commit followed by Device Hub termination or companion launch
failure is reported as partial success; the receipt remains available for
`restore`. A failure to close the companion before leaving legacy mode happens
before preference mutation.

Optional menu-operation failures are shown on the active simulator window and
do not change the route or launch Device Hub.

## Validation

Unit tests use fake commands, temporary Xcode/framework/plugin fixtures, and
isolated receipt directories. They cover tri-state transactions, interrupted
recovery, conflicts, idempotence, exact process identity, Xcode 27/28 gates,
wrapper parsing, generation/version mismatch, signatures, forbidden linkage,
and read-only status behavior.

Release verification builds both products, checks architectures and signatures,
verifies the exact archive file set, installs over a synthetic previous version,
and compares installed CLI/app files with the archive.

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
