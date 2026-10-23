# Using NeoSimulator

Open devices, manage their windows, and capture their screens.

## Open and create devices

Start the beta host with `xcode-simulator-host use neo`. Use **File → Open
Simulator** or **Window → Simulators** to start a device or reopen its window.
The browser supports search. Open Simulator groups devices by runtime; a
checkmark means a device has a window, and a dash means it is running without
one. Hold Option to show its runtime and device type.

**File → New Simulator…** creates a device from the installed runtimes. For an
iPhone, **Paired Apple Watch** adds a second page for a compatible watch.
Creation does not boot the new devices. If creation or pairing fails after a
device was created, the error names the devices kept. Install runtimes in Xcode.

Neo supports iPhone, iPad, Apple Watch, Apple TV, and Apple Vision Pro. Menus show
the controls supported by the active device. The selected Xcode supplies device
artwork and the visionOS user-interface plugin.

## Close, restart, or quit

Closing a device window normally shuts down its simulator. To leave it running,
Control-click the close button or choose **File → Close Window…**
(Control-Command-W), then **Keep Running**. The sheet can remember that choice.
Reopen a detached device through Open Simulator or the device browser.

Quitting normally shuts down devices with open windows. **Quit NeoSimulator…**
(Option-Command-Q) asks whether to keep them running. Settings can change both
defaults. CLI host switching leaves devices running so the next host can attach.

**Device → Restart** and **Erase All Content and Settings…** retain the window
and reconnect after boot. An active recording is saved first. **Shut Down**
stops the device and removes its window.

By default, Neo attaches already-booted devices, or starts the last selected
device when none attach. Settings can change this behavior; see
<doc:Configuration>.

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

## Save screens and recordings

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

## Install apps and import media

Drop simulator `.app` bundles, images, videos, or vCards onto a device window,
or choose **File → Install App or Import Media…**. Partial failures list both
completed imports and failed files. **I/O → Open URL…** opens web addresses and
custom app URL schemes in the active device.

## Debug and simulate conditions

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
