# Using NeoSimulator

Open devices, manage their apps and profiles, and capture their screens.

## Open and create devices

Select **NeoSimulator** under **Settings → General → Preferred Display Host**.
Choose a device in the main window, then **View Screen**. You can also open one
from **Device** in the Dock, **File → Open Simulator**, or **View → Show Devices**.

The browser groups simulators, physical devices, and VMs by availability. Search
by name, model, or OS; use the filter button to select device kinds, availability,
families, sorting, and grouping. The gear button opens Settings.

Create a simulator in **Settings → Devices** by choosing its family, model, OS,
and name. Neo remembers the last family and each family's model and OS.
Open Simulator groups devices by runtime: a checkmark means an open window,
a dash means running without a window. Hold Option to see runtime and device type.

Select one or more devices and open **Device → Manage Selected Devices** or Control-click the
selection for its management actions. Actions depend on the device's current
state and supported capabilities. Rename and Clone apply to one device; select
an iPhone and an Apple Watch from the same simulator set to pair them. Erase and
Remove ask for confirmation. If an operation fails for part of a selection,
the error identifies those devices and any completed steps.

Connected physical devices appear automatically. VMs offer Start, Shut Down,
Pause, Resume, and Remove when supported.

Choose **View Screen** to open a supported physical-device or VM screen.
Its inspector shows available controls.

A physical device's screen appears inside the same device frame that Device Hub
draws, and the frame's side buttons press the device's buttons. Click or drag
on the screen to touch it; scroll with two fingers on a trackpad to drag the
screen's content, and pinch on the screen to pinch in the device's app.

Connect physical devices by cable. On first use, choose **Choose Screen Source…**
and select the device's source; macOS does not identify which device each source
shows. Neo remembers the choice. Duplicate names are numbered. To correct a
choice, use **Device → Choose Screen Source…**.

Allow Camera access when prompted. If denied, enable NeoSimulator in
**System Settings → Privacy & Security → Camera**, then choose **Try Again**.
For an unavailable source, check the cable and try again.

**File → New Simulator…** creates a device from the installed runtimes. For an
iPhone, **Paired Apple Watch** adds a second page for a compatible watch.
For an existing iPhone, open its **More → Pair Apple Watch** menu to select an
unpaired watch offered by CoreDevice. **New Watch Simulator…** creates a compatible
watch in that iPhone's simulator set and pairs it with the existing phone.
Creation does not boot the new devices. If creation or pairing fails after a
device was created, the error names the devices kept. If pairing with an existing
simulator fails, the error includes the new device's identifier. Install runtimes in Xcode.

Menus follow the active device's capabilities. Xcode association is automatic.

### iPhone Duo simulators

The creation form and device-family filter list **iPhone Duo** separately because
it uses dedicated runtimes. Pairing and controls still treat it as an iPhone.

Duo requires iOS 27.1+ and a Duo-compatible runtime from
[Xcode 27.1 or later](https://developer.apple.com/iphone-duo/). The OS version
alone is insufficient: `com.apple.CoreSimulator.SimRuntime.iOS-27-2` excludes Duo,
while `com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4` supports only Duo.

**OS Version** lists only the runtimes that CoreSimulator reports as supporting the
selected device family, and it shows each runtime's build. If it shows
**No Runtimes Available**, install a runtime for Duo in Xcode.

## Main and compact windows

Choose **Switch to Compact Window** in the main toolbar to move the live screen
into its own window. Choose **Show in Main Window** in that window to return to
the browser with the same device selected. Moving the screen preserves its
connection, recording, and unsaved captures. Finish an open sheet or leave full
screen before switching windows.

The toolbar and **Device**, **I/O**, **Features**, and **Debug** menus provide
device actions. Main and compact windows keep separate scales. Selecting another
device or closing the main window keeps connections running; quitting applies
the device lifetime setting.

## Inspect a device

Select one device in the main window, then choose an inspector page from the
right side of the toolbar:

| Page | Contents |
| --- | --- |
| Settings | The selected device's available appearance, accessibility, location, and sound controls. |
| Background Services | Switches for a booted simulator's background services, such as Spotlight indexing and iCloud sync. |
| Reports | Reports from physical devices and VMs that support report access. |
| Info | Grouped device information and the Info, Apps, and Profiles categories. |

In **Info → Info**, use **Edit Visibility**, then **Done**, to save visible fields.
The cards show paired simulators and pairing controls. Use **Add** to pair
an existing iPhone or an unpaired Apple Watch with a simulator offered by
CoreDevice. On a watch, **New iPhone Simulator…** creates only a compatible iPhone
in the watch's simulator set and pairs it with that watch. Add is disabled when
the selected watch is already paired.

Start a simulator before inspecting its apps or profiles. For physical devices
and virtual machines, actions depend on the connected device's capabilities.
If a query fails, read the message in the inspector, reconnect or unlock the
device as needed, then use the inspector's refresh button.

### Applications

Choose **Info → Apps** and select an app to see its details. Use
**+** to install an `.app` bundle or `.ipa` package, **−** to remove the
selected app and its data, or the play button to launch it. Search filters installed apps. Apps must target the selected device; the installer
reports platform and signing errors.

The ellipsis button opens these application actions:

| Action | Use |
| --- | --- |
| Show Container in Finder | Open an accessible simulator data container on the Mac. |
| Export Data… | Save the app's accessible data container as an `.xcappdata` package. |
| Replace Data… | Stop the app and replace its current data with an `.xcappdata` package or a container folder. |

Export the current data before replacing it if you need a backup. Replacement
asks for confirmation. If it fails, the app may remain stopped and its data may
be partly replaced; inspect the app before retrying. Transfer errors identify
any retained partial download. An existing export is replaced
only after the new download completes.

### Profiles

Choose **Info → Profiles**. Devices supporting both profile kinds expose a
**Configuration / Provisioning** selector.
Select a profile to view its installed metadata. Use **+** to install a
`.mobileconfig` configuration profile or `.mobileprovision` provisioning profile,
or **−** to remove the selected profile after confirmation. Unavailable
operations are disabled.

Profiles are unavailable for simulators in custom device sets, including
parallel testing devices. Simulators support configuration profiles only.
Installed profile details show metadata supplied by the device; payload bodies
and entitlement values are unavailable.

## Close, restart, or quit

Closing a device window normally shuts down its simulator. To leave it running,
Control-click the close button or choose **File → Close Window…**
(Control-Command-W), then **Keep Running**. The sheet can remember that choice.
Reopen a detached device through Open Simulator or the device browser.

Closing a physical-device or VM screen disconnects the screen and leaves the
device running. Use **Device → Shut Down** to shut down a supported VM.

Quitting normally shuts down simulators with open windows. **Quit NeoSimulator…**
(Option-Command-Q) asks whether to keep them running. Settings can change both
defaults. Switching the display host leaves devices running so the next host can attach.

**Device → Restart** and **Erase All Content and Settings…** retain the window
and reconnect after boot. An active recording is saved first. **Shut Down**
stops the device and removes its window.

Launching NeoSimulator lists simulators without connecting to any of them,
including ones that are already running. **Start** or **Open** connects one.
When Xcode launches an app in a simulator whose screen is open, the screen
moves to that Xcode.

## Arrange windows

Drag a device bezel to move its compact window. Resize the window from its
edges or corners, with or without the bezel. In the main window, drag a
simulator's corner to enlarge or shrink its display without resizing the window.
**View → Show Device Bezels** and **Stay On Top** control its presentation.

| Window scale | Shortcut |
| --- | --- |
| Physical Size | Command-1 |
| Point Accurate | Command-2 |
| Pixel Accurate | Command-3 |
| Fit Screen | Command-4 |

Windows with bezels may extend beyond the Mac display. Neo remembers position
and scale for the display arrangement, reducing the restored scale and moving
the window inside the screen when necessary.

The toolbar provides Home, Save Screen, and rotation where supported. Hold
Option with the pointer over the toolbar to change the camera to Record Screen
and rotation to Rotate Left. Watches and Apple TV omit rotation; supported
watches also have an Always On control.

Physical-device and VM screen windows support standard macOS tabs. Moving a
screen between the main and compact windows keeps its connection. Home, Lock,
and volume controls appear when the
device supports them. **Reconnect** in the compact window's toolbar or in the
menu you get by Control-clicking beside the device retries the screen.

Where supported, **Resize App** in the toolbar opens the app's dedicated display.
Resize the window to request an app size; **Stop Resize** in the compact window
shows the accepted size in its help tag and returns to the primary display.
Moving between windows keeps the resize session. Finish recording before starting
or stopping Resize App. Captures made while resizing use the app's display.

## Save screens and recordings

### Simulator captures

| Operation | Shortcut | Result |
| --- | --- | --- |
| File → Save Screen | Command-S | PNG screenshot |
| File → Record Screen | Command-R | Start a recording immediately |
| File → Stop Recording | — | Finish the movie |
| Edit → Copy Screen | Control-Command-C | Unmasked PNG on the Mac pasteboard |

The camera becomes a stop button while recording. Hold Option for **Save
Screen…** or **Record Screen…** to choose a destination and device-mask option.
Save Screen… remembers its folder and mask choice; ordinary captures use the
saved mask choice.

Captures appear as floating thumbnails and save when dismissed. Screenshots use
the configured folder (initially the macOS screenshot location or Desktop);
recordings use Desktop. Thumbnails last five seconds for screenshots or the
movie's duration for recordings. Hover to keep one open, drag to export, or
Control-click to save elsewhere, copy, open, delete, or export a recording as GIF.

A new capture saves the preceding thumbnail's file. Quitting saves remaining
captures and finalizes recordings. Existing names receive a ` #2` suffix and
so on. If saving fails, the error includes the file's location for recovery.

### Physical-device and VM captures

With a physical-device or VM screen active, **File → Save Screenshot…**
(Command-S) saves its remote pixels as PNG. New captures require a connection
that can supply them.

If saving a screenshot fails, **Save Screenshot…** retries with the same captured
image, even after disconnection. To capture a new image, save the retained one
or confirm **Discard Screenshot…** first. Before closing, quitting, reconnecting,
or switching Preferred Display Host, NeoSimulator asks you to save or discard an unsaved
screenshot. Cancel in the save panel or close confirmation keeps the image;
cancelling Close also keeps the window open.

Choose **Record Screen** in the toolbar or File menu (Command-R) to start a
recording. **Stop Recording** finishes it and saves an MP4 movie in the chosen
capture folder, initially Desktop. Hold Option and choose **File → Record
Screen…** to choose a destination before starting.
Automatic saves number existing names with ` #2`, ` #3`, and so on. Choosing a
file in the save panel permits replacing it after the panel's confirmation.

If saving fails or you cancel the save panel, the completed recording remains
in memory. Choose **Save Recording…** to try another destination. Closing the
window, quitting, reconnecting, or switching Preferred Display Host finishes a pending
recording before disconnecting. An unsaved recording offers Save, Cancel, and
Don't Save; Cancel keeps the connection open. **Discard Recording…** explicitly
removes a retained recording after confirmation.

## Install apps and import media

Drop simulator `.app` bundles or `.ipa` packages, images, videos, or vCards
onto a device window, or choose **File → Install App or Import Media…**.
Partial failures list both completed imports and failed files.
**I/O → Open URL…** opens web addresses and custom app URL schemes in the
active device.

## Browse device reports

Select a device in the main window and choose **Reports** at the top of the right
inspector. Physical-device and VM report operations depend on the
connected device's capabilities. Crash, log, spin, and diagnostic reports are
unavailable for simulators.

Search by report name, path, file extension, or recorded type. **All Report
Types** lets you filter by the device's recorded log type, or by file extension
when no log type is supplied. An `.ips` extension alone does not identify a
report as a crash or hang. Select a report to view its available metadata,
relative path, and file properties.

Double-click a report or choose **Quick Look** to preview it. Its temporary copy
is removed when the preview closes, selection changes, or the app quits. Use
**Download Report…** to save a copy, confirming replacement if needed.

A transfer failure preserves an existing destination. If transfer data remains
on the Mac, the error gives its location for recovery. If saving succeeds but
cleanup fails, the error identifies both the saved report and the remaining
data. An incomplete report list keeps the available reports and shows a
message about records it could not read.

## Debug and simulate conditions

The main window's inspector changes the selected device's Appearance, Liquid
Glass, Color Filter, Text Size, accessibility settings, Location, and Sound.
Sound includes volume and the Mac's input and output devices. Select **System
Default** to follow the Mac's current audio route. Start a simulator or connect
a physical device or virtual machine to read and change its available settings.
Unsupported controls show **Unavailable**. If part of a query fails, the remaining
settings stay available. Return to NeoSimulator from another app to retry the query.

Device and Features menus include Home, Lock, Shake, orientation, appearance,
biometric enrollment and matches, Apple Pay authorization, preferred text size,
Increase Contrast, the in-call status bar, StandBy, and iCloud sync, where the
device supports them.

**Features → Location** offers None, a custom coordinate, and the active
runtime's routes. The last choice is saved and applied when a device connects.
A new installation uses Simulator.app's San Francisco coordinate; devices
whose runtime has no routes are left unchanged.

The Debug menu provides Slow Animations, Graphics Quality Override, rendering
diagnostics, a memory warning, and **Open System Log…** (Command-/). Slow
Animations and Graphics Quality Override are saved and applied on connection.
The color diagnostic checkmarks reflect the device's state. **File → GPU
Selection** changes CoreSimulator's shared rendering GPU preference.

Neo can also show Xcode's parallel testing devices from
`~/Library/Developer/XCTestDevices`, or `TestingDeviceSetPath`. **Debug → Show
Parallel Testing Devices** hides or shows their windows without shutting them
down. Their rotation and orientation commands are unavailable because
`devicectl` addresses only the default device set.

For gestures, pasteboard, platform-specific controls, audio, and external
displays, see <doc:InputAndPeripherals>.

### Background services

The inspector's **Background Services** tab turns off a running simulator's
background services, such as Spotlight indexing, iCloud sync, and Siri,
without restarting it. Each category says what stops working while it is
off; expand it to switch its services one at a time.

Services that simulators need stay on: turning one off says why and leaves it
on. After a change, the inspector lists services it kept on because another
enabled category uses them or, on watchOS and visionOS, the platform needs them,
and services that cannot start again until the next boot. While a change runs,
the simulator's management actions other than **Force Shut Down** are
unavailable. Start a simulator to change its background services; physical
devices and virtual machines do not offer them.

Choose the **Default Profile** in **Settings → Service Profiles**. It starts as
**All Services**, the built-in preset that enables all managed services. Each
simulator's **Startup Profile** menu offers **Use Default: <profile name>** to follow
that choice, or a saved profile to use independently. **Open Settings…** opens the
shared profile editor without changing the selection.

Individual service switches are saved as overrides. They stay in effect when
the profile changes; **Revert** clears them. **Save** updates the selected named
profile, or asks for a name when using the built-in All Services profile.
Startup-profile selections and overrides survive simulator erases.

Changing the default profile or editing a profile takes effect at the next
simulator start. Selecting a simulator's Startup Profile also applies it
immediately when that simulator is running. Automatic application works while
NeoSimulator is open, including starts from Xcode. Opening NeoSimulator leaves
already-running simulators unchanged.

To switch services that the built-in categories don't list, select one of your
profiles in **Settings → Service Profiles** and add categories of your own. The
**+** below the categories adds one, and the **+** below its services adds a
service by its launchd label. Your categories appear above the built-in ones in
each of your profiles and in the inspector, and each profile turns their
services on and off. All Services shows only the built-in categories, and still
turns on every service, including yours. Control-click one of your categories
to rename or delete it, or one of its services to remove it. Removing a service
leaves running simulators as they are, so a service that is off stays off.
Built-in categories can't be changed, and NeoSimulator doesn't add services that
simulators need or that stop a simulator from working while they're off.

To use a profile on another Mac, Control-click it and choose **Export…**, or drag
it to the Finder. The JSON Lines file has the profile's name, the services that
it turns off, and your categories that it lists, but not which simulators use it
or which profile is the default. To add profiles from files, choose **Import…**
from the **+** below the profiles, or drop the files on the profiles. Each
profile in a file becomes a new profile, and its categories join yours. A
category that you already have must match the file's. If a line of a file can't
be imported, nothing changes, and NeoSimulator names the file and the line.
