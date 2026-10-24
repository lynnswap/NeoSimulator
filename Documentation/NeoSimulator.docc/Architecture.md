# Architecture

The manager app owns host selection and preference recovery; its embedded
renderer owns device sessions.

## Hosts and preferences

Neo uses these CoreSimulator-route preferences:

| Domain | Key |
| --- | --- |
| `com.apple.dt.Xcode` | `DVTiPhoneSimulatorAlwaysLaunchInCoreSimulatorSession` |
| `com.apple.dt.Devices` | `disableAutoStartLiveDeviceView` |

Each key is absent, false, or true. Other types are configuration errors.
`DefaultsStore` reads and writes the managed domains through `defaults`, which
resolves Device Hub's container preferences. It queries those domains directly
without enumerating every preference domain on the Mac.

`RestorationReceipt` records original, expected, and pending preference states.
It records route preferences independently of the running renderer.
A lock serializes operations. Writes are journaled before mutation and verified
afterward. Recovery handles interrupted writes, preserves conflicting external
changes, and keeps the original tri-state values for restore.

## Host switching

Display Host is an app-wide setting in Settings. Before changing the route,
the manager validates its internally resolved Xcode, managed preferences, and
Device Hub identity. Renderer-specific compatibility checks also run before
receipt recovery or process termination; see <doc:SimulatorIntegration>.

Selecting Neo commits the CoreSimulator route if needed, closes Device Hub,
and starts a renderer when one is needed. Existing renderer processes remain
available. Selecting Device Hub closes the managed renderers, changes the
route, and opens Device Hub. Handover leaves simulator devices running.

The manager remains in the Dock in both modes. Its Dock Device menu and File
Open Simulator menu share the device catalog and launch action. They group
devices by runtime. Xcode resolution is internal to the controller.

The browser reads simulator catalogs and CoreDevice inventory independently.
Simulator identity includes its UDID and device-set path; physical devices and
virtual machines use their CoreDevice command identifier. A failed source
does not remove devices returned by the other sources. Simulator catalogs
remain authoritative for simulator availability and runtime information.
CoreDevice contributes capabilities without duplicating those simulator rows.

Management actions retain the selected identities through asynchronous work.
The controller reports each device's result and completed steps, so a partial
failure does not require repeating successful operations. Operations on a live
simulator wait for the renderer's recording and display cleanup before running
commands that remove its session.

The manager observes CoreDevice's device-change stream and refreshes inventory
when a device connects or disconnects. The observation does not advertise the
Mac or request pairing. VM power and removal operations resolve CoreDevice
capability implementations for the current target. These private interfaces run
in the manager process through ABIBridge, so availability and ABI failures affect
that process. Simulator display and clipboard ownership remain in their renderers.

Each Xcode installation has its own renderer process. The renderer has a
distinct bundle identity and runs separately because its loaded Objective-C
framework classes cannot be unloaded. This allows device windows to use
different framework versions at the same time.

Termination checks the running app's bundle identifier and normalized bundle
URL. The renderer's startup acknowledgement follows runtime creation,
device-set subscription, activation, and initial window handling. A
LaunchServices result alone does not establish successful startup.

`HostConflictMonitor` rejects a competing host at startup and observes later
launches. If Device Hub or Simulator.app appears, Neo cancels operations,
disconnects sessions, and exits, leaving devices running for handover. It does
not terminate the competing application.

## Device-to-Xcode association

The manager observes simulator app processes through public process APIs. It
uses `SIMULATOR_UDID` together with Xcode developer paths in the launch
environment to identify a device's launching Xcode. PID and process start time
distinguish new launches from an already processed observation. A newer launch
can transfer that device to the matching renderer while leaving other devices
with their existing renderers.

When no source observation is available, the controller chooses an installation
that lists the device as available. It considers the system-selected Xcode and
other compatible installations internally. An unsupported `xcode-select`
selection falls back to an installed Xcode 27 or later. Attaching a debugger to
an already-running process is not a verified source-association path.

Catalog and device-setting commands call the installed CoreSimulator `simctl`
directly with the resolved Xcode's `DEVELOPER_DIR`. Discovery does not run the
Xcode wrapper's first-launch installation.

New Simulator uses a shared AppKit form in the manager. A short-lived,
read-only renderer utility exports the CoreSimulator creation catalog and
validated watch/phone pairings without starting a display host. Creation and
pairing commands retain that catalog's developer context, including in Device
Hub mode.

## App ownership

| Owner | Responsibility |
| --- | --- |
| `SimulatorHostController` | Serialize route changes, track renderer ownership, and resolve the Xcode for each device. |
| `SimulatorManagerModel` | Publish catalogs, device settings, loading state, and operation results to AppKit. |
| `ManagerWindowController` | Present the sidebar, device canvas, and settings inspector in `NSSplitViewController`. |
| `SimulatorRuntime` | Load and validate private framework interfaces through ABIBridge. |
| `CoreSimulator` | Device-set access and simulator model data. |
| `HostApplication` | Observe device sets, own sessions and windows, and coordinate launch and shutdown. |
| `DeviceSession` | Device connection, input, pasteboard, audio, external-display state, and device operations. |
| `DeviceWindowController` | Present the device and forward user actions. |
| `ExternalDisplayWindowController` | Present a device's external display. |
| `DeviceCommand`, `MenuController` | Define commands and derive menu state from the active window. |
| `DeviceToolRunner` | Run and cancel selected-Xcode tool subprocesses. |
| `PasteboardSync` | Exchange copies between the Mac and connected sessions. |
| `ExternalDisplayChanges` | Serialize display and CarPlay changes across sessions for one device. |
| `DisplayKeyboardInput`, `DisplayFitting` | Shared input-focus and geometry behavior for both window types. |
| `TVRemoteController` | Present the remote; sessions retain held inputs until release. |

Within a renderer, the active device comes from `NSApp.keyWindow`; an
external-display window refers to its owning device. The manager's sidebar
selection identifies the inspector target independently of the active device
window.

## Device lifecycle

Neo observes the default device set and, when present, Xcode's parallel testing
set when Show Parallel Testing Devices is enabled. It does not create the
testing set. The manager coordinates attachment and process-source observations
for both sets, and commands retain the selected device's set path.
`AttachBootedOnStart`
controls the initial booted-device snapshot; later boot transitions can attach
new devices. Explicitly detached windows remain closed until the device leaves
the booted state or the user opens it again.

Each session discovers the integrated screen rather than assuming screen ID
zero, connects a `SimDisplayView`, and creates a `SimDeviceLegacyHIDClient`.
A connection failure is shown for that device without making other devices
unavailable. Shutdown removes its session. Closing with Keep Running suppresses
automatic reopening until the device leaves the booted state.

Restart and erase disconnect and reconnect the existing window. Session teardown
cancels commands and ends owned connections. Input releases and external-display
changes must finish against the session or device that owns them, even after
the active window changes.

## Failure ownership

Preference or host-switch failures appear in the manager with their remaining
recovery state. Device errors stay with the relevant window. A failed
capture keeps its recoverable file; partial imports and device creation retain
and report completed work. None of these failures changes the selected route
or launches Device Hub as a fallback.
