# Architecture

The manager app owns host selection, preference recovery, and device screens.
Its embedded renderer processes own simulator boot, restart, and shutdown, and
monitor manager termination independently of presentation windows.

For the public SDK, see <doc:UsingTheSDK>. For private-framework compatibility,
see <doc:SimulatorIntegration>.

## Hosts and preferences

NeoSimulator manages these CoreSimulator routing preferences:

| Domain | Key |
| --- | --- |
| `com.apple.dt.Xcode` | `DVTiPhoneSimulatorAlwaysLaunchInCoreSimulatorSession` |
| `com.apple.dt.Devices` | `disableAutoStartLiveDeviceView` |

Each value is absent, false, or true; other types are errors. `DefaultsStore`
uses `defaults` to access the managed domains, including Device Hub's container.
`RestorationReceipt` journals original, expected, and pending values under a
lock, verifies writes, and recovers interrupted transactions without overwriting
conflicting external changes.

`display-host.txt` stores the preferred host separately. If absent, the manager
uses a legacy receipt's intent or defaults to NeoSimulator. Startup applies the
preference and checks for external changes, as do explicit host changes and
restoration. Catalog reads and screen opening use local state.

Automatic presentation requires a successfully applied preference in the current
manager session. An interrupted transaction suspends attachment until a host
change or restoration resolves it. Restoration ends automatic Neo hosting even
if the original preferences selected the CoreSimulator route.

Host changes validate Xcode, managed preferences, Device Hub identity, and the
renderer contract before recovering receipts or terminating processes. Selecting
NeoSimulator configures the route, closes Device Hub, and starts renderers as
needed. Selecting Device Hub closes managed renderers, changes the route, and
opens Device Hub. Both leave guests running.

Startup applies the preference before processing URL requests or restoring
screens. Quitting closes screens and renderers and ends automatic hosting, but
keeps the route and restoration receipt. No background launch service is installed.

## Device discovery and Xcode association

The browser reads simulator catalogs and CoreDevice inventory independently. A
failed source preserves devices from that source. Simulator catalogs determine
simulator availability and runtime information; CoreDevice adds capabilities
without duplicating simulator rows.

A simulator's identity includes its UDID and device-set path. Physical devices
and VMs use their CoreDevice command identifier. CoreDevice change notifications
refresh inventory without advertising the Mac or requesting pairing.

The manager associates simulator app processes with Xcode using `SIMULATOR_UDID`
and developer paths in their launch environment. PID and process start time
distinguish launches. A newer launch can transfer one device to another renderer.
Without that observation, the controller chooses a compatible installation that
lists the device. An unsupported `xcode-select` selection falls back to an
installed Xcode 27 or later. Attaching a debugger to a running process is not a
verified association path.

Catalog and settings commands invoke the resolved installation's `simctl`
directly with `DEVELOPER_DIR`, avoiding the Xcode wrapper's first-launch setup.
New Simulator obtains a creation and pairing catalog from a short-lived,
read-only renderer utility. Creation retains that catalog's developer context,
including in Device Hub mode.

### Sidebar activity

For open native canvases, `DeviceActiveStateObservation` reads DeviceKit's
`SidebarModel.shouldRenderAsActive(_:)`. This predicate uses DeviceKit views in
the manager process; SimulatorKit, remote screens, Device Hub, and renderers do
not contribute their activity.

Evaluating a device can start its native HID services and interfere with
SimulatorKit input. `init(limitedTo:)` therefore evaluates only open native-canvas
devices reported by `DeviceScreens`, using their CoreDevice identifiers. Custom
simulator sets have no CoreDevice record and no activity value.

Within an availability group, active devices sort first. Other rows use the
remaining sort criteria and Neo's screen and boot state for artwork. A failed
read clears activity values and reports an inventory issue. DeviceKit's own
observation and coordinators last for the process; stopping Neo's observation
ends only its reads and callbacks.

## Ownership and presentation

| Owner | Responsibility |
| --- | --- |
| `SimulatorHostController` | Host changes, operation ordering, renderer ownership, and Xcode resolution. |
| `SimulatorManagerModel` | Observable inventory and the manager's operation queue. |
| `DeviceRegistry`, `DeviceModel` | Stable device identity, shared state, and ordered changes. |
| `ManagerSelection`, inspector models | Selection and presentation state. |
| `ManagerWindowController`, `DeviceScreenViewController` | Sidebar, inspector, and placement of screens in the main or compact window. |
| `DeviceScreens` | Index open screens and own their contexts and remote connections. |
| `SimulatorContext`, `SimulatorDeviceSession` | Public device discovery, guest lifetime, state, and commands. |
| `SimulatorScreens`, `SimulatorScreen` | Public AppKit presentation, using `DeviceWindowPresenter`. |
| `SimulatorScreenHost`, `DeviceSession` | Device-set observation, sessions, and resource cleanup. |
| `NativeFrameworks` | Private-framework loading and the process's single UI toolkit. |
| `SimulatorIORuntime`, `SimulatorPresentationRuntime` | Per-Xcode device interfaces and process-wide presentation interfaces. |
| `SimulatorScreenRouter` | Display connection and capability-based input and pasteboard routing. |
| `HostApplication` | Renderer lifecycle, menus, manager requests, and ownership registration. |
| `CapturedContent`, `RecordingStore`, `VideoRecording` | Capture files, destination claims, and recording completion. |
| `RemoteDeviceScreenSession` | Remote display transport, input, resize assertions, and recordings. |
| `SystemCommandRunner` | Subprocess launch, cancellation policy, reaping, and output cleanup. |
| `SimulatorDeviceChannel`, `DeviceIOHub` | Native request ordering, deadlines, and in-flight work. |

Each Xcode has a headless renderer with a bundle identifier distinct from the
manager's. The manager loads one SimulatorKit/DeviceKit UI toolkit for its
process lifetime while device operations retain their own Xcode contexts.
Objective-C framework classes cannot be unloaded.

Moving a screen between the main pane and a compact window retains its
connection, input queue, recording, and captures. It does not invoke close
policy. Restart finishes recording and disconnects presentation before changing
the guest, then reconnects the retained controller. Management operations report
completed steps and per-device failures.

Renderer startup acknowledges success only after runtime creation, ownership
registration, device-set subscription, and a final competing-host check.
Termination identifies the app by bundle identifier and normalized bundle URL.
`HostConflictMonitor` rejects competing hosts at startup and observes later
launches. When Device Hub or Simulator.app appears, Neo disconnects affected
sessions and leaves guests running. It neither quits the competitor nor ends the
manager for an in-process presentation conflict.

Observable models and AppKit presentation stay on MainActor. Blocking discovery,
process scans, catalog decoding, and preference I/O run in `@concurrent` helpers.
`NativeFrameworks` serializes framework checks and loads on its own queue.
Concurrent preparation joins the existing task.

Operations on different devices can overlap; operations on one device retain
acceptance order. Host, preference, and renderer-lifetime changes wait for all
prior operations and hold later ones. A screen open becomes such a barrier only
when it must start a renderer. Catalog reads keep a device that is being
changed in its earlier state until the change ends. The active command target comes from `NSApp.keyWindow`;
sidebar selection independently chooses the inspector target.

## Device lifecycle

Neo observes the default set and, when enabled and present, Xcode's parallel
testing set. It does not create the testing set. The manager attaches no device
by itself, whether it was booted at launch or later: only a request opens a
screen. Xcode launching an app moves an open screen to that Xcode. A renderer
that another app opens by itself follows `AttachBootedOnStart` instead.

Sessions discover the integrated screen rather than assuming screen ID zero.
A failed connection affects only that device. Teardown cancels commands and
releases connections; input releases and external-display changes finish against
their original session even if the active window changes.

## Native device requests

CoreSimulator calls can block indefinitely on a guest, service, or internal
queue. `SimulatorDeviceChannel` dispatches them to a serial worker and stays
responsive on its actor. Read-modify-write operations, such as Toggle Appearance,
run as one request.

A deadline ends the caller's wait, not the native call:

| Condition | Result |
| --- | --- |
| Cancelled before starting | `CancellationError`; the call never runs. |
| Read cancelled while running | `CancellationError`. |
| Change cancelled while running | `outcomeUnknown(.cancelled)`. |
| Read past its deadline | `noAnswer`. |
| Change past its deadline | `outcomeUnknown(.timedOut)`. |
| Requested or queued behind an overdue call | `notSent`. |

An overdue call makes the channel `unresponsive` until it returns. No replacement
worker starts. Late results receive cleanup through `lateCompletion` or
`cleanUp`. Abandoned requests are not replayed; the session reapplies current
preferences when the channel recovers, without delaying presentation.

### Device sets and clients

`SimulatorDeviceSet` opens and reads one set on its own worker, exposing cached
`SimulatorDeviceRecord` values. CoreSimulator's state and catalog accessors also
block, so menus and views read these values instead of calling them directly.
`refresh()` coalesces concurrent requests into one active read and at most one
pending read. Failure preserves cached values. Native notifications and channel
recovery request another read.

Guest access uses a shared `SimulatorDevice` for each developer directory,
device-set path, and UDID. Its private CoreSimulator context prevents a blocked
lookup from holding another device's connection. The client opens lazily;
concurrent callers share the opening, and a failed opening is retried on demand.
Closing a window, rebooting, or timing out retains the client.

Deletion or CoreSimulator connection invalidation ends the client. An unavailable
runtime or failed listing does not. Old requests then fail unsent; a replacement
uses the same worker so it cannot overlap an outstanding call.

Releasing the native context requires cancelling its connection, waiting for the
end notification and all `SimulatorDevice` holders, then clearing the private
set's retained context, devices, and pairs on the worker. Releasing earlier can
leak the context or leave SimulatorKit with a device whose weak set has gone.
Device-set and device workers have separate connections, but remain subject to
CoreSimulatorService-wide stalls and synchronous SimulatorKit calls.

### Optional services

CoreDevice initialization uses one `SharedTask`. Caller cancellation and the
`coreDeviceInitialization` deadline end only the wait; later callers join the
same initialization.

A display connects using its own requirements. Native input and pasteboard
services follow the device's capabilities. `CoreDeviceRecordDiscovery` waits for
a connected record using change notifications; it follows replacement records
and discards stale reads. A Duo canvas also needs this record and uses the
`coreDeviceRecord` deadline.

Only a connected record lacking a feature marks it unsupported. A connection
failure keeps the chosen route and offers retry. SimulatorKit input remains
active while native input prepares. Handover waits for held pointers and buttons
to release, then activates native touches before native keyboard or trackpad
input, because those services make the guest reject SimulatorKit touches.
3D Touch devices keep SimulatorKit input to preserve pressure.

### Termination

The manager gives accepted work `TerminationTimeout`, reports queued work as
not run, and stops running uninterrupted commands. Transactions and rollbacks
receive `terminationGrace`; unfinished outcomes remain unknown.
`TerminationAccount` records remaining work for the quit report, including
requests still held by `DeviceIOHub`.

## Device state

`DeviceRegistry` retains one `DeviceModel` per listed device. Inspector views,
screen commands, and SDK clients share its cached values. `keepCurrent(_:)`
retains interest in selected groups; unobserved groups refresh when interest
resumes. Separate processes have separate registries.

Settings and inspection groups read independently and publish only changed
values. Failed reads preserve values and report status; unsupported groups
clear their values. A temporarily stopped or disconnected device keeps its
values and reports that it cannot currently read them.

Changes run in order per device and invalidate only affected groups, including
after failure that may have partly changed the device. Stale reads cannot
overwrite accepted changes or a new device generation. One confirming read
follows the last accepted change in a group, even after the view closes.

Inventory removes a device only after every source that listed it successfully
reports its absence. A screen connection can update boot state before inventory
catches up; an older inventory read cannot overwrite it.

Native events, commands, explicit refresh, and foreground activation invalidate
state. Reads use no timer and coalesce invalidations received during a read.
Changes from other processes without an observable signal require revalidation.

## Captures and remote screens

A capture owns its temporary file until saved, deleted, or delivered. File work
runs serially off MainActor; destination claims prevent competing writes.
Shutdown waits for a bounded interval and reports files still in progress.
Late failures remain reportable until the capture is resolved or acknowledged;
failed saves are not retried automatically. Cross-volume saves publish only a
complete destination and report any source left behind. Partial imports and
device creation likewise report completed work.

VMs use Screen Sharing when VNC is available, with its pasteboard sharing
disabled. Physical devices use a user-selected AVFoundation capture source and
Metal rendering, with CoreDevice supplying input, geometry, and supported
recording operations. The manager requests Camera access. macOS does not identify
which device a capture source shows, so `ScreenCaptureSourceCatalog` stores the
user's choice in `RemoteScreenCaptureSources`, keyed by CoreDevice identifier.
A source belongs to at most one device; reconnecting fails if it does not return.

`RemoteDeviceScreenSession` owns the frame independently of its transport.
DeviceKit draws chrome and masks around the framebuffer without starting its own
display stream. Side buttons send the chrome's declared HID usages. Trackpad
events use one UniversalHID service per originating Mac HID service. The first
gesture event positions its hidden pointer with the current display transform;
later events retain that position. Focus loss resets gestures, and disconnect
removes the services.

Resize App uses a separate CoreDevice media stream and requires
`com.apple.videoconference.allow-conferencing`, which the manager's signing
profile does not include. Remote shutdown releases input and connections while
leaving the device running. Recording handles survive cancellation and failed
stops for retry; completed movies remain until saved or discarded. Cancelling an
unsaved-recording prompt keeps the window open.
