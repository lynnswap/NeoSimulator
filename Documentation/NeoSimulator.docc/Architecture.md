# Architecture

The manager app owns display sessions, preference recovery, and device screens.
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

Each value is absent, false, or true; other types are errors. NeoSimulator uses
`defaults` to access the managed domains, including Device Hub's container. A
restoration receipt journals the original, expected, and pending values. A new
host request reconciles the observed values with this receipt, retaining the
original values for explicit restoration. Writes are verified; changes detected
during the transaction stop it and retain its recovery information.

Neo mode sets Xcode's headless-session preference to false and suppresses
Device Hub's automatic live views. On Xcode's headless route, stopping the last
debug session shuts down a simulator that Xcode cold-booted. The normal route
leaves that guest running.

Each manager launch applies Neo mode and registers NeoSimulator's bridges.
There is no saved host choice; older `display-host.txt` files
are ignored. The controller owns the preferred host for the current session;
Settings changes it explicitly, and the next launch resets it to NeoSimulator.
Quitting releases the bridges and keeps routing preferences in place. Catalog
reads inspect only local recovery metadata.

Opening Device Hub directly temporarily releases the bridges. A process-exit
source observes each opened Device Hub; when the last one quits, the manager
reapplies the Neo route and registers its bridges if NeoSimulator remains preferred.
A screen request can also resume that session. Explicitly selecting Device Hub
keeps it preferred until another selection or the next manager launch. Restoration and quit cancel the exit observations so
late events cannot reclaim routing after ownership has ended.

Automatic presentation requires a successfully applied route in the current
manager session. An interrupted transaction suspends attachment until a screen
request or restoration resolves it. Restoration ends automatic Neo hosting even
if the original preferences selected the CoreSimulator route.

Session transitions validate Xcode, managed preferences, Device Hub identity, and
the renderer contract before recovering receipts or terminating processes. Starting
a Neo session configures the route, closes competing Device Hub instances, and
starts windowless display bridges and renderers as needed. Each bridge runs the
bundled renderer in a separate mode that registers with LaunchServices for the
selected Xcode's Device Hub path before AppKit starts. Xcode's device URLs reach
the bridge while Neo presents the screens. This mode loads no simulator runtime,
creates no windows, and launches no Apple Device Hub process. Additional simulator
launches reuse the bridge without presenting another host. Session startup waits
for bridges for the selected and other running Xcodes. A failure for another
Xcode is reported without disabling the selected working host. Xcodes opened
later are detected asynchronously, so their first Run can race initial bridge
preparation.

The bridge's launch arguments identify its manager by PID and launch date.
The manager and its renderers use this identity to distinguish bridges from
competing hosts. A bridge that exits is replaced while hosting is active and
exits when its manager dies. Xcode's Run requests retain the existing screen
opening policy: only explicitly opened Neo screens are presented. Opening Device
Hub normally, or choosing Devices and Simulators in Xcode, requests a temporary
handoff and forwards any device-management URL after the bridge has exited.
The handoff stops bridges, closes managed renderers, changes the route, and opens
Device Hub normally. Guests keep running.

Startup applies the Neo route before processing URL requests or restoring
screens. Quitting closes screens, renderers, and bridges, ends automatic hosting,
and keeps the current routing settings and recovery receipt. No background launch
service is installed. Startup closes orphaned bridges left by a previous
manager before preparing new ones.

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

The sidebar marks a device active using DeviceKit's own activity predicate, which
reflects DeviceKit views in the manager process. SimulatorKit, remote screens,
Device Hub, and renderers do not contribute their activity.

Evaluating a device can start its native HID services and interfere with
SimulatorKit input, so only devices with an open native canvas are evaluated.
Custom simulator sets have no CoreDevice record and no activity value.

Within an availability group, active devices sort first. Other rows use the
remaining sort criteria and Neo's screen and boot state for artwork. A failed
read clears activity values and reports an inventory issue.

## Screens and renderers

Each Xcode has a headless renderer with a bundle identifier distinct from the
manager's. The manager loads one SimulatorKit/DeviceKit UI toolkit for its
process lifetime while device operations retain their own Xcode contexts.
Objective-C framework classes cannot be unloaded.

Main and compact windows have separate screen connections and input queues for
the same guest. They share the manager's device registry, and each retains its
own recording and captures. The manager opens a compact window before connecting
its screen, then gives that window to the presentation controller. Closing a
compact window releases its connection and leaves the guest and main screen
running. Restart prepares and reconnects both presentations. Management
operations report completed steps and per-device failures.

A renderer reports a successful start only after it has subscribed to the device
set and checked once more for a competing host. Neo identifies an app to
terminate by its bundle identifier and normalized bundle URL. It rejects
competing hosts at startup and observes later launches. Its own windowless Device Hub
bridges are permitted. When another Device Hub or Simulator.app appears,
Neo disconnects affected sessions and leaves guests
running. It neither quits the competitor nor ends the manager for an in-process
presentation conflict.

Operations on different devices can overlap; operations on one device retain
acceptance order. Host, preference, and renderer-lifetime changes wait for all
prior operations and hold later ones. A screen open becomes such a barrier only
when it must start a renderer. Catalog reads keep a device that is being
changed in its earlier state until the change ends. Device commands act on the
screen in the key window; sidebar selection independently chooses the inspector's
device.

## Device lifecycle

Neo observes the default set and, when enabled and present, Xcode's parallel
testing set. It does not create the testing set. The manager attaches no device
by itself, whether it was booted at launch or later: only a request opens a
screen. Xcode launching an app moves an open screen to that Xcode. A renderer
that another app opens by itself also attaches no device that is running at its
launch, and starts none; it shows the devices that start later.

Sessions discover the integrated screen rather than assuming screen ID zero.
A failed connection affects only that device. Teardown cancels commands and
releases connections; input releases and external-display changes finish against
their original session even if the active window changes.

## Native device requests

CoreSimulator calls can block indefinitely on a guest, service, or internal
queue. Each device's calls run in order on its own worker, so a blocked call does
not stall the app. Read-modify-write operations, such as Toggle Appearance, run
as one request.

A deadline ends the caller's wait, not the native call:

| Condition | Result |
| --- | --- |
| Cancelled before starting | Cancelled; the call never runs. |
| Read cancelled while running | Cancelled. |
| Change cancelled while running | Outcome unknown. |
| Read past its deadline | No answer. |
| Change past its deadline | Outcome unknown. |
| Requested or queued behind an overdue call | Not sent. |

An overdue call makes the device unresponsive until it returns. Abandoned
requests are not replayed; the session reapplies current preferences when the
device recovers, without delaying presentation.

### Device sets and connections

Each device set is read on its own worker. CoreSimulator's state and catalog
accessors also block, so menus and views show the values from the last read. A
failed read keeps the previous values. Native notifications and device recovery
request another read.

Each device has its own CoreSimulator connection for each developer directory
and device set, so a blocked lookup cannot hold another device's connection.
Deleting the device or invalidating the CoreSimulator connection ends it; an
unavailable runtime or a failed listing does not. Requests to an ended connection
fail without being sent. Device sets and devices remain subject to
CoreSimulatorService-wide stalls and synchronous SimulatorKit calls.

### Optional services

CoreDevice initializes once per process. Cancelling or timing out ends only the
wait; later requests join the same initialization.

A display connects using its own requirements. Native input and pasteboard
services follow the device's capabilities and wait for the device's connected
CoreDevice record. A Duo canvas also needs this record.

Only a connected record lacking a feature marks it unsupported. A connection
failure keeps the chosen route and offers retry. SimulatorKit input remains
active while native input prepares. Handover waits for held pointers and buttons
to release, then activates native touches before native keyboard or trackpad
input, because those services make the guest reject SimulatorKit touches.
3D Touch devices keep SimulatorKit input to preserve pressure.

### Termination

On quit, the manager gives accepted work the time set by the `TerminationTimeout`
preference, reports queued work as not run, and stops running uninterrupted
commands. Transactions and rollbacks receive a further grace period; unfinished
outcomes remain unknown. The quit report lists the remaining work, including
device requests that have not returned.

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
disabled. Physical screens hold a CoreDevice usage assertion to keep developer
services available. Devices reporting primary-display stream support use
CoreDevice's media-stream negotiation and shared tunnel socket over USB or Wi-Fi.
The receiver assembles HEVC RTP access units, requests keyframes after packet
loss, and decodes with VideoToolbox into the existing Metal renderer. It receives
video directly, so it does not need avconferenced's conferencing entitlement.

Devices without primary-display stream support use the user-selected
AVFoundation capture source and require Camera access. macOS does not identify
which device a source shows, so the manager stores the user's choice in the
`RemoteScreenCaptureSources` preference, keyed by CoreDevice identifier. A source
belongs to at most one device; reconnecting fails if it does not return.
Both video paths use CoreDevice for input, geometry, and supported recording
operations. Shutdown stops the owned stream and releases its usage assertion.

A remote screen keeps its frame independently of its transport. DeviceKit draws chrome and masks around the framebuffer without starting its own
display stream. Side buttons send the chrome's declared HID usages. Trackpad
events use one UniversalHID service per originating Mac HID service. The first
gesture event positions its hidden pointer with the current display transform;
later events retain that position. Focus loss resets gestures, and disconnect
removes the services.

The app embeds a DeviceKit plugin in `Contents/PlugIns`, which DeviceKit loads
with its own plugins. The plugin's framebuffer provider shows a layer that the
app registers for a device's display, so DeviceKit's device view can show video
that the app receives itself. The plugin compiles against declarations rebuilt
from DeviceKit's exported symbols and links against a text-based stub of them.
Library validation loads the plugin into a hardened manager only when both have
the same team, so DeviceKit skips it in an ad hoc build with the hardened
runtime, such as the output of `scripts/build-local.sh`.

A physical folding iPhone's screen is DeviceKit's device view when the plugin
loads: DeviceKit draws the folding model, follows the hinge, and sends touches,
while the capture transport keeps the video, the device's buttons, screenshots,
and recording, and puts each decoded frame on the layer of the display that the
frame carries. Without the plugin the device keeps the framed screen.

Resize App uses a separate CoreDevice media stream and requires
`com.apple.videoconference.allow-conferencing`, which the manager's signing
profile does not include. Remote shutdown releases input and connections while
leaving the device running. Recording handles survive cancellation and failed
stops for retry; completed movies remain until saved or discarded. Cancelling an
unsaved-recording prompt keeps the window open.
