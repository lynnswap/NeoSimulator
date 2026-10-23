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
| `DeviceWindow.awakeFromNib` at `0x100035B28` | DarkAqua, clear non-opaque window, disabled tabbing, titlebar separator setup, layer-backed content, shadow invalidation | public AppKit window with full-size content below an AppKit title bar, native traffic lights, DarkAqua, clear or black background as the bezel says, explicit shadow invalidation |
| `DeviceWindowController.setShowChrome:` at `0x100048374` | calls SimulatorKit `SimDisplayView.showDeviceChrome` setter | dlsym the same thunk from the selected Xcode 27+ and set it explicitly |
| `windowDidResize:` at `0x10004BEF4`, `windowDidEndLiveResize:` at `0x10004C040` | outside full screen, `windowDidResize:` runs the geometry update without a size or origin and invalidates the shadow; `windowDidEndLiveResize:` sets `renderScale` to `scale(for:)` of the display view's frame | existing `beginResize` / `resizeTo` / `endResize` bridge for a live resize, excluding the detached header area |
| `WindowTitleHelper` around `0x10005AE20` | owns title/subtitle and Window menu naming | device name in `NSWindow.title`, runtime in `NSWindow.subtitle` |

The reference app's toolbar is app-local (`SimToolbar`,
`IndigoiPhoneToolbar.nib`) and cannot be reused on Xcode 27+. The standalone
host uses a public `NSToolbar` with `NSToolbarItem` controls between two
flexible spaces, as in the nibs, with the toolbar style that Simulator.app's
geometry update chooses and AppKit's own title bar, whose lower corners it
rounds above a bezel (see [Window layout](#window-layout)), while preserving
the underlying action owners. Native titlebar layout positions the traffic
lights, title, and subtitle.

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
| Hardware / Software Keyboard | `0x10005571C` / `0x10005574C` | `SimDevice setHardwareKeyboardEnabled:keyboardType:error:` / HID button `0x3f0`; see [Keyboard and touch pressure](#keyboard-and-touch-pressure) |
| Save Screen / Save Screen… | `0x1000570D8` | typed direct `simctl io … screenshot --mask=alpha\|ignored`; names from `0x100055758`, folder from `0x1000559C0` |
| Record Screen / Record Screen… | `0x100058EC4` | `simctl io … recordVideo --mask=black\|ignored`, H.264 (HEVC for visionOS); names from `0x100058634` |
| Stop Recording | `0x10005A014` | SIGINT after `Recording started`, then the movie is moved to the Desktop or the chosen file |
| Copy Screen | `0x100053A68` | `simctl io … screenshot --mask=ignored`, written to the general pasteboard as PNG only |
| Capture thumbnail | `0x100063CD8` / `0x1000637A8` | AppKit child window: white flash and shrink to a quarter size plus 10 points, 5-second or movie-length timer paused by hover, menus, and window moves; dismissal saves to the default folder; file-promise drag; GIF export at up to `GifMaxFramerate` 10 fps and `GifMaxFrameSize` 640 px with `CIDither` |
| Volume Up / Down | `0x100058224` / `0x10005823C` | `IndigoHIDMessageForHIDArbitrary`, consumer page `0x0c`, usages `0xe9` / `0xea`, shown with `com.apple.CoreSimulator.audio.routable` |
| Double Tap / Wrist Flick | `0x100054358` | `IndigoHIDMessageForWatchGesture` with `0` / `1`, one message; see [watchOS, tvOS, and visionOS](#watchos-tvos-and-visionos) |
| Simulate Fall | `0x10005485C` | `SimDevice darwinNotificationSetState:name:error:` with `com.apple.sos.user-fell` 0–3, then `postDarwinNotification:error:` |
| Window scale | `0x100054BBC` | `SimDisplayView.renderScale`, `size(for:)`, and `scale(for:)`; see [Window scale modes](#window-scale-modes) |

Representative coordinator actions:

| Action | Address | Status |
| --- | ---: | --- |
| Restart | `0x10001FDBC` | implemented with `simctl shutdown` and `boot` (plus `erase` for Erase All Content and Settings…), keeping the window and reconnecting after boot |
| Memory Warning | `0x10001FE70` | implemented as a checked, in-place write of `SimDevice.memoryWarningFilePath`, because `simulateMemoryWarning` discards its write result |
| Keyboard language sync | `0x1000207D4` | implemented with `SimDevice setKeyboardLanguage:error:` and the first language of the Mac's input source; see [Keyboard and touch pressure](#keyboard-and-touch-pressure) |
| Slow Animations / Graphics Quality Override | `0x10002180C` / `0x1000218AC` | implemented by setting and posting `com.apple.UIKit.SimulatorSlowMotionAnimationState` (0/1) and `com.apple.UIKit.ForceGraphicsQuality` (0/10/100), checked from `SlowMotionAnimation` / `GraphicsQualityOverride` and applied again on connection; Apple TV also stops PineBoard |
| Color options | `0x100021B84` onward | implemented with `setCADebugOption:enabled:` (options 2, 1, 14, 17), checked and verified with `getCADebugOption:` |
| Open System Log… | `0x100022064` | implemented: `<logPath>/system.log` opened in Console, reporting a missing file or failed launch |
| iCloud sync | `0x100022224` | implemented with `SimDevice triggerCloudSyncWithCompletionQueue:completionHandler:`, reporting its error |
| Text size / Increase Contrast | `0x100020654` / `0x1000204E8` | implemented with `currentContentSizeCategory`/`setContentSizeCategory:error:` (1–12, no change at the limits) and `currentIncreaseContrastMode`/`setIncreaseContrastEnabled:error:` |
| StandBy | `0x1000202D4` | implemented by flipping and posting the `com.apple.springboard.ambient.presentation` notification state |
| Location | `0x100022390` | implemented with `SimDevice availableLocationScenarios`, `clearSimulatedLocationWithError:`, `setLocationWithLatitude:andLongitude:error:`, and `setLocationScenario:error:`, restored at each connection from `LocationMode`/`LocationScenario`/`LocationLatitude`/`LocationLongitude`; the menu lists the key device's scenarios rather than the last connected device's; the `com.apple.iphonesimulator.simulateLocation` notification is not handled |
| Get Pasteboard / Send Pasteboard | `0x10001FC3C` / `0x10001FC80` | implemented with SimPasteboardPlus `pull` / `push` on a connection opened at the first command; see [Pasteboard](#pasteboard) |
| Audio Input / Audio Output | `0x1000142C8` (app delegate) | implemented with CoreSimDeviceIO's `SimAudioHostRoutable` port; see [Audio routing](#audio-routing) |
| External Displays | `0x1000208CC` | implemented with SimulatorKit's screen adapter and `SimScreen`'s mode and power setters, and CarPlay with `extended_display.plist`, CarPlay properties, `SimDevice enableCarPlay:error:`, and the CarPlay HID service; see [External displays](#external-displays) |
| Automatically Sync Pasteboard | `0x100012ABC` (app delegate) | implemented with `enableRemoteAutosync` / `disableRemoteAutosync` and the forwarding of a device's copy to the other devices, off by default; see [Pasteboard](#pasteboard) |

## Implemented parity set

The first set contains only actions with a concrete owner and observable failure
semantics:

- Application: About, Settings…, Hide, Hide Others, Show All, Quit, Quit…;
- File: New Simulator…, Open Simulator, Save Screen, Save Screen…, Record
  Screen, Record Screen…, Stop Recording, GPU Selection
  (`FramebufferServerGPUPolicy` in `com.apple.CoreSimulator`, rewritten as
  `selectPreferredGPUType:` at `0x100015ED4` does), Close Window, Close
  Window…;
- Edit: Copy Screen, Automatically Sync Pasteboard (off by default), Get
  Pasteboard, Send Pasteboard;
- Device: Rotate Left, Rotate Right, Orientation, Rotate Device Automatically,
  Home, Re-Center Open Apps, Lock, Side Button, Action Button, Gestures (Double
  Tap, Wrist Flick), Siri, Shake, App Switcher, Interaction, Look Around, Pan,
  Orbit, and Dolly Mode, Reset Camera, Trigger Screenshot, Simulated Scenes;
- I/O: Keyboard (Use the Same Keyboard Language as macOS, Connect Hardware
  Keyboard, Toggle Software Keyboard), Touch Pressure (Use Trackpad Force,
  Shallow Press, Deep Press), Audio Input, Audio Output, Increase Volume,
  Decrease Volume, External Displays (Disabled, six sizes, and CarPlay), Set
  Immersion To (50%, 75%, 100%);
- Features: Touch ID, Face ID, and Optic ID (Enrolled, Matching,
  Non-matching), Simulate Fall (Confirmed, Dismissed, Rejected, Unresponsive),
  Authorize Apple Pay, Toggle Appearance, Toggle In-call Status Bar, Show/Hide
  StandBy, FaceTime (six simulated sessions), Increase and Decrease Preferred
  Text Size, Toggle Increase Contrast, Trigger iCloud Sync, Location (None,
  Custom Location…, and the runtime's scenarios);
- Debug: Slow Animations, Graphics Quality Override, Color Blended Layers,
  Color Copied Images, Color Misaligned Images, Color Off-screen Rendered, Open
  System Log…, Simulate Memory Warning, Show Gaze Target, Show Parallel
  Testing Devices;
- Window: Minimize, Full Screen, Show Device Bezels, Show Apple TV Remote,
  Stay on Top, Physical Size, Point Accurate, Pixel Accurate, Fit Screen,
  Bring All to Front.
  Simulator.app hides Zoom.

The detached window header exposes Home, Save Screen, and Rotate using the same
session actions as the menus; watches and Apple TV have Home and Save Screen, a
watch with an always-on display also Always On, and Apple Vision Pro its
plugin's toolbar (see [watchOS, tvOS, and visionOS](#watchos-tvos-and-visionos)). With Option down over the toolbar, Save Screen
records the screen and Rotate turns the device left; while a video is
recording, Save Screen shows `stop.circle` and stops it, as in Simulator.app.
Software Keyboard is available from I/O and Command-K.

Menu commands are validated against the active device window at dispatch time.
Rotation and screenshot work is single-flight and cancelled when the owning
window closes.

## Window scale modes

The evidence is Simulator.app 16.0 (1063.4) from Xcode 26.6. `DWC` is
`Simulator.DeviceWindowController`.

| Reference owner | Observed behavior |
| --- | --- |
| `DWC.windowScaleChanged:` `0x100054BBC`, body `0x1000548B0` | Menu tags 4108 Physical Size, 4109 Pixel Accurate, 4110 Point Accurate, 4111 Fit Screen. Sets `renderScale`, updates the window geometry (`0x10005B4A0`), then `setFrameOrigin:` back to the previous top edge. Fit Screen then centers the window in the visible frame (`0x10003872C`); the others move it back inside (`0x100038840`), along each axis it crosses, using `window.screen ?? NSScreen.main` and skipping full screen. |
| Physical Size helper `0x100038260` | `NSDeviceSize.width / (CGDisplayScreenSize(NSScreenNumber).width / 25.4)` over `mainScreenDPI.width / mainScreenScale`. 110 replaces the Mac's value only without a window screen, `NSScreenNumber`, or `NSDeviceSize`; 163 replaces the device's only without a device type. A zero size is divided by as is. |
| Pixel Accurate helper `0x100038488` | `SimDeviceScreen.scale / window.screen.backingScaleFactor`, each 1 when missing. |
| Fit Screen helper `0x100037E08` | `scale(for:)` of the visible frame less the window's chrome (`window.frame − displayView.frame`) and 20 points; 1000 without any screen. Not clamped to 1. Outside full screen the display view fills the content view below the gap (see [Window layout](#window-layout)), so the chrome is the title bar and the gap. |
| `DWC.validateMenuItem:` scale branch `0x100051D4C` | Needs `connectedScreen` and `DeviceWindow.fullScreenState == 3`. The `FullScreenState` cases are `entering`, `fullScreen`, `exiting`, and `none`, so 3 is `none`. Fit Screen is then enabled with its state untouched. Physical Size needs `displayClass & 0xFFFF == 0`. Each of these checks returns NO through `0x100051B10` without `setState:`, so the checkmark stays as it was; so does a menu without a device window, where no window controller validates the items. A fixed scale then sets its checkmark (`setState:` at `0x100051F50`) from `CGFloat.isAlmost(_:precision:)`, `abs(a − b) < 0.001`, and only afterwards requires the minimum (`0x100047884`). The fit check runs only when `chromeView.chrome` is nil (`getEnumTagSinglePayload == 1` at `0x100051FD0`); it compares `size(for:)` with the visible frame less the title bar, `window.frame.height − contentRect(forFrameRect: window.frame).height` (`0x1000520C8`–`0x100052150`); without a chrome there is no gap above the display (see [Window layout](#window-layout)). |
| What makes `SimDisplayChromeView.chrome` nil (SimulatorKit of Xcode 26.6) | `SimDisplayView.showDeviceChrome`'s `didSet` (`0x35510`) sets `chromeView.deviceType` to the device's type, or to nil when the bezel is hidden. `set(deviceType:)` (`0x56384`) reloads the chrome (`0x579CC`), which is nil without a device type, a context, `supportedChromeProfileBundles`, a `chromeIdentifier`, or a matching profile bundle. Simulator.app's `setShowChrome:` sets `showDeviceChrome`, and each connection sets it from the app-wide `ShowChrome` default. |
| Show Device Bezels: `-[SimulatorAppDelegate toggleShowChrome:]` `0x10001356C`, the app delegate's validation `0x100012518`, defaults `0x100025218` | Saves the negation of `boolForKey:@"ShowChrome"` and sends `setShowChrome:` to the window controller of every device coordinator whose `windowExists` (`0x100013730`). The validation sets the checkmark from `ShowChrome` and returns YES, also without a device window. `ShowChrome` is registered as YES. |
| Minimum scale `0x100047884` | iOS on display class 0: 0.4 for an iPhone, 0.25 otherwise; watchOS 0.6; otherwise `scale(for: 240×240)`, or 240 over the screen's pixel height for a display with chrome on other platforms. |
| Connection `0x10004E08C`, reading `0x10007B408`, scale `0x10004E988` | Looks up the current screen configuration (`0x10007A9B0`, below) and reads `DevicePreferences[UDID].SimulatorWindowGeometry` (`0x100079EDC`), or `ExternalWindowGeometry` (`0x10007A210`) for a screen that is not the default, at that configuration's `UUIDString`. From that entry it reads `WindowCenter` (`NSPointFromString` of a string) and `WindowScale`; without an entry for the configuration, both count as missing. The scale is 1 for CarPlay, when missing, or when ≤ 0. |
| Screen configuration `0x10007A9B0` | Collects the `frame` of each of `NSScreen.screens` and reads `ScreenConfigurations` (`dictionaryForKey:`) as `[String: [String]]`, or as empty when any value is not a list of strings. The configuration is the first entry, in the dictionary's iteration order, with as many strings as screens where each screen's frame is `CGRectEqualToRect` to one of the entry's `NSRectFromString` rectangles, in any order; its name becomes an `NSUUID` (`initWithUUIDString:`, which traps when it is not a UUID). Without a match, it creates an `NSUUID`, sets `ScreenConfigurations[UUIDString]` to the frames as `NSStringFromRect` strings, and saves the dictionary, so reading the geometry also registers a new configuration. |
| Connected display, main-queue block `0x10004E9F8` … `0x10004F2B8` | Sets `showDeviceChrome` from `ShowChrome` and runs the chrome refresh. After a restart (`isRebooting`, which `-[DeviceCoordinator rebootDeviceWithErase:]` sets), an iOS display of class 0 turns to angle 0 through `0x100053DAC` (the Orientation path below); the block then clears the flag and skips the rest, so the window keeps its scale and takes the upright shape below its top edge (`0x10005BA50`), then moves back inside the visible frame. Otherwise: `renderScale = min(fit, scale)` (`0x10004EDF8`); `deviceRotation` is set to the device's current angle for an iOS device on display class 0 that was booted outside Simulator.app (`wasBootedExternally`, `0x10004EF68`), and to 0 for a device Simulator.app booted (`0x10004F04C`); then the geometry update (`0x10004F064`), so that the window has its final shape before the center: at (0, 0) the cascade `0x10007A95C` (`center` when the app-wide `lastCascadePoint` is zero, then `lastCascadePoint = cascadeTopLeftFromPoint:`), otherwise `setFrameOrigin:` at the center less half the size. Then the chrome refresh, `makeKeyAndOrderFront:`, and the move back inside the visible frame (`0x100038840`). |
| Disconnect `0x10004FDB8` → `0x100050D84`, saving `0x10007B254` | Before `orderOut:`, saves the frame's center as `WindowCenter` (`NSStringFromPoint`) and `renderScale` as `WindowScale` when the window exists and the device is not rebooting. The two form a new dictionary that replaces `SimulatorWindowGeometry[UUIDString]` for the current screen configuration (`0x100073098`); the device's other configurations stay, and the result is written back to `DevicePreferences[UDID]` (`0x100073844`). The closure takes `isRebooting` when it is created (`0x10004F9F0`). `windowExists` is set when the window controller's `window` getter creates the window (`0x1000493BC`) and cleared when the window is set to nil (`0x1000494CC`). |
| Geometry update `0x10005B4A0` → `0x10004B2E4` | Sizes the window's content to the display's `intrinsicContentSize` plus the gap above the display (`0x100036364`), as wide as the display with no minimum, keeping its bottom-left corner, sets the toolbar style for that width, adds the title bar, applies `NSIntegralRect`, and moves it down when its top is above the visible frame, then `setFrame:display:NO animate:NO`. It never sets `renderScale`. The steps are in [Window layout](#window-layout). |
| Rotation `0x10005BA50` | Outside full screen: keeps `renderScale`, runs the geometry update, and sets the origin to the rounded previous x and previous top less the new height, moved down when the top is above the visible frame. Every caller then moves the window back inside the visible frame (`0x100038840`): the guest's rotation (`0x10004DDB8`), `0x10005151C`, Rotate Left and Right (`0x100053D4C`), and the Orientation items (`0x100053F0C`), which the restart path reaches through `0x100053DAC`. |
| Chrome refresh `0x10005AFFC`, from `DWC.setShowChrome:` `0x100048374` (after it sets `showDeviceChrome`), the connection (`0x10004EC68`, `0x10004F170`), `simDisplayView(_:changedChrome:)` (`0x10005F624`), `windowWillEnterFullScreen:` (`0x10004C65C`), and the end of the exit animation once `fullScreenState` is none (`0x10004D6E8`, `0x10004D7D4`) | Gives the window its toolbar the first time (below), runs the title update (`0x10005A90C`) and the geometry update without arguments. With a chrome (both `DWC`'s stored chrome and the chrome view's), removes `NSWindowStyleMaskResizable`, clears the background, and turns the gap flag on; without one, adds it (`styleMask | 0xF`), sets `blackColor` only when `fullScreenState == 3` (`0x10005B1E0`–`0x10005B210`), and turns the gap flag off (`0x10005B24C`, stored at `0x10005B3EC`). Either way it sets the display's top constraint from the flag (`0x100035814`) and runs the geometry update when `fullScreenState == 3` (`0x10005B41C`), so Show Device Bezels keeps the scale. |
| Full screen `0x10004868C` | With `AllowFullscreenMode`, sets `collectionBehavior` to `fullScreenPrimary | fullScreenAllowsTiling` (0x880), which keeps full screen available for a window that is not resizable; otherwise `fullScreenAuxiliary`. |
| Full screen transitions: `windowWillEnterFullScreen:` `0x10004C604` → `0x10004C4D8`, `window:startCustomAnimationToEnterFullScreenOnScreen:withDuration:` `0x10004CC88` → `0x10004C964`, `customWindowsToExitFullScreenForWindow:` `0x10004CDFC` → `0x10004CE60` | Entering saves `renderScale` and the frame's origin, and Simulator.app animates the frame to the screen itself (`animator().setFrame(_:display:)`, `0x10004CB74`–`0x10004CB94`), so a window that is not resizable still fills the screen. Leaving sizes the window to `size(for:)` at the saved scale and animates it back to the saved origin. |
| `DeviceWindow.constrainFrameRect:toScreen:` `0x100037A20` → `0x100037950`, helper `0x100037AC8` | With `screen ?? self.screen` and `windowDraggingInsets.top > 0`: keeps the frame and, when `visibleFrame.maxY < y + height − top × renderScale`, sets `y = visible.minY + (visible.height − (height − top × renderScale))`. Otherwise returns `super` with the original screen argument. `windowDraggingInsets` is `(chrome?.images.padding.height ?? 0, 0, 0, 0)`, set when the chrome changes (`0x100047590`, from `simDisplayView(_:changedChrome:)` `0x10005F4C0`). In the installed bezels the padding is 9 points for iPads and 0 for most iPhones. |

Neither `windowDidChangeScreen:` nor `windowDidChangeBackingProperties:` is
implemented. A screen parameter change (`screenParametersChanged`
`0x100010CF0`, registered for `NSApplicationDidChangeScreenParametersNotification`)
only calls `ensureWindowIsEntirelyOnScreenIfPossible` (`0x100038A6C` →
`0x100038840`) on each existing device window; no scale is reapplied, and the
checkmarks follow the window's screen at the next validation.
`NSUserDefaults(Indigo)` also implements `windowLastScaleForDevice:` and
`setWindowLastScale:forDevice:` (`SimulatorWindowLastScale`), but nothing in
Simulator.app 16.0 calls them.

NeoSimulator reproduces these commands; its differences are listed in the
[design](Design.md#commands-and-menus).

## Window layout

The evidence is Simulator.app 16.0 (1063.4) from Xcode 26.6. `DWC` is
`Simulator.DeviceWindowController`; ivar offsets are the values stored at the
listed addresses.

| Reference owner | Observed behavior |
| --- | --- |
| `DWC` window getter `0x1000492FC` | Creates a `DeviceWindow` with content rect (0, 25, 500, 1200), `styleMask` 0x7 (titled, closable, miniaturizable), buffered, not deferred. Nothing sets `NSWindowStyleMaskFullSizeContentView`, `titlebarAppearsTransparent`, or `titleVisibility`, so the content view sits below the title bar and toolbar. The chrome refresh adds and removes `resizable` (row above). |
| `DeviceWindow` initializer `0x100035880` (from `initWithContentRect:styleMask:backing:defer:` `0x100035A9C`), setup `0x100035B50` | The initializer turns on the gap flag (offset at `0x1000DA3C0`), sets alpha 1, not opaque, and a clear background, then runs the setup: collection behavior 0x100, tabbing disallowed, DarkAqua, `titlebarSeparatorStyle` none, a layer-backed content view, and a `SimDisplayView` created with the content view's bounds and added to it without autoresizing constraints. |
| Constraints, setup `0x100035D84`–`0x100036014` | `display.top = content.top + gap` (`NSLayoutConstraint(item:attribute:relatedBy:toItem:attribute:multiplier:constant:)` through `0x10007BB0C`, kept at `0x1000DA3C8`); `content.bottom`, `content.left`, and `content.right` equal the display's (`0x1000DA3D0`, `0x1000DA3D8`, `0x1000DA3E0`); `display.centerX` and `display.centerY` equal the content's (`0x1000DA3E8`, `0x1000DA3F0`), created inactive. The content view's hugging and compression resistance are 490 on both axes. The display view therefore fills the content view below the gap. |
| Full screen state `didSet` `0x100036184` | Outside full screen (state 3, none), activates the top, bottom, left, and right constraints and deactivates the centers; while entering, in, or leaving full screen, the reverse, so the display keeps its intrinsic size centered in the content view. |
| Gap `0x10003570C`, uses `0x100036364`, `0x100035814`, `0x1000363A4` | The gap is `10 − (chromeView.chrome?.images.padding.height ?? 0)`, at the scale-1 padding whatever the display's scale. `0x100036364` adds it to a content height while the flag is on; `0x100035814` sets the top constraint's constant to it, or to 0 with the flag off. The initializer turns the flag on (`0x100035928`); the chrome refresh turns it on with a chrome and off without one (`0x10005B3D4` / `0x10005B24C`, stored at `0x10005B3EC`) and calls `0x100035814`. `simDisplayView(_:changedChrome:)` runs the chrome refresh (`0x10005F624`) and then sets the constant to the gap whatever the flag (`0x10005F644` → `0x1000363A4`); `setShowChrome:` and the connection run the chrome refresh again after they set `showDeviceChrome`, which reports the chrome change, so the constant ends up following the flag. The gap is 10 points for the iPhone 17 Pro's bezel (padding 9 by 0), 1 point for the iPad bezels (padding 10 by 9), and none without a bezel, where the display meets the title bar. |
| Geometry update `0x10004B2E4(size:origin:)`, from `0x10005B4A0` | A flag (`_updatingToolbarStyle`) ignores calls made while it runs. Without arguments it takes the size and origin of `contentRect(forFrameRect: frame)`. It reads `UseMonobar` and `UseCompactTitleBar` with `boolForKey:` on each call (`0x10004B3F0`, `0x10004B438`) and calls `setToolbarStyle:` (`0x10004B498`) with `unifiedCompact` (4) when `UseCompactTitleBar` is on; otherwise `unified` (3) when `UseMonobar` is on and `_minWidth`, the threshold below, is at most the width (`fcmp`, `cset ls` at `0x10004B41C`), else `expanded` (1). It then sets the title bar's corners (`0x10004B4C0` → `0x100036518`) and, on macOS 26 and later, hides the toolbar's last item when it is a flexible space unless the style is `expanded` (`setHidden:` of `toolbarStyle != 1`, `0x10004B5F4`). It then reads the title bar as `frame.height − contentView.frame.height`, takes `NSIntegralRect(x, y, width, height + title bar)`, moves the frame down when its top is above the visible frame, calls `setFrame:display:NO animate:NO`, and invalidates the shadow. `0x10005B4A0` passes the display's `intrinsicContentSize` plus the gap (for CarPlay, with an adjusted height). Before that, without a chrome it sets `contentAspectRatio` to the screen's pixel size, turned for landscape, and `contentMinSize` to `size(for:)` at the minimum scale; with a chrome it clears both. |
| Toolbar style threshold `0x100049D38` | Stores `_minWidth` (offset at `0x1000DAB70`): `_toolbarItemWidth` (`0x1000DAB68`) plus `_titleTextWidth` (`0x1000DABB8`) plus 130. The first is the sum, over the toolbar's items whose view is an `NSButton`, of the view's width plus 4 (`0x100049F90`–`0x10004A160`), measured once, when the chrome refresh first gives the window its toolbar (`0x10005B274` → `0x100049D70`, only while `window.toolbar` is nil and the screen is the default), before the window shows: 31, 32, and 25 points for the iPhone toolbar nib's Home, Save Screen, and Rotate buttons, and also 27 and 27 for the Keyboard Capture and Pointer Capture buttons of the iPad's, which an iPad that supports `SimFeatureSystemPointer` takes. That setup then sets the toolbar's private `minimumInlineWindowTitleWidth` to 0 (`0x10004A3D8`) and runs the geometry update (`0x10004A3EC`). The second is the wider of the title in `NSFont.preferredFont(forTextStyle: .headline, options: [:])` and the subtitle in `.subheadline`, each measured as an `NSAttributedString`'s `size()` (`0x10005AB70`–`0x10005ADA0`) by the title update `0x10005A90C`, which then recomputes `_minWidth` (`0x10005ADA8`) and sets the subtitle and title; it runs from the chrome refresh (`0x10005B0CC`) and from two observers (`0x100049A60`, `0x100049B28`), and the style follows at the next geometry update. |
| Title bar corners `0x100036518` | Finds the `NSTitlebarContainerView` by walking up from the toolbar's private `_toolbarView` and comparing class names (`0x1000363E4`). While the display view's `showDeviceChrome` is on and `fullScreenState` is none, sets its layer's `cornerRadius` to the window's private `_cornerRadius` on macOS 26 and later (10 earlier), `maskedCorners` to 3, the lower corners, and `masksToBounds`; otherwise only sets the radius to 0. It runs from the geometry update, the toolbar setup (`0x10004A18C`), each `fullScreenState` change (`0x100036198`), and `simDisplayView(_:changedChrome:)` (`0x1000363A4`). |
| `windowDidResize:` `0x10004BEF4` | When `fullScreenState` is none, runs the geometry update without arguments (`0x10004BEB0`), so a resize the geometry update did not make, such as a manual one, takes the style for the new width and keeps the height below the title bar, then invalidates the shadow. |
| Defaults `0x100024F48` (registration at `0x1000253E8`) | Registers `UseMonobar` as YES and `UseCompactTitleBar` as NO among 45 keys; only the geometry update reads them. |
| Toolbar nibs, toolbar setup `0x100049D70` | A watch takes `IndigoWatchToolbar`, or `IndigoWatchAODToolbar` with `SimFeatureAlwaysOnDisplay`; a TV `IndigoTVToolbar`; an iPad that supports `SimFeatureSystemPointer` `IndigoiPadToolbar`; any other device `IndigoiPhoneToolbar`. Every nib has Home (an `NSButton`, `house` described "home", `homeButtonPressed:`) and Save Screen (an `OptionSwitchingButton` in the item the `screenshotToolbarItem` outlet holds). The iPhone and iPad nibs add Rotate (an `OptionSwitchingButton`, outlet `rotateToolbarButton`, item label and tooltip Rotate, `rotate.right` described Rotate Right, `toggleRotationRight:` to the first responder), the iPad nib Capture Pointer and Capture Keyboard, and the always-on watch nib Always On, all three plain `NSButton`s. Each item's tooltip is on its `NSToolbarItemViewer`; the buttons have none until an `OptionSwitchingButton` state sets one, which then shows over the viewer's. |
| `OptionSwitchingButton` `0x10002E3B4`–`0x10002E820` | Keeps an up and a down image, action, optional button type, and optional tooltip. The configuration `0x10002E3B4` stores the images and actions and, unless told to follow Option at once, sets the up action and image. A state (`0x10002E574`; up `0x10002E520`, down `0x10002E550`) sets the image and action, and the type and tooltip when it has them. `optionKeyUp:` and `optionKeyDown:` apply the up and down states. Following Option (`0x10002E6D8`) applies the down state when `NSEvent.modifierFlags` has Option (bit 19) and the up state otherwise, then observes `OptionKeyUp` and `OptionKeyDown` on the default center; `0x10002E7B8` stops observing without changing the state. The only others are the Touch Bar's Touch ID and Face ID buttons (`0x10005D540`). |
| Save Screen button, toolbar setup `0x10004A208`–`0x10004A318` | The setup gives it up: the nib's `camera.on.rectangle`, `saveFramebufferImage:`, momentary push-in (7), and the tooltip Save Screen; and down: `NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Start Recording")`, `toggleVideoRecording:`, toggle (2), and the tooltip Record Screen. It shows the up state, turned off. Without a recording, `toggleVideoRecording:` runs the `startCapturingVideo:` body, which records without a save panel for a sender that is not an alternate menu item (`0x1000589E4`), as File ▸ Record Screen does. |
| Rotate button, toolbar setup `0x10004A198`–`0x10004A204` | Up: the nib's image and `toggleRotationRight:`; down: `NSImage(systemSymbolName: "rotate.left", accessibilityDescription: nil)`, whose description is the symbol's own (Rotate Left in English), and `toggleRotationLeft:`. They are Device ▸ Rotate Right's and Rotate Left's actions. Neither state has a type or tooltip, so the button keeps its type and the item's tooltip, Rotate. |
| `SimToolbar` pointer tracking `0x10002C434`, `mouseEntered:` `0x10002C56C`, `mouseExited:` `0x10002C61C` | The setup sets the toolbar's weak `trackingDelegate` to the window controller (`0x10004A370`–`0x10004A390`) and adds an `NSTrackingArea` to the toolbar's private `_toolbarView` (`0x10004A398` → `0x10002C434`), with its bounds, options 0x241 (entered and exited, active in the active app, in the visible rectangle), and the toolbar as owner. `mouseEntered:` calls the delegate's `0x10005F848`: unless `isCapturingVideo`, the Save Screen button follows Option; the Rotate button always does. `mouseExited:` calls `0x10005F8CC`: unless `isCapturingVideo`, the Save Screen button stops following and takes the up state; so does the Rotate button, always. Nothing else starts or stops the following besides the recording paths below. |
| AppKit tracking (macOS 26.6.2), `-[_NSTrackingAreaAKManager _updateActiveTrackingAreasForWindowLocation:modifierFlags:]` | An area in the visible rectangle covers the view's `_interactiveBounds`: for `_toolbarView`, the whole title bar with the `unified` (52 points) and `unifiedCompact` (40) styles, including the window buttons and the title, and the 44-point row below the title with `expanded`. An area active in the active app is active while the pointer is in it and `NSApp.isActive`, in any window. `activateTrackingRectsForApplicationActivation` and `deactivateTrackingRectsForApplicationDeactivation` do nothing for this manager; the next update, from a pointer movement over the window (`_mouseMoved:`) or the pointer leaving it (`_routeEnterExitEvent:`), sends `mouseExited:` once the app has resigned active and `mouseEntered:` once it is active again, with the modifier flags of that movement or `NSEvent.modifierFlags`. |
| Recording, `startCapturingVideo:` body `0x1000587FC`, `stopCapturingVideo:` body `0x100059764` | The toolbar has no Stop Recording item. Before its save panel or recorder, Record Screen stops the button from following Option (`0x10002E7B8`), gives it the down state (`0x10002E550`), turns it on (`0x1000588EC`), and sets `NSImage(systemSymbolName: "stop.circle", accessibilityDescription: "Stop Recording")` with no configuration or tint (`0x1000588F8`) and the tooltip Stop Recording (`0x100058948`). The toggle type has no alternate image, so the on state shows that image. A click, with or without Option, sends `toggleVideoRecording:` (`0x1000587D4`), which stops the recording while `isCapturingVideo` is set. Stop clears `isCapturingVideo` and, before the recorder finishes, turns the button off and lets it follow Option again (`0x10005983C`–`0x100059840`), which shows the up state unless Option is down; a cancelled save panel (`0x100058D88`–`0x100058D90`) and the dismissal of the error that a failed recorder start shows (`0x100059644`–`0x10005964C`) do the same. None of them checks the pointer, so the button then follows Option anywhere until the pointer next leaves the toolbar. The Rotate button follows Option throughout. The item stays, its width counts in the threshold as before, and nothing measures the toolbar again. File ▸ Record Screen is enabled while `isCapturingVideo` is off and Stop Recording while it is on (`0x100052560`, `0x100052584`). |

Measured on macOS 26.6 with Simulator.app's own `IndigoiPhoneToolbar.nib`
and `IndigoiPadToolbar.nib` in a window built as above, the title bar is 52
points with the `unified` style, 76 with `expanded`, and 40 with
`unifiedCompact`, and the window's `_cornerRadius` is 26, 16, and 20 points.
Right after `setToolbarStyle:`, before AppKit lays the title bar out, a
switch to `expanded` reads 84 points (72 from `unifiedCompact`); the window
still ends up with 76 points above its content, because AppKit keeps the
content size when it lays the title bar out. Right after
`setToolbar:`, before the window shows, the buttons still have the nib's
widths, so the threshold is 317.3 points for an iPhone 17 Pro titled
"iPhone 17 Pro" with the subtitle "iOS 26.5", and 413.4 for an iPad mini
(A17 Pro). With `minimumInlineWindowTitleWidth` at 0, a unified title bar
320 points wide shows all three iPhone buttons and truncates the title;
with AppKit's default, it shows none of them at that width and only Home
at 402 points. With a clear window background, AppKit draws the title bar
as a solid `NSTitlebarBackgroundView` (sRGB 0.118 gray in DarkAqua); with
a black one, it adds a scroll pocket with the `contentBackground` material.
A window with a full-size content view and a title bar that is not
transparent draws both the same way. AppKit itself gives an `NSWindow` an integral frame: it rounds the
origin down and the size up, which equals `NSIntegralRect` whenever the
origin is integral or the origin's fraction and the size's add up to a whole
point. When a `SimDisplayView` is up to a point larger than `size(for:)` at
its scale, SimulatorKit keeps the bezel, the screen, and the digitizer at
the view's lower-left corner, rounded to half points.

NeoSimulator's window keeps its full-size content view, whose
`contentLayoutRect` inset is the title bar, and lets AppKit draw the title
bar, which is no longer transparent, so that its background matches with
and without a bezel. Its geometry update chooses the toolbar style as above
from the widths of its own buttons in Simulator.app's nibs, lays the title
bar out before it reads the height, and runs on a resize it did not make, as
`windowDidResize:` does. Like Simulator.app, it sets the toolbar's
`minimumInlineWindowTitleWidth` to 0 and rounds the lower corners of the
title bar container with the window's `_cornerRadius`; it finds the
container as the close button's ancestor among the frame view's subviews. The gap, the black
background, the display filling the window below the gap, and the fit
checks follow the table above; the differences are listed in the
[design](Design.md#commands-and-menus).

## Bezel resizing and moving

The evidence is Simulator.app 16.0 (1063.4) from Xcode 26.6 and SimulatorKit
from Xcode 27.1. Simulator.app's `DeviceWindow` tracks a drag on a corner of
the bezel itself, and leaves a drag elsewhere on the bezel to the window
server; its window is not resizable while it shows a bezel.

| Reference owner | Observed behavior |
| --- | --- |
| `DeviceWindow.mouseDown:` `0x100037290` → `0x100036E70` | In full screen (`styleMask` bit 14) without a chrome, skips the corners; otherwise looks for the first of `displayView.typedResizeRects` whose `rect` contains `event.locationInWindow` (the display view sits at the window's origin). On a corner: sets `_allowResize`; saves `_initialFrame` (`contentRect(forFrameRect: frame)` with the display view's height), `_initialScale` (`renderScale`), `_initialMouse` (`NSEvent.mouseLocation`), `_resizeRectType`, and `_maxResizeScale` (`0x100037BB0`); calls `beginResize()` and posts `NSWindowWillStartLiveResizeNotification`. Then (`0x100037208`), unless `_allowResize` is set, reads `[[NSUserDefaults standardUserDefaults] boolForKey:@"AllowsMoveByDragOnWindowChrome"]` (`0x100037234`) and, when it is YES, calls `performWindowDragWithEvent:` with the event (`0x10003724C`), also in full screen. It never calls `super`. |
| Maximum `0x100037BB0` | `scale(for:)` of the size from the opposite corner of `_initialFrame` to the edges of `(screen ?? NSScreen.main).visibleFrame`: width `initial.maxX − visible.minX` for the left corners, `visible.maxX − initial.minX` for the right; height `initial.maxY − visible.minY` for the lower corners, `visible.maxY − initial.minY` for the upper. 1000 without a screen. |
| `DeviceWindow.mouseDragged:` `0x100037860` → `0x100037448` | Without a chrome or `_allowResize`, calls `super`. Otherwise the width is the initial width minus the pointer's x movement (`NSEvent.mouseLocation − _initialMouse`) for the left corners and plus it for the right; the height minus the y movement for the lower corners and plus it for the upper. Sets `renderScale = min(_maxResizeScale, max(minimum, scale(for: size)))` with the minimum of the scale commands (`0x100047884`), then calls the geometry update (`0x10004B2E4`) with the content size of the display's `intrinsicContentSize` plus the gap above the display (`0x1000377CC` → `0x100036364`) and the origin that keeps the display's opposite corner, computed from the display's size alone: `x = initial.maxX − width` for the left corners, else `initial.minX`; `y = initial.maxY − height` for the lower corners, else `initial.minY`. |
| `DeviceWindow.mouseUp:` `0x1000373F8` → `0x1000372E0` | Without a chrome or `_allowResize`, calls `super`. Otherwise calls `endResize()`, clears `_allowResize`, posts `NSWindowDidEndLiveResizeNotification` (so `DWC.windowDidEndLiveResize:` sets `renderScale` from the display view's frame), and runs `0x10003853C`: outside full screen, when the frame does not intersect the visible frame inset by 128 points (`0x100038638`), moves it along each axis until it touches that inset frame. |
| Geometry update `0x10004B2E4(size:origin:)` | Both arguments are optional; without them it uses the current content rect. The frame is the content size plus the title bar at the origin, `NSIntegralRect`, moved down when its top is above the visible frame, then `setFrame:display:NO animate:NO`. A flag ignores calls made while it runs, such as from `windowDidResize:`. |
| Resize cursors: the window's setup `0x100035B50` (from `awakeFromNib` and the initializer), `fullScreenState` `didSet` `0x100036184` | The setup turns `displayView.showResizeCursors` on (`0x100036010`); each full screen change sets it to `fullScreenState == none`, followed by `invalidateCursorRectsForView:`. |
| Defaults dictionary `0x1000250B4` … `0x1000253AC`, `registerDefaults:` `0x1000253E8` | Registers `AllowsMoveByDragOnWindowChrome` YES (key at `0x1000252C4`, `kCFBooleanTrue` at `0x1000252BC`). The Settings bundle does not list it. |
| Views under a press outside the display view: setup `0x100035B50`, `DeviceWindow.sendEvent:` `0x100036E20` → `0x100036D60` | The content view is the window's own `NSView`. Below the display view, the setup adds `blurredBackgroundContainerView` (an `NSView` with alpha 0 and the content view's frame, `0x100035C0C`–`0x100035C4C`) holding `visualEffectView` (an `NSVisualEffectView` with the container's frame, `0x100035C50`–`0x100035C98`). AppKit's hit test does not skip a view with alpha 0, so a press in the gap above the display view hits the effect view; `NSVisualEffectView` takes `NSView`'s `mouseDown:`, `hitTest:`, and `mouseDownCanMoveWindow`, and none of these views is Simulator.app's own class. `sendEvent:` only drops an event equal to the previous one (`_previousEvent`) before calling `super`. The press therefore reaches `DeviceWindow.mouseDown:`, which moves the window. |
| Setup `0x100036024`–`0x100036040` | Sets the content view's layer's private `hitTestsContentsAlphaChannel` to YES. AppKit's backing layer (`NSViewBackingLayer`) already has it on. |
| AppKit (macOS 26.6.2) `-[NSWindow performWindowDragWithEvent:]` | Calls `_beginWindowDragWithEvent:options:completionHandler:`, which passes the event's location in the window to `_dragWindowRelativeToMouseDown:options:completionHandler:`; that reaches SkyLight's `SLSPackagesDragWindowRelativeToMouse` through `_dragWindowRelativeToMouseDown:options:`, so the window server moves the window for the rest of the drag. |

SimulatorKit (Xcode 27.1):

| Owner | Observed behavior |
| --- | --- |
| `typedResizeRects` getter `0x63F7C` | Empty without a chrome. Otherwise one `TypedResizeRect` (`type`, `rect`) per entry of `SimDeviceChrome.resizeRects` (`chrome.json`'s `resizeRects`: `type`, `scales`, `centerPoint`, `size`): the size is multiplied by `renderScale` when `scales` is set, the center plus the chrome images' `padding` by `renderScale`, and a negative center coordinate, whose padding is negated, counts from the view's frame width or height. The rects are in the display view's coordinates. The iPhone 17 Pro's bezel has two rects at each corner, such as 40 by 20 and 20 by 40 points at scale 1. |
| `SimDeviceChrome.ResizeRectType` | Cases `lowerLeft` 0, `lowerRight` 1, `upperRight` 2, `upperLeft` 3, whose raw values are their names. |
| `SimChromeResizeRectsExcludeView`, created in `SimDisplayView.init` (`0x660B8`); `hitTest:` `0x34684` → `0x34504` | Returns itself for a point inside any `typedResizeRects` while the chrome exists, otherwise nil. It does not handle the mouse, so the press reaches the window through the responder chain. |
| `resetCursorRects` `0x6440C` → `0x642D0` | When `showResizeCursors` is on (it starts off), adds `_windowResizeNorthEastSouthWestCursor` over the `lowerLeft` and `upperRight` rects and `_windowResizeNorthWestSouthEastCursor` over the others. |
| `SimDigitizerInputView.hitTest:` `0x1E4B0` → `0x1E2A8` | Returns `super`'s result, except nil for a point that a view of `edgeSwipeExcludedViews` hits. |
| `EventHandlingView` event methods, such as `mouseDown:` `0x2CA1C`, → `0x2C7C4` | Call `handleEvent(_:)` (vtable offset `0x70`; the digitizer's is `0x1E510`). An event it returns goes to `super`'s method for the event's type through `objc_msgSendSuper2` (`0x2C4AC`), so `NSView` passes it up the responder chain. |
| `SimChromeButton.mouseDown:` `0x31328` | Tracks the press itself in a `nextEventMatchingMask:` loop for mouse up, drag, and periodic events (`0x31178`). |
| `SimDigitizerInputView.ignoreInsetDragAwayFromFramebuffer`, `ignoreInsetDragMinimumDistance` | Neither Simulator.app nor NeoSimulator sets them. Xcode 26.6's SimulatorKit has the same members. |
| `SimDisplayView.init(frame:)` `0x65F0C` (through `0x6CF78`); `updateConstraints` `0x675F0` → `0x66DC0` | `edgeSwipeInsets` starts at 24 points and `minimumEdgeSwipeInsets` at 5 on each side. With a chrome, `updateConstraints` makes the digitizer the screen plus, on each side, the larger of `edgeSwipeInsets × renderScale` and `minimumEdgeSwipeInsets` (`0x674A0`…`0x6751C`), and sets the digitizer's `screenInset` to those insets (`0x675B8`). Without one (`chromeView.chrome` nil, `0x66ED4`), it makes the digitizer fill the display view and sets `screenInset` to zero (`0x66FD8`…`0x66FE4`). Nothing else reads the two insets. Xcode 26.6's SimulatorKit does the same in `updateConstraints` (body `0x38A50`: chrome check `0x38B68`, zero inset `0x38C78`, insets `0x39150`…`0x391B4`). |
| `SimDigitizerInputView` event handler `0x1E510`, `screenRect` getter `0x1B838`, touch start `0x1FDF4` (second touch `0x2039C`), nearest edge `0x1F52C` | `screenRect` is the bounds inset by `screenInset`. A press counts as on the screen when `screenRect` contains it (`CGRectContainsPoint`, `0x1E7BC`) and `hitMask` is nil or lets it through (`0x1ECE4`); no SimulatorKit code sets `hitMask` outside the initializers and teardown. A touch that starts off the screen is given the side of the digitizer nearest to its start point, after the point is turned with the device (`0x1F740`…`0x1F7A0`); one that starts on the screen has no edge (`0x1FEBC`). Xcode 26.6's SimulatorKit does the same (touch start `0x655D8` and `0x65B70`, nearest edge `0x64D4C`). |

A live check through NeoSimulator's own code (an iOS 26.5 iPhone 17 Pro at
Point Accurate, SimulatorKit from Xcode 27.1) showed which presses SimulatorKit
passes on. In the 456 by 910 point display view, the bezel's image
(`SimDisplayChromeRenderView`) spans x 9 to 447, the screen is at (27, 18, 402,
874), and the digitizer at (3, −6, 450, 922), with
`ignoreInsetDragAwayFromFramebuffer` on and `ignoreInsetDragMinimumDistance`
5. Each press went to the view that `hitTest:` returned, as AppKit gives it in
a key window:

| Press | Reached the window |
| --- | --- |
| At x 1.5, left of the bezel's image and outside the digitizer (`SimDisplayChromeView`) | At once |
| On the bezel 12 points left of the screen, released in place, or moved 4 points away from the screen, 60 points along its edge, or 30 points toward it | No; the digitizer kept it |
| The same press moved 60 points away from the screen, or a press below the screen moved 60 points down | Yes, as its original mouse down |
| A swipe on the screen | No; the guest's screenshot changed from a Home Screen page to the App Library |
| A corner (`SimChromeResizeRectsExcludeView`) | Yes, as a corner drag |

On each button, `hitTest:` returns `SimChromeButton` on the part outside the
bezel's image and the digitizer on the part over it.

The digitizer's 24-point margin around the screen in that check is
`edgeSwipeInsets` at scale 1, and only a touch that starts in that margin
carries an edge. A window without a bezel has no margin. With the bezel
hidden, the same iPhone's digitizer was the display view's 402 by 874 points
with `screenInset` zero, and drags that started 1 and 4 points above the
bottom edge reached the guest as ordinary touches and did not go home (see
[watchOS, tvOS, and visionOS](#watchos-tvos-and-visionos)). Simulator.app 16.0
lays out a window without a bezel the same way, with the display view at its
`intrinsicContentSize` and no gap (see [Window layout](#window-layout)), and
sets none of `edgeSwipeInsets`, `minimumEdgeSwipeInsets`, or `screenInset`;
it imports none of their accessors. In Simulator.app too, a swipe from the
edge of such a window therefore starts on the screen and reaches the guest as
an ordinary touch, so the swipe up from the bottom edge does not go home there
either; Home stays available in the Device menu and the toolbar. UIKit's edge
region for state 0 of `SimulatorWantsEdgeSwipes`, which needs no edge from
the digitizer, serves only the iPad software keyboard. NeoSimulator keeps this
layout.

The window server chooses the window before AppKit's hit test.
`NSWindow.windowNumber(at:belowWindowWithWindowNumber:)` names the window
that a mouse down at a point would hit; it was read with an opaque window
right behind the device window and both above other apps' windows, without
posting events. It named the device window for x 1.5, a point outside the
bezel image's rounded corner, the bezel image, the screen, and the header's
capsule, and the window behind for the gap below the header and for the
header rectangle's corner outside the capsule. Turning the content view
layer's `hitTestsContentsAlphaChannel` on or off changed none of these. A
window rebuilt as Simulator.app builds its own (titled without a full-size
content view, clear, the alpha-0 container with an `NSVisualEffectView`, the
flag set, and an opaque view 10 points below the content view's top) gave the
window behind for the gap, where AppKit's hit test returns the
`NSVisualEffectView`, with the flag on or off.

NeoSimulator reads `typedResizeRects` through ABIBridge: the getter returns
the array as a runtime value, `Array.count` and `Array.subscript` bound to
`TypedResizeRect` read its elements, and `TypedResizeRect.rect`, `type`, and
`ResizeRectType.rawValue` read each one. `DeviceWindow` passes the mouse
events that reach it to `DeviceWindowController`, which tracks a corner drag
as above. For any other press while `AllowsMoveByDragOnWindowChrome` is on,
it calls `performDrag(with:)`. Unlike
Simulator.app, it converts the press to the display view's coordinates, reads
the pointer from each event's `CGEvent` location instead of
`NSEvent.mouseLocation`, does not post the live resize notifications, and
starts no drag of either kind in full screen. The user-visible differences are
listed in the [design](Design.md#commands-and-menus).

## Keyboard and touch pressure

The evidence is Simulator.app 16.0 (1063.4) from Xcode 26.6, SimulatorKit from
Xcode 27.1, and CoreSimulator 1174.9.2. `SimFeatureKeyboard` is
`com.apple.hid.keyboard` and `SimFeatureTouchPressure` is
`com.apple.hid.touch-pressure`. In `MainMenu.nib`, I/O ▸ Keyboard lists Use the
Same Keyboard Language as macOS, Connect Hardware Keyboard (`K` with Command,
so Shift-Command-K), and Toggle Software Keyboard (Command-K); I/O ▸ Touch
Pressure (tag 2020) lists Use Trackpad Force, Shallow Press (Shift-Command-1),
and Deep Press (Shift-Command-2). Neither submenu has separators, and Touch
Pressure follows Keyboard before the separator above Audio Input.

| Reference owner | Observed behavior |
| --- | --- |
| Defaults `0x1000250A0` … `0x1000253E8` | Registers `EnableKeyboardSync`, `ConnectHardwareKeyboard`, and `UseTrackpadForce` as YES in the standard defaults. |
| `-[DeviceCoordinator deviceWindowBecameKey:]` `0x100019B0C`, at `0x10001A4CC` and `0x10001A568` | Hides the Keyboard submenu (and Send Keyboard Input to Device) without `SimFeatureKeyboard`, and the Touch Pressure submenu without `SimFeatureTouchPressure`. |
| Device preference getter `0x100079D64` | `DevicePreferences[UDID]` (`dictionaryForKey:`) cast to `[String: Any]`, then `ConnectHardwareKeyboard` cast to `Bool`; YES when any step is missing or not of that type. The app-wide `ConnectHardwareKeyboard` is not read. |
| Device preference setter `0x100073A70` | Sets `DevicePreferences[UDID].ConnectHardwareKeyboard` to a Boolean, keeping the device's other entries and the other devices, and writes `DevicePreferences` back. |
| `DWC.validateMenuItem:` `0x1000523B4`, `0x100052460` | Connect Hardware Keyboard: enabled with `SimFeatureKeyboard`; checked with the feature and the device's preference. Toggle Software Keyboard: enabled with the feature and the device's preference (a connected hardware keyboard); its state is not set. |
| `DWC.toggleHardwareKeyboard:` `0x10005571C`, body `0x100055310` | Saves the negation of the device's preference (`0x100073A70`), calls `KeyboardController.updateMode` (`0x100073F74`), reads the preference again, and on a global queue (`0x100055564`) calls `setHardwareKeyboardEnabled:keyboardType:error:` with `IndigoHIDGetKeyboardType()`, trapping on a type above 0xFF. A failure is printed ("Failed to toggle hardware keyboard state: …"); nothing is shown and the preference stays. |
| `KeyboardController` (`_TtC9Simulator18KeyboardController`), `becomeKey(coordinator:)` `0x100073C30`, `updateMode` `0x100073F74` → `0x1000740FC` | Mode 1 while a key device coordinator's device has `SimFeatureKeyboard` and its preference is on, otherwise 0. `SimKeyboardInputController.isEnabled` follows mode 1, so the Mac's keyboard types into the device only while its hardware keyboard is connected; the pasteboard shortcut group is enabled in mode 0. |
| `-[DeviceCoordinator _onSessionQueue_connect]` `0x10001B314`, main-queue block `0x10001B97C` → `0x10001BABC` | Each connection, including after a restart: with `EnableKeyboardSync`, calls `updateKeyboardLayoutToMatchHost` (`0x10001B82C`); then reads the app-wide `boolForKey:@"ConnectHardwareKeyboard"` (`0x10001B9F4`) and, on a global queue, calls `setHardwareKeyboardEnabled:` with it, `IndigoHIDGetKeyboardType()`, and a NULL error. The device's own preference is not read here. |
| `-[DeviceCoordinator makeWindowGroupKeyAndOrderFront:]` `0x100019A28` | Called once from `connectAsync` (`0x10001B2B8`); after `makeKeyAndOrderFront:`, calls `updateKeyboardLayoutToMatchHost` again with `EnableKeyboardSync`. |
| `-[DeviceCoordinator validateMenuItem:]` keyboard branch `0x10001F4C0`; `toggleKeyboardSync:` `0x1000207D4` | Enabled with `deviceSupportsKeyboard` (`SimFeatureKeyboard`) and checked from `EnableKeyboardSync`; otherwise disabled and unchecked. The action flips `EnableKeyboardSync` and synchronizes the defaults; it sends nothing to the device. |
| `-[SimDevice(KeyboardSync) updateKeyboardLayoutToMatchHost]` `0x100022D7C` | On the main queue: `TISCopyCurrentKeyboardInputSource`, `kTISPropertyInputSourceLanguages`, and the array's first element; an empty array logs "KEYBOARD: Unable to determine keyboard layout". Otherwise, on a global queue (`0x100022F28`), `setKeyboardLanguage:error:` with a NULL error. |
| `keyboardSelectionDidChangeNotification:` `0x100026A8C`, registered at `0x10002576C` | For `NSTextInputContextKeyboardSelectionDidChangeNotification`: with `EnableKeyboardSync`, calls `updateKeyboardLayoutToMatchHost` on the key device coordinator's device only. |
| `SimulatorAppDelegate.validateMenuItem:` `0x100012350`, `0x100012380`, `0x1000123D4` | The key device's coordinator decides. Use Trackpad Force: enabled with `SimFeatureTouchPressure` and `forceTouchTrackpadAvailable`, checked from `useForceTrackpadFor3DTouch`. Shallow and Deep Press: enabled with the feature and `productFamilyID` 4 (watch), checked from `touchesAreDeep` (Shallow from its negation). A disabled item is unchecked. None needs a booted device. |
| `useForceTrackpadFor3DTouch` `0x10001522C` / setter `0x100015294`; `toggleTrackpadFor3DTouch:` `0x100012C1C` | The getter is `UseTrackpadForce && forceTouchTrackpadAvailable`. The action sets the negation of the getter; the setter saves `UseTrackpadForce` and sends it to the window controller of every device coordinator whose `windowExists` and whose device has `SimFeatureTouchPressure` (`DWC.setUseForceTrackpadFor3DTouch:` `0x100047DAC` → `SimDigitizerInputView.useForceTrackpadForPressure`). |
| `setTouchPressureShallow:` `0x100012BE8`, `setTouchPressureDeep:` `0x100012BB4`, `setTouchesAreDeep:` `0x100014FF8` | Set the app delegate's `touchesAreDeep` (NO at launch, `0x10000ED80`, never saved) and send it to the same windows (`DWC.setTouchesAreDeep:` `0x100047F1C` → `simulatedTouchMode` 0 or 1, the raw values of `SimDigitizerInputView.TouchMode`). |
| `forceTouchTrackpadAvailable` `0x100015664`, HID client `0x100015500` | The client is `IOHIDEventSystemClientCreate` matching `PrimaryUsagePage` 13 and `PrimaryUsage` 12 (a multiple-point digitizer). Each call copies its services and returns YES when the registry entry of a service's `IOHIDServiceClientGetRegistryID` has `ForceSupported` true; nothing is cached. |
| Window setup `0x10004A6F8` … `0x10004A734`; `connectTo:completionQueue:completion:` `0x10004DE68`, at `0x10004E480` … `0x10004E550` | The window sets its digitizer's `useForceTrackpadForPressure` from `useForceTrackpadFor3DTouch`. Each display connection sets `supportTouchPressure` to `SimFeatureTouchPressure` on display class 0 and NO on other screens. `simulatedTouchMode` is not set, so a new display is shallow whatever the menu shows. |

SimulatorKit exports `IndigoHIDGetKeyboardType` and dispatch thunks for
`SimDigitizerInputView.supportTouchPressure`, `useForceTrackpadForPressure`,
and `simulatedTouchMode` (a `TouchMode` with `Int` raw values). CoreSimulator's
`setHardwareKeyboardEnabled:keyboardType:error:` takes a Boolean and a byte
(`B32@0:8B16C20^@24`), and `setKeyboardLanguage:error:` a language string.
Touch pressure exists only on device types with `SupportsForceTouch`, such as
the iPhone XS on iOS 18 and the Apple Watch Series 2 to 5, which the installed
watchOS 26.5 runtime does not run. On iOS 26.5, `setKeyboardLanguage:` with `de`
selects `de_AT@sw=QWERTZ-German` as the guest's `KeyboardLastUsed` and adds it to
`AppleKeyboards`; it takes 0.2 to 0.5 seconds, `setHardwareKeyboardEnabled:`
a few milliseconds.

NeoSimulator reproduces these commands; its differences are listed in the
[design](Design.md#keyboard-and-touch-pressure).

## Settings and touch indicators

The evidence is Simulator.app 16.0 (1063.4) from Xcode 26.6, AppKit of macOS
26.6.2 (25G83), and SimulatorKit from Xcode 27.1. `MainMenu.nib` has
Simulator ▸ Preferences… (Command-,) sending `orderFrontPreferencesPanel:` to
the first responder; no class of Simulator.app implements it.

| Reference owner | Observed behavior |
| --- | --- |
| AppKit `-[NSApplication(NSSimplePreferences) orderFrontPreferencesPanel:]` | Asks the delegate's `applicationOrderFrontPreferencesPanel:`; unless it returns YES, calls `[[NSSimplePreferences sharedPreferences] showPreferencesPanel]`. The category is in no public header. |
| `-[NSSimplePreferences settingsBundlePathToUse]`, `loadFromSettingsBundle`, `showPreferencesPanelForOwner:` | Uses `Settings.bundle` from the main bundle (or a bundle given to `+setBundleToSearch:`) and adds one pane from its `Root.plist`. Without the bundle it logs that nothing will be displayed. |
| `-[NSSimplePreferences _viewForItems:rootBundle:module:]` | Lays out `PSGroupSpecifier` titles as labels, `PSToggleSwitchSpecifier` as checkboxes, and `PSRadioGroupSpecifier` as radio buttons, binds each to `NSUserDefaultsController.sharedUserDefaultsController` at `values.<Key>`, and sets the controller's `initialValues` from each item's `DefaultValue`. |
| `Settings.bundle/Root.plist` | One flat pane: an untitled group with the stop-capture shortcut (`CaptureEscapeKeyCodes`: `[41]` esc, `[227,231]` both Command keys, `[224,226,65535]` Control-Option); Simulator lifetime (`StartLastDeviceOnLaunch`, `DetachOnWindowClose`, `DetachOnAppQuit`); Visual indicators (`ShowSingleTouches`, `ShowPinches`, `ScreenShotUseMask`); `GifMaxFrameSize` 320/640/1280; `GifMaxFramerate` 10/15. `ShowPinches` has `DefaultValue` false. |
| `+[PreferencesController registerDefaults]` `0x100024F48` … `0x1000253E8` | Registers `ShowSingleTouches` NO, `ShowPinches` YES, `ShowPinchPivotPoint` NO, `HighlightEdgeGestures` NO, and the other settings with the Settings.bundle's defaults. |
| `DWC` window creation `0x10004A59C`, from the `window` getter `0x1000492C8`, at `0x10004A794` … `0x10004A834` | Reads the four preferences (`NSUserDefaults(Indigo)` `0x10003A1F0` onward) and inserts or removes `.normalTouch`, `.pinchTouches`, `.pinchPivotPoint`, and `.edgeGestures` in `digitizerView.drawOptions` through `drawOptions.modify` (`0x100048A24`). Then it observes `NSUserDefaultsDidChangeNotification` on the main queue (`0x10004A9CC`). |
| Observer `0x10004AA5C` | While the window exists, reapplies `ShowPinches` and `ShowSingleTouches` only, then updates the window's geometry (`0x10004B2E4`); once the window controller is gone, it removes itself. |
| Internal menu, tag 7000; `toggleShowSingleTouches:` `0x100012C5C`, `toggleShowPinches:` `0x100012EA0`, `toggleShowPinchPivotPoint:` `0x1000130E4`, `toggleHighlightEdgeGestures:` `0x100013328` | `applicationDidFinishLaunching:` hides the menu unless `os_variant_has_internal_ui` (`0x10000EDD0`). Each action saves the negation of the preference and calls `DWC.setShowSingleTouches:` (`0x100048024`) and its siblings on every window controller whose `windowExists`. |

A registered value wins over the controller's initial value: in a probe on
macOS 26.6.2, a key registered YES with an initial value of NO read 1 through
`values`, and a key with no registered value read the initial value. So
Simulator.app's panel shows Show pinch gestures checked, and pinches are drawn.
Foundation posts `NSUserDefaultsDidChangeNotification` only for changes the
process makes, so by its code Simulator.app applies a `defaults write` to open
windows only when it next changes a default itself or opens a window; this was
not run.

SimulatorKit from Xcode 27.0, 27.1, and 27.2 exports `drawOptions` getter and
setter dispatch thunks, `DrawOption.rawValue`, `DrawOption(rawValue:)`, and the
four options' static getters. With Xcode 27.1, their raw values are 0x2, 0x4,
0x8, and 0x10, and a new iOS 26.5 display starts with `drawOptions` 0x24:
`.pinchTouches` and `.lockedTouches` (0x20).

NeoSimulator's settings window and touch indicators are described, with their
differences, in the [design](Design.md#settings-and-touch-indicators).

## Pasteboard

The evidence is Simulator.app 16.0 (1063.4) from Xcode 26.6, `simctl` and
`SimPasteboardPlus` from CoreSimulator 1174.9.2, and iOS 26.5 iPhones in a
separate device set; for synchronization, two of them and a guest app that
copies with `UIPasteboard`. In `MainMenu.nib`, the Edit menu ends with a
separator after Paste, then Automatically Sync Pasteboard
(`togglePasteboardAutomaticSync:`), Get Pasteboard, and Send Pasteboard,
without shortcuts. `DC` is `DeviceCoordinator`.

| Reference owner | Observed behavior |
| --- | --- |
| `DC.validateMenuItem:` `0x10001F160` … `0x10001F528` | Get and Send Pasteboard are enabled when `productFamilyID` is 1, 2, or 7, `pasteboardInterface` is not nil, and the app delegate's `isSynchronizingPasteboards` is off; otherwise disabled, never hidden, with no checkmark. |
| `DC.getPasteboard:` `0x10001FC3C` | On the main queue, sends `pull` to `pasteboardInterface`. |
| `DC.sendPasteboard:` `0x10001FC80` | When `NSPasteboard.generalPasteboard.changeCount` equals `lastSyncedPasteboardSnapshotLocalGeneration`, logs "Pasteboard for device %@ is unchanged since last push from device, refusing to loop it back." and stops; otherwise sends `push`. |
| `DC._onSessionQueue_resetPasteboardInterfaceWithInitialPush:` `0x10001E5FC` | Sets `pasteboardInterface` to nil. For a connected device of family 1, 2, or 7 (otherwise it logs "we're detaching from the device" or "the device doesn't support pasteboards"), calls `SimDevice lookup:error:` with `SimPasteboardInterfaceListener.machServiceName`. A port that is `MACH_PORT_NULL` or `MACH_PORT_DEAD` logs "Failed to lookup pasteboard Mach service in device %@: %@" and leaves the interface nil. Otherwise it creates `initWithConnectingToPort:managingPasteboard:delegate:delegateQueue:` with the general pasteboard, the coordinator, and the main queue. On the main queue it then calls `updatePasteboardAutosyncStatus:` with `isSynchronizingPasteboards` and, when asked for an initial push and synchronizing, `push`. |
| Callers | `_onSessionQueue_connect` passes YES after `setConnected:YES` (`0x10001B894`); `simPasteboardDidLoseConnection:` `0x10001EBB4` logs and passes NO on the session queue. |
| `DC.updatePasteboardAutosyncStatus:` `0x10001FD68` | Sends `enableRemoteAutosync` or `disableRemoteAutosync`. |
| Delegate callbacks `0x10001EB3C` … `0x10001F0B8` | `simPasteboardDidBecomeActive:` logs. `simPasteboardShouldApplySnapshot:…` logs and returns YES. `simPasteboardDidApplySnapshot:…`, on the main queue, saves the sender's UUID and the `atGeneration` argument as `lastSyncedPasteboardSnapshotSender` and `lastSyncedPasteboardSnapshotLocalGeneration`, then enqueues `SimDeviceChangedLocalPasteboard` with the device on `NSNotificationQueue.defaultQueue`, with `NSPostASAP` and `NSNotificationCoalescingOnName`. Nothing reads the sender. `simPasteboardErrorApplyingSnapshot:…` logs the error, saves the sender, and sets the generation to -1. `simPasteboardDidChangeAutoNotifyState:…` raises an assertion, "Device coordinator is out of sync with remote pasteboard interface.", when the state differs from `isSynchronizingPasteboards`. No failure reaches the user. |
| `SimulatorAppDelegate.togglePasteboardAutomaticSync:` `0x100012ABC` | Sends a `com.apple.simulator.menu` msgtracer message with `on` or `off`, then `setSynchronizingPasteboards:` with the opposite of `isSynchronizingPasteboards`. |
| `SimulatorAppDelegate.setSynchronizingPasteboards:` `0x1000104C8` | Returns when the value does not change. Otherwise it saves `PasteboardAutomaticSync` (registered YES), adds a `SimDeviceChangedLocalPasteboard` observer on the main queue when on or removes it when off, and sends `updatePasteboardAutosyncStatus:` to every coordinator. The observer sends `sendPasteboard:` to every coordinator whose device's UDID differs from the notification object's. `applicationDidFinishLaunching:` calls it with `boolForKey:` (`0x10000F27C`) before it connects the booted devices. |
| `SimulatorAppDelegate.validateMenuItem:` branch `0x1000122F4` | Automatically Sync Pasteboard is always enabled and checked from `isSynchronizingPasteboards`. |
| `DC.connectAsync` `0x10001B1BC` | For a connected coordinator, sends `updatePasteboardAutosyncStatus:` with `isSynchronizingPasteboards` and brings its window group to the front; otherwise connects. File ▸ Open Simulator (`simDeviceSelected:`), launching, Show Parallel Testing Devices, device state changes, and `startSessionNotification:` call it. |
| Window focus and disconnection | `windowDidBecomeKey:` (`0x10004AFD0`), `deviceWindowBecameKey:` (`0x100019B0C`), and `_onSessionQueue_disconnectWithCompletionGroup:` (`0x10001AEB0`) send no pasteboard message; only `_onSessionQueue_resetPasteboardInterfaceWithInitialPush:` sets `pasteboardInterface`. Synchronization does not follow focus. |
| `simctl pbsync` `0x10000B098`, `SimDevice(diagnose) lookupPasteboardInterfaceWithDelegate:…` `0x100017CFC`, `SimctlPBCmdDelegate` `0x100017EC4` … `0x1000180B0` | Requires the runtime's `SimFeaturePasteboard` (`com.apple.CoreSimulator.pasteboard`) and a booted device, then creates the same interface. After `pull` it waits for `simPasteboardDidApplySnapshot:…` or an error; after `push`, for the connection's second `simPasteboardDidBecomeActive:`. Each wait gives up after one second; a lost connection fails with `ECONNRESET`. Nothing calls `enableRemoteAutosync`. |

The live check on the separate device set showed:

- Opening a connection transfers nothing. Changes made on either side with
  `simctl pbcopy` or to the managed pasteboard stayed where they were, both
  before the first transfer and between transfers.
- `pull` completed within a few milliseconds with
  `simPasteboardDidApplySnapshot:…`, also for an empty device pasteboard, which
  empties the managed one. The managed pasteboard reads each type from the
  device when it is read: after the connection closed, the types were still
  listed but returned no data.
- Each `push` was followed by one `simPasteboardDidBecomeActive:` once the
  data was sent: 0.8 to 1.2 seconds for a 260 MB type, which stayed on the
  device after the connection closed. A 300 MB type did not reach the device,
  and no callback reported it.
- `pull` and `push` on a connection that the device closed did nothing and
  called nothing. `lookup:error:` on a shut-down device failed with "Unable to
  lookup in current state: Shutdown".
- The guest's CoreSimulatorBridge (`com.apple.CoreSimulator.bridge`) serves
  `com.apple.CoreSimulator.SimPasteboardInterface`; killing it closed the
  connection with `simPasteboardDidLoseConnection:`.
- `enableRemoteAutosync` transferred nothing by itself, and the connection
  called `simPasteboardDidChangeAutoNotifyState:…` with YES within a
  millisecond; `disableRemoteAutosync` called it with NO.
- With two connections managing the same pasteboard and synchronizing, a
  change of that pasteboard reached both devices about 0.6 seconds later, each
  followed by `simPasteboardDidBecomeActive:`. A copy made by an app on one
  device was applied to the managed pasteboard
  (`simPasteboardShouldApplySnapshot:…`, then
  `simPasteboardDidApplySnapshot:…` with its change count) and was not sent
  back, but it did not reach the other device either. That device's
  pasteboard, which held the managed pasteboard's earlier snapshot, then read
  as empty, since its data is fetched from the Mac when read. `simctl pbcopy`
  does not make the guest report its change.
- After CoreSimulatorBridge was killed, a new connection and
  `enableRemoteAutosync` synchronized again. Releasing a synchronizing
  connection without `disableRemoteAutosync` stopped its exchange; after
  `disableRemoteAutosync`, nothing crossed.

NeoSimulator reproduces these commands; its differences are listed in the
design under [Get and Send Pasteboard](Design.md#get-and-send-pasteboard) and
[Automatically Sync Pasteboard](Design.md#automatically-sync-pasteboard).

## Modifier gestures

The evidence is Simulator.app 16.0 (1063.4) from Xcode 26.6 and SimulatorKit
from Xcode 27.1. Simulator.app has no gesture code of its own: SimulatorKit's
digitizer receives the mouse and modifier events through AppKit, and
Simulator.app calls nothing on it when focus changes or a window closes.

| Reference owner | Observed behavior |
| --- | --- |
| `DWC.windowDidBecomeKey:` `0x10004AFD0`, body `0x10004ACB8` | Calls `KeyboardController.becomeKey(coordinator:)` (`0x10004ADD0` → `0x100073C30`), sets the chrome `active`, and sends `deviceWindowBecameKey:`. It neither changes the first responder nor sends a modifier event. |
| `DWC.windowDidResignKey:` `0x10004B170`, closure `0x10004B074` | Calls `KeyboardController.resignKey(coordinator:)` (`0x10004B0DC` → `0x100073DE8`), which calls `SimKeyboardInputController.clearModifiers()` (`0x100073F00`), then sets the chrome `inactive` and sends `stopCapturingInput:`. Nothing reaches the digitizer. |
| `SimulatorApp.sendEvent:` `0x1000240FC` | For every modifier event (`flagsChanged`), before AppKit's route, posts `OptionKeyDown` with the app as object when the event's `modifierFlags` has Option (0x80000) and `OptionKeyUp` otherwise, for the toolbar buttons; after it, forwards a Command key-up to the key `DeviceWindow`. Only events that reach the app, which is active, pass here. |
| Defaults `0x1000251B0` … `0x1000251DC`; window setup `0x10004A794` … `0x10004A830` through `0x100048A24` | Registers `ShowSingleTouches` NO, `ShowPinches` YES, `ShowPinchPivotPoint` NO, and `HighlightEdgeGestures` NO, and inserts or removes the matching `SimDigitizerInputView.DrawOption` for each window. The Internal menu that toggles them (tag 7000) is shown only when `os_variant_has_internal_ui` (`0x100024894`). |
| `DWC.windowWillClose:` `0x10004B2D8` → `-[DeviceCoordinator deviceWindowWillClose:]` `0x100019720` → `_onSessionQueue_disconnectWithCompletionGroup:` `0x10001AEB0` | Disconnects the window controllers through `DWC.disconnectWithCompletionGroup:completionQueue:completionHandler:` `0x100050998`, which calls `SimDisplayView.disconnect(completion:)` at `0x100050360`, then sends `resetHIDSession` to the coordinator's legacy HID client (`0x10001B19C`). No touch end is sent. |

SimulatorKit (Xcode 27.1):

| Owner | Observed behavior |
| --- | --- |
| `EventHandlingView` mouse, key, and `flagsChanged:` methods `0x2CA1C` … `0x2CA80` → `0x2C75C` | Pass every event to the subclass handler (vtable `0x70`; `SimDigitizerInputView` `0x1E510`), whose state machine takes the modifiers from the events it receives. |
| `SimDigitizerInputViewDelegate` defaults `0x1988C`, `0x19828` | `wantsFirstResponder` makes the digitizer its window's first responder; `wantsMouseMovedEvents` sets the window's `acceptsMouseMovedEvents`. |
| `SimDigitizerInputView.DrawOption` `0x1B8CC` … `0x1B988` | `normalTouch` 2, `pinchTouches` 4, `pinchPivotPoint` 8, `edgeGestures` 16, `lockedTouches` 32; `defaults` is 36, the set that Simulator.app's registered defaults produce. |
| `SimDisplayView.disconnect(completion:)` `0x69A44` | Sets the digitizer's `isEnabled` to NO (setter `0x1A190`, whose observer `0x1A030` clears the drawn points without sending events), clears its `delegate` and `wakeOnTouchDelegate`, and resets the display's HID session (`0x17648`). Active contacts are not ended. |
| `SimKeyboardInputDefaultDelegate.isEnabled` observer `0x2A654` | On NO, calls the shared `SimKeyboardInputController.clearModifiers()` (`0x28BE0`) after the display has stopped taking the keyboard, so that display keeps its held modifiers. |
| `SimKeyboardInputController` init `0x28604`, `applicationDidResignActive:` `0x28C40` | The only SimulatorKit observer of `NSApplicationDidResignActiveNotification`; it releases keyboard modifiers. Nothing in SimulatorKit observes key-window changes. |

A guest app on an iOS 26.5 iPhone 17 Pro in a separate device set recorded
`UITouch` phases and pinch, rotation, and two-finger pan recognizers while
NeoSimulator's window controller received generated AppKit events. Option
pinches and rotations, Option-Shift moves and recentering, and Control pinning
and release behaved as the README describes, with modifiers that the real
keyboard did not hold, so the digitizer took them from the events. Releasing
Option before the button left both touches down until the next click. Closing
or disconnecting the window left the touches down; the next connection's first
touch ended them and, for a pinned finger, became that touch's end. A restart
cleared them. Before NeoSimulator kept its modifier release from the digitizer,
deactivating the app during an Option drag stopped the fingers and left them
down until the next click; Simulator.app does not send the digitizer that
release, and the drag now continues as it does there. The generated events
cover AppKit's routing inside the app but not the window server's pointer
tracking, so they do not replace a check with a physical keyboard and trackpad.

NeoSimulator reproduces this behavior; its handling is described in the
[design](Design.md#modifier-gestures).

## Audio routing

The evidence is Simulator.app 16.0 (1063.4) and SimulatorKit from Xcode 26.6,
CoreSimulator 1174.9.2 with its CoreSimDeviceIO and SimAudioProcessorService,
CoreDevice 651.13.5, and an iOS 26.5 iPhone 17 Pro in a separate device set. In
`MainMenu.nib`, I/O ▸ Audio Input and Audio Output follow the separator after
Touch Pressure and precede Increase Volume and Decrease Volume. `DC` is
`DeviceCoordinator`.

| Reference owner | Observed behavior |
| --- | --- |
| `-[DC initWithDevice:]` `0x100018914`, block `0x100018ECC` | Each coordinator owns an Audio Input and an Audio Output submenu with one item, `System`, whose action is `changeSelectedAudioDevice:` and whose tag is `0x20000001` (input) or `0x40000001` (output). |
| `-[DC _onSessionQueue_connect]` `0x10001B314`, at `0x10001B528` … `0x10001B65C` | With `SimFeatureRoutableAudio` (`com.apple.CoreSimulator.audio.routable`), creates `SimDeviceAudioClient initWithDevice:eventHandlerQueue:error:changedEventHandler:` with the main queue. A failure logs "Unable to start Audio Client, will be unable to change audio routing. Error: %@", and the submenus keep only System. |
| Changed handler `0x10001B900` | On each state the client reports: `updateAudioMenuWithState:`, then `synchronizeSelectedAudioDevicesInScope:` with 1 and 2. |
| `-[DC deviceWindowBecameKey:]` `0x100019B0C`, at `0x100019F9C`; `-[DC deviceWindowWillClose:]` `0x100019720`, at `0x1000198E8` | Send `connectAudioSubmenus:` YES and NO. |
| `-[DC connectAudioSubmenus:]` `0x10001D0DC` | With YES and `SimFeatureRoutableAudio`, enables the app delegate's `audioInputMenuItem` and `audioOutputMenuItem` and gives them this coordinator's submenus; otherwise disables them and removes their submenus. They are never hidden. |
| `-[DC updateAudioMenuWithState:]` `0x10001CA38` | For each direction: finds System by its tag, removes all items, adds System back, then adds an item per `inputDevices` or `outputDevices` entry: `displayName`, `changeSelectedAudioDevice:`, the device as `representedObject`, tag `0x20000000` or `0x40000000`. A device is checked when the client does not use the default and its `uniqueIdentifier` equals the selected device's. When a device's identifier equals the effective default device's, System's title becomes `System (%@)` with its `displayName`; otherwise the title stays. System is checked from `useDefaultInputDevice` or `useDefaultOutputDevice`. No separator is added. |
| `SimulatorAppDelegate.validateMenuItem:` `0x10001202C`, at `0x1000121A8` → `0x100012720` | `changeSelectedAudioDevice:` is enabled while `keyDeviceCoordinator.device` is not nil. |
| `-[SimulatorAppDelegate changeSelectedAudioDevice:]` `0x1000142C8` | Tag `0x20000001` or `0x40000001` chooses `SimAudioHostUseSystemDefaultDeviceUID`; another item's `representedObject`, which must conform to `SimAudioHostDevice`, gives its `uniqueIdentifier`, and tag bit 29 tells input from output. Records an analytics event, inserts the route at index 0 of the recent list (`arrayByInsertingObject:` `0x10003B8FC`), saves it, and sends `synchronizeSelectedAudioDevicesInScope:` with that direction to every coordinator in `deviceCoordinators`. |
| `NSUserDefaults(Indigo)` `recentAudioInputDeviceUIDs` `0x10003AD64`, `recentAudioOutputDeviceUIDs` `0x10003B0D0` → `0x10003B13C` | `RecentAudioInputDeviceUIDs` or `RecentAudioOutputDeviceUIDs` cast to `[String]`; when missing, not of strings, or empty, `[SimAudioHostUseSystemDefaultDeviceUID]`. |
| Setters `0x10003AD7C`, `0x10003B240` → `0x10003B2A0` | Keep the first occurrence of each route (`0x10003ADDC`), keep the first five (`0x10003B004`), and `setObject:forKey:`. |
| `-[DC synchronizeSelectedAudioDevicesInScope:]` `0x10001D2A4`, block `0x10001D324` | On the session queue, passes the recent list, the client state's devices, selected device, and default flag of that direction to `_onQueue_synchronizeSelectedAudioDevices:hostDevices:currentlySelectedDevice:currentlyUsingDefaultDevice:inScope:`. |
| `_onQueue_synchronize…` `0x10001D46C` | For each recent route in order: System while using the default, or the selected device's identifier while not, logs "already selected" and stops. Otherwise the first host device with that identifier, or for System the first host device whose `isDefaultInScopes` has the direction's bit, makes it call `routeGuestWithScope:to:completionQueue:completionHandler:` (`0x10001D7C0`) on the main queue and stop. With none, it logs "Unable to find the preferred audio device for scope %@!". The completion (`0x10001D8FC`) only logs the error or success. |

SimulatorKit 26.6's `SimDeviceAudioClient` (`SimAudioHostRouteClient.swift`):

| Owner | Observed behavior |
| --- | --- |
| `init(device:eventHandlerQueue:changedEventHandler:)` `0x813B0` | Takes `SimDevice.io`, its `ioPorts`, and the first port whose `descriptor` conforms to `SimAudioHostRoutable`; without one it throws `noAudioPort`. On its serial queue `com.apple.SimulatorKit.AudioHostRouteClient.<UDID>`, it reads the port (`0x81DE8`) and reports that state, then registers `availableDevicesChangedCallback` (`0x81EF4`) and `selectedDeviceUIDChangedCallback` (`0x820E4`, scope and route). |
| State `0x8267C`, `0x82B30`, `0x83388` | `inputDevices` and `outputDevices` are `availableHostDevices` with at least one input or output channel. The effective default device has the identifier of `effectiveDefaultInputDeviceUID` or `effectiveDefaultOutputDeviceUID`. The selected device is the device of the guest's route, or else the device that is the default in that direction. `useDefaultInputDevice` and `useDefaultOutputDevice` compare the guest's route with `SimAudioHostUseSystemDefaultDeviceUID`. |
| `routeGuest(scope:to:completionQueue:completionHandler:)` `0x83B9C` | Sends `routeGuestDeviceScope:toHostDeviceUID:completionQueue:completionHandler:` to the port. |

Xcode 27's SimulatorKit has no `SimDeviceAudioClient`. The port remains:

- CoreSimDeviceIO declares `SimAudioHostRoutable` with `availableHostDevices`,
  `guestInputHostDeviceUID`, `guestOutputHostDeviceUID`,
  `effectiveDefaultInputDeviceUID`, `effectiveDefaultOutputDeviceUID`,
  `routeGuestDeviceScope:toHostDeviceUID:completionQueue:completionHandler:`
  (`v48@0:8Q16@"NSString"24@"NSObject<OS_dispatch_queue>"32@?<v@?@"NSError">40`),
  `registerCallbackWithUUID:availableDevicesChangedCallback:` (a block taking
  an array), `registerCallbackWithUUID:selectedDeviceUIDChangedCallback:` (a
  block taking a scope and a route), and `unregisterCallbackWithUUID:`.
  `SimAudioHostDevice` has `uniqueIdentifier`, `name`, `displayName`,
  `dataSourceID`, `dataSourceName`, `scope`, `inputChannels`,
  `outputChannels`, and `isDefaultInScopes`. It exports
  `SimAudioHostUseSystemDefaultDeviceUID`, whose value is
  `__sim__hostUseSystemDefaultDeviceUID`.
- SimAudioProcessorService handles CoreAudio's device-list, default-input, and
  default-output changes (`0x10000C824`, `0x10000C900`, `0x10000CA04`); each
  calls `0x10000CB08`, which calls the `availableDevicesChangedCallbacks`
  (`0x10000CBBC`).
- CoreDevice's SimulatorCoreDevicePlugin implements `devicectl device settings
  audio` and `device info audio` with `io`, `ioPorts`, `descriptor`,
  `conformsToProtocol:` `SimAudioHostRoutable`, the guest's routes, and the
  route message ("No audio routable port found on the device"). CoreDeviceService
  implements `devicectl list audioDevices` with CoreAudio
  (`AudioObjectGetPropertyData` and a device-list listener).

The live check on the separate device set showed:

- The device had 14 I/O port proxies; finding the routable one took 7 ms and
  reading its state 2 to 7 ms. `availableHostDevices` gave the identifiers
  that `devicectl list audioDevices` gives, with CoreAudio's names.
- Routes completed in 3 to 50 ms without an error, and
  `selectedDeviceUIDChangedCallback` reported each scope and route. The
  callbacks and the completion arrived on the proxies' own queues, although the
  completion queue was the main queue. Registering reported nothing.
- A route to an identifier that the Mac lacked, and an input route to an
  output-only device, completed without an error; the guest then used the
  Mac's default device by its identifier.
- With the output routed to BlackHole 2ch, an existing loopback device,
  BlackHole's `kAudioDevicePropertyDeviceIsRunningSomewhere` changed from 0 to
  1 while a guest process played a tone and back to 0 after it; the guest's
  `AVAudioSession` still reported its own Speaker route.

NeoSimulator reproduces Audio Input and Audio Output; its handling and
differences are described in the [design](Design.md#audio-input-and-audio-output).

## External displays

The evidence is Simulator.app 16.0 (1063.4) from Xcode 26.6, SimulatorKit from
Xcode 27.1, CoreSimulator 1174.9.2 with its CoreSimDeviceIO, and an iOS 26.5
iPhone 17 Pro and iPad Pro 11-inch (M5) in a separate device set. In
`MainMenu.nib`, I/O ▸ External Displays (tag 2014) follows a separator after
Decrease Volume and is followed by a separator. `DC` is `DeviceCoordinator`,
`DWC` is `Simulator.DeviceWindowController`, and `SDS` is the app's
`SimDevice+Screens.swift` extension.

| Reference owner | Observed behavior |
| --- | --- |
| Menu items, `DC.tvOutModeChanged:` `0x1000208CC` | Disabled (2114), a separator, 640×480 (2214), 720×480 (2514), 1024×768 (2314), 1280×720 (720p) (2414), 1920×1080 (1080p) (2614), 3840×2160 (4K) (2664), a separator, and CarPlay (2714). The action records an analytics event per tag, opens the Stark options panel for CarPlay when `CarPlayExtraOptions` is on, and otherwise calls `configureExternalDisplay:` with the tag. |
| `DC.deviceWindowBecameKey:` `0x10001A5A8` … `0x10001A614` | Hides the submenu item and its separator unless the device supports `SimFeatureExternalDisplay` (`com.apple.display.supports-external`) and `SimFeatureInternalDisplay` (`com.apple.display.integrated`). |
| `DC.validateMenuItem:` `0x10001F578` … `0x10001F6DC` | Enabled with both features, and for CarPlay also `SimFeatureCarPlay`. The checkmark compares the item's tag with `externalDisplayModeForDevice:` (`0x10001F608`); without the features, the item is disabled and unchecked. There is no connection check. |
| `NSUserDefaults(Indigo)` `externalDisplayModeForDevice:` `0x10003B744` → `0x100079A70`, `setExternalDisplayMode:forDevice:` `0x10003B7D0` → `0x100073214` | `DevicePreferences[UDID].SimulatorExternalDisplay`, an integer tag; missing or not an integer reads as 2114. |
| `DC.configureExternalDisplay:` `0x100020C00` | Maps the tag to a pixel size at scale 1; CarPlay takes the Stark configuration's size, scale, and `carPlayPropertiesDictionary`, and becomes 2114 without `SimFeatureCarPlay`; another tag is 2114. Calls `starkConfigWriteToDisk:` (`0x100021628`), which for a device with `SimFeatureCarPlay` writes `<dataPath>/Library/Application Support/Simulator/extended_display.plist`, `{stark: false}` for every item but CarPlay. A device without both display features gets 2114. It then saves the tag with `setExternalDisplayMode:forDevice:` (`0x100020F2C`), so a choice is saved before it is applied, saves the external window's geometry when it has a connected screen (`0x100020FBC`), and runs the session block on the coordinator's session queue. |
| Session block `0x100021090` | With the display features: 2114 with a connected external window powers its screen off (`setPowerState:0 completionQueue:completionHandler:`, `0x100021184`; the completion `0x100021470` only logs), and without one takes no action. Another tag with a connected window removes a CarPlay HID service and calls `enableCarPlay:NO` when that screen is CarPlay (`0x100021268`–`0x100021280`), then calls `reconfigureScreen:toSize:scale:carPlayProperties:completionQueue:completion:` (`0x100021440`), whose completion (`0x1000214E0`) logs and, for CarPlay, enables CarPlay and its HID service. Without a connected window it calls `configureExternalDisplayWithSize:scale:carPlayProperties:` (`0x10002136C`). |
| `SDS.configureExternalDisplay(withSize:scale:carPlayProperties:)`, Objective-C entry `0x100030F20`, handler `0x100030BF4` | Needs `SimFeatureCarPlay` with CarPlay properties, otherwise `SimFeatureExternalDisplay`. Registers `SimDevice.screenAdapter`'s `register(screenID: nil, …)` and, on the first `.connected` screen whose properties' `screenType` is **1** (`0x100030D04`–`0x100030D08`; TVOut, also for CarPlay), registers that screen's lifecycle events (`0x10002EF2C`) and releases the adapter registration. On the screen's `.connected` event (`0x10002F0B4`) it calls `0x10002F3DC` on its queue. Without an adapter it logs "Failed to get screen adapter for device". |
| Mode choice `0x10002F688`, setter `0x10002F3DC` | The current mode when `pixelSize` equals the size and `currentMode.preferredUIScale` the scale; otherwise the first `supportedScreenModes` entry with that `preferredUIScale` whose `sizeRule` takes the size: 0 `exactSize`, 1 `minSize` ≤ size ≤ `maxSize`, 2 one of `allowedSizes` (`NSEqualSizes`); another rule traps. It reads no `refreshRate`; no code in the app sends it. Then `setCurrentMode:pixelSize:carPlayProperties:completionQueue:completionHandler:` (`0x10002F540`) with that mode and the size; without a mode it logs "unable to find target mode matching size". The completion (`0x10002FA78`) only logs. No power call follows: setting the mode turns the screen on. |
| `SDS.reconfigureScreen` `0x10002FCE4`, `0x100030218` | The same mode choice and setter "without power cycling" (`0x10002FF7C`, `0x1000303DC`); without a mode the completion receives "No matching mode found". |
| `SimDeviceScreenMonitor` `startMonitoring` `0x100032A20`, property handler `0x100032DB4` | Started by `DC._onSessionQueue_connect` (`0x10001B684`–`0x10001B708`). Registers `register(screenID: nil, …)` on the adapter; on `.connected` records power, size, scale, and CarPlay properties, registers `.properties` events, and calls `screenConnected:`. A properties event compares `powerState` (1 is on) and calls `screenPoweredOn:` or `screenPoweredOff:`, then `geometryChangedForScreen:dimensions:scale:` and `carPlayPropertiesChangedForScreen:carPlayProperties:` on changes. |
| `DC.screenConnected:` `0x10001BAF0`, `screenPoweredOn:` `0x10001BDAC` | A screen that connects powered on is handled as powered on. Powering on creates `DWC` `initWithCoordinator:` for the screen ID, kept in `windowControllers`, and calls `connectTo:starkConfig:completionQueue:completion:` (the Stark configuration only for CarPlay); the completion logs and, for CarPlay, enables CarPlay and its HID service. The device's own screen and an external screen use the same path. |
| `DC.screenPoweredOff:` `0x10001C1A8`, `screenRemoved:` `0x10001C288`, `screenDisconnected:` `0x10001BC6C` | Powering off or disconnecting disconnects that screen's window (`disconnectWithCompletionGroup:completionQueue:completionHandler:`); its completion disables CarPlay for a CarPlay screen and drops the controller of a screen that is not the default. |
| `DC.geometryChangedForScreen:dimensions:scale:` `0x10001C5B0` | Calls the window's `updateWindowGeometry` on the main queue, keeping its `renderScale`. |
| `DC.externalDisplayWindowController` `0x10001923C` | The first window controller whose connected screen is not the default. |
| `DC._onSessionQueue_connect` `0x10001B75C` … `0x10001B7BC`, block `0x10001B970` | After starting the monitor, dispatches `configureExternalDisplay:` with the saved tag to the main queue. An Apple TV instead configures its screen at the device type's main screen size and scale (`0x10001B408`). |
| `DC.deviceWindowWillClose:` `0x100019720` | Closing the external window calls `configureExternalDisplay:2114`, which saves Disabled and powers the screen off. Closing the device's window disconnects the coordinator, whose `_onSessionQueue_disconnectWithCompletionGroup:` (`0x10001AEB0`) stops the monitor and disconnects every window controller; the saved tag stays. |
| `DWC` disconnect `0x10004FDB8` … `0x1000506A8` | A window whose screen's `displayClass` is not 0, on a device with `SimFeatureInternalDisplay` that is neither shut down nor shutting down (`state` 1 or 4), enumerates the screen adapter port's screens (`enumerateScreensWithCompletionQueue:completionHandler:`) and powers off each of `screenType` 1, except on Apple TV, whatever its power. The disconnect's completion group is entered for the enumeration (`0x1000503F8`) and for each power-off (`0x10005061C`); the power-off's completion (`0x1000507CC`) logs "Failed to power off TVOut screen: " on an error and leaves the group (`0x1000508BC`), and the enumeration leaves it after the loop (`0x1000506C8`). Quitting disconnects every coordinator in `prepareForTermination` (`0x10000FD20`), whether or not it shuts the devices down, and `applicationShouldTerminate:` (`0x10000FFD0`) waits for those disconnections within `TerminationTimeout` (60 seconds), so the app exits after the power-offs complete. It saves the window's geometry before `orderOut:` (`0x100050D84`): `ExternalWindowGeometry` for a screen that is not the default (`0x100050EB8`, `0x10007B254`). |
| `DWC` connection `0x10004E24C` … `0x10004E9F4`, chrome refresh `0x10005B254` | Reads `SimulatorWindowGeometry` and `ExternalWindowGeometry`; the scale is 1 for CarPlay, the default geometry's for the default screen, and the external geometry's otherwise. Every screen's display connects with the digitizer and hardware buttons (`0x10004E620`–`0x10004E6C4`); `supportTouchPressure` is off for a display class other than 0. Only the default screen's window gets a toolbar (`0x10005B260`–`0x10005B274`). The chrome refresh (`0x10005AFFC`) runs for the other screens' windows too: without a chrome it makes the window resizable, sets the black background outside full screen, and turns the gap flag off, so the display meets the title bar. Without a toolbar, the title bar corners (found through the toolbar's view) stay square, and the toolbar style that the geometry update sets does not change the title bar: AppKit's plain title bar, 32 points on macOS 26.6 for every style with a title and a subtitle. |
| `DWC` title `0x10005A9C8` … `0x10005AA1C` | The subtitle's label is `CarPlay` for a CarPlay screen and `External Display` for another screen that is not the default, joined to a suffix of the device's name with " – " (`0x10005AA5C`) as the runtime is. |
| CarPlay choice, `DC.tvOutModeChanged:` `0x1000209D0`, `DC.configureExternalDisplay:` `0x100020C74` … `0x100020E64` | Needs `SimFeatureCarPlay` and takes the coordinator's `StarkConfig`: `init` (`0x1000271EC`) sets 800×480, a scale of 2.0, `stark` and `hasTouchScreen` on, and the wheel, back, and home controls off; `construct` (`0x1000272C4`) loads `CarPlayConfig` only when `CarPlayExtraOptions` is on, which also shows an options panel before the choice and titles the item `CarPlay…` (`0x10000FC58`). The screen gets 800×480 as its pixel size at that scale with `carPlayPropertiesDictionary` (`0x100027820`): `SimCarPlayPropertyKeyStark` and `SimCarPlayPropertyKeyHasTouchScreen` set to true, a false control left out. It is the TVOut screen: the new-display path waits for `screenType` 1 (`0x100030D08`), and the existing-display path reconfigures the connected screen. |
| `DC.starkConfigWriteToDisk:` `0x100021628` | For a device with `SimFeatureCarPlay`, before each choice is saved and applied (`0x100020EE8`), creates the folder and writes `<dataPath>/Library/Application Support/Simulator/extended_display.plist` with `writeToFile:atomically:NO`: `StarkConfig`'s plain keys (`stark`, `width`, `height`, `scale`, `hasBackButton`, `hasHomeButton`, `hasWheel`, `hasWheelBump`, `hasTouchScreen`, `hasTouchScreenLofi`, `protocols`) for CarPlay and `{stark: 0}` otherwise. A failure is logged ("Failed to save extended display settings") and the choice goes on. |
| CarPlay steps, session block `0x100021240` … `0x100021600`, `DC.screenPoweredOn:` `0x10001BDAC` … `0x10001C120`, window disconnect completion `0x10001C45C` … `0x10001C540` | Before reconfiguring a connected CarPlay screen, removes the CarPlay HID service (`0x10002126C`) and calls `enableCarPlay:NO` (`0x100021280`), going on after a failure. After a CarPlay screen is set, or its window connects, calls `enableCarPlay:YES` (`0x100021570`, `0x10001C090`) and, whether or not that succeeded, creates the HID service (`0x100021600`, `0x10001C120`). Disabled powers the screen off, and the window's disconnection then removes the service and calls `enableCarPlay:NO`. The device window's disconnection and quitting power the screen off without ending CarPlay. Failures are logged only. |
| HID service, `0x100020B88` (create), `0x100020BD8` (remove), sent at `0x10001ABAC` | `IndigoHIDMessageToCreateCarPlayService(starkConfig.hasTouchScreen)` and `IndigoHIDMessageToRemoveCarPlayService()` through the coordinator's `SimDeviceLegacyHIDClient`, `sendWithMessage:freeWhenDone:YES completionQueue:nil completion:nil`. Both exist in SimulatorKit 26.6 and 27.0–27.2 with these declarations; the messages are 192 bytes with extended commands 7 and 8 for the CarPlay service target 1. |
| CarPlay window, `DWC` connection `0x10004E988`, `0x10004F1B4`, geometry update `0x10005B4A0` | The initial scale is 1 for CarPlay, also with a saved `ExternalWindowGeometry` scale, while the saved center is used (`0x10004E438`). `allowFullscreenMode` is false for CarPlay, which sets `collectionBehavior` to `.fullScreenAuxiliary` (`0x1000486D8`). Without wheel, back, or home controls, the window adds no height for them (`0x10005B98C`) and is resizable like a TVOut window. |

CoreSimDeviceIO's `SimScreenAdapter` declares
`createScreenWithProperties:currentMode:pixelSize:carPlayProperties:completionQueue:completionHandler:`
(completion `(UInt32 screenID, NSError *)`), `removeScreenWithID:…`,
`enumerateScreensWithCompletionQueue:completionHandler:`,
`registerScreenAdapterCallbacksWithUUID:callbackQueue:screenConnectedCallback:screenWillDisconnectCallback:`,
and `creatableScreenProperties`. `SimScreen` declares
`setCurrentMode:pixelSize:carPlayProperties:completionQueue:completionHandler:`
and `setPowerState:completionQueue:completionHandler:`, each completing with an
`NSError`. Neither Simulator.app nor SimulatorKit calls the creation method.

SimulatorKit 27.1's `SimDeviceScreenAdapter.register(screenID:queue:handler:)`
(`0x3F83C` → `0x3F8A0`) adds a `Registration` holding the queue and the
handler to the adapter, then reports each screen in `screens` as connected
for a nil screen ID, or only that screen for an ID. Each report is a block
dispatched asynchronously to the queue (`0x3F418`) that retains the
registration. `ScreenEvent` has the cases `connected(SimDeviceScreen)` and
`disconnected(SimDeviceScreen)` and exports its case symbols, as a resilient
enum does; Simulator.app's handler copies it through its value witnesses,
compares its tag with `.connected`, and projects the screen
(`0x100030C78`–`0x100030CF4`).

The live check on the separate device set showed:

- `register(screenID: nil, …)` on the main queue, with SimulatorKit 27.0,
  27.1, and 27.2, reported `.connected` for each of the adapter's screens
  within 10 ms, in an order that varied between runs, also to a registration
  released right after it was made. The properties' `screenID` gave the IDs
  that `simctl io enumerate` lists. A registration held across `simctl
  shutdown` and `boot` received `.disconnected` for each screen and, after
  the boot, `.connected` for each again; the released one received nothing
  more.
- `simctl io <UDID> enumerate`, also on a shut-down device, lists the
  iPhone's screens 1 LCD (Integrated), 2 TVOut, and 3 Wireless (CarPlay), and
  the iPad's 1 LCD and 2 TVOut. `SimScreenProperties.screenType` is 0, 1, and
  2 for these. Both adapters list no creatable screen properties, and both
  refused `createScreenWithProperties:…` with each existing screen's
  properties and current mode (`Swift.String` error, code 1).
- The TVOut screen starts off at 720×480 with a scale of 1. It advertises an
  exact 720×480 mode at 60 Hz, the TVOut entry of the device type's
  `capabilities.plist`; 120 Hz modes allowing the six menu sizes at scales 1
  and 2; and on the iPhone 60 Hz ranges from 320×200 to 3840×2160 at scales 1,
  2, and 3. The order of `supportedScreenModes` differed between reads.
  `refreshRate` is in hundredths of a hertz (6000, 12000). On iOS 27.0 the
  iPhone 17 Pro's TVOut screen had no ranges, only the exact mode and the
  120 Hz modes, as the iPad's.
- `setCurrentMode:…` turned the screen on at the size and completed within
  50 ms; `setPowerState:0` turned it off, and on a screen that was already
  off completed without an error and left it off; each change reported a
  properties event, which reached the main queue just before the completion.
  Changes sent every 20 ms while `simctl shutdown` ran (146 of them)
  completed without an error; after the shutdown, and after the device booted
  again, changes through a screen connection made before completed with
  `Invalid argument`, up to 4.5 seconds after they were sent.
  SimulatorKit's display of the screen has no bezel, a `displayClass` of 1,
  and takes a new size one or two main-queue turns after the event by setting
  its view's frame to that size at its scale.
- The guest left the screen black until an app presented an external display
  scene, and its `UIScreen` took the size only for a 60 Hz mode. With a
  120 Hz mode the guest's SpringBoard switched the display to 720×480 at
  60 Hz itself: its log shows the display connecting at "1920x1080 120Hz"
  with the other mode "720x480 60Hz", then "preferred_mode_with_criteria: …
  target rate (0) … target high refresh rate (0) … --> 720x480@60" and a
  display change to 720×480. In the iOS 26.5 runtime's QuartzCore,
  `ModeSet::preferred_mode_with_criteria_internal` skips modes below 49 Hz
  (without a target rate) or above 60.5 Hz, and `Display::Mode::operator<`
  orders modes by width × height × whole hertz; the QuartzCore of the iOS
  18.5 and 26.0 runtimes has the same bounds. The guest's QuartzCore imports
  no `SFBDisplaySetCurrentMode`, so the screen keeps the mode that was set.
  At 60 Hz, 640×480 also ended at 720×480 on both devices, and on iOS 18.6
  and 27.0; 1024×768 through 3840×2160 kept their size. A change from
  1280×720 at 60 Hz to 1920×1080 at 120 Hz while the display was on showed
  1920×1080 in no try: the scene went to 720×480, stayed at 1280×720, or,
  5 seconds after the previous change, was torn down ("told display did
  disconnect") with no new pick, leaving the display black.
- CoreSimulator's SimRenderServer builds the TVOut screen's size
  specification with refresh rates 30, 60, 75, and 120 Hz
  (`0x100027240`–`0x1000272C0`) and lists it at 120 Hz. Passing the iPad's
  exact 720×480 mode with 1920×1080 set the screen to 1920×1080 at 60 Hz
  (`currentMode` an exact 1920×1080 mode at 6000), which the guest's scene
  took; 1000×700 with either mode failed with "Unsupported Mode: { 1000.0x700.0@…hz 1X … }".
- On the iPad Pro 11-inch (M5) with iOS 26.5, and the iPad Pro 11-inch (M4)
  with iOS 26.0 and 18.6, 3840×2160 at 60 Hz made the display an extended
  display (`SBSystemShellExtendedDisplayControllerPolicy`, wanting a pointer),
  which SpringBoard re-evaluated about nine times a second; turning the
  display off, or changing it to 1920×1080, then aborted SpringBoard on an
  assertion (`SBSystemShellExtendedDisplayControllerPolicy.m:199`), which
  launchd restarted. The iPad with iOS 27.0 kept SpringBoard. These iPads'
  device types have `DeviceSupportsEnhancedMultitasking`; the iPhone 17 Pro's
  does not.

For CarPlay, CoreSimulator's `SimDevice environment` gives the guest the
file's path as `SIMULATOR_EXTENDED_DISPLAY_PROPERTIES` (and
`IPHONE_TVOUT_EXTENDED_PROPERTIES`) for a device with `SimFeatureCarPlay`. In
the iOS 26.5 runtime, backboardd reads it when the TVOut screen's modes change
and, with `stark` on, makes that display a car display ("Making display
'PurpleTVOut' a car display for the simulator"). `-[SimDevice
enableCarPlay:error:]` (CoreSimulator `0x50D68`) sends
`host_support_mig_set_carplay_state` to the guest's CoreSimulatorBridge
(`com.apple.CoreSimulator.host_support`), which counts sessions with
CarPlayServices' `CRSSessionController`: a start adds one, an end removes
one, and an end without a session is an error. SimulatorKit 27's display
sends the touches of a TVOut or CarPlay screen to HID target 1 when the device
has `SimFeatureCarPlay` (`0x67FA4`, `0x6B570`). The live check on the iOS 26.5
iPhone 17 Pro in the separate device set showed:

- With the file written first, the 800×480 CarPlay screen at a scale of 2,
  `enableCarPlay:YES`, and the HID service, the guest launched its CarPlay app
  on the TVOut display (`Car[2-3]`, "is car display: YES") and drew the
  dashboard; a click through SimulatorKit's display opened an app on it. The
  same steps on the wireless screen 3 left it an AirPlay display, black.
- After the CarPlay app had run once, a TVOut screen that changed from a size
  to the CarPlay screen in place, or that came back as one right after a
  power-off, connected as an AirPlay display that stayed in the guest's
  display debouncing (`FBSDisplaySource … debouncing`), and CarPlay never drew
  on it. A screen that had been off for 0.2 seconds or longer connected as a
  car display in every try. CarPlay to a size in place, and CarPlay chosen
  again, worked.
- A size after CarPlay left `carPlayProperties` nil; `enableCarPlay:NO` ended
  the CarPlay app's session, and the remove message disconnected the HID
  service.
- The iPad Pro 11-inch (M5) has no `SimFeatureCarPlay`.

NeoSimulator reproduces External Displays; its handling and differences are
described in the [design](Design.md#external-displays).

## watchOS, tvOS, and visionOS

Reference addresses are in Simulator.app 16.0 (1063.4) from Xcode 26.6;
SimulatorKit addresses are in Xcode 27.1's arm64e slice. The live checks used
Xcode 27.1, CoreSimulator 1174.9.2, an Apple Watch Series 11 (46mm) on watchOS
27.0, an Apple Watch SE (44mm) (2nd generation) on watchOS 26.5, an Apple TV 4K
(3rd generation) on tvOS 27.0, and an Apple Vision Pro on visionOS 26.5 in a
separate device set, through NeoSimulator's code.

| Reference owner | Observed behavior | Neo |
| --- | --- | --- |
| `SimDevice(KeyboardSync)` `isIOS` (body `0x10003BABC`), `isWatch`, `isTV`, `isVision` (`0x10003BCCC`) | Families by `deviceType.productFamilyID`: iOS is 1 or 2, TV 3, watch 4, Vision 7. | `DeviceCapabilities.Family`; devices of other families are not hosted. |
| `DC.deviceWindowBecameKey:` `0x100019B0C` | Hides Shake, App Switcher, Trigger Screenshot, Toggle Appearance, Toggle In-call Status Bar, the text sizes, and Toggle Increase Contrast unless iOS; Lock unless iOS or watch (`0x10001A038`…`0x10001A054`); Side Button unless watch; Show Device Bezels for Vision (`0x10001A9A0`); the viewport, Reset Camera, Simulated Scenes, Set Immersion To, and FaceTime items unless Vision (`0x10001A8A0`…`0x10001A9D8`); Increase and Decrease Immersion and 0% and 25% always (`0x10001A6A4`…`0x10001A728`); Optic ID without `SimFeatureOysterID` (`0x10001A134`…`0x10001A164`); Show Gaze Target without `SimFeatureHoverboard95880941` (`0x10001A620`…`0x10001A650`). Re-Center Open Apps is never hidden. | The same rules through `DeviceCommand.isSupported`, `PluginCommand.isShown`, and `DeviceCapabilities.supportsDeviceBezels`; the always hidden items are left out. |
| `DWC.validateMenuItem:` `0x100051A40` | Lock (`lockButtonPressed:`) is enabled for iOS and otherwise for a watch. | Lock is shown only for them. |
| Toolbar setup `0x100049D70` | A watch takes `IndigoWatchAODToolbar` with `SimFeatureAlwaysOnDisplay`, otherwise `IndigoWatchToolbar`; a TV `IndigoTVToolbar`; Vision the iPhone toolbar until its plugin's replaces it. The watch and TV nibs have Home and Save Screen; the always-on nib adds Always On: label "Always On", tooltip "Toggle Always On", a 25-point toggle `NSButton` (shows state by its contents) with the asset `ToolbarAlwaysOnSymbol` (`watch.always.on`) and an on image, to `lockButtonPressed:`. | `DeviceCommand.alwaysOn` on watches with `com.apple.display.aot`, an on/off toolbar button with `applewatch.watchface`. |
| Always On update `0x100054128` | Only for family 4; backlight 0 or 1 sets the button on, 2 off, other values leave it, and an unchanged value is skipped. The chrome refresh (`0x10005B0B8`) passes `SimDisplayView.backlightState`; the `simDisplayView(_:screen:propertiesChanged:)` witness (`0x10005F7D8`) passes `properties.backlight.state`. | Reads `SimScreenProperties.backlight.state` both times. Live, at a property change the properties already had the new value while `backlightState` still had the old one, until the next main-queue turn. The Series 11 went 2 → 1 → 2 with Lock, the SE 2 → 0 → 2; Apple TV and Apple Vision Pro report -101. |
| Title updater `0x10005A90C`, `0x10005AABC`…`0x10005AB18` | After `WindowTitleHelper`, a title with the prefix "Apple Watch " loses those 12 characters, for any device. | `deviceWindowTitles`: "Apple Watch Series 11 (46mm)" is titled "Series 11 (46mm)". |
| `DC._onSessionQueue_connect` `0x10001B3A4`…`0x10001B408` | For family 3, `configureExternalDisplayWithSize:` the device type's `mainScreenSize`, `scale:` its `mainScreenScale`, `carPlayProperties:` nil. | Not sent. Live, the Apple TV's default screen 1 was a TVOut screen (`screenType` 1, `displayClass` 1), powered on at 3840×2160, the device type's size, right after `simctl boot`. |
| SimulatorKit `SimDisplayView` connect `0x68474`…`0x6860C`, loader `0x48358` | Loads the device type's `userInterfaceIdentifier` profile from the service context's `supportedUserInterfaceProfileBundles`, keeps the principal-class instance in `_userInterfacePlugin` (`0x685A4`), and adds `overlayView` as a subview (`0x6860C`); a failed load logs "Failed to load simdeviceui bundle for device". | Live, the plugin (`PalomaSimSupport`) was set when the display factory returned, its overlay `XROS.VirtualHMDInputView` covered the 1920×1080 display and became the first responder, and the XROS image came from the selected Xcode. |
| `simDisplayView(_:changedUserInterfacePlugin:)` witness `0x10005F82C` → `0x10005F66C` | Stores `deviceUserInterfacePlugin`, sets the window's toolbar to the plugin's `toolbar` when it has one, and makes the plugin the app delegate's game-controller delegate when it conforms to `SimGameControllerDelegate`. | Sets the window's toolbar; no game-controller delegate. The plugin's `XROS.SimToolbar` had Home (`homeButtonPressed:`), Save Screen (`saveFramebufferImage:`, `toggleVideoRecording:` with Option), Capture Pointer, Capture Keyboard (both handled by the overlay), and Simulated Scenes. |
| XROS `VirtualHMDInputView.toggleCapturingMouse:` and `mouseUp:` (Xcode 27.1 `0x2943C`…`0x29640`) | Capture Pointer starts choosing the gaze target; the click that ends it passes `toggleCapturingMouse:` to the next responder when the overlay's `client` is `.simulatorApp`, and otherwise starts `SimHIDCaptureManager` itself (`startCaptureSessionWithDevice:hidDeviceTypes:error:`, type 2). | Live, the overlay's `client` was `.simulatorApp`; Capture Keyboard left `_captureKeyboardEnabled` off, and a click after Capture Pointer ended the gaze choice without a capture, because no responder in Neo captures. |
| DWC `homeButtonPressed:`, `saveFramebufferImage:`, `toggleVideoRecording:`; recording notifications `0x1000594B4` / `0x10005991C` | The plugin's toolbar actions reach the device window through the responder chain. Starting and stopping a recording posts `SimulatorVideoRecordingStartedNotification` / `…StoppedNotification` with the `SimDevice` under `…DeviceUserInfoKey`. | The device window implements the three actions; the session posts both notifications. Live, they turned the plugin's Save Screen button into Stop Recording (`toggleVideoRecording:`) and back. |
| `MainMenu.nib` | Device ▸ Re-Center Open Apps (`recenterAllOpenApps:`) after Home; Interaction, Look Around, Pan, Orbit, and Dolly Mode (`viewportModeChangedToInteraction:` to `viewportModeChangedToDolly:`, Control-Command-1 to 5), Reset Camera (`resetViewportCamera:`, Control-Command-0), and Simulated Scenes (`selectSimulatedScene:`, no submenu), each group after a separator; I/O ▸ Increase Immersion, Decrease Immersion, and Set Immersion To ▸ 0%, 25%, 50%, 75%, 100% (`setImmersionTo0:` to `setImmersionTo100:`); Features ▸ Optic ID ▸ Enrolled, Matching Eye, Non-matching Eye (`toggleOysterIDEnrolled:`, `oysterIDMatching:`, `oysterIDNonMatching:`); Features ▸ FaceTime, after Show StandBy and a separator, ▸ User and 1, 2, 3, and 4 Spatial Participants, User, 1 Participant and 4 Spatial Participants, and User, 8 Participants and 4 Spatial Participants (`configureSimulatedFaceTimeSession1x1:` to `configureSimulatedFaceTimeSession1x4:`, `configureSimulatedFaceTimeSession1x4x1:`, `configureSimulatedFaceTimeSession1x4x8:`, no shortcuts); Debug ▸ Show Gaze Target (`toggleShowGazeTarget:`). All go to the first responder. | `PluginCommand` items with the same actions and no target; Optic ID as `DeviceCommand`s. |
| `DWC.validateMenuItem:` `0x100051B8C`…`0x100051BB8` and `0x100051CD4`…`0x100051D28`; `DWC.recenterAllOpenApps:` `0x100058630` | Re-Center Open Apps is enabled with `SimFeatureHoverboard95880941`, but the device window's action is empty, so only the overlay, which comes first in the responder chain, carries it out. The Optic ID items are enabled with `SimFeatureOysterID`. | Re-Center Open Apps reaches only the overlay; without it, the item is disabled. |
| `deviceWindowBecameKey:` `0x10001A210`…`0x10001A264`, `updateKeyEquivalentForBiometricMenuItem:matching:enabled:` `0x10001AA6C` | Matching Eye and Non-matching Eye get Option-Command-M and N when the device supports `SimFeaturePearlID`, and no shortcut otherwise. | `DeviceCommand.hasKey`: none on Apple Vision Pro. |
| `sendOysterIDWithEnrolled:` `0x10003C7E8`, `sendOysterIDWithMatched:` `0x10003CA2C` | Enrolled sets and posts `com.apple.BiometricKit.enrollmentChanged`, which Touch ID and Face ID share; Matching Eye and Non-matching Eye post `com.apple.BiometricKit_Sim.oyster.match` and `.nomatch`, all with `SimDevice postDarwinNotification:error:`. | The same notifications. Live, `notifyutil` in the guest read the state 0, 1, and 0 again and received both posts. |
| XROS `VirtualHMDInputView.validateMenuItem:` (Xcode 27.1 `0x2ED38`, body `0x2E9BC`) | Checks Show Gaze Target while `PalomaSimController.cursorIsCurrentlyVisible`; enables the immersion actions only while `ImmersionController.immersionStyle` is 2 when the guest reports the style; for `selectSimulatedScene:` calls `fillSimulatedScenesSubmenu` (`0x2E028`), which needs a selected scene and builds or updates a submenu of the scenes (`selectSimulatedSceneWithSender:`, the scene identifier as represented object) with the selected one checked; enables the other actions, the six FaceTime actions among them (`0x2ECB0`…`0x2ED24`), without a checkmark. The camera-mode actions ignore their sender. | Validated by the overlay through AppKit. Live with Xcode 27.1: the camera modes moved the toolbar's segment to 0–4; a drag in Orbit Mode moved the camera and Reset Camera brought it back; Re-Center Open Apps moved the open Settings window; Show Gaze Target drew and removed the gaze target and its checkmark; the immersion items were disabled at style 1, and their actions changed the guest's level. With Xcode 27.0, 27.1, and 27.2, Simulated Scenes listed the six scenes of visionOS 26.5, checked the current one, and switched to the chosen one, and Show Gaze Target's checkmark followed the overlay. A device booted before its window connected reported no scene, which left Simulated Scenes disabled. |
| XROS `VirtualHMDInputView.configureSimulatedFaceTimeSession1x1:` … `1x4x8:` (Xcode 27.0, 27.1, and 27.2 `0x2D92C`…`0x2DDDC`; Xcode 26.6 `0x25F20`…`0x26344`), `SimVirtualHeadsetRemoteService configureSimulatedFaceTimeSession:spatialParticipantCount:` (`0x3968`) | Each action logs "Configuring simulated FaceTime session - …" and calls the plugin service with the counts of other and spatial participants: 0 and 1, 0 and 2, 0 and 3, 0 and 4, 1 and 4, 8 and 4. The service sends the guest an XPC message with `cmd` `simulate_facetime_session`, `standard_participant_count`, and `spatial_participant_count`, without a reply. In visionOS 26.5, `/usr/libexec/vhmdd`'s `FaceTimeSessionController` joins a conversation with that many of its test members through `TUCallCenter` (`TUJoinConversationRequest`). Simulator.app implements none of the actions; the overlay does, so the items work only while it is in the key window's responder chain. | `PluginCommand.faceTimeSessions`. Live with Xcode 27.0, 27.1, and 27.2 on an Apple Vision Pro on visionOS 26.5, the overlay enabled all six items. Each action reached `vhmdd`, which logged "Creating simulated FaceTime session with 0 standard participant(s) and 1 spatial participant(s)" and the other items' counts (1x1, 1x2, and 1x3 with Xcode 27.1, 1x4x8 with 27.0, 1x4 and 1x4x1 with 27.2), and FaceTime showed the call with its spatial test participants, such as Test Robot, and tiles for the others. |

The watch controls below were checked live with Xcode 27.0, 27.1, and 27.2 on
an Apple Watch Series 11 (46mm) on watchOS 27.0 and an Apple Watch Series 9
(45mm) and an Apple Watch SE (44mm) (2nd generation) on watchOS 26.5, in a
separate device set, through NeoSimulator's code. The Series 11 and Series 9
support `SimFeatureWatchGestures` (`com.apple.hid.watch.gestures`), all three
`SimFeatureDigitalCrown` (`com.apple.hid.digital-crown`) and
`SimFeatureFallDetection` (`com.apple.motion.fall-detection`).

| Reference owner | Observed behavior | Neo |
| --- | --- | --- |
| `DC.deviceWindowBecameKey:` `0x10001A3B4`…`0x10001A44C`, `0x10001A7AC` | Hides Gestures (`watchGestureMenuMenuItem`) without `SimFeatureWatchGestures`, Wrist Flick (`watchGestureWristFlickMenuItem`) when `device.runtime.version` is below `0xC0000` (watchOS 12), whatever the feature, and Simulate Fall without `SimFeatureFallDetection`. | The same rules through `DeviceCommand.isSupported`; a submenu whose items are all hidden is hidden. |
| `DWC.validateMenuItem:` `0x100051B6C`, `0x10005273C` | Enables `watchGestureTriggered:` with `SimFeatureWatchGestures` and `sendFallResolutionStatus:` with `SimFeatureFallDetection`. No checkmarks. | Shown only with the feature, enabled while the device is connected and booted. |
| `DWC.watchGestureTriggered:` `0x100054358`, body `0x1000542C0`; `DC sendIndigoHIDData:freeWhenDone:` `0x10001ABB4` | Passes the sender's tag (Double Tap 0, Wrist Flick 1) to `IndigoHIDMessageForWatchGesture`, which allocates one message with event subtype `0x46` (SimulatorKit 27.1 `0xBDC0`), and sends it through the coordinator's `legacyHIDClient` with `sendWithMessage:freeWhenDone:NO completionQueue:nil completion:nil`, so the message is never freed and its delivery is ignored. | Sends the same message through the display's `SimDeviceLegacyHIDClient` with `freeWhenDone:` YES and a completion that reports a failure. Live, Wrist Flick went from the app grid to the watch face and from the Smart Stack back to the face, and Double Tap on the face opened the Smart Stack. |
| `simDisplayView(_:changedChrome:)` witness `0x10005F828` → `0x10005F4C0` | Sets `digitizerView.supportScrolling` when the chrome is nil or the device supports `SimFeatureDigitalCrown` or `SimFeatureDigitalDial`. Then, when the display's screen `isDefault` and its `enabledInputs` contain `SimDeviceDisplayInputType` 0, which SimulatorKit adds while `digitizerView.isEnabled` (27.1 getter `0x64C58`), calls `SimDevice wantsEdgeSwipes:` with whether the chrome is non-nil (`0x10005F5AC`…`0x10005F620`). Simulator.app connects every display with the digitizer. | The same rule each time the window shows or hides the bezel, also when the display connects and after a restart: `setSupportsScrolling`, then `setWantsEdgeSwipes(padding != nil)`. A device window always shows the default screen, and IDEPlaygroundSimulator's factory connects every input, so its digitizer is enabled (live, `isEnabled` was true). |
| `SimDevice(KeyboardSync) wantsEdgeSwipes:` `0x10003C20C` → `0x10003D008`, body `0x10003C1AC`, helper `0x10003BF00` | On a global queue, sets the guest's `com.apple.UIKit.SimulatorWantsEdgeSwipes` state to the flag with `darwinNotificationSetState:name:error:` and posts it with `postDarwinNotification:error:`; a failure is released without a report. | `SimulatorConnection.setWantsEdgeSwipes` makes the same two calls on the main actor and logs a failure. |
| iOS 26.5 UIKitCore `-[_UIScreenEdgePanRecognizer initWithType:settings:]` `0xCB9694` and its notification block `0xCB97E8`, `useGrapeFlags` `0xCB9974`, `_incorporateInitialTouchAtLocation:…` `0xCB9C78`; `-[UIKeyboardLayout reloadKeyboardGestureRecognition]` `0xFF5860`, `-[UIKeyboardLayoutStar targetEdgesForScreenGestureRecognition]` `0xEDB908` | Each recognizer reads the state when it is created and when it is posted, and logs "Notification: Simulator edge swipe gestures are enabled" or "disabled". While it is 1, the recognizer treats the whole screen as the edge region but fails any touch whose edge modifier is not 1–4; at 0 it takes touches that start within the edge region, 13 points (11 at the bottom). The only creator is `UIKeyboardLayout`, for the edges of `targetEdgesForScreenGestureRecognition`, which `UIKeyboardLayoutStar` makes the bottom edge on an iPad and no edge elsewhere; a recognized swipe drops the keyboard's deferred touch, and a failed one plays it. `UIScreenEdgePanGestureRecognizer` uses its own gesture features (`_UISE…GestureFeature`, also in iOS 18.0, 18.6, and 26.0) and does not read the state. | Live, an iPad Air 11-inch (M3) on iOS 26.5 read 1 after its window connected with the bezel and then 0, 1, 0, 1 as Show Device Bezels changed; with the software keyboard up in Spotlight, Spotlight logged "disabled" and "enabled" at each change. On an iPhone 17 Pro on iOS 26.5, a drag from the bezel into the screen reached the guest as an edge touch (`swipe-locked`) and went home with the state at 0 and at 1; drags that started 1 and 4 points above the bottom edge went home with neither state, with or without the bezel, because only a touch that starts off the screen gets an edge (see [Bezel resizing and moving](#bezel-resizing-and-moving)). |
| SimulatorKit `SimDeviceLegacyHIDClient.simDigitizerInputView(_:scrollEvent:)` (27.1 `0x18BF8`) | Sends `IndigoHIDMessageForDigitalCrownEvent` with the negated vertical delta for a device with a crown, `IndigoHIDMessageForDigitalDialEvent` for one with a dial, and nothing otherwise. | Live, the factory's display had this client as the digitizer's delegate; scrolling with a mouse wheel (line deltas) and a trackpad (pixel deltas with phases) over the screen zoomed the app grid and opened the Smart Stack from the watch face, and with `supportScrolling` off it changed nothing. |
| `DWC.sendFallResolutionStatus:` `0x10005485C`, body `0x1000547F0`, dispatch `0x10003CB80`, helper `0x10003BF00` | Maps the sender's tag (Confirmed 0, Dismissed 1, Rejected 2, Unresponsive 3) to the state of `com.apple.sos.user-fell`, sets it with `SimDevice darwinNotificationSetState:name:error:`, posts it with `postDarwinNotification:error:`, and discards both errors. | The same calls; a failure is reported. Live, `notifyutil -1` and `-g` spawned in the device received each post and read states 0 to 3, the Mac's own state stayed 0, and the guest's Carousel (`com.apple.NanoPhone`, `sos_newton`) logged "simulating fall event with resolution: 0" to 3. |

### Apple TV Remote

Reference addresses are in Simulator.app 16.0 (1063.4) from Xcode 26.6 and its
`AppleRemoteWindowController.nib`; SimulatorKit's message builder is at
`0x11F88` in Xcode 26.6's and at `0xBE2C` in Xcode 27.0's, 27.1's, and 27.2's.
The live checks used Xcode 27.0, 27.1, and 27.2, CoreSimulator 1174.9.2, an
Apple TV 4K (3rd generation) on tvOS 27.0, and an Apple TV 4K (3rd
generation) (at 1080p) on tvOS 26.5 in a separate device set, through
NeoSimulator's code.

| Reference owner | Observed behavior | Neo |
| --- | --- | --- |
| `MainMenu.nib`; `DC` validation `0x10001F430`…`0x10001F574` | Window ▸ Show Apple TV Remote, after Show Device Bezels, with Shift-Command-R, sends `toggleAppleRemoteWindow:` to the first responder. The coordinator enables it when the key device's `productFamilyID` is 3 and titles it "Hide Apple TV Remote" while the shared remote's window is visible, otherwise "Show Apple TV Remote". `deviceWindowBecameKey:` never hides it. | `DeviceCommand.appleTVRemote`. |
| `DC.toggleAppleRemoteWindow:` `0x10001FDC4` | Closes `AppleRemoteWindowController.sharedInstance` while its window is visible, and otherwise sends it `showWindow:`. | `TVRemoteController.toggle()`, one controller for the app. |
| `AppleRemotePanel` `0x10002AADC` / `0x10002AAE4`, `AppleRemoteWindowController.windowDidLoad` `0x100023248`, `AppleRemoteContentView` `0x100022F38` / `0x100023044` | The 155 × 515 panel, titled "Apple TV Remote", is borderless (its initializer drops the nib's style mask), not opaque, with a clear background, movable by its background, hidden while the app is inactive, and never key. It does not cascade and saves its frame as "Apple TV Remote Window". The content view draws `Remote Chrome`. The touch surface (`AppleRemoteControlSurface`, the top 161 points, over the hint "Hold Option to touch") is Select; `AppleRemoteMouseDownTrackingControl`s over circle and capsule images are Menu, TV, Siri, Play/Pause, and Volume Up and Down. | The same panel, layout, and hint, drawn with AppKit and SF Symbols. |
| Button actions: Select `0x1000234B4`, Menu `0x100023584`, TV `0x100023654`, Play/Pause `0x100023724`, Volume Up `0x1000237F4`, Volume Down `0x1000238C4`, Siri `0x100023994`; `DC.deviceSupportsAppleTVRemote` `0x10001AB2C` | Each action checks that the key device's runtime platform is `kSimPlatformIdentifierTV`, then sends `IndigoHIDMessageForButton(button, sender.isButtonDown, 0x15)`, with buttons `0x190`, `0x191`, `0x192`, `0x194`, `0x195`, `0x196`, and `0x3F2`, through `sendIndigoHIDData:` (`0x10001ABAC`), discarding the result. A tracking control sends its action on mouse down and on mouse up (`_toggleIfNecessary:` `0x10002A1D0`). | The same messages, 1 and 0 at target `0x15`, for an Apple TV through the session's `SimDeviceLegacyHIDClient`. |
| `AppleRemoteControlSurface` `0x100026C88`…`0x100027094`; `SimulatorApp.sendEvent:` `0x1000240FC` | The surface tracks the pointer while the app is active and keeps the last point as x over its width and 1 − y over its height. With Option held when the pointer enters or moves, or when Option goes down with the pointer inside (`SimulatorApp` posts `OptionKeyDown` or `OptionKeyUp` for each modifier change), it starts a touch, then moves it; Option's release, a move without Option, or the pointer leaving ends the touch. A drag is followed as a move; the tracking area (options `0x43`) reports no exit while the mouse is down, and the point is not clamped, so a drag past the surface's edges moves the touch outside 0–1 and leaves it down after the mouse comes up. | `TVRemoteTouchSurface`, with a local monitor of modifier changes; a drag that leaves the surface ends the touch at the edge it crosses. |
| Touch actions `0x100023A64` / `0x100023B38` / `0x100023BFC` | `IndigoHIDMessageForTrackpadMoveEvent(point, 0x16)`. A start sets the UInt32 at `0x38` to `0x23` and at `0xD8` to 3; an end sets `0x38` to `0x21`, `0x64` and `0x68` to 0, `0xD8` to 1, and the 8 bytes at `0x104` to 0; a move sends the builder's message. | The same changes. Every builder above lays out the same 0x160-byte message: a header with 2 events of 0xA0 bytes, the second a copy of the first, whose event masks at `0x38` / `0xD8` are 4 (position) and whose flags at `0x64`, `0x68` / `0x104`, `0x108` are 1. The runtime check requires those. |
| `DC.deviceWindowBecameKey:` `0x100019BB4`…`0x100019C4C`, from `DWC.windowDidBecomeKey:` (body `0x10004ACB8`, call `0x10004AE58`) | For a key device with `SimFeatureTVRemote` (`com.apple.hid.tv-remote`), orders a visible remote front; for another device, closes it. An external display's or CarPlay's window is a `DeviceWindowController` of the same device, so it reaches the rule too. | The same, for each window that becomes key and stands for a device window, an external display's window included. |
| Device window close `0x100019774`…`0x1000197D4`; connection block `0x10001B97C` | Closing the last device window, of a device with `SimFeatureTVRemote`, closes the remote, and so does a device without the feature connecting. | The same at a close, counting visible and minimized device windows; a connecting device's window becomes key, which closes the remote. |
| `AppleRemoteWindowController.showWindow:` `0x100023CDC` / `windowWillClose:` `0x100023D50` | Post `AppleTVRemoteWindowDidShow` / `AppleTVRemoteWindowWillClose` for the Touch Bar's remote button. | Not posted; Neo has no Touch Bar items. |
| `SimulatorAppDelegate.keyDeviceCoordinator` `0x1000113F4` | The key window's device, or else the device of the frontmost device window. | `TVRemoteController.keyOrFrontmostDeviceWindow()`. |

Live, with each Xcode and runtime, both Apple TVs had `SimFeatureTVRemote`,
and the panel's controls, driven with mouse events as AppKit delivers them:

- Select opened Settings from the home screen. A drag down the touch surface
  with Option moved the focus from the first row to the sixth, and a drag up
  moved it back (`simctl io screenshot` before and after each).
- Menu, and TV, went back to the home screen from Settings.
- Holding Siri brought up Siri's dictation screen.
- Play/Pause, Volume Up, and Volume Down changed nothing on the home screen,
  and no input reported a failure. Option over the surface without a move
  changed nothing.

## Input capture

The evidence is Simulator.app 16.0 (1063.4) from Xcode 26.6, SimulatorKit from
Xcode 27.0, 27.1, and 27.2, whose `SimHIDCaptureManager` code is the same at the
addresses below, macOS 26.6.2, and an iOS 26.5 iPad mini (A17 Pro) in a
separate device set. In `MainMenu.nib`, I/O ▸ Input comes first and lists Send
Pointer to Device (Control-Command-K, `toggleCapturingMouse:`), Send Keyboard
Input to Device (Option-Command-K, `toggleCapturingKeyboard:`), and the hidden
Send Game Controller to Device (tag 7007). `SimFeatureSystemPointer` is
`com.apple.hid.pointer.system`. `DC` is `DeviceCoordinator`, `DWC` is
`Simulator.DeviceWindowController`, and `CM` is SimulatorKit's
`SimHIDCaptureManager`.

| Reference owner | Observed behavior |
| --- | --- |
| `DC.deviceWindowBecameKey:` `0x10001A50C`–`0x10001A55C` | Hides Send Keyboard Input to Device without `SimFeatureKeyboard` and Send Pointer to Device without `SimFeatureSystemPointer`. |
| `DWC.toggleCapturingMouse:` `0x10005834C`, `DWC.toggleCapturingKeyboard:` `0x100058458`, `DC.beginCapturingInputForHIDInputType:error:` `0x10001FFF0` | Send Pointer to Device captures types 3 (pointer and keyboard), Send Keyboard Input to Device type 1; choosing the command again stops the capture (`stopCapturingInput:`). The coordinator gives the manager the stop-capture keys (`CaptureEscapeKeyCodes`) and a safe pointer position, then calls `startCaptureSessionWithDevice:hidDeviceTypes:error:` (`0x100020140`). |
| Toolbar setup `0x100049D70`, capture update `0x1000499FC` | An iPad with `SimFeatureSystemPointer` takes the iPad toolbar, whose Capture Pointer and Capture Keyboard buttons send the same two actions. The update reads the capture types (pointer 2, keyboard 1), sets each button's state and its on or off image, and while a capture runs replaces the window's subtitle with `captureEscapeString`. |
| `+[CM localizedDescriptionForEscapeKeyCodes:]` `0xFB54` | The hint for the three settings: "Press esc to stop capture" (`[41]`), "Press both ⌘ keys to stop capture" (`[227,231]`), and "Press ⌃ ⌥ to stop capture" (`[224,226,65535]`). |
| `-[CM init]` `0xE074` | Creates an HID event-system client of type 1 (monitor) with `IOHIDEventSystemClientCreateWithType` and schedules it on its own queue; a NULL client fails an assertion. |
| `-[CM startCaptureSessionWithDevice:hidDeviceTypes:error:]` `0xE1D8` | On the main queue, stops a running capture and opens a `SimDeviceLegacyHIDClient`, whose failure is the only one it returns. For the pointer it detaches the pointer from the mouse (`CGAssociateMouseAndMouseCursorPosition(false)`), hides it, moves it to the safe position, and creates the guest's pointer and mouse services (`IndigoHIDMessageToCreatePointerService`, `IndigoHIDMessageToCreateMouseService`). It then creates an active event tap at the HID level (`CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault, …)`, `0xE66C`) and passes the result unchecked to `CFMachPortCreateRunLoopSource` (`0xE68C`); registers an HID event filter at priority `0x7FFFFFFF` (`IOHIDEventSystemClientRegisterEventFilterCallbackWithPriority`, `0xF240`), which reports no result; sorts the client's services into mice, Magic Mice, and trackpads; and posts `SimHIDCaptureManagerCaptureStartedNotification`. |
| Filter callback `0xF26C` | Sends the captured devices' keyboard events (`IndigoHIDMessageForKeyboardArbitrary`) and pointer, scroll, and trackpad events (`IndigoHIDMessageForPointerEventFromHIDEventRef`, `…ScrollEventFromHIDEventRef`, `…TrackpadEventFromHIDEventRef`) to the guest and consumes them, so they never become events for macOS or its apps. It also matches the stop-capture keys and then stops the capture on the main queue (`0x100C8`). |
| Event tap callback `0xEF14` | Sends nothing to the guest. It swallows key downs with their repeats and key ups, and the mouse, scroll, and gesture events of the captured mice and trackpads; it passes the key ups of keys pressed before the capture. |
| Entitlements | Simulator.app is signed with `com.apple.private.hid.client.event-filter`, `com.apple.private.hid.client.event-monitor`, and `com.apple.private.tcc.allow` for `kTCCServicePostEvent` and `kTCCServiceListenEvent`. |
| IOKit's HID event-system server, `_io_hideventsystem_register_event_filter` | Registers a filter only for an admin connection or one whose entitlements include `com.apple.private.hid.client.event-filter`; otherwise it logs "Error: the client with pid %d is missing the '%s' entitlement." and still returns success. |

The live check used an ad-hoc signed process, started from a shell, that had
neither Accessibility nor Input Monitoring: `AXIsProcessTrusted`,
`CGPreflightListenEventAccess`, and `CGPreflightPostEventAccess` returned false,
`IOHIDCheckAccess` returned denied for both, and no prompt appeared. It showed:

- The HID client connected as a monitor with entitlements `0x0`. Registering a
  filter as the manager does, passing every event through for half a second,
  made WindowServer log that the client was missing
  `com.apple.private.hid.client.event-filter`; the filter received no event.
- `CGEventTapCreate` with the manager's arguments returned NULL for its
  keyboard mask and for its mouse mask (`0xE640001E`).
- The iPad supported `SimFeatureSystemPointer` and `SimFeatureKeyboard`.
  `startCaptureSessionWithDevice:hidDeviceTypes:error:` with type 1 crashed
  the process with `EXC_BAD_ACCESS` in `CFMachPortCreateRunLoopSource`, called
  from the start method at `0xE690`, before it returned or posted a
  notification.

An app without the event-filter entitlement therefore cannot use the manager.
Without Accessibility, starting a capture crashes it. With Accessibility, the
code shows that the tap would swallow the Mac's key downs, and for pointer
capture freeze and hide the pointer, while nothing reaches the device and the
stop-capture keys, which only the filter matches, are never recognized. An
ad-hoc signature's designated requirement is its code hash (`cdhash H"…"`), so
a privacy permission such as Accessibility granted to one ad-hoc signed build
does not carry over to the next.

NeoSimulator leaves input capture out; the reasons and the alternatives that
were considered are in the [design](Design.md#input-capture).

## New Simulator's Paired Apple Watch

Simulator.app's File ▸ New Simulator… form is SimulatorKit's
`SimDeviceCreationView`. The addresses below are in SimulatorKit 16.0 (955.7)
from Xcode 26.6, arm64e slice; the nib is its
`SimDeviceCreationView.nib`.

| Reference owner | Observed behavior | Neo |
| --- | --- | --- |
| `SimDeviceCreationView.nib` | Under OS Version, the first page has a `Paired Apple Watch` checkbox (`pairedWatchButton`, action `_updateForwardButtonTitle:`). The second page, `pairedWatchCreationView`, has Paired Watch Name, Device Type, and OS Version (`gizmoDeviceNameField`, `gizmoDeviceList`, `gizmoRuntimeList`). Both pages replace each other in one box under "Create a new simulator:". Previous (`previousButton`) sits left of the forward button and starts disabled. | The same controls and titles in two grids, one hidden at a time. |
| Main-page update `0x7AE64` (`0x7B030`…`0x7B08C`), device-type correction `0x7AA7C` (`0x7AD40`…`0x7ADA4`) | Enables the option when the selected device type's `productFamilyID` is 1; otherwise also turns it off and updates the forward button. | The same after each device type or runtime choice. |
| `_updateForwardButtonTitle:` `0x7D700`, `0x78E18` | When the option is enabled and on, the forward button is "Next" with `nextPageButtonPressed:`; otherwise "Create" with `createSimulatorButtonPressed:`. | One action that checks the same state. |
| Next `0x7BF90`, Previous `0x7C0C8` | Next shows the second page, enables Previous, titles the button "Create", and enables it by the pairing check. Previous shows the first page, disables Previous, enables the button, and updates its title. | The same. |
| Watch menus, `0x7A098`…`0x7A4D8` | Device types with `productFamilyID` 4 in the service context's order, without separators, and the available runtimes that support any of them. Without watch device types both menus stay empty; without such a runtime, the runtime menu gets a disabled "No Runtimes Available" and both menus are disabled. The first update runs with the runtime menu as the sender. | The same. |
| Watch update `0x7BB98`, runtime menu rebuild `0x7B1A8`, device-type correction `0x7B880` | Sets the name's placeholder to the watch device type's name. When the runtime does not support the device type, a device-type choice (or an empty runtime) rebuilds the runtime menu with the runtimes that support it and selects the first, and a runtime choice selects the first device type it supports. | The same. |
| Create enabling `0x7BE80`, check `0x78E94` | Only on the second page: enabled when the four selections exist, the watch's runtime `supportsDeviceType:` its device type (`0x79158`), and `+[SimDevicePair testPossiblePairingWithDeviceTypeA:RuntimeA:DeviceTypeB:RuntimeB:error:]` returns YES for the watch's device type and runtime, then the phone's (`0x79184`). The error is dropped. | `SimulatorCatalog.canPair`, resolved at startup. |
| Create `0x7C200`; completions `0x7CA34`, `0x7CD9C`, `0x7D2D0`, `0x7D578` | Creates the phone with `SimDeviceSet createDeviceAsyncWithType:runtime:name:completionQueue:completionHandler:`. When the option is enabled and on, it then creates the watch the same way (`0x7CD04`), named by the field or else its placeholder (`0x78D5C`), and pairs them with `createDevicePairAsyncWithGizmo:companion:completionQueue:completionHandler:` (`0x7D1F8`). Each failure goes to `deviceCreationDidFail:error:`, an alert sheet on the form; nothing deletes the devices already created. Success closes the form. | `simctl create` for each device and `simctl pair <watch> <phone>`, which calls `createDevicePairWithGizmo:companion:error:`. The alert also names the devices already created. |

The live check used Xcode 27.1 and CoreSimulator 1174.9.2 in a separate device
set, through NeoSimulator's form. An iPad turned the option off. With an iPhone
17 Pro on iOS 27.0, the second page listed 32 watch device types and watchOS
26.5 and 27.0. Create made the iPhone and an Apple Watch Series 11 (46mm) on
watchOS 27.0, and `simctl list pairs` showed them as an active pair. Pairing
them again failed with CoreSimulator error 403 and left both devices.
`testPossiblePairing…` accepted every installed iOS runtime (18.0 through 27.2)
with watchOS 26.5 and 27.0 and rejected Apple TV and Apple Vision Pro as the
phone. It also accepted watch device types that the watch runtime does not
support, which is why the runtime check comes first.

## Deferred features

These have viable Xcode 27+ primitives but need a dedicated state/capability
contract before being user-visible:

- status-bar overrides;

## Excluded features

- Standard Edit/Services clipboard routing.
- Global keyboard, pointer, and game-controller capture. The reference app has
  private HID event-filter/event-monitor and TCC entitlements that the companion
  does not have; for the keyboard and pointer, see
  [Input capture](#input-capture).
- Device Manager or any Device Hub URL handoff.

These exclusions are part of the Neo-mode safety boundary, not missing
fallbacks.
