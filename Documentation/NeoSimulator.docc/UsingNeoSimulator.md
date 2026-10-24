# Using NeoSimulator

Open devices, manage their apps and profiles, and capture their screens.

## Open and create devices

Open NeoSimulator.app and select **NeoSimulator** as the display host. Select a
device in the main window and choose **View Screen** to open it. You can also
use **Device** in the Dock menu, **File → Open Simulator**, or **View → Show Devices**
to start a device or reopen its window. The manager's device menus group devices
by OS version.
The browser lists simulators, physical devices, and virtual machines in
Available and Unavailable groups. Search by name, model, or operating system.
Use the filter button beside **+** to choose a device kind, availability, or
family, change the sort order, or turn grouping off. **+** opens New Simulator.
Open Simulator groups devices by runtime; a
checkmark means a device has a window, and a dash means it is running without
one. Hold Option to show its runtime and device type.

Select one or more devices and open the **Device** menu or Control-click the
selection for its management actions. Actions depend on the device's current
state and supported capabilities. Rename and Clone apply to one device; select
an iPhone and an Apple Watch from the same simulator set to pair them. Erase and
Remove ask for confirmation. If an operation fails for part of a selection,
the error identifies those devices and any completed steps.

Physical devices appear automatically when CoreDevice detects their connection.
Virtual machines offer Start, Shut Down, Pause, Resume, and Remove when their
current CoreDevice capabilities support those operations.

Choose **View Screen** for a connected physical device or virtual machine to
open its screen when the device supports it. The settings inspector currently
provides simulator settings.

**File → New Simulator…** creates a device from the installed runtimes. For an
iPhone, **Paired Apple Watch** adds a second page for a compatible watch.
Creation does not boot the new devices. If creation or pairing fails after a
device was created, the error names the devices kept. Install runtimes in Xcode.

Neo supports iPhone, iPad, Apple Watch, Apple TV, and Apple Vision Pro. Menus show
the controls supported by the active device. Each renderer uses its Xcode installation for device artwork and the visionOS
user-interface plugin.

## Inspect a device

Select one device in the main window, then choose an inspector page from the
right side of the toolbar:

| Page | Contents |
| --- | --- |
| Settings | The selected simulator's appearance, accessibility, location, and sound controls. |
| Content | Installed applications, configuration profiles, and provisioning profiles. |
| Info | Available device properties, with expandable groups for details. |

In **Info**, open **Visible Fields** to choose the properties or groups to show.
NeoSimulator remembers these choices. Choose **Show All Fields** to reset them.

Start a simulator before inspecting its apps or profiles. For physical devices
and virtual machines, actions depend on the connected device's capabilities.
If a query fails, read the message in the inspector, reconnect or unlock the
device as needed, then use the inspector's refresh button.

### Applications

Choose **Content → Applications** and select an app to see its details. Use
**+** to install an app, **−** to remove the selected app and its data, or the
play button to launch it. The search field filters the installed apps.

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

Choose **Content → Configuration Profiles** or **Provisioning Profiles**.
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

Quitting normally shuts down devices with open windows. **Quit NeoSimulator…**
(Option-Command-Q) asks whether to keep them running. Settings can change both
defaults. Switching the display host leaves devices running so the next host can attach.

**Device → Restart** and **Erase All Content and Settings…** retain the window
and reconnect after boot. An active recording is saved first. **Shut Down**
stops the device and removes its window.

**Start the last used simulator on launch** in Settings controls launch
restoration. The `AttachBootedOnStart` preference controls attachment of devices
that are already booted when the manager starts. See <doc:Configuration>.

## Arrange windows

Drag a device bezel to move its window, or drag its corners to resize it. With
the bezel hidden, resize from the window edges. **Window → Show Device Bezels**
and **Stay on Top** control its presentation.

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

Physical-device and VM screen windows support standard macOS tabs. Use the
toolbar's **Compact Window** button to reduce a window, and click it again to
restore its previous size. Home, Lock, and volume controls appear when the
device supports them. **Reconnect** retries a disconnected screen.

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

A capture appears as a floating thumbnail beside the window. It saves when the
thumbnail disappears: screenshots go to the configured screenshot folder
(initially the macOS screenshot location or Desktop), and recordings go to the
Desktop. The thumbnail lasts five seconds for a screenshot or the movie's
duration for a recording. Hover to keep it open, drag to export a file, or
Control-click to save elsewhere, copy, open, or delete. The recording menu can
also export an animated GIF.

A new capture saves the preceding thumbnail's file. Quitting saves remaining
captures and finalizes recordings. Existing names receive a ` #2` suffix and
so on. If saving fails, the error includes the file's location for recovery.

### Physical-device and VM captures

With a physical-device or VM screen active, **File → Save Screenshot…**
(Command-S) saves its remote pixels as PNG. Capture actions are disabled when
the connection cannot supply them.

Choose **Record Screen** in the toolbar or File menu (Command-R) to start a
recording. **Stop Recording** finishes it and saves an MP4 movie in the chosen
capture folder, initially Desktop. Hold Option and choose **File → Record
Screen…** to choose a destination before starting.
Automatic saves number existing names with ` #2`, ` #3`, and so on. Choosing a
file in the save panel permits replacing it after the panel's confirmation.

If saving fails or you cancel the save panel, the completed recording remains
in memory. Choose **Save Recording…** to try another destination. Closing the
window, quitting, reconnecting, or switching Display Host finishes a pending
recording before disconnecting. An unsaved recording offers Save, Cancel, and
Don't Save; Cancel keeps the connection open. **Discard Recording…** explicitly
removes a retained recording after confirmation.

## Install apps and import media

Drop simulator `.app` bundles, images, videos, or vCards onto a device window,
or choose **File → Install App or Import Media…**. Partial failures list both
completed imports and failed files. **I/O → Open URL…** opens web addresses and
custom app URL schemes in the active device.

## Browse device reports

Select a physical device or virtual machine in the main window, choose
**Content** in the right inspector's toolbar, then **Reports**. Report listing
and downloads depend on the connected device's capabilities. Reports are
unavailable for simulators.

Search by report name, path, file extension, or recorded type. **All Report
Types** lets you filter by the device's recorded log type, or by file extension
when no log type is supplied. An `.ips` extension alone does not identify a
report as a crash or hang. Select a report to view its available metadata,
relative path, and file properties.

Double-click a report file or choose the eye button (**Quick Look**) to preview
it in a separate window. Closing the preview, selecting another report or
device, or quitting removes its temporary copy. Use **Download Report…** to
keep a copy: choose the download button and select a destination in the save
panel. Confirm replacement if that destination already exists.

A transfer failure preserves an existing destination. If transfer data remains
on the Mac, the error gives its location for recovery. If saving succeeds but
cleanup fails, the error identifies both the saved report and the remaining
data. An incomplete report list keeps the available reports and shows a
message about records it could not read.

## Debug and simulate conditions

The main window's inspector changes the selected device's Appearance, Liquid
Glass, Color Filter, Text Size, accessibility settings, Location, and Sound.
Sound includes volume and the Mac's input and output devices. Select **System
Default** to follow the Mac's current audio route. Start the simulator to read
and change its settings; controls that it cannot supply are unavailable.

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
