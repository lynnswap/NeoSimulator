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

`display-host.txt` in the same state directory records the preferred display host.
An installation without that file uses a legacy receipt's intent when available,
or NeoSimulator by default. The receipt records managed Xcode settings independently
of that preference. Status, connection synchronization, and screen opening use
local metadata. Startup applies the preference and checks Xcode's settings for
external conflicts, as do explicit host changes and restoration.

The controller also tracks whether this manager session successfully applied its
display preference. Participating sessions follow the shared preferred host. The
preference alone does not enable Neo presentation after a failed startup.
An interrupted transaction disables automatic attachment until a host
change or restore resolves it. Restore relinquishes automatic Neo hosting even
when the original preferences used the CoreSimulator route.

## Host switching

Preferred Display Host is an app-wide setting in Settings. Before changing the route,
the manager validates its internally resolved Xcode, managed preferences, and
Device Hub identity. Renderer-specific compatibility checks also run before
receipt recovery or process termination; see <doc:SimulatorIntegration>.

Selecting Neo commits the CoreSimulator route if needed, closes Device Hub,
and starts a renderer when one is needed. Existing renderer processes remain
available. Selecting Device Hub closes the managed renderers, changes the
route, and opens Device Hub. Handover leaves simulator devices running.

Startup queues the display session before the initial URL requests, including
screen restoration after relaunch. It reads and applies the preference in one
transaction, using the same Xcode
resolution as device operations, without launching a renderer; screen requests start
renderers as needed. After the manager has closed its screens and renderers and
prepared any requested relaunch, it ends automatic hosting in its controller.
The selected route remains configured after exit. Only an explicit host change
or restoration changes the preferences. The receipt remains available for
explicit restoration and interrupted preference transactions; no background
launch service is installed.

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
failure does not require repeating successful operations. Operations that
restart, erase, shut down, or remove a live simulator first wait for the manager
to finish its screen's recording and disconnect the screen.

The manager observes CoreDevice's device-change stream and refreshes inventory
when a device connects or disconnects. The observation does not advertise the
Mac or request pairing. VM power and removal operations resolve CoreDevice
capability implementations for the current target. These private interfaces run
in the manager process through ABIBridge, so availability and ABI failures affect
that process. Simulator display and clipboard sessions also run in the manager;
headless renderer processes own guest boot, restart, and shutdown.

The sidebar's Active priority and artwork for a simulator shown in DeviceKit's
native canvas come from DeviceKit's `SidebarModel.shouldRenderAsActive(_:)`, the
predicate behind Device Hub's own sidebar. The predicate uses the interaction and
activation state of DeviceKit views in the manager process, which only the native
canvas supplies. Screens shown through SimulatorKit or Neo's remote-screen
transports, Device Hub, and renderer processes do not contribute that state.

Evaluating the predicate for a device creates a DeviceKit coordinator for it,
which can start the device's native HID services. iOS simulators whose screens
kept SimulatorKit's touches and buttons were observed to stop accepting them
afterward, although a fresh tvOS 27.2 simulator still accepted SimulatorKit's
Home button after its native keyboard and the guest's `dtuhidd` had started.
The manager therefore creates `DeviceActiveStateObservation` with
`init(limitedTo:)`, which evaluates the predicate only for the devices that
`DeviceScreens` reports: open screens that use the native canvas, joined to the
CoreDevice identifier of their inventory record. Each read requests that set
under Observation, so opening or closing such a screen, replacing its session,
or an inventory change rereads the values. DeviceKit matches devices by
CoreDevice identifier, so simulators in custom device sets have no value.

Every other device has no value. Within the same availability, a row that
DeviceKit reports as Active comes first. A row without a value is ordered with
the inactive rows by the remaining comparisons, and its artwork follows Neo's
open screens and booting or shutting-down states. A failed read clears every
value and is reported with the other inventory issues.

Starting the observation still reads DeviceKit's device list, which starts its
observation of every device. DeviceKit exports no API to stop that observation or
a coordinator, so they stay with DeviceKit for the rest of the manager process.
Quitting stops Neo's reads and callbacks along with the inventory observation.

Each Xcode installation has its own headless renderer process, a separate
instance of the embedded renderer app, whose bundle identifier differs from the
manager's. The manager loads one compatible SimulatorKit UI toolkit for
its process lifetime and opens device service contexts for each owning Xcode.
Loaded Objective-C framework classes cannot be unloaded, so UI toolkit selection
stays fixed while device operations retain their own developer context.

The same presentation owner retains the connection, input queue, recording, and
captures when its view controller moves between the center pane and a compact
window. Moving a presentation does not invoke device-close policy. Restart
finishes recording and disconnects presentation before the headless backend
mutates the guest, then reconnects the retained presentation controller.

Termination checks the running app's bundle identifier and normalized bundle
URL. The renderer's startup acknowledgement follows runtime creation, ownership
registration, device-set subscription, and a final competing-host check. A
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
| `SimulatorManagerModel` | Own observable inventory and its DeviceKit Active values, loading state, and the accepted operation queue. |
| `DeviceRegistry` | Keep one stable `DeviceModel` for each device for as long as the inventory lists it. A record leaves only when a source that lists it read successfully without it. An application owns its registry, and each process has its own. |
| `DeviceModel`, `DeviceSettingsState`, `BackgroundServicesState` | Hold what one device last answered, for everything in the process that presents it: its settings field by field, its background services, its command state, audio routes and location, its health and its last issue. Own that device's accepted changes and their order, independently of other devices. See [Device state](#Device-state). |
| `ManagerSelection` | Hold which device the manager shows, and keep that device's state current while it does. It holds no device state itself. |
| `DeviceInspectorModel` | Own inspector records and reject results from an earlier selection or page. |
| `ManagerWindowController` | Present the sidebar, device screen pane, and settings inspector in `NSSplitViewController`, own the selection, the toolbar, and the latest placement choice for the selected device, and decide where each opened or restored screen goes. |
| `DeviceScreenViewController` | Show the selected device's screen or preview in the center pane, with its canvas controls and activity footer; move screens in the order the window accepts them, stopping a move once a later choice replaces it; and return to the preview when that screen closes. |
| `DeviceScreens` | Index the manager's open screens by device, own a public `SimulatorContext` and `SimulatorScreens` for each Xcode and the remote screen connections, and stop them without shutting devices down. |
| `DeviceScreen` | Keep one open screen's canvas controls current from its state, and send their actions to that screen's device. |
| `NativeFrameworks` | Load private frameworks and validate what is loaded on one serial queue of its own, off every UI and control executor, and keep the process's one UI toolkit by making each check, load and record of it a single step. |
| `SimulatorIORuntime` | Load one Xcode's CoreSimulator and audio interfaces, which reading and managing devices need and which choose no UI toolkit. |
| `SimulatorPresentationRuntime` | Load the display, input and pasteboard interfaces of the UI toolkit that the process has, over a `SimulatorIORuntime`. |
| `SimulatorScreenRouter`, `NativeInputPlan` | Connect a device's display with what the display itself needs, and select its native input and pasteboard transports from what the device is, never from whether a transport answered. |
| `NativeInputActivation`, `SimulatorPasteboardRoute`, `DeviceOptionalServices` | Connect a device's optional services after its display opens and hand them over in place, stating how far each has come. |
| `CoreSimulator` | Device-set access and simulator model data. |
| `SimulatorContext`, `SimulatorDeviceSession` | Expose the public Kit API for discovery, guest lifetime, and an open device's state and commands, with no presentation dependency. |
| `SimulatorScreens`, `SimulatorScreen` | Expose the public UI API for AppKit screen presentation. Creating `SimulatorScreens` loads the process's UI toolkit and gives its context a `DeviceWindowPresenter`. The manager uses these same screen lifetimes, with package-only hooks routing guest management to its backend. |
| `SimulatorScreenHost` | Observe one Xcode's device sets and own its simulator sessions and resource cleanup, drawing them through a `DevicePresenter` when it has one. |
| `HostApplication` | Compose the renderer's application lifecycle, menus, manager requests, and ownership registration around a `SimulatorScreenHost`. |
| `DeviceSession` | Device connection, input, pasteboard, audio, external-display state, and device operations. |
| `DeviceWindowController` | Present the device and forward user actions. |
| `RemoteDeviceScreenSession` | Own one active physical-device or VM screen transport, its resize assertion and input resources, and unfinished or completed recordings. |
| `CoreDeviceAppResizeTransport` | Bridge native app-resize eligibility and assertions for Simulator and remote sessions. |
| `CoreDevicePasteboardTransport` | Transfer a default-set simulator's pasteboard and observe both pasteboards' changes through CoreDevice. Simulators that CoreDevice does not list keep SimPasteboardPlus. |
| `RemoteDeviceWindowController` | Present a remote screen and drain accepted captures, recording saves, and input before disconnecting. |
| `ExternalDisplayWindowController` | Present a device's external display. |
| `DeviceCommand`, `MenuController` | Define commands and derive menu state from the active window. |
| `SystemCommandRunner` | Run one subprocess without blocking its caller, from launch until the child is reaped and its output files are removed. Each command's `CommandPolicy` states whether it has a limit and what the caller's cancellation does to the child. |
| `CommandReads` | Stop every read a controller has running while the operations waiting on them finish, so quitting does not cancel an accepted change and an unresponsive child cannot hold it. A stopped read ends as `CancellationError`, and its consumers publish nothing. |
| `UninterruptedCommands` | Hold the commands that keep running when their callers are cancelled, so that a quit that has waited for them can stop them and bound the rollbacks that follow. |
| `SimulatorDeviceChannel`, `DeviceIOHub` | Own the native requests of each device and device set, one channel per identifier and device-set path, or per developer directory and device-set path, for the life of the process: their order, deadlines, cancellation and what is still in flight. See [Native device requests](#Native-device-requests). |
| `SimulatorDeviceSet` | Create and read one CoreSimulator device set on its channel's worker, and hold what it last reported as values for everything that presents it. Own the `SimulatorDevice` of each device something asked to reach. |
| `SimulatorDevice` | A device's own CoreSimulator context and connection, one per developer directory, device-set path and identifier, for everything that reaches the guest. See [A device's own connection](#A-devices-own-connection). |
| `DeviceToolRunner` | Run a device's selected-Xcode tools one at a time and let its session cancel the running one. |
| `PasteboardSync` | Exchange copies between the Mac and connected sessions. |
| `ExternalDisplayChanges` | Serialize display and CarPlay changes across sessions for one device. |
| `DisplayKeyboardInput`, `DisplayFitting` | Shared input-focus and geometry behavior for both window types. |
| `NativeDeviceKeyboard` | Send a simulator's keyboard input through one guest UniversalHID service per Mac keyboard, described by that keyboard's properties, which CoreDevice creates for a default-set simulator and `SimulatorGuestHID` for one in another set. |
| `NativeDeviceTrackpad` | Send a simulator's trackpad scrolling and pinches over its integrated screen through one guest UniversalHID service per sending Mac HID service, described by that Mac service's properties and created as for `NativeDeviceKeyboard`. Mouse movements, and each scroll or pinch as it begins, move the guest service's hidden pointer through the screen's current window-to-pointer transform. |
| `NativeDeviceScreenInput` | For an iPhone or iPad simulator without touch pressure, send the integrated screen's touches, as SimulatorKit's digitizer interprets them, and the device's button usages to the guest's touchscreen and button services, through CoreDevice or `SimulatorGuestHID`, once the screen's keyboard or trackpad input is native; release what they hold when the screen disconnects. |
| `SimulatorGuestHID` | Reach the guest HID services of a simulator in a set that CoreDevice does not list, through the Mach services its `SimDevice` looks up, with the messages CoreDevice sends them. Each input stream owns its connection, and the guest removes a connection's services when the connection ends. |
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

The active device comes from `NSApp.keyWindow`, including the main window while
it shows a device screen; an external-display window refers to its owning
device. The manager's sidebar selection identifies the inspector target
independently of the active device window.

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

## Native device requests

CoreSimulator's guest requests wait synchronously for the guest's bridge,
CoreSimulatorService or the device's I/O server, and nothing can cancel such a
wait. So no UI-facing interface offers them synchronously, and none of them runs
on MainActor or on an actor's executor. `SimulatorDevice`, the audio, pasteboard and input connections
and the external screen send them through their device's `SimulatorDeviceChannel`,
an actor that stays responsive because it only owns the requests. The calls run
one at a time on the device's serial worker. Reading and changing a value as one
step, such as Toggle Appearance or a text-size change, is one request, whose
decision is a pure closure that the session passes in.

A deadline does not stop a call; it only ends the wait for it:

| What happened | What the caller is told |
| --- | --- |
| Cancelled before the call started | `CancellationError`, and it never runs. |
| A read cancelled while running | `CancellationError`. |
| A change cancelled while running | `outcomeUnknown(.cancelled)`. |
| A read past its deadline | `noAnswer`. |
| A change past its deadline | `outcomeUnknown(.timedOut)`. |
| Requested or waiting behind a call past its deadline | `notSent`. |

A call past its deadline makes the channel `unresponsive` until that call
actually returns. No replacement worker starts, since CoreSimulator's own state
could be what holds the call. When it returns, what it created gets its cleanup
from `lateCompletion` or `cleanUp`, which is never refused. Nothing that was
refused or abandoned is sent again; instead `DeviceSession` applies what is wanted
of the guest now: debug settings, keyboard, location, audio route, pasteboard
synchronization and the external display's saved choice. Restoring these preferences
does not delay presentation. Preparing native input and pasteboard transports during
connection can still wait for CoreDevice initialization, up to its caller deadline.

Channels separate caller waits, but devices of one `SimServiceContext` also share its
connection to CoreSimulatorService. A `lookup:error:` waiting for a stopped `launchd_sim`
holds later lookups on that connection, including a different device's first bridge,
input connection or screen. So each device has its own context, as described next.

### A device's own connection

`SimulatorDeviceSet` lists devices through the process's shared context, as
`SimulatorDeviceRecord` values, which cannot reach a guest. Whatever has to reach one asks
`client(withIdentifier:)` for its `SimulatorDevice`, which holds that device's own context
and set: the screen, input, guest settings and tools of a device all share it. Listing
devices makes none, since each costs about 3 MB and 2 Mach ports for as long as it lasts.

The device's worker creates it the first time it is asked for. Whoever asks meanwhile
joins that opening, each for as long as it waits. An opening that outlives its waiters
stays open for the next request, and one that fails leaves nothing open and is tried again
only when asked. Closing a window and rebooting the guest keep the client, and neither a
timeout nor an unknown outcome replaces it.

Only two things end a client, both through the one report that CoreSimulator makes when
its connection ends:

| What happened | How it is known | What follows |
| --- | --- | --- |
| The device was deleted | `device_removed` on the client's own set, and `devicesByUDID` no longer holds it | The client cancels its own connection, which returns a lookup it holds, and the device reports state 0. |
| CoreSimulator ended the connection | `XPC_ERROR_CONNECTION_INVALID`, which the context does not recover from | Logged. `INTERRUPTED` is not this: the context resubscribes by itself. |

A failed read or a shorter `availableDevices` is neither: a device whose runtime is
unavailable is not deleted. A cancelled connection does not return a call held in the
guest's bridge, so that call keeps its lane and its unknown outcome. The next client opens
on the same worker, so it cannot overlap a request of the one before it. The old
`SimulatorDevice`'s requests fail unsent from then on, because CoreSimulator answers a
message to a device whose context is gone as though nothing had failed.

A context and its set retain each other, the connection retains the context, and each
device and pair of the set holds a handler that retains the set. So releasing means
cancelling the connection and, after that, clearing the set's `serviceContext` and removing
the devices and pairs from that private set, which changes only its own maps. It waits for
two things. Clearing before the connection's end has been reported can leave the context
allocated. And since a `SimDevice` holds its set weakly and SimulatorKit throws when it uses
one without a set, it also waits until whatever holds the ended `SimulatorDevice`, such as
an open screen, has let go. The release is then a `cleanUp` on the device's worker. An
external screen's `SimDeviceScreen` keeps a completion block after calling it, so that block
gives up its completion when called; otherwise it would hold the screen's connection and so
the device.

A client separates a device's requests from another device's. It does not separate them from
what holds CoreSimulatorService itself, or SimulatorKit's main-actor calls.

Validating a menu reads `DeviceModel` and asks the device nothing. A menu
that opens, a connection, the session's own changes and a recovery read the guest
again, one read at a time, and an open menu updates if that changes what it shows.
Audio route reports coalesce the same way, so a device that does not answer gains
no queue.

CoreSimulator's own reads are not plain metadata either. `-[SimDeviceSet devices]`,
`devicesByUDID` and `devicePairs` wait on the set's queue with `dispatch_sync`;
`-[SimDevice state]`, `name`, `runtimeIdentifier` and `lastBootedAt` on the device's;
and `-[SimServiceContext supportedRuntimes]` and `supportedDeviceTypes` on its own.
`-[SimDevice runtime]`, `deviceType` and `supportsFeature:` reach those same queues,
and opening a set can start CoreSimulatorService. A Swift job that waited on them would
hold its thread for as long as CoreSimulator takes. So `SimulatorDeviceSet`, which
every path to one set in one developer directory shares, makes these calls only on
its own channel's raw serial worker: opening the context and set, listing devices,
capturing what each reports, looking one up, and the creation catalog with every
pairing answer, so that a catalog's `canPair` is a lookup in values. A set's channel
follows the table above, with `DeviceOperationLimit.deviceSet` as its deadline.

What a set last read stays on `SimulatorDeviceSet`, and each existing `SimulatorDevice`
is updated in place, so `state`, `lastBootDate` and the catalog properties wait for
nothing. A menu, a browser and a connection's `isBooted` read those values. Whoever
has to know what is true now awaits `refresh()`: one read runs at a time, and everyone
who asks while it runs shares one more, however many ask. A read that fails, also
because its call is held, leaves those values as they were: a set that does not answer
is no reason to think its devices shut down. CoreSimulator's notifications ask for a
rescan, and so does a set whose channel becomes ready again. Connecting reads a
device's features once on its own worker, and a stop that has to know the device's
state now asks there too.

The worker of a set is not the worker of a device, and neither shares a connection with
the other, so a call held on one leaves the other able to answer. When no integrated screen appears in time, the failure says what
reading the screens last failed with and which native requests had still not returned.

CoreDevice's full initialization is one `SharedTask`: nothing replaces it while it is
pending, and no caller's cancellation stops it. Each caller waits for at most
`DeviceOperationLimit.coreDeviceInitialization`, and is told so when that passes. The
delay notice stays until the initialization actually finishes, and whoever asks after
that gets its result. A screen's input route that could not wait reports that failure, which the
screen shows with a Retry, and keeps SimulatorKit's input in the meantime, while the inventory
observation asks again.

A device's screen opens with what the screen itself needs: its display and, for a Duo, the
independent canvas that is its screen. Its native input and pasteboard follow from what the device
is. Only a connected CoreDevice record that lacks a feature makes the device `unsupported`, and only
then does SimulatorKit or SimPasteboardPlus serve it for good. A simulator's record can arrive late
and lists no features until CoreDevice connects, so one `CoreDeviceRecordDiscovery` for each connection
waits on CoreDevice's `deviceChanges` and `deviceInfoChanges` while the service stays `pending`, with
no timer. A Duo's screen waits for the record the same way, until `DeviceOperationLimit.coreDeviceRecord`.
A transport that did not answer says nothing about the device, so it is `failed`: nothing else takes
its place, the failure stays visible, and asking again asks the same transport. A retry while a device's
channel holds a call is refused unsent, and the channel saying the call returned starts one more attempt.
What connected but no display took up stops through its own ports, however late it answered.
Native input activates on the open screen once the pointer and any button SimulatorKit holds are
up, the touches first, because the guest drops SimulatorKit's touches and buttons once native
keyboard or trackpad input starts. A 3D Touch screen keeps SimulatorKit's input throughout, as only
its touches carry pressure.

SimulatorKit's `SimDisplayView` is AppKit and stays on MainActor, though creating
one waits on the device's I/O server. A device's file paths come from its set's path
and UDID and wait on no queue. The screen's properties and modes, which ROCKit
memoizes, and listing a device's screens stay synchronous too.

Quitting never waits on a held call. The manager gives accepted work
`TerminationTimeout`, then reports what has not started as not run and stops the
uninterrupted commands still running as `terminating`, whose transactions finish
with what they know. What does not finish in `terminationGrace` is reported as
unknown. Later uninterrupted commands, such as a rollback, each have that grace too.
Everything that waits on a device during a quit is bounded and notes what it left
in `TerminationAccount`; the quit's owner reports those notes and what
`DeviceIOHub` still holds, logging them and showing them for a limited time.

## Device state

A `DeviceRegistry` holds one `DeviceModel` per device in a process, so the
inspector, a screen's commands and an external client read the same values and
selecting a device again blanks nothing and reads nothing. Choosing what to show
stays outside: `keepCurrent(_:)` keeps a device's state current until its result is
released, and what nothing keeps current is read when something next does.

Settings read in groups. Each group publishes as it finishes, independently of the
others, and changes only the properties whose values changed, so a view updates only
for what it read. A failed read keeps the group's values and reports its reason in
`status(of:)`; `unsupported` clears only that group. Only the next invalidation reads
a failed group again.

A read that began before an accepted change does not answer for the group it changed,
and a read that began before the device restarted or changed what it can answer for
answers for nothing. Each accepted change shows at once and stays attached to its
device, which runs its changes in the order they were accepted, without waiting for
any other device. Its outcome is what the change's own caller receives, and what
confirms it is one read after the last change accepted for the device, even if nothing
shows the device any longer.

Inventory reads list which sources answered. A failed source says nothing of what
only it listed, so those records and their state stay; only a successful read of
every source that listed a device removes it. A device that returns after that is a
new device. An inventory change that alters no answer, such as a new name, asks the
device nothing.

Reads run on an invalidation and never by a timer: a native report, a session's own
command, the device changing state, an explicit refresh, or the application coming to
the foreground. Invalidations that arrive while a read runs coalesce into one read
after it. A value that something outside this process changes, without a signal this
process can observe, stays as it was last read until one of those happens. That
includes another process's registry, which shares no objects with this one.

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

`RemoteDeviceScreenSession` owns the device frame, independent of its
transports. When a connection starts, it reads the primary display's size and
DeviceKit chrome and framebuffer-mask identifiers from CoreDevice, falling back
to DeviceKit's `chrome_map.plist` entry for the product type. DeviceKit's
`ChromeView` and `DisplayViewModel` draw that chrome and lay it out; the
transports draw in a screen view placed at DeviceKit's framebuffer frame,
masked by the framebuffer mask and turned with the display's orientation. The
frame does not start DeviceKit's own display stream. Its side buttons send the
HID usages their `chrome.json` declares. A resized app's dedicated display is
shown without the frame. As in Device Hub, trackpad scrolling and pinches that
begin on the screen go to a UniversalHID service that carries the properties
of the Mac trackpad that sent it, under that trackpad's HID service registry ID
and with its pointer hidden. The trackpad's first event creates the service, and
UniversalHIDKit's `EventObserver` translates scroll and magnify events into
native reports, preserving phases, scrolling deltas, momentum, and magnification.
On a screen without a pointer
connection, such as a resized app's dedicated display, a mouse movement over the
display goes to the service of the Mac HID service that sent it; the observer
maps the event's window location with the display's window-to-pointer transform
into an absolute pointer report, and the service's gestures happen at that
pointer. Panning or zooming the canvas moves the display under a still mouse
without a mouse movement, so a gesture that begins first places the pointer the
same way at its own window location, using the display's transform at
the time the session sends the event. Later steps stay where the gesture
began. A synthesized gesture or movement, which no Mac HID service sent, reaches
no service. When the screen loses input during a gesture,
the session resets these services' gesture state; disconnecting the
screen removes them.

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
