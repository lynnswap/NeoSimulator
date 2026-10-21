# Simulator.app analysis

This document records the evidence used to reproduce Simulator behavior without
depending on Simulator.app at runtime.

## Scope

The binary analysis below uses Simulator.app 16.0 (1063.4) from Xcode 26.5;
the window appearance was also compared with Simulator.app from Xcode 26.6. The target
runtime is Xcode 27 or later, where Simulator.app is absent. No resource, class,
or binary from the reference app is loaded by the packaged host.

The analysis used:

- `Simulator.DeviceWindow` and `Simulator.DeviceWindowController` metadata and
  disassembly;
- `Resources/Base.lproj/MainMenu.nib` as the menu source of truth;
- the iPhone/iPad/watch/TV toolbar nibs only to identify action ownership;
- Xcode 27 SimulatorKit/CoreSimulator/CoreDevice binaries to confirm replacement
  primitives.

The user-supplied screenshot was an appearance acceptance reference, not the
source of behavioral assumptions.

## Window and display evidence

| Reference owner | Observed behavior | Standalone mapping |
| --- | --- | --- |
| `DeviceWindow.awakeFromNib` at `0x100035B28` | DarkAqua, clear non-opaque window, disabled tabbing, titlebar separator setup, layer-backed content, shadow invalidation | public AppKit window with full-size transparent titlebar, native traffic lights, DarkAqua, clear background, explicit shadow invalidation |
| `DeviceWindowController.setShowChrome:` at `0x100048374` | calls SimulatorKit `SimDisplayView.showDeviceChrome` setter | dlsym the same thunk from the selected Xcode 27+ and set it explicitly |
| `windowDidResize:` at `0x10004BEF4` | derives display scale and invalidates the shadow | existing `beginResize` / `resizeTo` / `endResize` bridge, excluding the detached header area |
| `WindowTitleHelper` around `0x10005AE20` | owns title/subtitle and Window menu naming | device name in `NSWindow.title`, runtime in `NSWindow.subtitle` |

The reference app's toolbar is app-local (`SimToolbar`,
`IndigoiPhoneToolbar.nib`) and cannot be reused on Xcode 27+. The standalone
host uses a public `NSToolbar` with `NSToolbarItem` controls, the unified window
toolbar style, and a capsule background while preserving the underlying action
owners. Native titlebar layout positions the traffic lights, title, and subtitle.

The Xcode 27 display factory already selects the device's chrome identifier and
leaves `preferSimpleChrome` false. Its chrome state starts inactive, whose tint
flattens the device artwork to gray. Simulator.app imports both active/inactive
chrome states and the state setter. Neo forwards window key-state changes to
that setter instead of overriding the profile or drawing replacement bezels.

## Menu archive

Static decoding of `MainMenu.nib` recovered:

- 10 top-level menus;
- 181 reachable non-separator items;
- 157 control connectors;
- item titles, selectors, targets, shortcuts, modifier masks, tags, alternate
  state, and hidden state.

The top-level menus are Simulator, File, Edit, Device, I/O, Features, Debug,
Window, Help, and a hidden Internal menu. There is no separate View menu.

The archive is a capability superset. It contains iPhone, iPad, watchOS, tvOS,
visionOS, external-display, private-debug, and entitlement-specific commands.
The reference app uses four validation owners to hide or disable items:

- `SimulatorAppDelegate.validateMenuItem:` at `0x10001202C`;
- `DeviceCoordinator.validateMenuItem:` at `0x10001F10C`;
- `DeviceWindow.validateMenuItem:` at `0x100036728`;
- `DeviceWindowController.validateMenuItem:` at `0x100052A9C`.

Recreating every archived item without equivalent capability checks would
create dead controls.

## Action evidence

Representative per-window actions in the reference binary:

| Action | Address | Xcode 27+ replacement |
| --- | ---: | --- |
| Rotate Left / Right | `0x100053B50` / `0x100053DA0` | typed direct `devicectl device orientation rotate` |
| Home | `0x1000540EC` | `IndigoHIDMessageForButton`, button `0`, down/up, integrated target |
| Lock | `0x10005411C` | same HID function, button `1` |
| Hardware / Software Keyboard | `0x10005571C` / `0x10005574C` | CoreSimulator keyboard selector / HID button `0x3f0` |
| Save Screen / Save Screen… | `0x1000570D8` | typed direct `simctl io … screenshot --mask=alpha\|ignored`; names from `0x100055758`, folder from `0x1000559C0` |
| Record Screen / Record Screen… | `0x100058EC4` | `simctl io … recordVideo --mask=black\|ignored`, H.264 (HEVC for visionOS); names from `0x100058634` |
| Stop Recording | `0x10005A014` | SIGINT after `Recording started`, then the movie is moved to the Desktop or the chosen file |
| Copy Screen | `0x100053A68` | `simctl io … screenshot --mask=ignored`, written to the general pasteboard as PNG only |
| Capture thumbnail | `0x100063CD8` / `0x1000637A8` | AppKit child window: white flash and shrink to a quarter size plus 10 points, 5-second or movie-length timer paused by hover, menus, and window moves; dismissal saves to the default folder; file-promise drag; GIF export at up to `GifMaxFramerate` 10 fps and `GifMaxFrameSize` 640 px with `CIDither` |
| Volume Up / Down | `0x100058224` / `0x10005823C` | `IndigoHIDMessageForHIDArbitrary`, consumer page `0x0c`, usages `0xe9` / `0xea`, shown with `com.apple.CoreSimulator.audio.routable` |
| Window scale | `0x100054BBC` | `SimDisplayView.renderScale`, `size(for:)`, and `scale(for:)`; see [Window scale modes](#window-scale-modes) |

Representative coordinator actions:

| Action | Address | Status |
| --- | ---: | --- |
| Restart | `0x10001FDBC` | implemented with `simctl shutdown` and `boot` (plus `erase` for Erase All Content and Settings…), keeping the window and reconnecting after boot |
| Memory Warning | `0x10001FE70` | omitted: private implementation discards its file-write result |
| Hardware keyboard sync | `0x1000207D4` | available, deferred pending UI state ownership |
| Graphics/debug options | `0x10002180C` onward | available, outside first parity |
| iCloud sync | `0x100022224` | implemented with `SimDevice triggerCloudSyncWithCompletionQueue:completionHandler:`, reporting its error |
| Text size / Increase Contrast | `0x100020654` / `0x1000204E8` | implemented with `currentContentSizeCategory`/`setContentSizeCategory:error:` (1–12, no change at the limits) and `currentIncreaseContrastMode`/`setIncreaseContrastEnabled:error:` |
| StandBy | `0x1000202D4` | implemented by flipping and posting the `com.apple.springboard.ambient.presentation` notification state |
| Location | `0x100022390` | implemented with `SimDevice availableLocationScenarios`, `clearSimulatedLocationWithError:`, `setLocationWithLatitude:andLongitude:error:`, and `setLocationScenario:error:`, restored at each connection from `LocationMode`/`LocationScenario`/`LocationLatitude`/`LocationLongitude`; the menu lists the key device's scenarios rather than the last connected device's; the `com.apple.iphonesimulator.simulateLocation` notification is not handled |

## Implemented parity set

The first set contains only actions with a concrete owner and observable failure
semantics:

- Application: About, Hide, Hide Others, Show All, Quit, Quit…;
- File: New Simulator…, Open Simulator, Save Screen, Save Screen…, Record
  Screen, Record Screen…, Stop Recording, Close Window, Close Window…;
- Edit: Copy Screen;
- Device: Rotate Left, Rotate Right, Orientation, Rotate Device Automatically,
  Home, Lock, Side Button, Action Button,
  Siri, Shake, App Switcher, Trigger Screenshot;
- I/O: Toggle Software Keyboard, Increase Volume, Decrease Volume;
- Features: Touch ID and Face ID (Enrolled, Matching, Non-matching),
  Authorize Apple Pay, Toggle Appearance, Toggle In-call Status Bar,
  Show/Hide StandBy, Increase and Decrease Preferred Text Size, Toggle
  Increase Contrast, Trigger iCloud Sync, Location (None, Custom Location…,
  and the runtime's scenarios);
- Debug: Show Parallel Testing Devices;
- Window: Minimize, Full Screen, Show Device Bezels, Stay on Top, Physical
  Size, Point Accurate, Pixel Accurate, Fit Screen, Bring All to Front.
  Simulator.app hides Zoom.

The detached window header exposes Home, Save Screen, and Rotate Right using
the same session actions as the menus. A red stop control appears while a video
is recording; Software Keyboard is available from I/O and Command-K.

Menu commands are validated against the active device window at dispatch time.
Rotation and screenshot work is single-flight and cancelled when the owning
window closes.

## Window scale modes

The evidence is Simulator.app 16.0 (1063.4) from Xcode 26.6. `DWC` is
`Simulator.DeviceWindowController`.

| Reference owner | Observed behavior |
| --- | --- |
| `DWC.windowScaleChanged:` `0x100054BBC`, body `0x1000548B0` | Menu tags 4108 Physical Size, 4109 Pixel Accurate, 4110 Point Accurate, 4111 Fit Screen. Sets `renderScale`, updates the window geometry (`0x10005B4A0`), and keeps the window's top edge. Fit Screen then centers the window in the visible frame (`0x10003872C`); the others move it back inside (`0x100038840`). |
| Physical Size helper `0x100038260` | `NSDeviceSize.width / (CGDisplayScreenSize(NSScreenNumber).width / 25.4)` over `mainScreenDPI.width / mainScreenScale`. 110 replaces the Mac's value only without a window screen, `NSScreenNumber`, or `NSDeviceSize`; 163 replaces the device's only without a device type. A zero size is divided by as is. |
| Pixel Accurate helper `0x100038488` | `SimDeviceScreen.scale / window.screen.backingScaleFactor`, each 1 when missing. |
| Fit Screen helper `0x100037E08` | `scale(for:)` of the visible frame less the window's chrome (`window.frame − displayView.frame`) and 20 points; 1000 without any screen. Not clamped to 1. |
| `DWC.validateMenuItem:` scale branch `0x100051D4C` | Needs `connectedScreen` and `DeviceWindow.fullScreenState == 3`. The `FullScreenState` cases are `entering`, `fullScreen`, `exiting`, and `none`, so 3 is `none`. Fit Screen is then enabled with its state untouched. A fixed scale sets its checkmark from `CGFloat.isAlmost(_:precision:)`, `abs(a − b) < 0.001`, then requires the minimum (`0x100047884`). Physical Size needs `displayClass & 0xFFFF == 0`. The fit check runs only when `chromeView.chrome` is nil, that is without a bezel (`getEnumTagSinglePayload == 1` at `0x100051FD0`); it compares `size(for:)` with the visible frame less the title bar. |
| Minimum scale `0x100047884` | iOS on display class 0: 0.4 for an iPhone, 0.25 otherwise; watchOS 0.6; otherwise `scale(for: 240×240)`, or 240 over the screen's pixel height for a display with chrome on other platforms. |
| Connection `0x10004E24C` … `0x10004EDFC` | Opens at `min(fit, WindowScale ?? 1)` from `DevicePreferences[UDID].SimulatorWindowGeometry` (1 also for a value ≤ 0), at `WindowCenter` when saved. |
| Disconnect `0x10004FDB8` → `0x100050D84` | Saves `WindowCenter` (`NSStringFromPoint`) and `WindowScale` (`renderScale`) when the window exists and the device is not rebooting. |
| Rotation `0x10005BA50` | Keeps `renderScale`, updates the geometry, and keeps the top edge inside the visible frame. |
| `DeviceWindow.constrainFrameRect:toScreen:` `0x100037A20` | While the window has chrome insets, moves it vertically instead of calling `super`, so a window with a bezel is not shrunk to the screen. |

Neither `windowDidChangeScreen:` nor `windowDidChangeBackingProperties:` is
implemented. A screen parameter change only calls each window's
`ensureWindowIsEntirelyOnScreenIfPossible`; no scale is reapplied, and the
checkmarks follow the window's screen at the next validation.
`NSUserDefaults(Indigo)` also implements `windowLastScaleForDevice:` and
`setWindowLastScale:forDevice:` (`SimulatorWindowLastScale`), but nothing in
Simulator.app 16.0 calls them.

NeoSimulator reproduces these commands; its differences are listed in the
[design](Design.md#commands-and-menus).

## Deferred features

These have viable Xcode 27+ primitives but need a dedicated state/capability
contract before being user-visible:

- Connect Hardware Keyboard and keyboard-language sync;
- status-bar overrides;
- external displays and CarPlay.

## Excluded features

- Automatic, send, receive, or continuous pasteboard synchronization.
- Standard Edit/Services clipboard routing.
- Global keyboard, pointer, and game-controller capture. The reference app has
  private HID event-filter/event-monitor and TCC entitlements that the companion
  does not have.
- watchOS, tvOS, and visionOS-specific gesture, remote, camera, immersion, and
  viewport commands.
- FaceTime/audio-routing and internal GPU/debug menus.
- Device Manager or any Device Hub URL handoff.

These exclusions are part of the Neo-mode safety boundary, not missing
fallbacks.
