# Architecture

The CLI owns host selection and preference recovery; the app owns device sessions.

## Hosts and preferences

Legacy and Neo share these CoreSimulator-route preferences:

| Domain | Key |
| --- | --- |
| `com.apple.dt.Xcode` | `DVTiPhoneSimulatorAlwaysLaunchInCoreSimulatorSession` |
| `com.apple.dt.Devices` | `disableAutoStartLiveDeviceView` |

Each key is absent, false, or true. Other types are configuration errors.
`DefaultsStore` uses `defaults` because direct CFPreferences access does not
reliably observe Device Hub's container domain.

`RestorationReceipt` records original, expected, and pending preference states.
It stores no Legacy/Neo selection: process identity determines the display host.
A lock serializes operations. Writes are journaled before mutation and verified
afterward. Recovery handles interrupted writes, preserves conflicting external
changes, and keeps the original tri-state values for restore.

## Host switching

Every `use` command validates the selected Xcode, managed preferences, and exact
Device Hub identity before mutation. Host-specific compatibility checks also
run before receipt recovery or process termination; see
<doc:SimulatorIntegration>.

For Legacy or Neo, the CLI closes managed direct hosts, commits the
CoreSimulator route if needed, terminates the selected Xcode's Device Hub, then
launches the requested host. Failure to terminate Device Hub prevents that
launch. Repeating a host selection still restarts its process.

For Device Hub, it closes Neo and validated Legacy instances before changing
the route. Restore closes direct hosts only when recovering a Device Hub route.
It does not choose a host for an original CoreSimulator route.

Termination checks the running app's bundle identifier and normalized bundle
URL. Neo's startup acknowledgement follows runtime creation, device-set
subscription, activation, and initial window handling. A LaunchServices result
alone does not establish successful startup. Legacy launch verifies the returned
app identity against the validated bundle.

`HostConflictMonitor` rejects a competing host at startup and observes later
launches. If Device Hub or Simulator.app appears, Neo cancels operations,
disconnects sessions, and exits, leaving devices running for handover. It does
not terminate the competing application.

## App ownership

| Owner | Responsibility |
| --- | --- |
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

The active device is derived from `NSApp.keyWindow`; an external-display window
refers to its owning device. No second selection store mirrors it.

## Device lifecycle

Neo observes the default device set and, when present, Xcode's parallel testing
set. It does not create the testing set. A booted supported device gets a
session when launch settings and explicit attachment state permit it.

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

Preference or host-switch failures go to the CLI with their exit category and
remaining recovery state. Device errors stay with the relevant window. A failed
capture keeps its recoverable file; partial imports and device creation retain
and report completed work. None of these failures changes the selected route
or launches Device Hub as a fallback.
