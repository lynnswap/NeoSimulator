# Architecture

The manager app owns host selection, preference recovery, and device screen
presentation. Its embedded renderer processes retain simulator guest ownership
and monitor manager termination independently of the presentation windows.

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

Ordinary startup, status, connection synchronization, and screen opening read
the saved display choice rather than another app's preferences. A settled
receipt supplies the managed intent; without a receipt, `display-host.txt` in
the same state directory supplies the last selected host, initially Device Hub.
An interrupted transaction disables automatic attachment until an explicit
host change or restore resolves it. This local metadata does not establish the
current Xcode preferences. Only explicit host changes and restoration validate
those values and check for external conflicts. A restore relinquishes automatic
Neo hosting even when the original preferences used the CoreSimulator route.

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
that process. Simulator display and clipboard sessions also run in the manager;
headless renderer processes own guest boot, restart, and shutdown.

Each Xcode installation has its own headless renderer process with a distinct
bundle identity. The manager loads one compatible SimulatorKit UI toolkit for
its process lifetime and opens device service contexts for each owning Xcode.
Loaded Objective-C framework classes cannot be unloaded, so UI toolkit selection
stays fixed while device operations retain their own developer context.

The same presentation owner retains the connection, input queue, recording, and
captures when its view controller moves between the center pane and a compact
window. Moving a presentation does not invoke device-close policy. Restart
finishes recording and disconnects presentation before the headless backend
mutates the guest, then reconnects the retained presentation controller.

Termination checks the running app's bundle identifier and normalized bundle
URL. The renderer's startup acknowledgement follows runtime creation,
device-set subscription, activation, and initial window handling. A
LaunchServices result alone does not establish successful startup.

`HostConflictMonitor` rejects a competing host at startup and observes later
launches. If Device Hub or Simulator.app appears, Neo cancels operations,
disconnects sessions, and retires the affected host, leaving devices running
for handover. An in-process presentation host leaves the manager running. It
does not terminate the competing application.

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
| `SimulatorManagerModel` | Own observable inventory, loading state, and the accepted operation queue. |
| `DeviceSettingsModel` | Own the selected settings snapshot, cancellable reads, and readback after queued edits. |
| `DeviceInspectorModel` | Own inspector records and reject results from an earlier selection or page. |
| `ManagerWindowController` | Present the sidebar, device screen pane, and settings inspector in `NSSplitViewController`, and own the selection and toolbar. |
| `DeviceScreenViewController` | Show the selected device's screen or preview in the center pane, with its canvas controls and activity footer. |
| `SimulatorRuntime` | Load and validate private framework interfaces through ABIBridge. |
| `CoreSimulator` | Device-set access and simulator model data. |
| `HostApplication` | Observe device sets, own sessions and windows, and coordinate launch and shutdown. |
| `DeviceSession` | Device connection, input, pasteboard, audio, external-display state, and device operations. |
| `DeviceWindowController` | Present the device and forward user actions. |
| `RemoteDeviceScreenSession` | Own one active physical-device or VM screen transport, its resize assertion and input resources, and unfinished or completed recordings. |
| `CoreDeviceAppResizeTransport` | Bridge native app-resize eligibility and assertions for Simulator and remote sessions. |
| `RemoteDeviceWindowController` | Present a remote screen and drain accepted captures, recording saves, and input before disconnecting. |
| `ExternalDisplayWindowController` | Present a device's external display. |
| `DeviceCommand`, `MenuController` | Define commands and derive menu state from the active window. |
| `DeviceToolRunner` | Run and cancel selected-Xcode tool subprocesses. |
| `PasteboardSync` | Exchange copies between the Mac and connected sessions. |
| `ExternalDisplayChanges` | Serialize display and CarPlay changes across sessions for one device. |
| `DisplayKeyboardInput`, `DisplayFitting` | Shared input-focus and geometry behavior for both window types. |
| `NativeDeviceKeyboard` | Send a default-set simulator's keyboard input through one CoreDevice keyboard service per Mac keyboard, described by that keyboard's properties. |
| `TVRemoteController` | Present the remote; sessions retain held inputs until release. |

The manager's observable models stay on MainActor. SwiftUI observes their
properties directly; AppKit tracks the properties used by layout and targeted
list or toolbar updates. The manager drains accepted edits before quitting.
Cancelled reads cannot replace the current selection's snapshot, and a refresh
interrupted by an edit resumes after the operation queue finishes.

`SimulatorHostController` retains shared ownership state and operation ordering.
Synchronous discovery, catalog decoding, process scans, and host preference I/O
run in `@concurrent` helpers. Initial native bindings resolve asynchronously
while UI receivers and framework loading stay on MainActor. Concurrent loads of
the same context join its preparation without changing the fixed UI toolkit.

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

VMs use Screen Sharing when a VNC endpoint is available, with its pasteboard
sharing disabled. A USB-connected physical device's primary display comes from
the Mac capture source chosen for that device: `CoreDeviceCaptureTransport`
receives IOSurface-backed frames through AVFoundation, and Metal copies the
latest frame into the AppKit screen view. Input goes to the same CoreDevice
device through its HID services, and CoreDevice also supplies the display
geometry and, where supported, recording. Screenshots copy the latest captured
frame. Resize App shows the app's dedicated display through CoreDevice's media
stream and is unavailable unless the manager's signature has the
`com.apple.videoconference.allow-conferencing` entitlement that the stream
requires; the manager's signing profile does not include it. These transports
run inside the manager app, which requests Camera access before capture
starts. A remote screen closes its owned connections and releases held inputs
without shutting down the device.

macOS lists a connected device's screen as an AVFoundation capture source once
the manager enables CoreMediaIO screen-capture devices for its process, but it
does not report which CoreDevice device a source shows. A source's name does
not identify the device either, so the screen does not connect until the user
chooses its source. `ScreenCaptureSourceCatalog` stores the chosen source's AVFoundation
unique ID and name under the device's CoreDevice identifier in the
`RemoteScreenCaptureSources` preference of `dev.lynnswap.NeoSimulator`.
Choosing a source removes it from any other device's entry. A later connection
waits briefly for the stored source and fails if it does not reappear; choosing
a source again replaces the entry.

The screen session retains a native recording handle through start and stop,
including a handle returned after cancellation. Stopping keeps the completed
movie until a successful atomic save or an explicit discard. A failed stop
keeps the handle available for retry. Windows drain accepted capture and save
operations before closing; cancellation of an unsaved-recording prompt keeps
the window open.
