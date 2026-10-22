# NeoSimulator

Use iOS Simulator from Xcode 27+ through CoreSimulator, without making
Device Hub the display host.

> [!IMPORTANT]
> `use legacy` with Apple's `Simulator.app` from Xcode 26 is the recommended
> host. The packaged `NeoSimulator` host is under active development and is
> currently in beta.

## Why

Xcode 27 no longer bundles `Simulator.app`. Its default simulator UI is Device
Hub, but CoreSimulator still owns the simulated devices used by Build & Run.
This package makes that direct CoreSimulator route usable again and lets you
choose the UI that presents it.

## Host Choices

NeoSimulator provides three explicit host choices through the
`xcode-simulator-host` command:

| Command | UI host | Status and intended use |
| --- | --- | --- |
| `use legacy` | Apple's `Simulator.app` from Xcode 26 | **Recommended.** Keep the complete Simulator UI while using Xcode 27+ for Build & Run |
| `use neo` | Packaged `NeoSimulator` app | **Beta.** Try the standalone host under active development without needing an older Xcode |
| `use device-hub` | Device Hub from the selected Xcode | Return to Xcode's default behavior |

Legacy and Neo both select the same direct CoreSimulator preference route; the
difference is the process that presents the simulator. The restoration receipt
therefore owns preference recovery, not a remembered UI-host choice.

## Requirements

- macOS 26.4+
- Apple Silicon
- Xcode 27+
- Xcode 26 (`use legacy`)
- Swift 6.4+ (source builds)

## Recommended Quick Start: Simulator.app from Xcode 26

Install the latest prebuilt release:

```bash
curl -fsSL https://github.com/lynnswap/NeoSimulator/releases/latest/download/install.sh | sh
```

Follow the printed PATH guidance if needed, then run:

```bash
xcode-simulator-host use legacy
```

When Xcode 26 is installed in `/Applications`, the highest validated Xcode 26
version is selected automatically. Keep the selected Xcode 27+ installation
open and use **Build & Run** as usual; Xcode 26 supplies only the Simulator UI.

Running `use legacy` again is safe. The exact validated `Simulator.app` is
closed and reopened without rewriting an already-correct CoreSimulator route.

### Choose a Specific Xcode 26 Installation

To use an Xcode 26 installation outside `/Applications`, or to choose one
explicitly:

```bash
xcode-simulator-host use legacy \
  --legacy-xcode /Applications/Xcode_26.app
```

`--legacy-xcode` selects only the legacy UI host. Build & Run still uses the
Xcode 27+ installation selected through `DEVELOPER_DIR` or `xcode-select`.

## Try NeoSimulator (Beta)

`NeoSimulator` is an alternative host currently in beta and under active
development. It uses the selected Xcode 27+ installation and does not require
Xcode 26.

```bash
xcode-simulator-host use neo
```

Neo currently provides:

- a searchable device browser to start simulators or reopen their windows;
- one window for each booted iOS, watchOS, tvOS, and visionOS simulator,
  resized by dragging the corners of its device bezel, or its edges while it
  shows no bezel, and moved by dragging its bezel away from the screen;
- device bezel, touch, accessibility, and focused keyboard input;
- a Simulator-style window header with the device name, runtime, Home,
  Save Screen, and Rotate controls, which become Record Screen and Rotate
  Left while Option is held with the pointer over the toolbar. Watches and
  Apple TV have Home and Save Screen, and a watch with an always-on display
  also has Always On, which locks the watch and stays on while its display is
  dimmed or off. As in Simulator.app, a watch's title leaves out
  "Apple Watch";
- Apple Vision Pro with the spatial controls and toolbar of the selected
  Xcode's visionOS simulator plugin (`XROS.simdeviceui`), as in Simulator.app:
  the plugin's view over the screen takes the pointer and the keyboard, and
  its toolbar has Home, Save Screen, Capture Pointer, Capture Keyboard, and
  Simulated Scenes. Capture Pointer and Capture Keyboard do not capture the
  Mac's input, which Neo leaves out;
- Simulator.app's Save Screen, Record Screen, and Copy Screen commands, with
  its file names, save folders, and device-mask option; recordings are
  finalized when a window closes or the app quits;
- Edit → Get Pasteboard and Send Pasteboard, which copy the whole pasteboard
  between the Mac and the active device when you choose them, and
  Automatically Sync Pasteboard, which stays off until you turn it on;
- simulator app installation and image, video, and vCard import through a file
  picker or drag and drop;
- opening web addresses and custom app URL schemes on the selected device;
- File, Edit, Device, I/O, Features, Debug, Window, and Help menus in
  Simulator.app's order, showing only the commands the active device supports;
- Home, Lock, Shake, rotation, the six device orientations, Rotate Device
  Automatically, appearance, bezel, Stay on Top, and standard window commands;
- Simulator.app's window scales: Physical Size (Command-1), Point Accurate
  (Command-2), Pixel Accurate (Command-3), and Fit Screen (Command-4). As in
  Simulator.app, a window with a bezel may extend past the screen, and a
  device's window reopens, in the arrangement of displays it closed in,
  centered where it closed, at the scale it closed reduced to fit the screen,
  and moved inside the screen where it crosses an edge;
- the hardware inputs the active device supports: Side Button, Action Button,
  Siri, App Switcher, Trigger Screenshot, Increase and Decrease Volume, and
  Authorize Apple Pay;
- for watches, Device → Gestures (Double Tap, and Wrist Flick from watchOS 12),
  and the Digital Crown, which turns when you scroll with the mouse wheel or
  trackpad over the watch's screen;
- I/O → Keyboard: Connect Hardware Keyboard (Shift-Command-K), Toggle Software
  Keyboard (Command-K), and Use the Same Keyboard Language as macOS; and I/O →
  Touch Pressure for devices with 3D Touch: Use Trackpad Force, Shallow Press
  (Shift-Command-1), and Deep Press (Shift-Command-2);
- I/O → Audio Input and Audio Output, which choose the Mac audio devices that
  simulators use;
- I/O → External Displays, which connects an external display from 640×480 to
  3840×2160 (4K) and shows it in its own window;
- Features menu controls: Touch ID and Face ID enrollment and matching or
  non-matching events, Simulate Fall on a watch with fall detection, the
  in-call status bar, StandBy, preferred text size, Increase Contrast, Trigger
  iCloud Sync (Shift-Command-I), and Location;
- Debug menu tools: Slow Animations, Graphics Quality Override, Color Blended
  Layers, Color Copied Images, Color Misaligned Images, Color Off-screen
  Rendered, Open System Log… (Command-/), and Simulate Memory Warning
  (Shift-Command-M);
- File → GPU Selection, the GPU that CoreSimulator prefers for rendering
  simulators;
- NeoSimulator → Settings… (Command-,), Simulator.app's settings for starting
  and leaving simulators, touch indicators, the device mask, and animated GIFs.

Use **File → Open Simulator** to choose a device, **File → New Simulator…**
to create one, and **Device → Shut Down** to stop it. As in Simulator.app, Open
Simulator groups devices by runtime and marks booted devices: a checkmark when
the device has a window, a dash when it does not; hold Option to see each
device's runtime and type.

Watches, Apple TV, and Apple Vision Pro show the commands Simulator.app shows
for them: Lock and Side Button for watches, Gestures and Simulate Fall for
watches that support them, and no Lock for Apple TV or Apple Vision Pro. The
Apple TV Remote window, and the visionOS camera, scene, and immersion commands
of the Device, I/O, and Debug menus are not available yet. File → New
Simulator… does not create a paired Apple Watch yet.

Neo also shows the devices Xcode boots for parallel testing, from
`~/Library/Developer/XCTestDevices` (or the `TestingDeviceSetPath` default).
**Debug → Show Parallel Testing Devices** hides their windows without shutting
the devices down. Rotation and orientation commands are unavailable for these
devices, because `devicectl` reaches only the default device set.

As in Simulator.app, Neo remembers **Debug → Slow Animations** and
**Graphics Quality Override** (`SlowMotionAnimation`, `GraphicsQualityOverride`)
and applies them to each device when it connects. The checkmarks of the color
options show the device's own state. **Open System Log…** opens the device's
`system.log` in Console. **File → GPU Selection** edits CoreSimulator's
`FramebufferServerGPUPolicy` setting, which Simulator.app also edits and which
applies to all simulators. Unlike Simulator.app, Neo reports when a device
rejects a change, when the memory-warning signal cannot be written, and when
the system log cannot be opened.

**Device → Restart** and **Device → Erase All Content and Settings…** keep the
window open and reconnect it when the device boots again; an active recording
is saved first.

Closing a device window shuts the device down, as Simulator.app does by
default; earlier versions of Neo left it running. To keep it running, hold
Control while closing, or choose **File → Close Window…** (Control-Command-W),
and choose Keep Running. Checking "Remember as the default close action" makes
that the default (`DetachOnWindowClose`). A device left running can be reopened
from File → Open Simulator or from **Window → Simulators**, NeoSimulator's own
device list, which also opens when no device window is open. Quitting shuts
down the devices that have windows unless `DetachOnAppQuit` is on;
**Quit NeoSimulator…** (Option-Command-Q) asks. When it launches, Neo shows
windows for devices that are already booted (`AttachBootedOnStart`), or else
starts the device last opened (`StartLastDeviceOnLaunch`, `CurrentDeviceUDID`).

Neo requires no `Simulator.app` installation.

**File → Save Screen** (Command-S) and the header's camera button capture a PNG
named like Simulator.app's, and **File → Record Screen** (Command-R) starts
recording at once. As in Simulator.app, a capture first appears as a floating
thumbnail beside the device window. When the thumbnail goes away, after five
seconds or the movie's length, the capture is saved: a screenshot to the
screenshot folder (`ScreenShotSaveLocation`, which starts as the macOS screenshot
location, or the Desktop), a recording to the Desktop. Hover over the thumbnail
to keep it, drag it out as a file, or Control-click it to save it elsewhere,
copy, open, or delete it; a recording's menu also saves an animated GIF. A
new capture saves the previous thumbnail's capture, and quitting saves any that
remain. A file of the same name gets " #2" and so on. Hold Option for **Save Screen…** and **Record Screen…**, which ask for a
destination and whether to apply the device mask to a non-rectangular screen;
Save Screen… remembers the folder and the choice (`ScreenShotUseMask`), which
Save Screen and Record Screen then use. As in Simulator.app, holding Option
with the pointer over the window's toolbar turns the camera button into a
record button, which starts Record Screen, and the rotate button into one that
rotates left. The camera button becomes a stop button while a recording runs;
click it or choose **File → Stop Recording** to finish the recording. If a save fails, the error includes the
capture's location for recovery. **Edit → Copy Screen** (Control-Command-C)
puts a PNG of the screen, without the mask, on the Mac pasteboard.

**Edit → Get Pasteboard** replaces the Mac pasteboard with the active device's,
and **Edit → Send Pasteboard** replaces the device's pasteboard with the Mac's,
with all their types, such as text and images. They are available for iPhone,
iPad, and Apple Vision Pro devices while Automatically Sync Pasteboard is off. As in
Simulator.app, the Mac reads what Get Pasteboard brings from the device when an
app pastes it, so paste it while the device's window is open.

**Edit → Automatically Sync Pasteboard** synchronizes pasteboards as
Simulator.app does: what you copy on the Mac reaches every device that has a
window, and what an app copies on one device reaches the Mac and the other
devices. A device that connects while it is on, for example after a restart,
receives the Mac pasteboard; turning it on sends nothing until something is
copied. Neo remembers the choice (`PasteboardAutomaticSync`).

Simulator.app turns automatic synchronization on by default; Neo leaves it off
until you turn it on. While it is on, everything you copy on the Mac, including
passwords and other private text, goes to every open simulator, where any app
can read it, and a copy made inside a simulator, for example by an app under
test, replaces what you copied on the Mac. While it is off, nothing crosses
between the Mac and a device unless you choose Get or Send Pasteboard.

**I/O → Keyboard → Connect Hardware Keyboard** (Shift-Command-K) connects or
disconnects the active device's hardware keyboard. As in Simulator.app, each
device keeps its own choice (`DevicePreferences[UDID].ConnectHardwareKeyboard`),
which is on until you turn it off. While it is off, the Mac's keyboard does not
type into the device, and the device shows its software keyboard; while it is
on, **Toggle Software Keyboard** (Command-K) shows or hides it. **Use the Same
Keyboard Language as macOS** (`EnableKeyboardSync`, on by default) gives a
device's keyboard the language of the Mac's input source when the device
connects, and gives the active device's keyboard the new language when you
switch input sources; like Simulator.app, turning it on waits for the next of
these. Unlike Simulator.app, which connects the hardware keyboard again on a
device's next connection, such as after a restart, Neo keeps the device's
choice, and it reports a failed change.

**I/O → Touch Pressure** appears for devices with 3D Touch, such as iPhone XS
on iOS 18. **Use Trackpad Force** (`UseTrackpadForce`) passes the pressure of a
Force Touch trackpad's click to the device; it needs such a trackpad. Shallow
Press and Deep Press choose the pressure of a click on a watch with touch
pressure. The settings apply to every device window, as in Simulator.app.

**I/O → Audio Input** and **I/O → Audio Output** choose the Mac audio device
that simulators record from and play to. **System** follows the Mac's default
device and shows its name; the other items list the Mac's devices, and the
device's current choice is checked. As in Simulator.app, a choice applies to
every device window and is remembered (`RecentAudioInputDeviceUIDs`,
`RecentAudioOutputDeviceUIDs`). When a device connects, including after a
restart, and whenever the Mac's devices change, Neo routes each device to the
most recently chosen device that the Mac has, so a headset is used again when
it is plugged back in. A device whose route another tool changes, such as
`devicectl device settings audio`, is routed back. The menus are available for
devices that support audio routing, including parallel testing devices.
Unlike Simulator.app, which only logs it, Neo reports a choice that a device
could not apply.

**I/O → External Displays** connects the active device's external display at
one of Simulator.app's sizes, from 640×480 to 3840×2160 (4K); **Disabled**
turns it off. The menu appears for devices that support external displays,
such as iPhone and iPad. The display opens in its own window, titled with the
device and "External Display", without a toolbar or bezel, and the Window menu's
scales apply to it while it is the active window. Closing that window turns the
display off, as Disabled does. A display that another tool turns on, such as
`xcrun simctl io <device> screenConfig`, opens its window too. As in
Simulator.app, the choice is saved for each device (`DevicePreferences`,
`SimulatorExternalDisplay`) and applied when the device connects, including
after a restart, and closing the device window while the device keeps running
turns the display off. Unlike Simulator.app, which checks the saved choice,
the checkmark shows the size the display actually has, and Neo reports a choice
that the device could not apply. The guest shows nothing on the display until an
app presents a scene for an external display; iOS does not mirror the device's
screen to it. A device that has no external display port cannot get one:
CoreSimulator offers no screen that a client can add.
CarPlay is not available yet.

**NeoSimulator → Settings…** (Command-,) shows the settings window that macOS
builds from the app's `Settings.bundle`, as it does for Simulator.app. It lists
Simulator.app's settings that Neo uses: booting the most recently used
simulator at launch (`StartLastDeviceOnLaunch`), leaving simulators running
when a window closes or Neo quits (`DetachOnWindowClose`, `DetachOnAppQuit`),
showing single touches and pinch gestures (`ShowSingleTouches`,
`ShowPinches`), applying the device mask to Save Screen and Record Screen
(`ScreenShotUseMask`), and the size and frame rate of animated GIFs
(`GifMaxFrameSize`, `GifMaxFramerate`). Simulator.app's stop-capture shortcut
is left out, because Neo does not capture the Mac's pointer and keyboard. As in
Simulator.app, pinch gestures are shown and single touches are not until you
change them, and every device window follows a change at once. Neo also follows
`ShowPinchPivotPoint` and `HighlightEdgeGestures`, which only Apple's internal
builds of Simulator.app show in a menu, and changes that `defaults write
dev.lynnswap.NeoSimulator` makes while Neo runs.

**Features → Location** simulates the active device's location: **None**
clears it, **Custom Location…** asks for a latitude and longitude, and the
other items run the routes the device's runtime provides, such as City Run or
Freeway Drive. As in Simulator.app, a choice changes only the active device,
and the last choice is saved (`LocationMode`, `LocationLatitude`,
`LocationLongitude`, `LocationScenario`) and applied to each device that
connects, including after a restart. A new installation therefore starts
devices at Simulator.app's San Francisco coordinate. Devices whose runtime
lists no routes are left alone. Unlike Simulator.app, which lists the routes
of the device that connected last, the menu lists the active device's own.

Drop simulator `.app` bundles or media onto a device, or choose
**File → Install App or Import Media…**. If only some files succeed, Neo lists
the completed imports and individual failures. **I/O → Open URL…** opens a web
address or a custom URL scheme in the active simulator. Device and runtime
creation remain in Xcode.

Later Xcode versions are accepted only when their private CoreSimulator,
SimulatorKit, CoreDevice, and command-tool surfaces pass the compatibility gate.
An incompatible version fails closed; Neo never falls back to Device Hub.

Running `use neo` again is safe. It revalidates and restarts the exact packaged
host with the currently selected Xcode, so switching between compatible Xcode
27+ installations cannot leave a host using frameworks from the previous
selection.

### Mouse and Keyboard Gestures

Use these controls over the simulated screen:

| Control | Interaction |
| --- | --- |
| Hold Option | Show two fingers mirrored around the point where Option went down |
| Hold Option, then drag | Pinch by changing the distance between the two fingers; rotate by moving around their center |
| Hold Option and Shift, then move the pointer | Reposition the two-finger gesture center |
| Hold Option and Shift, then drag | Move both fingers together |
| While dragging, press Control and release the mouse button | Pin the first finger while you interact with a second finger |

To release a pinned finger, release Control, click the pinned position, and
release the mouse button. Releasing Control alone leaves the finger pinned.

SimulatorKit handles these gestures in Neo as in Simulator.app, so they behave
the same way in both:

- Pressing or releasing Shift during an Option drag switches between pinching
  and moving both fingers. Pressing Option during a one-finger drag adds the
  second finger.
- Release the mouse button before Option. Releasing Option first stops both
  fingers where they are, and they stay down after the button comes up until
  the next click.
- A gesture in progress continues when another window or app becomes active;
  releasing the mouse button lifts the fingers.
- A change of window scale or a drag on the bezel keeps a pinned finger at its
  place on the device's screen. After a rotation, the pinned finger stays at
  its place in the window, so it moves on the device's screen; click that place
  in the window to release it.
- Closing the window or quitting Neo while a finger is down or pinned leaves
  the touch active in a device that keeps running. The next touch from a
  device window ends it first and can become that touch's end, so finish
  gestures and release pinned fingers before closing. Restarting the device
  clears it.

Unlike Simulator.app, Neo applies the current modifier keys when a device
window becomes active, so an Option release that happened while another window
or app was active does not turn the next click into a two-finger touch.

Arbitrary gestures with three or more fingers are not supported. Neither are
Simulator.app's **I/O → Input** commands, Send Pointer to Device and Send
Keyboard Input to Device, or the matching buttons in an iPad's toolbar: macOS
lets only apps that Apple signs capture the Mac's pointer and keyboard that way.
See [Input capture](Documentation/Design.md#input-capture).

## Return to Device Hub

```bash
xcode-simulator-host use device-hub
```

Validated legacy Simulator and Neo processes close before the default Device
Hub route is enabled.

## Restore the Original Settings

```bash
xcode-simulator-host restore
```

Use `restore` to undo the tool's preference changes instead of guessing which
route was originally configured. If the saved original route is CoreSimulator,
`restore` does not guess whether Legacy or Neo should be opened.

## Inspect the Current Route

```bash
xcode-simulator-host status
```

Compact status reports `CoreSimulator` or `Device Hub`. It cannot distinguish
Legacy from Neo because those hosts intentionally share the same preference
route.

For host availability, selected Xcode details, compatibility-checked private
components, preferences, restoration state, and running processes:

```bash
xcode-simulator-host status --verbose
```

Both commands are read-only. See
[Advanced configuration](Documentation/AdvancedConfiguration.md) for
`DEVELOPER_DIR`, `--legacy-xcode`, and recovery details.

## Safety and Recovery

> [!IMPORTANT]
> Both direct-host modes use undocumented Xcode preferences. Legacy launches an
> intact Apple-signed `Simulator.app` from a validated Xcode 26 installation.
> The beta Neo host also uses undocumented Apple frameworks.

Neither `use legacy` nor `use neo` launches Device Hub. If the exact Device Hub
process cannot be closed, the requested UI host is not opened. While Neo is
running, it also exits if Device Hub or a legacy `Simulator.app` appears, so two
UI hosts cannot own the same simulator session.

Before changing preferences, every `use` command validates the selected Xcode
27+ installation, the preference surfaces, and the exact Device Hub identity.
Additional host-specific gates run before any process or preference mutation:

- `use legacy` validates the outer Xcode 26 application, its version and Apple
  signature, and the nested `Simulator.app` identity, `DTXcode`, executable,
  and Apple signature;
- `use neo` validates the installed CoreSimulator/CoreDevice generations,
  direct tools and plugin, the packaged NeoSimulator identity, and the exact
  private runtime contract used by the GUI process.

Preference changes are journaled and verified. A conflicting external change
is left untouched unless the user explicitly runs `restore --force`.

The restoration receipt is stored at:

```text
~/Library/Application Support/xcode-simulator-host/state.plist
```

Do not run mutation commands with `sudo`; preferences and recovery state are
per-user. Run `restore` before uninstalling the command or deleting its state.

See the [design and safety contract](Documentation/Design.md), the
[Simulator.app analysis](Documentation/SimulatorAppAnalysis.md), and the
[NeoSimulator contract](Documentation/StandaloneHost.md) for exact owners and
exclusions.

## Install to a Custom Directory

```bash
curl -fsSL https://github.com/lynnswap/NeoSimulator/releases/latest/download/install.sh \
  | sh -s -- --bindir "$HOME/bin"
```

The installer keeps the CLI and bundled beta NeoSimulator app in a fixed
relative layout. It resolves a symlinked bindir to its physical directory, then
stages and verifies both before replacing an existing installation.

## Build from Source

```bash
git clone https://github.com/lynnswap/NeoSimulator.git
cd NeoSimulator
scripts/build-local.sh
.build/local/arm64/bin/xcode-simulator-host --help
```

The source build uses SwiftPM for the CLI and the beta `NeoSimulator` app
target in `NeoSimulator.xcworkspace`. The staging script puts both
products in the same relative layout used by releases.

Open `NeoSimulator.xcworkspace` to edit the app alongside the Swift package's
CLI, tests, build-info tool, and plugin. Select `NeoSimulator` to build the app,
`xcode-simulator-host` to build the CLI, or `XcodeSimulatorHostTests` to run the
package tests. The app project uses Xcode's JSON `project.xcproj` format and
requires Xcode 27 or later to open.

The host application is written in Swift. It calls the dynamically loaded
CoreSimulator, SimulatorKit, and IDEPlaygroundSimulator interfaces through
[ABIBridge](https://github.com/lynnswap/ABIBridge) by their source-level names,
including SimulatorKit members exported only as dispatch thunks. Open `DeviceBrowser.swift` with the `NeoSimulator` scheme to
use the `#Preview` canvas. These previews use the same browser UI as the app,
with sample devices and no CoreSimulator connection. Device windows use an
AppKit toolbar and the selected Xcode's native device artwork.

Build and switch to the recommended Legacy host in one command:

```bash
scripts/build-local.sh && .build/local/arm64/bin/xcode-simulator-host use legacy
```

This runs from the repo-local staging directory; it does not install the command
into `PATH`. Use `use neo` instead to try the locally built beta host.

Run the isolated test suite with:

```bash
swift test
```

Run the Swift host tests, including native input focus, the selected Xcode's
digitizer getter, device browsing, command cancellation, and capture failures,
without booting or connecting to a simulator:

```bash
scripts/test-input-focus.sh
```

## License

NeoSimulator is available under the [MIT License](LICENSE).
