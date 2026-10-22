# NeoSimulator design

## Consumer contract

```console
xcode-simulator-host status [--verbose] [--legacy-xcode /path/to/Xcode_26.app]
xcode-simulator-host use neo
xcode-simulator-host use legacy [--legacy-xcode /path/to/Xcode_26.app]
xcode-simulator-host use device-hub
xcode-simulator-host restore [--force]
```

- `status` is read-only. Compact output reports only the route used by the next
  Xcode Run. `--verbose` adds Neo and Legacy availability,
  compatibility-checked components, preferences, restoration state, and
  running processes.
- `use neo` selects the direct CoreSimulator route and launches the packaged
  host with the selected Xcode 27+ installation.
- `use legacy` selects the same CoreSimulator route and launches Apple's
  `Simulator.app` from a validated Xcode 26 installation. The highest validated
  `/Applications/Xcode*.app` candidate is used unless `--legacy-xcode` is set.
- `use device-hub` closes Neo and validated legacy Simulator processes before
  restoring Xcode's default Device Hub route.
- `restore` restores the exact preference state captured before the first
  mutation. If that route uses Device Hub, it closes both direct-route UI hosts
  first. A restored CoreSimulator route does not imply a Neo or Legacy choice.
- `restore --force` is the explicit recovery path for a conflicting Boolean
  live state.

Xcode is resolved from `DEVELOPER_DIR` or `xcode-select -p`. Xcode 27 is the
minimum generation. Later versions are supported when they satisfy the same
verified private contract.

## Why two direct-route hosts

Xcode 27 no longer supplies Simulator.app, while Device Hub is not an acceptable
display host for workflows that require CoreSimulator without continuous
pasteboard synchronization and other device-management behavior. Xcode Previews
demonstrates that SimulatorKit can render and interact with a CoreSimulator
screen directly.

Neo is the self-contained Xcode 27+ path: the package ships a narrow AppKit
companion instead of embedding DeviceKit or launching Device Hub. Legacy is the
compatibility path for users who already have Xcode 26: it reuses Apple's full
`Simulator.app` while the selected Xcode 27+ installation remains the Build &
Run owner.

```text
Xcode Build & Run
  -> CoreSimulator session
  -> NeoSimulator.app
       -> CoreSimulator device-set membership
       -> IDEPlaygroundSimulator display factory
       -> SimulatorKit SimDisplayView
       -> AppKit window, header, menus
       -> typed HID and device-tool actions
```

## Package and distribution topology

```text
NeoSimulator repository and distribution
├── NeoSimulator (Swift package)
│   ├── xcode-simulator-host (executable product)
│   ├── XcodeSimulatorHost (executable target and module)
│   └── XcodeSimulatorHostTests
└── NeoSimulator.xcworkspace
    └── NeoSimulator (AppKit application target)
```

The release archive preserves this layout:

```text
bin/xcode-simulator-host
libexec/xcode-simulator-host/NeoSimulator.app
```

The CLI resolves the app relative to its own real executable path. The installer
first resolves a symlinked bindir to its physical directory, then stages and
verifies both artifacts, installs the app first, commits the CLI last, and
restores the previous pair if installation fails. Rollback derives whether an
old artifact moved from the presence of its same-filesystem backup path, so a
signal cannot land between a move and a separate bookkeeping update.

## Owner map

| Responsibility | Owner |
| --- | --- |
| Parse CLI commands | ArgumentParser command types |
| Execute fixed system commands | `SystemCommandRunner` |
| Read and mutate the two preferences | `DefaultsStore` |
| Persist original and pending state | `ReceiptStore` |
| Validate Xcode 27+ and private components | `InstallationInspector` |
| Serialize route and process transitions | `HostModeController` |
| Observe and terminate exact app identities | `WorkspaceClient` |
| Observe booted iOS simulator membership | `HostApplication` |
| Load and validate the private runtime | `SimulatorRuntime` |
| Own one device's display, HID client, tools, and operations | `DeviceSession` |
| Present one device window | `DeviceWindowController` |
| Define commands, their availability, and state | `DeviceCommand` |
| Build and validate active-window menus | `MenuController` |
| Run device tool subprocesses | `DeviceToolRunner` |
| A device's SimPasteboardPlus connection, for Get and Send Pasteboard and synchronization | `DeviceSession` |
| Edit ▸ Automatically Sync Pasteboard and the exchange between devices | `PasteboardSync` |
| Route a device's audio over its `SimAudioHostRoutable` port | `DeviceSession` |
| Configure a device's external display and follow its state | `DeviceSession` |
| Order the changes sent to a device's external display, with the guest's CarPlay, across its sessions | `ExternalDisplayChanges`, one per device in `HostApplication` |
| Present an external display's window | `ExternalDisplayWindowController` |
| Give a window's display the Mac's keyboard and the focus, as both windows do | `DisplayKeyboardInput` |
| Fit a window's display in full screen and during a live resize, as both windows do | `DisplayFitting` |
| Keep the app-wide recent audio routes | `PreferenceStore` (`RecentAudio…DeviceUIDs`) |

The active simulator for a menu command is derived from `NSApp.keyWindow` each
time; an external display's window stands for its device window. Device
selection is not mirrored in a second state store.

## Compatibility gates

Every mode first validates the selected Xcode 27+ application, its exact Device
Hub, and both managed preference surfaces. Host-specific validation then runs
before receipt recovery, process termination, or preference mutation.

Neo additionally requires:

- selected-Xcode SimulatorKit and IDEPlaygroundSimulator frameworks with
  matching `DTXcode` generation and intact Apple signatures;
- installed CoreSimulator and CoreDevice frameworks whose `DTXcode` generation
  matches the selected Xcode;
- exactly one numeric `EXPECTED_VERSION` literal in each selected-Xcode
  `simctl` and `devicectl` wrapper;
- exact equality between those expected versions and the installed framework
  versions;
- intact Apple-signed direct `simctl` and `devicectl` executables with their
  expected identifiers;
- an intact Apple-signed simulator CoreDevice plugin whose version matches
  CoreSimulator and whose generation matches Xcode;
- no DeviceKit or Device Hub load-path fragments in direct `devicectl` or the
  simulator CoreDevice plugin;
- the packaged companion app at the exact relative path, with its expected
  bundle identifier and executable.

After those provenance checks, the gate executes the exact packaged companion
in non-UI `--validate-runtime` mode. `SimulatorRuntime` then performs the same
framework loads, ABIBridge lookups of every private message and Swift member,
and loaded-image checks used by the GUI process, without creating an
application, CoreSimulator device set, or display session. This keeps the runtime contract in one owner while still
rejecting a changed Xcode before preference mutation.

Wrappers and direct private tools are inspected but never executed by the gate.
This prevents their mismatch path from implicitly running
`xcodebuild -runFirstLaunch`.

An unknown later Xcode that changes a private symbol or component version is
unavailable. It is never guessed compatible and never falls back to Device Hub.

Selecting a Legacy installation to launch validates:

- an outer `com.apple.dt.Xcode` application whose version is exactly generation
  26 and whose application signature is intact and Apple-anchored;
- its nested `Contents/Developer/Applications/Simulator.app` bundle identifier,
  executable, version metadata, generation-26 `DTXcode`, and Apple application
  signature.

An already-running legacy Simulator is validated separately for termination.
The same Simulator bundle metadata, executable, and Apple application signature
checks apply, along with the supported Xcode 26 directory layout and parent
metadata. Its parent Xcode is not used as a launch source by termination, so
unrelated resources outside `Simulator.app` do not block switching hosts.
The workspace client rechecks the running process's bundle identifier and exact
normalized bundle URL before sending a termination request.

An explicitly selected legacy Xcode may live outside `/Applications`. A copied
or substituted `Simulator.app` outside the supported Xcode 26 layout is never
managed. Full parent-Xcode integrity remains required when selecting that
installation to launch.

## Managed preferences

```text
domain: com.apple.dt.Xcode
key:    DVTiPhoneSimulatorAlwaysLaunchInCoreSimulatorSession

domain: com.apple.dt.Devices
key:    disableAutoStartLiveDeviceView
```

Each value is `absent`, `false`, or `true`. Any other type is a configuration
error. The live adapter uses `defaults`; direct CFPreferences access cannot
reliably observe the Device Hub container domain from this process.

The preferences encode only two routes: CoreSimulator and Device Hub. Neo and
Legacy are separate process strategies for the same CoreSimulator state. The
receipt consequently stores only original, expected, and pending preference
states; persisting a Neo/Legacy choice there would create a second source of
truth for process lifecycle.

## Preference transaction

The first mutation stores a receipt under the user's Application Support
directory. It records the original tri-state values, last verified state,
selected Xcode version/build, and an optional pending `before -> target`
mutation. Later switches preserve the original state.

For a route transition, `HostModeController`:

1. acquires an exclusive operation lock;
2. validates every required component;
3. closes validated UI hosts that conflict with the requested host;
4. reads the current preference state;
5. records the pending transition;
6. verifies full state before and after each individual preference write;
7. finalizes the receipt;
8. applies target-specific process lifecycle work while still holding the lock.

If a write fails, the controller restores the immediately preceding state when
that state can still be proven. A different live state is treated as an
external conflict and is not overwritten.

An intermediate state that could be either an interrupted first write or an
external change is intentionally ambiguous. Normal `use` and `restore` leave it
untouched; only `restore --force` gives the saved original state precedence.

Compact `status` takes an optimistic read before state exists and retries under
the existing lock if the state directory appears concurrently. Once state
exists, status always uses that lock and never performs recovery or mutation.

## Process lifecycle

### Select Neo

1. Validate the selected Xcode, packaged NeoSimulator app, private frameworks,
   tools, plugin, and runtime contract.
2. Validate each running legacy Simulator's application signature and exact
   Xcode 26 location for termination.
3. Reject receipt conflicts, then close those legacy Simulators and restart the
   exact Neo bundle.
4. Commit the CoreSimulator preference state if it is not already active.
5. Terminate only Device Hub instances whose resolved bundle URL matches the
   selected Xcode; failure stops before Neo is opened.
6. Reverify the managed state and launch Neo with
   `--xcode <selected Xcode.app>`.

Every `use neo` restarts Neo. This makes Xcode 27-to-28 selection changes
deterministic and avoids retaining frameworks from a previous selection.

### Select Legacy

1. Validate the selected Xcode 27+, the requested or discovered Xcode 26, and
   its nested `Simulator.app`.
2. Validate every running legacy Simulator by its actual bundle URL.
3. Reject receipt conflicts, then close Neo and all validated legacy Simulator
   instances.
4. Commit the same CoreSimulator preference state used by Neo if needed.
5. Terminate the exact selected-Xcode Device Hub; failure stops before
   Simulator is opened.
6. Reverify the managed state and open the exact validated `Simulator.app`.

Neo-to-Legacy and Legacy-to-Neo switches still execute this process lifecycle
when the preference route is already CoreSimulator. “No preference change” is
not treated as “already using this host.”

### Select Device Hub or restore

`use device-hub` closes the exact Neo bundle and every validated legacy
Simulator before committing the Device Hub preference state. Failure to close a
managed direct-route host stops the transition before mutation.

`restore` closes both host types only when the saved original route is Device
Hub. When the original is CoreSimulator, the receipt has no authority to guess
whether Neo or Legacy should run.

### Runtime host conflicts

Neo refuses to connect if Device Hub (`com.apple.dt.Devices`) or legacy
Simulator (`com.apple.iphonesimulator`) is already running. It observes
application launches while active. If either appears, it cancels device
operations, disconnects every display, and exits. It never kills the competing
host or falls back to it.

## Standalone display lifecycle

The host connects to the selected Xcode's CoreSimulator service context and
subscribes to the default device set. It creates sessions only for booted iOS
devices.

A session discovers the default integrated `SimDeviceScreen`; screen ID zero is
not assumed. It creates a connected `SimDisplayView` and one
`SimDeviceLegacyHIDClient`, and installs the view in a transparent AppKit
window, which shows the device bezel as Window ▸ Show Device Bezels says. A
window with a bezel resizes by dragging the bezel's corners and moves by
dragging the bezel elsewhere; a window without one resizes by its edges (see
window scale below).
Shutdown removes the session. Closing a window
shuts the device down, as Simulator.app does with `DetachOnWindowClose` off;
a close that keeps the device running suppresses reopening until the device
leaves the booted state. File ▸ Close Window… (or Control-closing) asks with
Simulator.app's sheet, and Quit NeoSimulator… asks the same for quitting. A
shutdown on close abandons a restart in progress. Launch follows
`AttachBootedOnStart`, then, when no window was attached, starts
`CurrentDeviceUDID` or Simulator.app's fallback: the last iPhone in
CoreSimulator's order, or the first device.

The header and window shell follow the owner behavior found in Simulator.app:
DarkAqua, a title bar that AppKit draws with the toolbar style Simulator.app
chooses for the window's width, native traffic lights, device chrome, render
scaling during resize, and shadow invalidation. Simulator.app itself is an
analysis source only and is not a runtime dependency.

## Commands and menus

The first parity set contains only commands with an available, validated owner:

- NeoSimulator: Settings…;
- File: New Simulator…, Open Simulator, Save Screen, Save Screen…, Record
  Screen, Record Screen…, Stop Recording, GPU Selection, Close Window, Close
  Window…;
- Edit: Copy Screen, Automatically Sync Pasteboard, Get Pasteboard, Send
  Pasteboard;
- Device: Restart, Erase All Content and Settings…, Shut Down, Rotate
  Left/Right, Orientation, Rotate Device Automatically, Home,
  Lock, Side Button (watchOS devices only, so hidden until Neo hosts them),
  Action Button, Siri, Shake, App Switcher, Trigger Screenshot;
- I/O: Keyboard (Use the Same Keyboard Language as macOS, Connect Hardware
  Keyboard, Toggle Software Keyboard), Touch Pressure (Use Trackpad Force, and
  Shallow Press and Deep Press, which need a watch and so stay disabled until
  Neo hosts one), Audio Input, Audio Output, Increase Volume, Decrease Volume,
  External Displays (Disabled, Simulator.app's six sizes, and CarPlay);
- Features: Touch ID and Face ID (Enrolled, Matching, Non-matching),
  Authorize Apple Pay, Toggle Appearance, Toggle In-call Status Bar,
  Show/Hide StandBy, Increase and Decrease Preferred Text Size, Toggle
  Increase Contrast, Trigger iCloud Sync, Location (None, Custom Location…,
  and the runtime's scenarios);
- Debug: Slow Animations, Graphics Quality Override, Color Blended Layers,
  Color Copied Images, Color Misaligned Images, Color Off-screen Rendered, Open
  System Log…, Simulate Memory Warning, Show Parallel Testing Devices;
- Window: standard minimize/zoom/full screen, Show Device Bezels, Stay on Top,
  Physical Size, Point Accurate, Pixel Accurate, Fit Screen, Simulators, Bring
  All to Front.

File ▸ Open Simulator follows Simulator.app's menu delegate: CoreSimulator's
available-device order, a submenu per runtime (none for a single runtime), the
device name with its `descriptiveName` as the Option alternate, and markers on
for booting or booted devices with a visible window and mixed without one. Neo
lists iOS devices only, because it hosts no other platform yet. File ▸ New
Simulator… rebuilds Simulator.app's creation form: every supported device type
and available runtime in CoreSimulator's order, selection corrected to the first
compatible choice, the device type's name as the default name, and `simctl
create` without booting. Its Paired Apple Watch page waits for watchOS hosting.
Window ▸ Simulators is NeoSimulator's own device list; Simulator.app has no such
window.

Parallel testing devices come from a second device set, opened with
`SimServiceContext.deviceSetWithPath:error:` at `TestingDeviceSetPath` or
`~/Library/Developer/XCTestDevices`, never at the default set's path. Neo does
not create a missing set; it watches the parent directory until Xcode creates
it. While Debug ▸ Show Parallel Testing Devices (`ShowTestingDevices`, on by
default) is on, booted devices of both sets get windows; turning it off closes
the testing devices' windows without shutting them down, and turning it on
attaches every booted testing device again. `simctl` reaches a testing device
with `--set`; `devicectl` does not, so rotation and orientation commands are
hidden for it.

Debug ▸ Slow Animations and Graphics Quality Override use Simulator.app's guest
notifications: the session sets the state of
`com.apple.UIKit.SimulatorSlowMotionAnimationState` (0 or 1) or
`com.apple.UIKit.ForceGraphicsQuality` (0, 10, or 100 for Device Default, Low
Quality, and High Quality) with `darwinNotificationSetState:name:error:`, then
posts it with `postDarwinNotification:error:`. As in Simulator.app, the
checkmarks come from the app's `SlowMotionAnimation` and
`GraphicsQualityOverride` defaults, and connecting a device applies them again:
slow animations when the guest supports `SimFeatureUIKitSlowMotionStateful`,
and a quality other than Device Default when it supports
`SimFeatureUIKitGraphicsQualityOverride`. Without the first feature, the
command is Simulator.app's "Toggle Slow Animations in Frontmost App", which
still alternates the state but has no checkmark. Without the second, Graphics
Quality Override is hidden, where Simulator.app disables it. Neo saves a
setting only after the guest accepts its state and reports a failed post as a
partial change; Simulator.app saves first and discards both errors. On Apple
TV, a quality change also stops PineBoard with `simctl spawn <UDID> launchctl
stop com.apple.PineBoard`, which launchd restarts. Because that is a device-tool
operation, an Apple TV's quality choices are disabled while another one runs,
where Simulator.app keeps them enabled. On other devices the change is
immediate and stays available during tool operations, as in Simulator.app.

The color options call `SimDevice setCADebugOption:enabled:` with options 2
(Color Blended Layers), 1 (Color Copied Images), 14 (Color Misaligned Images),
and 17 (Color Off-screen Rendered). Their checkmarks come from
`getCADebugOption:` instead of Simulator.app's per-device `DeviceCoordinator`
flags, which start off at each connection and only record what it last
requested. Both selectors
drop CoreSimulator's errors, so the session reads an option back after changing
it and reports a mismatch; an option whose read fails shows as off.

Open System Log… opens `<SimDevice.logPath>/system.log` in Console
(`com.apple.Console`) with `NSWorkspace.open(_:withApplicationAt:configuration:)`
and reports a missing file or a failed launch, where Simulator.app only logs
the failure. Simulate Memory Warning writes the empty trigger file at
`SimDevice.memoryWarningFilePath` (`<dataPath>/var/run/memory_warning_simulation`)
in place, as `SimDevice.simulateMemoryWarning` does, but reports a failed
write, which that method discards. A successful write does not confirm that an
app handled the warning.

File ▸ GPU Selection edits CoreSimulator's `FramebufferServerGPUPolicy` string
array in the `com.apple.CoreSimulator` defaults, which its render server reads.
Unset, the order is `automatic, external, discrete, lowPower, headless`, and a
single string is an order of one. As in Simulator.app, each choice rewrites the
whole order: Automatic gives `automatic`, Prefer Integrated GPU gives
`lowPower, discrete`, and Prefer Discrete GPU gives `discrete, lowPower`, with
`external` first while Use External GPU When Available is on and last
otherwise. Toggling the external GPU keeps the current preference, and other
kinds such as `headless` are dropped. The checkmarks follow the first entry
after a leading `external`. The setting is global, so the menu does not need a
device window; whether a running device changes GPU at once is not established.

Hardware inputs send Indigo HID messages to the connected screen's
`buttonTarget` through `SimDeviceLegacyHIDClient`: button messages for Home,
Lock, Software Keyboard, Side Button, Action Button, Siri, and Authorize Apple
Pay, and consumer-page usages for Trigger Screenshot and volume. Each command
follows Simulator.app's timing: the staccato Action Button is released after
0.5 seconds, and App Switcher presses Home twice 150 ms apart. The session
reports the first failed event of a command, including a delivery failure
SimulatorKit reports later. Closing the window cancels pending steps and
releases a held button first. Commands are shown only for the device family or
`SimDevice` feature Simulator.app requires. Shake uses a
fail-loud CoreSimulator Darwin-notification call. Appearance uses the current
and target UI style selectors.

Rotation uses direct Apple `devicectl`. On initial attachment and after each
relative rotation or Device ▸ Orientation choice, the session reads the
versioned JSON orientation result and sets `SimDisplayView.deviceRotation` from
that actual value; no local counter is the orientation source of truth. The
physical orientation drives the Orientation checkmark, and the last upright
orientation drives the display angle, so Face Up and Face Down keep it. A device
turned counterclockwise (landscape left) is shown at +90°, matching
SimulatorKit's touch mapping and Simulator.app.

Rotate Device Automatically stores Simulator.app's
`RotateWindowWhenSignaledByGuest` key in the app's standard defaults.
SimulatorKit's display view reads that key and sets `deviceRotation` itself
when the guest changes its interface orientation. Each connection registers for
`SimDeviceScreen` property events (`register(types:queue:handler:)` with
`.properties`). When the preference is on and the guest's interface orientation
(`SimScreenProperties.uiOrientation`) changes, the session shows the display at
that orientation's angle and the window takes its new shape at the display's
scale (see window scale below). Other property changes, such as
the backlight, keep the window size. A window opened while the preference is on
also starts at the guest's interface orientation. Releasing the registration on
disconnect ends the events. The Orientation checkmark keeps showing the physical
orientation that `devicectl` reports, which a guest-initiated rotation does not
change. Screenshots and recordings use direct Apple `simctl io` with a
`--mask` policy: `alpha` for screenshots and `black` for recordings when the
device mask applies, and `ignored` otherwise. Save Screen and Record Screen
follow Simulator.app's names (`Simulator Screenshot - <device> - <date>.png`,
`Simulator Screen Recording - <device> - <date>.mov`) and capture to a
temporary file first. A `CapturedContent` holds the temporary file and its
default folder while a `CaptureThumbnail` shows it beside the device window;
dismissing the thumbnail saves it with `CaptureFile.move`, which numbers a
taken name and keeps the capture when the move fails. Like Simulator.app, one
app-wide list holds the thumbnails, so a new capture ends and saves the
previous one. Unlike Simulator.app, closing the device window or quitting
saves a pending capture at once instead of leaving it in the temporary folder,
including a recording whose animated GIF is still being written; captures that
cannot be saved while quitting are listed in an alert with their locations.
A quick recording is named when it stops, as in Simulator.app.
A destination chosen in a save panel is written through a same-directory
temporary file that is checked and then atomically renamed, so cancellation
or failure preserves an existing destination.
Device-tool operations are single-flight, drain both output pipes, have a
bounded timeout, and are cancelled when their window closes.

Window ▸ Physical Size (Command-1), Point Accurate (Command-2), Pixel Accurate
(Command-3), and Fit Screen (Command-4) follow Simulator.app's
`windowScaleChanged:`. Each sets `SimDisplayView.renderScale` and sizes the
window to `SimDisplayView.size(for:)` at that scale below the window's top
edge; the device's screen does not change.

- Physical Size divides the Mac screen's points per inch (`NSDeviceSize` width
  over the `CGDisplayScreenSize` width in inches of the window's screen) by the
  device's (`SimDeviceType.mainScreenDPI` width over `mainScreenScale`). An
  unknown value counts as 110 for the Mac and 163 for the device.
- Point Accurate is 1.
- Pixel Accurate is `SimDeviceScreen.scale` over the window screen's
  `backingScaleFactor`, each 1 when unknown.
- Fit Screen asks `SimDisplayView.scale(for:)` for the visible frame less the
  window's title bar at its current toolbar style, the gap above the display,
  and 20 points, so it can exceed 1.

Fit Screen then centers the window on its screen, and the fixed scales move it
back inside the visible frame. The commands need a connected display outside
full screen, including the full screen transitions. Physical Size also needs
`SimDeviceScreen.displayClass` 0, the device's own screen. A fixed scale needs
at least the device's minimum (0.4 for an iPhone and 0.25 for an iPad on its
own screen, 0.6 for a watch, otherwise the scale at which the display fits 240
by 240 points). Like Simulator.app, a display without a bezel must also fit
the visible frame below the window's title bar, while a window with a bezel
may extend past the screen. The bezel is the display's
`SimDisplayChromeView.chrome`, which NeoSimulator reads through
ABIBridge with its `images.padding`. It is nil while Show Device Bezels is
off, because SimulatorKit then clears the chrome view's device type, and for
a device type whose chrome SimulatorKit cannot load. A fixed scale is checked while `renderScale` is within 0.001 of it, also
when it is below the minimum or does not fit. The menu computes the target from
the window's current screen each time it validates, so a manual resize, or a
move to a screen with another resolution or size, clears the checkmark without
changing the scale. A checkmark stays as it was without a connected display,
in full screen and its transitions, for Physical Size on another screen than
the device's own, and without a device window, where Simulator.app's
validation returns before setting it or does not run. Fit Screen has no
checkmark.

Show Device Bezels is Simulator.app's app-wide `ShowChrome` preference,
registered on, which NeoSimulator keeps in its own defaults. Like
Simulator.app's `boolForKey:`, NeoSimulator reads it with
`UserDefaults.bool(forKey:)`, so a string that `defaults write` saves, such as
`NO`, turns the bezels off. As in Simulator.app, changing it applies to every
open device window, including one whose device is restarting, and a window
shows the bezel as the preference says when it opens, before it takes its
first scale, and when it reconnects after a restart. The menu's checkmark
shows the preference, also without a device window.

The device window is a `DeviceWindow`, which follows its bezel as Simulator.app's
window does:

- While the display shows a bezel, the window is not resizable, so AppKit
  keeps the window's top edge on the screen without shrinking a window taller
  than the screen; the bezel's corners resize it instead, as described below.
  Without a bezel, the window is resizable. Full screen stays
  available through the `fullScreenPrimary` collection behavior. AppKit's full
  screen transition fills the screen only with a resizable window, so the
  window is resizable from `windowWillEnterFullScreen(_:)` until it leaves
  full screen, also when the bezel changes there. Like Simulator.app, leaving
  full screen restores the display's scale and the window's origin from
  before it entered, which AppKit's own return does not keep for a window
  taller than the screen.
- When the bezel's images have top padding (`SimDeviceChrome.images.padding.height`
  in the bezel's `chrome.json`: 9 points for the iPad bezels, 0 for the bezels
  of most iPhones, including the iPhone 17 Pro), `constrainFrameRect(_:to:)` keeps the frame's size and
  only moves it down, so that the window's top less the padding at the
  display's scale stays below the top of the visible frame. Otherwise AppKit
  constrains the frame. This applies to programmatic frame changes and to
  moving the window.
- The window's header is its title bar, which holds the toolbar. Like
  Simulator.app's geometry update, each size change gives the toolbar a
  style for the display's width: the compact unified style when
  `UseCompactTitleBar` is on; otherwise the unified style while `UseMonobar`
  is on and the display is at least as wide as the toolbar needs, and the
  expanded style below that. The toolbar needs the width of each of its
  buttons in Simulator.app's toolbar nib plus 4 points (Home 31, Save Screen
  32, and Rotate 25 points), the wider of the window's title in the
  headline font and its subtitle in the subheadline font, and 130 points:
  317.3 points for the iPhone 17 Pro and 351.4 for the iPad mini (A17 Pro),
  and 29 points less outside the default device set, where the toolbar has
  no Rotate button. The title bar is 52 points high with the unified style, 76 with the
  expanded one, and 40 with the compact one, and the window's height follows
  it. As in Simulator.app's toolbar nibs, the buttons sit between two
  flexible spaces, and the last one is hidden unless the style is expanded,
  so that the buttons follow the title in a unified title bar and are
  centered in their own row in an expanded one. Like Simulator.app's, the
  toolbar's minimum inline title width is 0, so a unified title bar
  truncates the title before it moves buttons into the overflow menu, and
  all the buttons stay in the title bar from the threshold up. Both
  preferences are
  registered as in Simulator.app, `UseMonobar` on and `UseCompactTitleBar`
  off, in NeoSimulator's own defaults, and each size change reads them
  again.
- As in Simulator.app, a recording adds no item to the toolbar. While it
  runs, the Save Screen button shows `stop.circle`, untinted, with the
  tooltip and image description Stop Recording, and a click stops the
  recording; the item keeps its Save Screen label. The button is Save Screen
  again as soon as the recording stops, before the movie is finished, and
  when the recording ends on its own or fails. The toolbar keeps its items,
  so the threshold does not change. AppKit sizes the button to its image, as
  it does Simulator.app's, so the button is narrower while it shows
  `stop.circle`.
- As in Simulator.app, the Save Screen and Rotate buttons show their Option
  alternates while the pointer is over the toolbar and Option is down; Home
  has none. Save Screen becomes Record Screen: it shows `record.circle`,
  described Start Recording, with the tooltip Record Screen, and a click
  starts a recording as File ▸ Record Screen does. Rotate turns the device
  left instead: it shows `rotate.left` with the symbol's own description
  (Rotate Left in English), while its tooltip stays Rotate. The items keep
  their labels, Save Screen and Rotate, which are also their tooltips
  otherwise. A recording's Stop Recording takes precedence: Save Screen
  stays Stop Recording whatever Option does, and follows Option again as
  soon as the recording stops, while Rotate follows Option throughout.
- Like Simulator.app's `SimToolbar`, the toolbar tracks the pointer with an
  `NSTrackingArea` on the toolbar's own view (`NSToolbar._toolbarView`,
  below), with the same options: entered and exited, active in the active
  app, in the visible rectangle. The area spans the title bar with the
  unified styles and the row below the title with the expanded one, and
  works in every window of the app while the app is active. When the pointer
  enters, the buttons read the modifier keys held, and until it leaves, they
  read them again at each modifier event the app dispatches, as
  Simulator.app's `sendEvent:` reports Option for each one. AppKit makes no
  change at activation itself: once the app has resigned active, the next
  pointer movement over the window, or the pointer leaving it, reports the
  pointer leaving the toolbar, and the buttons take their own faces; Option
  changes made in another app do not reach this one. Once the app is active
  again, the pointer entering reads the keys held. A window resigning key
  changes nothing.
- A resize the window does not make itself, such as a manual one, also gives
  the toolbar the style for the new width outside full screen and keeps the
  window's height below the title bar, as Simulator.app's
  `windowDidResize:` does.
- Below the title bar, the window keeps Simulator.app's gap above the
  display: with a bezel, 10 points less the top padding of the bezel's
  images, so 10 points for the iPhone 17 Pro's bezel and 1 point for the
  iPad bezels, whose images have 9 points of top padding; without a bezel,
  none, as Simulator.app's chrome refresh turns the gap off. The gap does
  not change with the display's scale. While the window has the display's
  size, the display fills the window below the gap, as Simulator.app's
  constraints pin its display view; SimulatorKit keeps the device at the
  view's lower-left corner when the view is a fraction of a point larger. In
  full screen and after a manual resize, the display keeps its own size,
  centered below the gap.
- As in Simulator.app's window, AppKit draws the title bar, which is not
  transparent. Around a bezel, the window is clear, and the title bar's
  lower corners are rounded with the window's corner radius, which follows
  the toolbar's style (26 points unified, 16 expanded, and 20 compact on
  macOS 26), so that the header floats above the bezel. Without a bezel, the
  window is black, which shows wherever the display leaves it uncovered,
  and the title bar is square below; so it is in full screen, which keeps
  the window's color until it leaves full screen.
- Each size change takes the display's size plus the header and the gap,
  keeps the window's bottom-left corner, unless a drag on the bezel's corners
  (below) moves it, takes the smallest integral frame around that
  (`NSIntegralRect`), and moves the window down when its top would be above
  the visible frame, as Simulator.app's geometry update does. AppKit on
  macOS 26 also rounds window frames to whole points, the same way for every
  frame these paths set. A scale command then puts the top edge back where it
  was, and a rotation keeps the top edge, moving the window down only when that
  edge would be above the visible frame. After a rotation, as after a fixed
  scale, the window moves back inside the visible frame along each axis where
  it crosses an edge.
- A change to the screens (`NSApplication.didChangeScreenParametersNotification`),
  such as a display removed or the Dock resized, moves the window back inside
  its screen's visible frame the same way, as Simulator.app's
  `screenParametersChanged` does for every device window. No scale is
  reapplied.

The title bar and its toolbar use three private AppKit members, as
Simulator.app does, because no public API gives the same result on macOS 26:

- `NSToolbar.minimumInlineWindowTitleWidth`, which NeoSimulator sets to 0
  through key-value coding. With AppKit's default, a unified title bar
  keeps the whole title and moves buttons into the overflow menu: an
  iPhone's window 320 points wide shows none of its three buttons, and one
  402 points wide only Home. `NSToolbarItem.visibilityPriority` does not
  change that.
- `NSWindow._cornerRadius`, which NeoSimulator calls, as a method that
  returns a `CGFloat`, each time it rounds the title bar's corners. No public
  API reports a window's corner radius before macOS 27's
  `NSView.cornerConfiguration`.
- `NSToolbar._toolbarView`, which NeoSimulator reads through key-value
  coding once, when the window takes the toolbar, for the view whose
  tracking area shows the buttons' Option alternates. AppKit creates no
  public view for an image item, and the toolbar's view is the region
  Simulator.app tracks.

NeoSimulator uses each only when the toolbar or the window responds to its
selector. Without the first, the title bar keeps AppKit's minimum title
width, so near the threshold buttons move into the overflow menu; without
the second, the corners take the radius macOS 26 gives each toolbar style;
without the third, the buttons never show their Option alternates. All
three were checked on macOS 26.6.2 (25G83) and appear in AppKit's class
dumps of macOS 26.2 through 26.6.2.

Like Simulator.app's `DeviceWindow`, a window with a bezel resizes by
dragging the bezel's corners:

- The corners are `SimDisplayView.typedResizeRects`, which SimulatorKit builds
  from the `resizeRects` of the bezel's `chrome.json` in the display view's
  coordinates at its scale; there are none without a bezel. SimulatorKit's
  `SimChromeResizeRectsExcludeView` takes the clicks there, so they reach the
  window through the responder chain, and `SimDisplayView.showResizeCursors`
  shows diagonal resize cursors over them. NeoSimulator reads the corners
  through ABIBridge and turns the cursors on outside full screen, as
  Simulator.app does.
- A press in a corner, outside full screen, starts a drag between
  `beginResize()` and `endResize()`. The drag asks for the display's size at
  the press, grown by how far the pointer has moved away from the opposite
  corner. The display takes the largest scale at which it fits that size
  (`scale(for:)`), no smaller than the minimum of the fixed scales and no
  larger than the scale at which the dragged corner reaches the edges of the
  screen's visible frame (1000 without a screen).
- The window then takes the display's size with the display's opposite corner
  where it was, through the same geometry update as the scale commands, so it
  moves down when its top would be above the visible frame. Like a manual
  resize, the drag clears the checkmark of a fixed scale it leaves.
- When the drag ends, a window that does not reach 128 points into the
  visible frame moves along each axis until it does.

Like Simulator.app's `DeviceWindow`, a window with a bezel moves with a drag
elsewhere on the bezel:

- SimulatorKit's views decide which presses reach the window, the same way in
  both apps. The digitizer covers the device's screen and the bezel around
  it; on an iPhone 17 Pro it covers all of the bezel's image. It keeps the
  presses on the screen. It passes a press on the bezel to the window through
  the responder chain once the pointer moves more than 5 points away from the
  screen (`ignoreInsetDragAwayFromFramebuffer` and
  `ignoreInsetDragMinimumDistance`, which neither app changes); a press that
  stays where it is, or moves toward the screen or along its edge, stays with
  the digitizer. The bezel's buttons (`SimChromeButton`) track their own
  presses where they stand out of the bezel, and the corners reach the window
  as described above. A press on the display outside the digitizer reaches the
  window at once.
- Before any view, the window server chooses the window: it gives a press on
  a pixel the window leaves fully transparent to the window behind. The gap
  below the header draws nothing, so a press there goes to the window behind,
  as it does in Simulator.app's window, while the whole display view takes
  presses, also outside the bezel's rounded outline. Simulator.app also turns
  on the content view layer's private `hitTestsContentsAlphaChannel`; AppKit's
  backing layers have it on already, and turning it off or on changed none of
  these results, so NeoSimulator does not set it.
- Outside full screen, every press that reaches the window away from the
  corners calls AppKit's `performDrag(with:)` (Simulator.app's
  `performWindowDrag(with:)`), which hands the rest of the drag to the window
  server. As in Simulator.app, where no view takes a press outside the
  display, this includes a press outside the display, such as in the gap,
  that AppKit gives the window.
- Simulator.app's app-wide `AllowsMoveByDragOnWindowChrome` turns this off.
  NeoSimulator registers it on in its own defaults, as Simulator.app does, and
  reads it with `UserDefaults.bool(forKey:)` at each press, as Simulator.app
  reads it with `boolForKey:`. A value that `defaults write` saves applies to
  the next press. Neither app shows the preference in its settings.

A rotation, Show Device Bezels, and a restart keep the display's scale and
resize the window, even when the window no longer fits the screen, as in
Simulator.app. Without a bezel, AppKit then shrinks a window taller than the
screen while the display keeps its scale. After a restart, the device's next
connection shows a new, upright display; like Simulator.app, which turns its
display upright then, the window takes that display's shape as after a
rotation, below its top edge, and moves back inside the visible frame.

Like Simulator.app, a window's geometry is saved for each arrangement of the
Mac's screens, under Simulator.app's keys in NeoSimulator's own defaults.
`ScreenConfigurations` names each arrangement with a UUID and lists the
screens' frames (`NSStringFromRect`). The arrangement of `NSScreen.screens` is
the entry with as many frames, each of the screens' frames among them in any
order; without one, a new UUID is saved with the frames, also when a window is
only reading its geometry. Closing a window saves its center
(`NSStringFromPoint`) and scale as `WindowCenter` and `WindowScale` in
`DevicePreferences[UDID].SimulatorWindowGeometry[UUID]`, replacing what was
saved for that arrangement and keeping the others. Like Simulator.app, which
saves nothing while its device is rebooting, a window that closes from the
start of a restart until the device reconnects saves nothing. Neither does a
new window that `HostApplication` discards before it shows, when another
simulator host appears first.

A new window reads the geometry saved for the current arrangement once, when
it connects. It opens at the saved scale, or at Point Accurate, reduced to Fit
Screen's scale on the screen it is placed on, and is centered at the saved
center. A window saved in another
arrangement, such as before a display was connected, removed, or moved, opens
as one that was never saved. Without a saved center, or at the zero point,
which is also what an unreadable value gives, it cascades as in Simulator.app:
the first such window is centered on its screen with `center()`, and each takes
`cascadeTopLeft(from:)` from the app-wide point the previous one returned. A
new window then moves back inside the visible frame where it crosses an edge.

Simulator.app turns the display to the device's orientation before it chooses
a new window's scale and places it. NeoSimulator reads the orientation with
`devicectl` after the window shows, so when that first reading arrives, a
window that is still where it was placed and as large takes the scale it opens
at in the new shape (the saved scale or Point Accurate, reduced to Fit
Screen's) and is placed again: centered at the saved center, or with
`center()` for the first cascading window, then moved back inside the visible
frame. A window that cascades from another keeps its top-left corner. A window
moved or resized before the reading keeps its scale and its top-left corner,
as after any rotation; a rotation that follows the guest with Rotate Device
Automatically does not count as such a change.

These differ from Simulator.app:

- Physical Size also uses the default densities for a zero or non-finite value,
  where Simulator.app divides by zero.
- A `ScreenConfigurations` entry whose name is not a UUID matches no
  arrangement, where Simulator.app stops.
- Simulator.app also starts a drag on a corner of the bezel in full screen,
  which then sets the full screen window's frame, and passes a press elsewhere
  on the bezel to `performWindowDrag(with:)`, which leaves it to the window
  server. NeoSimulator starts neither in full screen, where the display fits
  the window.
- A manual resize, possible without a bezel, does not keep the display's
  aspect ratio and stops at 320 by 300 points instead of the display's size at
  the minimum scale; the display is centered in the window. The scale
  commands, rotation, and Show Device Bezels make the window as wide as the
  display, as in Simulator.app, also when that is narrower.
- Simulator.app's minimum for a tvOS or visionOS display with a bezel, 240
  points over the screen's pixel height, is not reproduced.
- Simulator.app measures Fit Screen, and a new window's scale, with the
  title bar the window has before the scale is applied. When that scale makes
  the window narrow enough to take the taller expanded title bar, the window
  ends up taller than the screen there. NeoSimulator measures again with the
  expanded title bar and takes the smaller scale, so the window fits.
- Without a bezel, Simulator.app checks whether a fixed scale fits the screen
  with the title bar the window has. NeoSimulator checks it with the title
  bar the window would take at that scale, the height it last laid out for
  that style (macOS 26's 52, 76, or 40 points until then), so a scale that
  changes the style is neither enabled when it would not fit nor disabled
  when it would.
- The toolbar style's threshold counts the buttons NeoSimulator's toolbar
  has. Simulator.app's iPad toolbar also has Keyboard Capture and Pointer
  Capture, 27 points each, which NeoSimulator does not host (see
  [Input capture](#input-capture)), so an iPad's window keeps the unified
  style down to a display 62 points narrower than in Simulator.app: 351.4
  points instead of 413.4 for the iPad mini (A17 Pro).
- Simulator.app's Save Screen button already shows `stop.circle` while
  Record Screen… asks where to save, and, when the recorder cannot start,
  until the error is dismissed. NeoSimulator's shows it only while a
  recording runs.
- After a recording stops, after Record Screen… is cancelled, and after the
  error of a recorder that cannot start is dismissed, Simulator.app's Save
  Screen button follows Option wherever the pointer is, until the pointer
  next leaves the toolbar, because those paths start the following without
  checking the pointer. NeoSimulator's follows Option only while the pointer
  is over the toolbar.
- Simulator.app's buttons take Option from each modifier event.
  NeoSimulator's read the keys held at each modifier event, so the modifier
  release that a window sends its device through the app when it resigns key
  (see [Modifier gestures](#modifier-gestures)) does not turn the alternates
  off while Option is held, for example when an Option click on another
  window's toolbar makes the key window resign. Simulator.app sends no such
  event.
- Simulator.app gives Save Screen's Option state the toggle button type,
  which its click turns on before the recording starts. NeoSimulator's
  toolbar items have no button type.
- Simulator.app animates the window into and out of full screen itself.
  NeoSimulator uses AppKit's transition, so the window is resizable in full
  screen.
- Because the first window that cascades is placed before the orientation is
  read, the point the next window cascades from follows that window's shape
  before the reading.

Features ▸ Location follows Simulator.app's split between a per-device
selection and app-wide saved settings. Each `DeviceSession` owns its device's
selection (None, Custom, or a scenario by name) and the scenario list that
`SimDevice availableLocationScenarios` returned when it connected. On every
new connection and every reconnection after a restart, `HostApplication` starts
the session's restore without waiting for it. When the list is empty or nil,
nothing happens.
Otherwise `LocationMode` 5101 restores None, 5102 Custom, and a value above
5102 the `LocationScenario` name, which falls back to None (saved as 5101)
when the runtime lacks it. The restored choice is applied at once, so the
registered default (5102 at 37.785834, -122.406417) reaches every device with
scenarios. Right after a boot, CoreSimulator takes up to a second to list the
scenarios and to apply a location, so `SimulatorDevice` makes the location
calls on a serial queue of its own, as Simulator.app makes them on a global
queue. The main actor stays responsive, and changes reach the device in the
order they are made. A choice made while the restore waits for the list is
kept, and a session that ends meanwhile is left alone.

Choosing an item saves the choice and applies it to the key device only, with
`clearSimulatedLocationWithError:`,
`setLocationWithLatitude:andLongitude:error:`, or `setLocationScenario:error:`.
The checkmark shows the host's selection, because CoreSimulator offers no
readback. Like Simulator.app, the choice stays when applying fails; Neo
reports the failure of a chosen item on the device window and logs a failed
restore. The Location menu is rebuilt from the key device's own scenario list
when it opens. This deliberately differs from Simulator.app, which keeps one
list built by the last connected device, whose names may not exist on the key
device's runtime.

Custom Location… opens a titled window for the device window, with
Simulator.app's text and number formatters (up to six fraction digits, within
±90 and ±180). OK is enabled only while both fields parse; it saves the
coordinate and selects Custom. The window takes its device window's level, also
when Stay on Top changes, and closes with its device window and before a
restart. Simulator.app's `com.apple.iphonesimulator.simulateLocation`
distributed notification, through which another process sets a scenario file
or a coordinate, is not handled.

The following are intentionally absent:

- Services;
- global keyboard, pointer, or game-controller capture (for the keyboard and
  pointer, see [Input capture](#input-capture));
- Device Manager, CarPlay, and FaceTime menus;
- platform-specific watchOS, tvOS, and visionOS commands, such as Debug ▸ Show
  Gaze Target;
- commands whose remaining private implementation silently discards failure.

See [Simulator.app analysis](SimulatorAppAnalysis.md) for the complete menu
inventory and classification.

### Get and Send Pasteboard

Edit ▸ Get Pasteboard replaces the Mac's general pasteboard with the active
device's, and Edit ▸ Send Pasteboard replaces the device's pasteboard with the
Mac's. Each command copies the whole pasteboard once, with all its types, such
as text and images. Unless Automatically Sync Pasteboard is on, nothing crosses
between the Mac and the device at any other time.

Both commands use Simulator.app's mechanism, `SimPasteboardInterface` from
`SimPasteboardPlus`, a framework that CoreSimulator loads. Get Pasteboard sends
the interface `pull`, and Send Pasteboard sends it `push`. The interface
connects to the port that `SimDevice lookup:error:` returns for `SimPasteboardInterfaceListener.machServiceName`,
`com.apple.CoreSimulator.SimPasteboardInterface`, which the guest's
CoreSimulatorBridge serves. `SimulatorRuntime` resolves the initializer, both
messages, the service name, and `lookup:error:` at startup. `simctl pbsync`
uses the same interface but exits after the transfer. A pull needs the
connection longer: the Mac pasteboard asks the device for each type only when
an app pastes it, which fails once the connection is closed.

Each `DeviceSession` therefore connects to its device's pasteboard on the first
Get or Send, managing the general pasteboard, and keeps the connection until
the device closes it or the session disconnects. Connecting transfers nothing.
Like Simulator.app, the session then tells the connection whether to
synchronize, with `enableRemoteAutosync` or `disableRemoteAutosync`; see
[Automatically Sync Pasteboard](#automatically-sync-pasteboard). The
interface's messages return nothing, so its delegate callbacks, on the main
queue, complete the commands:
`simPasteboardDidApplySnapshot:…` completes a pull, and each
`simPasteboardDidBecomeActive:` after the connection's first one completes a
push, as `simctl pbsync` waits for it. A failed connection,
`simPasteboardErrorApplyingSnapshot:…`, and a connection the device closes
while a transfer is pending are reported on the device window. A connection
closed with nothing pending is logged, and the next command connects again.

Like Simulator.app, both commands are shown for every device and enabled for a
booted iPhone, iPad, or Apple Vision whose device has `SimFeaturePasteboard`,
while Automatically Sync Pasteboard is off.

These differ from Simulator.app:

- Simulator.app connects when a device connects and again as soon as the
  connection closes, and it enables the commands only while connected. While
  Automatically Sync Pasteboard is off, Neo connects on the first command and,
  after the device closes the connection, on the next one, so it reports why a
  device's pasteboard cannot connect.
- Simulator.app's Send Pasteboard does nothing while the Mac pasteboard still
  holds the snapshot last received from the device, which keeps automatic
  synchronization from echoing a change back. Without automatic
  synchronization, the device's pasteboard can change after Get Pasteboard
  without the Mac learning of it, so Neo sends on every request.
- Simulator.app only logs failures.

A transfer that the device accepts but never completes is not reported, and
SimPasteboardPlus drops a type too large to send, such as one of 300 MB,
without a callback. `simctl pbsync` gives up after one second, which a push of
260 MB can exceed.

### Automatically Sync Pasteboard

Edit ▸ Automatically Sync Pasteboard turns on Simulator.app's automatic
pasteboard synchronization for every device that has a window. Neo saves the
choice as `PasteboardAutomaticSync` and registers it off; Simulator.app
registers it on. Like Simulator.app's, the item is enabled without a device
window and checked while synchronization is on, and Get and Send Pasteboard
are disabled meanwhile.

`PasteboardSync` keeps the choice and owns the exchange between devices, as
Simulator.app's app delegate does; it reads the sessions from the host's
windows. Each `DeviceSession` owns its connection, as described in
[Get and Send Pasteboard](#get-and-send-pasteboard). Synchronization works as
in Simulator.app:

- Turning it on sends `enableRemoteAutosync` to every device's connection,
  connecting a device that has none; turning it off sends
  `disableRemoteAutosync` to every connection and keeps the connections.
  Neither transfers anything.
- While a connection synchronizes, SimPasteboardPlus sends each change of the
  Mac pasteboard to the device, about half a second later, and applies a copy
  made on the device to the Mac pasteboard. It ignores the change that it
  makes itself, so the copy is not sent back to the device that made it.
- For the same reason, the copy does not reach the other devices. Like
  Simulator.app's `SimDeviceChangedLocalPasteboard` observer, `PasteboardSync`
  sends the Mac pasteboard to every other device when the run loop ends its
  pass. Of several copies applied in one pass, only the last one's device is
  left out, and each other device is sent the Mac pasteboard once. A device is
  not sent a Mac pasteboard whose change count still equals the one that its
  own last copy left, Simulator.app's
  `lastSyncedPasteboardSnapshotLocalGeneration`; a copy that could not be
  applied clears it.
- A device that connects while synchronization is on, when its window opens
  or after a restart, is connected, told to synchronize, and sent the Mac
  pasteboard.
- When the device closes the connection, for example because its
  CoreSimulatorBridge restarted, the session connects again at once and tells
  the new connection to synchronize, without sending the Mac pasteboard. A
  device that is shutting down is not connected again.
- Synchronization does not depend on which window is key: every device that
  has a window takes part. Closing a window releases its connection, which
  stops the device's synchronization.
- Choosing a connected device in File ▸ Open Simulator tells its connection
  the current choice again.

Failures to connect or send are logged, as Simulator.app logs them; no command
waits for them.

These differ from Simulator.app:

- Simulator.app synchronizes by default.
- Simulator.app connects every device when the device connects, so turning
  synchronization on only tells those connections. Neo connects the devices
  then, which transfers nothing. For the same reason, choosing a connected
  device in Open Simulator connects one whose connection could not be
  reopened, which Simulator.app leaves without one until the device connects
  again.
- Simulator.app raises an assertion when a connection reports a
  synchronization state other than the app's; Neo logs it.

### Keyboard and touch pressure

I/O ▸ Keyboard and I/O ▸ Touch Pressure follow Simulator.app's menu archive and
validation. Keyboard is shown for a device with `SimFeatureKeyboard`, and Touch
Pressure for one with `SimFeatureTouchPressure`: a device type with
`SupportsForceTouch`, from the iPhone 6s to the iPhone XS, such as an iPhone XS
on iOS 18. Current iPhones, iPads, and watches have no touch pressure.

Connect Hardware Keyboard (Shift-Command-K) is each device's choice, saved as
`DevicePreferences[UDID].ConnectHardwareKeyboard` in NeoSimulator's own defaults
and on unless turned off. The command saves the opposite of the choice, then
calls `SimDevice setHardwareKeyboardEnabled:keyboardType:error:` with
`IndigoHIDGetKeyboardType()`. Like Simulator.app's keyboard controller, a
display takes the Mac's keyboard (its `_defaultKeyboardDelegate`'s `isEnabled`)
only while its window is key and its device's hardware keyboard is connected,
and Toggle Software Keyboard (Command-K) is enabled only then. Without a
hardware keyboard the guest shows its software keyboard.

Use the Same Keyboard Language as macOS (`EnableKeyboardSync`, app-wide, on
unless turned off) gives the guest's keyboard the first language of the Mac's
current input source (`TISCopyCurrentKeyboardInputSource`,
`kTISPropertyInputSourceLanguages`) with `setKeyboardLanguage:error:`. This
happens on each connection and, for the key device only, on
`NSTextInputContext.keyboardSelectionDidChangeNotification`. As in
Simulator.app, the command changes only the preference. Each connection,
including after a restart, first applies the device's hardware keyboard choice,
then the language; a failure of one does not stop the other. CoreSimulator
takes up to half a second to change the language, so `SimulatorDevice` makes
the keyboard calls on a serial queue of its own, as Simulator.app makes them on
a global queue.

Touch Pressure is app-wide, as in Simulator.app's app delegate; one
`TouchPressure` object, shared by every device window, owns it. Use Trackpad
Force saves `UseTrackpadForce` (on unless turned off) as the opposite of its
checkmark, which also needs a Force Touch trackpad: an HID event-system service
with `PrimaryUsagePage` 13 and `PrimaryUsage` 12 whose registry entry has
`ForceSupported`. NeoSimulator finds it through the public
`IOHIDEventSystemClientCreateSimpleClient` each time it is needed, so a
trackpad connected later counts. Shallow Press (Shift-Command-1) and Deep Press
(Shift-Command-2) need a watch. The mode is kept only while the app runs and
starts at Shallow Press. A change reaches the digitizer
(`SimDigitizerInputView`) of every window whose device has touch pressure:
`useForceTrackpadForPressure` and `simulatedTouchMode` (0 shallow, 1 deep). Each
display connection also sets `supportTouchPressure` to the device's support on
its own screen (display class 0).

These differ from Simulator.app:

- On each connection Simulator.app connects the hardware keyboard as the
  app-wide `ConnectHardwareKeyboard` (registered on) says, while its
  checkmark, keyboard input, and Toggle Software Keyboard follow the device's
  choice, so a keyboard disconnected there comes back after a restart.
  NeoSimulator applies the device's choice, which the app-wide value stands in
  for until the device has one.
- Simulator.app leaves a newly connected display at Shallow Press whatever the
  checkmark shows; NeoSimulator gives it the app's mode.
- Simulator.app applies Use Trackpad Force to a window only when it opens or
  the setting changes, so a window that opened before a Force Touch trackpad
  was connected ignores its force while the checkmark shows the option on.
  NeoSimulator watches the I/O Registry for HID event services and applies the
  option again to every window when a Force Touch trackpad appears or goes
  away.
- NeoSimulator presents a failed Connect Hardware Keyboard on the window, where
  Simulator.app only prints it, and logs failures of a connection's keyboard
  settings and of a language change, which Simulator.app discards. As in
  Simulator.app, the choice stays saved after a failure; choosing again retries.
  A keyboard type that does not fit a byte is reported, where Simulator.app traps.
- Connect Hardware Keyboard needs a connected, booted device, like
  NeoSimulator's other device commands; Simulator.app enables it for any
  device with a keyboard.

### Input capture

Simulator.app's I/O ▸ Input ▸ Send Pointer to Device (Control-Command-K) and
Send Keyboard Input to Device (Option-Command-K), and the Capture Pointer and
Capture Keyboard buttons of an iPad's toolbar, send the Mac's pointer and
keyboard to the device until the stop-capture keys are pressed. During the
capture, the device also receives the shortcuts and trackpad gestures that
macOS would otherwise act on, and the window's subtitle names the stop-capture
keys, such as "Press esc to stop capture". NeoSimulator has neither the
commands nor the buttons, and its settings leave out the stop-capture keys
(`CaptureEscapeKeyCodes`).

Simulator.app captures with SimulatorKit's `SimHIDCaptureManager`, which sends
the input to the device from an HID event-system filter; the filter also keeps
the input from macOS and recognizes the stop-capture keys. The HID event system
registers a filter only for an app signed with
`com.apple.private.hid.client.event-filter`, which an ad-hoc or Developer ID
signature cannot carry; for any other app it logs the missing entitlement, and
the filter receives nothing. The manager also
installs an active event tap, which needs Accessibility, and does not check
whether the tap was created: without Accessibility, starting a capture crashes
the app. With Accessibility but without the filter, the manager would swallow
the Mac's keystrokes, and for pointer capture hide and freeze the pointer,
while nothing reaches the device and the stop-capture keys go unrecognized.

Two replacements were considered and not built:

- An active event tap of NeoSimulator's own, with Accessibility granted by the
  user, could keep keyboard and mouse events from macOS and send them to the
  device. It receives no raw trackpad input, which the filter forwards for an
  iPad's trackpad gestures, and turning mouse events into the device's pointer
  events would take the private `CGEventCopyIOHIDEvent`. NeoSimulator's release
  is ad-hoc signed, and macOS records a permission for an ad-hoc signed app by
  its code hash, so the user would grant Accessibility again after every
  update. Without that permission, whether such a tap keeps shortcuts like
  Command-Tab from macOS could not be verified.
- Capturing only the input that reaches NeoSimulator, with the pointer hidden
  and detached from the mouse, needs no permission. But macOS acts on its own
  shortcuts, such as Command-Tab and Command-Space, and on trackpad gestures,
  such as Mission Control's, before any app receives them, and the capture
  would end whenever another app became active.

Without capture, a device window still sends typing to its device while the
window is key and the device's hardware keyboard is connected (see
[Keyboard and touch pressure](#keyboard-and-touch-pressure)). The evidence is
in the [Simulator.app analysis](SimulatorAppAnalysis.md#input-capture).

### Audio Input and Audio Output

I/O ▸ Audio Input and Audio Output choose the Mac audio devices that the
simulators use. Simulator.app reaches them through SimulatorKit's
`SimDeviceAudioClient`, which Xcode 27 removed. The primitive under it remains:
CoreSimDeviceIO's `SimAudioHostRoutable`, the descriptor of one of a booted
device's I/O ports, which CoreSimulator's SimAudioProcessorService serves.
`SimDevice.io` returns the device's `SimDeviceIOClient`, and the port whose
`descriptor` conforms to `SimAudioHostRoutable` among its `ioPorts` routes
audio. CoreDevice's simulator plugin uses the same port for `devicectl device
settings audio` and `devicectl device info audio`. Neo sends it messages
directly instead of running `devicectl`, because the port:

- reaches devices of any device set, including parallel testing devices, which
  `devicectl` cannot address;
- lists the Mac's devices with the identifiers that its routes take, which
  `devicectl list audioDevices` also reads from CoreAudio;
- reports changes of the Mac's devices and of the guest's routes, which the
  command line cannot.

The port gives `availableHostDevices`, each a `SimAudioHostDevice` with
`uniqueIdentifier` (CoreAudio's device UID), `displayName`, `inputChannels`,
`outputChannels`, and `isDefaultInScopes`; the guest's routes,
`guestInputHostDeviceUID` and `guestOutputHostDeviceUID`; and the Mac's default
devices, `effectiveDefaultInputDeviceUID` and
`effectiveDefaultOutputDeviceUID`. A route is a device UID or
`SimAudioHostUseSystemDefaultDeviceUID` (`__sim__hostUseSystemDefaultDeviceUID`),
which follows the Mac's default device.
`routeGuestDeviceScope:toHostDeviceUID:completionQueue:completionHandler:`
changes the input (scope 1) or the output (scope 2).
`registerCallbackWithUUID:availableDevicesChangedCallback:` and
`registerCallbackWithUUID:selectedDeviceUIDChangedCallback:` report changes
until `unregisterCallbackWithUUID:`. The service listens to CoreAudio's device
list and default input and output devices, and reports each of their changes
through `availableDevicesChangedCallback`, so Neo needs no CoreAudio listener
of its own.

The port and the Mac's devices are remote proxies, so `SimulatorRuntime`
checks at startup that their protocols declare these messages and that
`SimAudioHostUseSystemDefaultDeviceUID` has the value that recent routes are
saved with; the messages are bound to each proxy when a device connects. The
proxies call the change blocks, and a route's completion despite its completion
queue, on threads of their own; the connection passes each call to the main
queue.

Like Simulator.app:

- Audio Input and Audio Output stay in the I/O menu. For a key device with
  `SimFeatureRoutableAudio` (`com.apple.CoreSimulator.audio.routable`) they
  have their submenus; otherwise they are disabled and have none.
- Each submenu lists System first, titled `System (<name>)` with the Mac's
  default device when the port lists it, then the devices with channels in
  that direction, in the port's order, without separators. System is checked
  while the guest follows the Mac's default; otherwise the device of the
  guest's route is checked, or, for a route the Mac lacks, the Mac's default
  device, as SimulatorKit selects it.
- A choice puts the route first in the app-wide recent routes,
  `RecentAudioInputDeviceUIDs` or `RecentAudioOutputDeviceUIDs`, which keep
  each route once and five at most, and which are System alone while missing,
  empty, or not strings. Every device window then synchronizes that direction.
- Synchronizing goes through the recent routes in order. The first route that
  the guest already uses ends it; the first that the Mac has is routed to.
  System counts as present while a device is the Mac's default for that
  direction. When none is available, the route stays.
- Each connection, including after a restart, and each change the port
  reports synchronizes both directions. A route that another tool changes is
  therefore routed back, and a device that returns is used again.

`DeviceSession` owns the device's port connection and its last reported state,
which the menus show; `DeviceWindowController` synchronizes its session when
`AudioRouting.didChangeNotification` reports a choice.

These differ from Simulator.app:

- Simulator.app attaches the submenus when a device window becomes key and
  keeps them while another kind of window is key. Neo attaches them for the key
  device window each time the I/O menu opens, and disables them without one.
- Simulator.app keeps the System item's last title when the Mac's default
  device is not listed; Neo shows `System`.
- Simulator.app only logs failures. Neo logs the failures of routes it makes
  on its own, on connection and after a change, and presents on each device
  window the failure of a route that a choice asks for, including why a
  device's port did not connect.

CoreSimulator does not fail a route to a device that the Mac lacks or that has
no channels in that direction: it routes the guest to the Mac's default device
by that device's UID. Neo, like Simulator.app, routes only to devices that the
port lists.

### External displays

I/O ▸ External Displays connects a device's external display and shows it in
a window of its own, and CarPlay makes that display a car's CarPlay display
(see [CarPlay](#carplay)). A device that supports external displays has a
TVOut screen from its creation: `SimScreenType` 1 among the screens of its
CoreSimDeviceIO screen adapter (0 is the device's own screen and 2 is CarPlay),
turned off at 720×480. On the iOS 26.5 iPhone 17 Pro and iPad Pro 11-inch (M5)
it is screen 2; the iPhone also has a wireless screen of the CarPlay type, 3,
which Simulator.app does not use. `simctl io <UDID> enumerate` lists these
screens on a device that is shut down.

The adapter declares
`createScreenWithProperties:currentMode:pixelSize:carPlayProperties:completionQueue:completionHandler:`,
but its `creatableScreenProperties` is empty on these devices, neither
Simulator.app nor SimulatorKit calls it, and it refused the properties and
current mode of each existing screen (an `NSError` of domain `Swift.String`,
code 1). A device without the TVOut screen therefore cannot get one; its
choices report that the device has no external display port.

Neo reaches the screen as Simulator.app does:

- SimulatorKit's `SimDevice.screenAdapter` lists the device's screens by ID in
  `SimDeviceScreenAdapter.screens`. The external display is the first, by ID,
  whose `SimScreen` is connected and whose properties' `screenType` is TVOut,
  as Simulator.app waits for the first TVOut screen to connect. The adapter
  fills `screens` from an enumeration that ends asynchronously, possibly after
  the device's own screen connects. A device's screens exist from its
  creation, so the TVOut screen is in that enumeration or the device has none:
  the session looks for it every 250 ms for as long as the host waits for the
  device's own screen (10 seconds), then applies the saved choice, or a choice
  made meanwhile. A later choice looks again; until the display is found, the
  items check nothing.
- `SimDeviceScreen.screen`'s `setCurrentMode:pixelSize:carPlayProperties:completionQueue:completionHandler:`
  sets a size and turns the screen on; `setPowerState:completionQueue:completionHandler:`
  with 0 turns it off. The mode is Simulator.app's choice: the current mode
  when the screen already has the size and that mode has the scale, otherwise
  the first of `supportedScreenModes` whose size rule takes the size at its
  `preferredUIScale` (0 `exactSize`, 1 from `minSize` through `maxSize`, 2 one
  of `allowedSizes`). A size that no mode takes is reported.
- CoreSimulator completes a change later, so a device's changes go one at a
  time, also across its sessions. A change asked for while one is in flight
  waits for it and replaces an earlier change that waits, so the last one
  wins. A window that disconnects during a change turns the display off after
  it, and the next session of the device, after a reopening or a restart,
  sends its changes after that power-off.
- A change whose completion does not come must not hold the device's later
  sessions. In the iOS 26.5 simulator every change completed: those sent while
  the device shut down without an error, and those sent after it shut down,
  or after it booted again through a connection made before, with `Invalid
  argument`, up to 4.5 seconds late. The queue still stops waiting for the
  change in flight when the session that sent it disconnects from a device
  that is no longer booted, and, as a last resort, after 10 seconds, which it
  reports as the change's failure. Either is logged, and a completion that
  comes later is ignored.
- Disabled, and closing the device window while the device is booted,
  always send the power-off, after a change in flight. No record of whether
  the display is on decides it, which reports and completions that arrive in
  either order, and other tools' changes, could leave wrong.
- `SimDeviceScreen.register(types:queue:handler:)` with `.properties` reports
  each change of the screen's `powerState`, `pixelSize`,
  `currentMode.preferredUIScale`, and `carPlayProperties`, also those another
  tool makes.
- The window shows the screen through the display factory, with the screen's
  ID. SimulatorKit's display takes a new size one or two main-queue turns
  after the properties event, so the window takes the size CoreSimulator
  reports instead of the display's. In full screen and during a live resize,
  where the display fits the window, the display fits it again once
  SimulatorKit's display takes the new size, which sets its view's frame.

`screenAdapter` is declared in SimulatorKit's extension of the Objective-C
class `SimDevice`. ABIBridge finds such a member only through an instance, so
it is bound to the first device that needs it and reused for the others;
`screens`, a `Dictionary`, is passed as its single reference. The screens,
their properties, and their modes are proxies, so `SimulatorRuntime` checks at
startup that `SimScreen`, `SimScreenProperties`, and `SimScreenMode` declare
the messages Neo sends, and they are bound to each proxy class when they are
first sent. `SimDeviceScreenAdapter.register(screenID:queue:handler:)`, which
Simulator.app uses to learn of screens, is not used: the pinned ABIBridge has
no support for a value `Optional` such as its `UInt32?` parameter. A host
description of `Optional<UInt32>`'s layout passes it, but ABIBridge does not
check that description against the declaration; an indirect one registers
without an error and never reports a screen. A device's screens exist from its
creation, so looking in `screens` until the enumeration ends finds the
external display, and the screen's own property reports cover the changes Neo
needs.

Like Simulator.app:

- The submenu follows Increase and Decrease Volume and a separator: Disabled
  (tag 2114), a separator, 640×480 (2214), 720×480 (2514), 1024×768 (2314),
  1280×720 (720p) (2414), 1920×1080 (1080p) (2614), 3840×2160 (4K) (2664), a
  separator, and CarPlay (2714). It is shown for a key device with
  `SimFeatureExternalDisplay` (`com.apple.display.supports-external`) and
  `SimFeatureInternalDisplay` (`com.apple.display.integrated`), and its items
  are enabled with a key device window, also while the device restarts;
  CarPlay is enabled, and can be checked, only for a device that also has
  `SimFeatureCarPlay` (`com.apple.carplay`).
- A choice is saved for the device first, as its tag in
  `DevicePreferences[UDID].SimulatorExternalDisplay`, which is Disabled while
  missing or not an integer. A size then sets the screen's mode at a scale of
  1, which also turns it on; Disabled turns it off.
- Each connection, including after a restart, applies the saved choice: a
  size sets the mode. Simulator.app's Disabled powers off only a display whose
  window is connected, which a new connection does not have yet, so Disabled
  leaves the display as it is, and a display that is on gets its window.
  CarPlay saved for a device without `SimFeatureCarPlay`, which Simulator.app
  turns into Disabled, is kept and not applied.
- The window opens while the display is on, whoever turned it on, and closes
  once the display is off. It has the device window's title, with `External
  Display`, or `CarPlay` for a CarPlay screen, where the runtime goes, no
  toolbar and no bezel, and a black background. Simulator.app's window for it is its device window class, whose
  chrome refresh, without a bezel, keeps no gap and sets the black
  background, so the display meets AppKit's plain title bar, which a window
  without a toolbar has whatever the toolbar style.
  It opens centered where it last closed in the current arrangement of
  screens, at the scale it closed at, reduced to Fit Screen's on the screen
  it is placed on, from `DevicePreferences[UDID].ExternalWindowGeometry`,
  which closing saves. As for the device window, it is placed before its
  scale is chosen and placed again at its new size.
- A new size keeps the display's scale. A drag on the window's edges keeps the
  screen's aspect ratio and stops at the scale that fits the display in 240 by
  240 points, both of which follow a new size during the drag, as
  Simulator.app's geometry update sets them on each resize. While the window is key, Point Accurate, Pixel Accurate (the
  screen's scale over the Mac screen's), and Fit Screen scale it; Physical
  Size is unavailable, as for every screen that is not a device's own.
- The display takes the pointer as touches and, while its window is key and
  the device's hardware keyboard is connected, the Mac's keyboard. It takes no
  touch pressure and draws the touch indicators the preferences turn on.
- Closing the window chooses Disabled. Closing the device window, quitting, or
  restarting closes it and, while the device is booted, turns the display off,
  keeping the choice for the next connection. Quitting, also with
  `DetachOnAppQuit` on, waits for every device's changes within
  `TerminationTimeout` before the app exits, including the power-offs of
  windows that closed earlier; a display whose changes have not completed by
  then is listed in the alert that quitting shows for its failures.

`DeviceSession` owns its connection to the device's external display, the
look-up for it, and its last reported state; `DeviceWindowController` opens
and closes the `ExternalDisplayWindowController` from that state. The changes
sent to the display belong to the device instead: `HostApplication` keeps one
`ExternalDisplayChanges` for each device, which the device's successive
sessions share, each change going through the connection of the session that
asked for it. A session's pending changes thereby outlive it: the next
session's changes follow them, and quitting waits for them. While an external
display's window is key, the other menus act on its device window.

These differ from Simulator.app:

- Simulator.app checks the saved choice. Neo checks the display's actual state:
  Disabled while it is off, CarPlay while it is a CarPlay screen, and otherwise
  the size it shows at a scale of 1, or no item for another size or scale. A
  failed choice or a size that `simctl` set therefore does not show as the
  saved one.
- Simulator.app only logs failures. Neo presents on the device window the
  failure of a choice, including a device without the TVOut screen, a size
  that no mode takes, and an error CoreSimulator reports later; restoring the
  choice on connection logs its failures. When turning the display off from
  its window fails, the window opens again. Quitting logs a failed power-off
  and lists a display that did not turn off within `TerminationTimeout`.
- A window without a saved place cascades from its device window, where
  Simulator.app cascades from its app-wide cascade point.
- Simulator.app sends `setPowerState:0` only while the display's window is
  connected. Neo sends it for every Disabled and every close of a booted
  device's window: in the iOS 26.5 simulator, turning off a display that is
  already off completes without an error and leaves it off, so the power-off
  needs no state to decide on.

In the iOS 26.5 simulator, the guest leaves the display black until an app
presents a scene for it (`UIWindowSceneSessionRoleExternalDisplayNonInteractive`),
which does not take touches. The guest's `UIScreen` took the requested size
when the mode had a `refreshRate` of 60 Hz; with the 120 Hz `allowedSizes`
modes it stayed at 720×480 and drew in that corner of a larger display, with
or without a display view connected. The iPad's TVOut screen advertised only
those 120 Hz modes, and the iPhone's `supportedScreenModes` listed them before
or after its 60 Hz ranges in different reads. The result of Simulator.app's
choice, which Neo keeps, therefore depends on that order.

#### CarPlay

Simulator.app's CarPlay is the same TVOut screen set up as a car's display, in
the default `StarkConfig`: 800×480 pixels at a UI scale of 2, a touch screen,
and no wheel, back, or home controls. Its options panel, behind the
`CarPlayExtraOptions` default, is not reproduced. Four parts make it, each
through an Xcode 27 primitive that Simulator.app also uses:

- The configuration file. A choice on a device with `SimFeatureCarPlay` first
  writes `<dataPath>/Library/Application Support/Simulator/extended_display.plist`
  in place, creating its folder: for CarPlay, `StarkConfig`'s plain keys
  (`stark` true, `width` 800, `height` 480, `scale` 2.0, `hasTouchScreen`
  true, the other controls false, `protocols` empty), and `{stark: 0}` for
  every other item. CoreSimulator gives the guest that path as
  `SIMULATOR_EXTENDED_DISPLAY_PROPERTIES` when the device boots, and the iOS
  26.5 guest's backboardd reads the file each time the TVOut screen's modes
  change: with `stark` on, it makes the screen a car display instead of an
  AirPlay display. The file must therefore be written before the screen
  changes.
- The screen. `setCurrentMode:pixelSize:carPlayProperties:…` sets 800×480 at a
  scale of 2 with the properties of the default configuration,
  `SimCarPlayPropertyKeyStark` and `SimCarPlayPropertyKeyHasTouchScreen`
  (CoreSimDeviceIO's exported keys, which `SimulatorRuntime` reads at startup)
  set to true. The screen then reports these as its `carPlayProperties`,
  which SimulatorKit's `SimDeviceScreen.isCarPlay` also counts; a size sets
  none, and the screen drops them.
- The guest's CarPlay session. `SimDevice enableCarPlay:error:` asks the
  guest's CoreSimulatorBridge to start or end a CarPlay session, which
  launches the guest's CarPlay app. The bridge counts the sessions that hosts
  start and needs an end for each; the request waits for the guest, so it runs
  on a serial queue off the main actor.
- The HID service. `IndigoHIDMessageToCreateCarPlayService(YES)` and
  `IndigoHIDMessageToRemoveCarPlayService()`, sent through a
  `SimDeviceLegacyHIDClient`, create and remove the guest's CarPlay HID
  service with a digitizer. SimulatorKit's display of the TVOut screen sends
  its touches to that service's target on a device with `SimFeatureCarPlay`,
  so the window's display takes the pointer as CarPlay's touches.

A choice of CarPlay writes the file, ends the CarPlay that this host started,
if any, sets the CarPlay screen, then starts the session and, once it started,
creates the HID service. A size writes `{stark: 0}`, ends this host's CarPlay
by removing the HID service and ending the session, then sets the size, as
Simulator.app does before it reconfigures a CarPlay screen. Disabled writes
`{stark: 0}`, turns the screen off, then ends this host's CarPlay, as
Simulator.app does once the screen reports it is off. Each choice goes
through `ExternalDisplayChanges` as one change. The queue counts the
sessions that this host started in the device's current boot
(`CarPlaySessions`, by `SimDevice.lastBootedAt`), from each request's own
completion, also one that comes after its change stopped waiting, and counts
a request that has not completed as if it will succeed, since a
connection's requests reach the guest one at a time. Ending CarPlay ends that many
sessions, one at a time, and stops at one that does not end, which stays
counted for the next change; CarPlay then keeps that session, recreating its
HID service, instead of starting another beside it. An end without a session
would count below zero in the bridge, which keeps that count and refuses the
next start; a session also belongs to its boot, because a restart can shut
the device down before its window's power-off and the session's end reach
the guest, and the next boot's bridge starts with none. The tag 2714 is saved
like the others, and a connection restores it, also after the device
restarts; the file on the device's disk keeps the configuration for the
guest.

The window of a CarPlay screen is the external display's window with the
subtitle `CarPlay`. Like Simulator.app, it opens at Point Accurate (a scale of
1, so the 800×480 screen shows as 400×240 points), reduced to Fit Screen's,
while it still opens at the center saved in `ExternalWindowGeometry`, and it
takes no full screen space of its own (`.fullScreenAuxiliary`); Physical Size
stays unavailable. A screen that changes between CarPlay and a size in place
keeps its window, which follows the subtitle and full screen behavior.

These differ from Simulator.app:

- Every failure is reported: the file, the screen, the session's start or
  end, and the HID service's creation or removal. The failures of one choice
  share one alert on the device window, a line each; restoring on connection
  and disconnecting log them. Simulator.app logs them, and drops the HID
  messages' send results.
- A session that did not start gets no HID service; Simulator.app creates it
  either way. A step that fails does not stop the others, except that a
  screen that did not change ends the change.
- Neo ends only the sessions it started, as `CarPlaySessions` counts them,
  and keeps a session that did not end instead of starting another.
  Simulator.app ends a session whenever the screen it reconfigures or
  disconnects is a CarPlay screen, which can end another host's session, and
  starts one after each CarPlay screen, also beside a session it could not
  end.
- Closing the device window, quitting, and restarting, which turn the display
  off, also end the CarPlay that this host started, keeping the saved choice
  and the file. Simulator.app's disconnection powers the screen off without
  ending the session, so the bridge's count stays up for the device's next
  host.
- CarPlay chosen while the display shows a size turns the display off first,
  so its window closes and a CarPlay window opens, and a CarPlay screen waits
  until the display has been off for a second since a change turned it off.
  Simulator.app sets the CarPlay screen in place. In the iOS 26.5 guest, a
  display that becomes a car display in place, or that comes back as one
  before the guest has handled its power-off, connects as an AirPlay display
  that stays in the guest's display debouncing, and a CarPlay app that is
  already running, as it keeps running after its first session, never draws
  on it. Turned off for 0.2 seconds or longer, it connected as a car display
  in every try.
- A CarPlay screen that another tool turns off keeps the guest's session
  until the next choice; Simulator.app ends it when the screen reports it is
  off.

In the iOS 26.5 simulator, on an iPhone 17 Pro in a separate device set,
CarPlay drew the CarPlay dashboard in its window, a click on an app's icon in
the window opened that app on the CarPlay screen, and the CarPlay app's
session and the HID service ended with Disabled. CarPlay came back after a
size, after Disabled, and on the connection after a restart. The iPad Pro
11-inch (M5) has no `SimFeatureCarPlay`. Right after a boot, the guest's
CarPlay app once took seven seconds to start after the session did.

### Settings and touch indicators

NeoSimulator ▸ Settings… (Command-,) sends `orderFrontPreferencesPanel:` to the
first responder, as Simulator.app's menu item does. AppKit's
`NSApplication(NSSimplePreferences)` category answers it: unless the app
delegate's `applicationOrderFrontPreferencesPanel:` handles it, AppKit builds a
settings window from the main bundle's `Settings.bundle/Root.plist`, binds each
control to `NSUserDefaultsController.shared` (`values.<Key>`), and gives the
controller each item's `DefaultValue` as an initial value. The category is not
in the public SDK; macOS 26 has it. Where it is missing, AppKit's menu
validation finds no responder and disables the item. NeoSimulator's
`Settings.bundle` has Simulator.app's items, titles, controls, and order,
without the ones Neo has no consumer for: the stop-capture shortcut
(`CaptureEscapeKeyCodes`), because Neo does not capture the pointer and
keyboard (see [Input capture](#input-capture)), and the empty group before it.
"When Simulator starts" names NeoSimulator. Every other item already has a
reader that reads the standard defaults when it acts: launch, window close,
quit, Save Screen and Record Screen, and GIF export. The release archive, the
installer, and the release verification carry
`Contents/Resources/Settings.bundle/Root.plist` as one of the app's files.

Simulator.app registers `ShowPinches` on and `ShowSingleTouches`,
`ShowPinchPivotPoint`, and `HighlightEdgeGestures` off, while its
Settings.bundle gives `ShowPinches` the default `false`. The controller uses an
initial value only for a key without any value, and a registered key always
has one, so pinch gestures are on in Simulator.app. NeoSimulator registers the
same defaults, and its Settings.bundle states `true` for `ShowPinches` to match.

`TouchIndicator` maps the four preferences to `SimDigitizerInputView.DrawOption`
`.normalTouch`, `.pinchTouches`, `.pinchPivotPoint`, and `.edgeGestures`.
`DrawOption` is a resilient option set, so `SimulatorDisplayInterface` reads its
`rawValue`, makes one with `init(rawValue:)`, and reads the four options' raw
values when the host starts. Showing or hiding an indicator reads the
digitizer's `drawOptions`, sets or clears that option's bits, and writes the
result back, so the other options stay, such as `.lockedTouches`, which a
new display starts with. Each display connection, including after a restart,
applies all four preferences. `HostApplication` observes the four keys of the
standard defaults with key-value observing and posts
`TouchIndicator.didChangeNotification`; every open window then applies them
again.

These differ from Simulator.app:

- Simulator.app reapplies only `ShowPinches` and `ShowSingleTouches` when the
  process posts `NSUserDefaultsDidChangeNotification`, which a change from
  another process, such as `defaults write`, does not post. Its pivot point and
  edge gesture preferences change open windows only through the Internal
  menu, which only Apple's internal builds show. NeoSimulator has no Internal
  menu and applies a change to any of the four preferences, from Settings or
  from another process, to every open window.

### Modifier gestures

SimulatorKit's `SimDigitizerInputView` owns the Option, Option-Shift, and
Control gestures in both apps. It takes the modifiers from the modifier and
mouse events it receives, draws the finger indicators, keeps a pinned finger,
and sends the touches to the guest. NeoSimulator keeps no contact state; it
decides only which events reach the digitizer.

The window makes the digitizer its first responder when it becomes key and
after each device command, and sends it the current modifier flags.
Simulator.app has no such step: its digitizer asks for focus when the pointer
enters it and keeps the last modifiers it saw. There, an Option release that
reaches another window or app leaves the digitizer with Option down, and the
next plain click becomes a two-finger touch. NeoSimulator deliberately
reconciles the modifiers instead. An external display's window does the same:
both windows give their display the keyboard and the focus through
`DisplayKeyboardInput`.

When the window resigns key, it releases the guest's held modifier keys before
its display stops taking the Mac's keyboard, as Simulator.app's
`clearModifiers()` does; SimulatorKit itself releases modifiers only on
displays that still take the keyboard. NeoSimulator sends the release as a
modifier event through the app, where SimulatorKit's keyboard monitor reads it.
AppKit passes such an event to the app's key window, and while the app
deactivates that is still the device window. Its digitizer would take the
release as Option going up, stop an Option gesture in progress, and keep both
touches down until the next click. The window therefore becomes its own first
responder for the release and then gives focus back to the digitizer, which
sees nothing, as in Simulator.app.

The finger indicators that `drawOptions` turns on follow the touch indicator
preferences, as described under
[Settings and touch indicators](#settings-and-touch-indicators); pinned touches
stay drawn.

Because both apps give the digitizer the same events, the gestures behave the
same way in each of these cases:

| Case | Behavior in both apps |
| --- | --- |
| Shift pressed or released during an Option drag | Switches between pinching and moving both fingers |
| Option pressed during a one-finger drag | Adds the mirrored second finger; releasing the button lifts both |
| Option released before the mouse button | Both fingers stop and stay down after the button comes up, until the next click |
| Control pressed during an Option drag | Releasing the button lifts both fingers; nothing is pinned |
| Another window or app becomes active during a gesture | The gesture continues; releasing the button lifts the fingers. A pinned finger stays pinned |
| Scale command or bezel-corner drag | The gesture continues; a pinned finger keeps its place on the device's screen |
| Display rotation | Touches follow the new mapping; a pinned finger keeps its place in the window, which moves it on the device's screen, and a click at that place releases it |
| Pointer leaving the screen during a drag | The touch stops at the edge and ends when the button comes up |
| Window close, quit, or disconnect | `SimDisplayView.disconnect(completion:)` turns the digitizer off without sending touch ends, so a finger that is down or pinned stays active in a device that keeps running. The next touch from a new connection ends it first and can become that touch's end |
| Device restart | The guest restarts; no touch remains |

Neither app ends active touches before disconnecting, and NeoSimulator does
not synthesize touches that Simulator.app does not send. The evidence is in the
[Simulator.app analysis](SimulatorAppAnalysis.md#modifier-gestures).

## Failure semantics

The executable follows BSD `sysexits` categories:

| Code | Meaning |
| ---: | --- |
| 0 | success or documented no-op |
| 64 | invalid invocation |
| 69 | unavailable Xcode, host, framework, symbol, tool, or plugin |
| 70 | internal invariant failure |
| 73 | receipt or lock cannot be created |
| 74 | preference or state I/O failed |
| 75 | another operation holds the lock or a managed app does not terminate |
| 78 | malformed configuration, receipt conflict, or external state conflict |

Preference commit followed by Device Hub termination or requested-host launch
failure is reported as partial success; the receipt remains available for
`restore`. A failure to close Neo or a validated legacy Simulator before
selecting Device Hub happens before preference mutation.

Neo launch is successful only after the new process writes its private
startup result following runtime creation, device-set subscription, activation,
and any initial booted-device window creation. LaunchServices returning an
application object is not itself a successful startup.

Legacy launch requires LaunchServices to return the same validated Simulator
bundle URL and identifier. A substituted application is terminated and reported
as a configuration failure.

Optional menu-operation failures are shown on the active simulator window and
do not change the route or launch Device Hub.

## Validation

Unit tests use fake commands, temporary Xcode/framework/plugin fixtures, and
isolated receipt directories. They cover tri-state transactions, interrupted
recovery, conflicts, idempotence, same-route Neo/Legacy switching, exact process
identity, Xcode 26/27/28 gates, wrapper parsing, generation/version mismatch,
signatures, forbidden linkage, exported runtime symbols, and read-only status
behavior.

Release verification builds the SwiftPM CLI and the workspace app target, checks
bundle versions, architectures, and signatures, verifies the exact archive file
set, installs over a synthetic previous version, and compares installed CLI/app
files with the archive.

Live validation additionally covers framebuffer/touch/accessibility, focused
keyboard input, Home, Software Keyboard, connecting and disconnecting the
hardware keyboard, the keyboard language, the digitizer's touch pressure
settings and touch indicator draw options, the settings window, modifier
gestures through the lifecycle cases above, audio routes to an existing
loopback device and back with the guest's audio reaching it, resize, menu rotation, screenshot
PNG, Get and Send Pasteboard with text and a PNG and without any exchange
between commands, Automatically Sync Pasteboard between the Mac and two devices
(on and off, across a CoreSimulatorBridge restart, a device restart, and a
closed window), external displays at 1920×1080 and 640×480 with a guest app's
external scene in their windows, Disabled, closing their windows, a restart,
and restoring the saved choice on an iPhone and an iPad, CarPlay on an iPhone
with a click reaching the guest, switched with a size, Disabled, a closed
window, and restored after a restart, Device Hub absence, and loaded-image
provenance.

## Non-goals

- Modifying, replacing, re-signing, or deleting Xcode or Device Hub.
- Preventing another user or application from executing Device Hub at the OS
  policy layer.
- Claiming undocumented behavior is supported by Apple.
- Guessing compatibility when a later Xcode changes private contracts.
- Reproducing every platform- or entitlement-specific Simulator.app feature in
  the first release.
