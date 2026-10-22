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
| `windowDidResize:` at `0x10004BEF4`, `windowDidEndLiveResize:` at `0x10004C040` | outside full screen, `windowDidResize:` runs the geometry update without a size or origin and invalidates the shadow; `windowDidEndLiveResize:` sets `renderScale` to `scale(for:)` of the display view's frame | existing `beginResize` / `resizeTo` / `endResize` bridge for a live resize, excluding the detached header area |
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
| Hardware / Software Keyboard | `0x10005571C` / `0x10005574C` | `SimDevice setHardwareKeyboardEnabled:keyboardType:error:` / HID button `0x3f0`; see [Keyboard and touch pressure](#keyboard-and-touch-pressure) |
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
  Home, Lock, Side Button, Action Button,
  Siri, Shake, App Switcher, Trigger Screenshot;
- I/O: Keyboard (Use the Same Keyboard Language as macOS, Connect Hardware
  Keyboard, Toggle Software Keyboard), Touch Pressure (Use Trackpad Force,
  Shallow Press, Deep Press), Audio Input, Audio Output, Increase Volume,
  Decrease Volume;
- Features: Touch ID and Face ID (Enrolled, Matching, Non-matching),
  Authorize Apple Pay, Toggle Appearance, Toggle In-call Status Bar,
  Show/Hide StandBy, Increase and Decrease Preferred Text Size, Toggle
  Increase Contrast, Trigger iCloud Sync, Location (None, Custom Location…,
  and the runtime's scenarios);
- Debug: Slow Animations, Graphics Quality Override, Color Blended Layers,
  Color Copied Images, Color Misaligned Images, Color Off-screen Rendered, Open
  System Log…, Simulate Memory Warning, Show Parallel Testing Devices;
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
| `DWC.windowScaleChanged:` `0x100054BBC`, body `0x1000548B0` | Menu tags 4108 Physical Size, 4109 Pixel Accurate, 4110 Point Accurate, 4111 Fit Screen. Sets `renderScale`, updates the window geometry (`0x10005B4A0`), then `setFrameOrigin:` back to the previous top edge. Fit Screen then centers the window in the visible frame (`0x10003872C`); the others move it back inside (`0x100038840`), along each axis it crosses, using `window.screen ?? NSScreen.main` and skipping full screen. |
| Physical Size helper `0x100038260` | `NSDeviceSize.width / (CGDisplayScreenSize(NSScreenNumber).width / 25.4)` over `mainScreenDPI.width / mainScreenScale`. 110 replaces the Mac's value only without a window screen, `NSScreenNumber`, or `NSDeviceSize`; 163 replaces the device's only without a device type. A zero size is divided by as is. |
| Pixel Accurate helper `0x100038488` | `SimDeviceScreen.scale / window.screen.backingScaleFactor`, each 1 when missing. |
| Fit Screen helper `0x100037E08` | `scale(for:)` of the visible frame less the window's chrome (`window.frame − displayView.frame`) and 20 points; 1000 without any screen. Not clamped to 1. Outside full screen the display view fills the content view below the gap (see [Window layout](#window-layout)), so the chrome is the title bar and the gap. |
| `DWC.validateMenuItem:` scale branch `0x100051D4C` | Needs `connectedScreen` and `DeviceWindow.fullScreenState == 3`. The `FullScreenState` cases are `entering`, `fullScreen`, `exiting`, and `none`, so 3 is `none`. Fit Screen is then enabled with its state untouched. Physical Size needs `displayClass & 0xFFFF == 0`. Each of these checks returns NO through `0x100051B10` without `setState:`, so the checkmark stays as it was; so does a menu without a device window, where no window controller validates the items. A fixed scale then sets its checkmark (`setState:` at `0x100051F50`) from `CGFloat.isAlmost(_:precision:)`, `abs(a − b) < 0.001`, and only afterwards requires the minimum (`0x100047884`). The fit check runs only when `chromeView.chrome` is nil (`getEnumTagSinglePayload == 1` at `0x100051FD0`); it compares `size(for:)` with the visible frame less the title bar, `window.frame.height − contentRect(forFrameRect: window.frame).height` (`0x1000520C8`–`0x100052150`), which leaves out the gap above the display. |
| What makes `SimDisplayChromeView.chrome` nil (SimulatorKit of Xcode 26.6) | `SimDisplayView.showDeviceChrome`'s `didSet` (`0x35510`) sets `chromeView.deviceType` to the device's type, or to nil when the bezel is hidden. `set(deviceType:)` (`0x56384`) reloads the chrome (`0x579CC`), which is nil without a device type, a context, `supportedChromeProfileBundles`, a `chromeIdentifier`, or a matching profile bundle. Simulator.app's `setShowChrome:` sets `showDeviceChrome`, and each connection sets it from the app-wide `ShowChrome` default. |
| Show Device Bezels: `-[SimulatorAppDelegate toggleShowChrome:]` `0x10001356C`, the app delegate's validation `0x100012518`, defaults `0x100025218` | Saves the negation of `boolForKey:@"ShowChrome"` and sends `setShowChrome:` to the window controller of every device coordinator whose `windowExists` (`0x100013730`). The validation sets the checkmark from `ShowChrome` and returns YES, also without a device window. `ShowChrome` is registered as YES. |
| Minimum scale `0x100047884` | iOS on display class 0: 0.4 for an iPhone, 0.25 otherwise; watchOS 0.6; otherwise `scale(for: 240×240)`, or 240 over the screen's pixel height for a display with chrome on other platforms. |
| Connection `0x10004E08C`, reading `0x10007B408`, scale `0x10004E988` | Looks up the current screen configuration (`0x10007A9B0`, below) and reads `DevicePreferences[UDID].SimulatorWindowGeometry` (`0x100079EDC`), or `ExternalWindowGeometry` (`0x10007A210`) for a screen that is not the default, at that configuration's `UUIDString`. From that entry it reads `WindowCenter` (`NSPointFromString` of a string) and `WindowScale`; without an entry for the configuration, both count as missing. The scale is 1 for CarPlay, when missing, or when ≤ 0. |
| Screen configuration `0x10007A9B0` | Collects the `frame` of each of `NSScreen.screens` and reads `ScreenConfigurations` (`dictionaryForKey:`) as `[String: [String]]`, or as empty when any value is not a list of strings. The configuration is the first entry, in the dictionary's iteration order, with as many strings as screens where each screen's frame is `CGRectEqualToRect` to one of the entry's `NSRectFromString` rectangles, in any order; its name becomes an `NSUUID` (`initWithUUIDString:`, which traps when it is not a UUID). Without a match, it creates an `NSUUID`, sets `ScreenConfigurations[UUIDString]` to the frames as `NSStringFromRect` strings, and saves the dictionary, so reading the geometry also registers a new configuration. |
| Connected display, main-queue block `0x10004E9F8` … `0x10004F2B8` | Sets `showDeviceChrome` from `ShowChrome` and runs the chrome refresh. After a restart (`isRebooting`, which `-[DeviceCoordinator rebootDeviceWithErase:]` sets), an iOS display of class 0 turns to angle 0 through `0x100053DAC` (the Orientation path below); the block then clears the flag and skips the rest, so the window keeps its scale and takes the upright shape below its top edge (`0x10005BA50`), then moves back inside the visible frame. Otherwise: `renderScale = min(fit, scale)` (`0x10004EDF8`); `deviceRotation` is set to the device's current angle for an iOS device on display class 0 that was booted outside Simulator.app (`wasBootedExternally`, `0x10004EF68`), and to 0 for a device Simulator.app booted (`0x10004F04C`); then the geometry update (`0x10004F064`), so that the window has its final shape before the center: at (0, 0) the cascade `0x10007A95C` (`center` when the app-wide `lastCascadePoint` is zero, then `lastCascadePoint = cascadeTopLeftFromPoint:`), otherwise `setFrameOrigin:` at the center less half the size. Then the chrome refresh, `makeKeyAndOrderFront:`, and the move back inside the visible frame (`0x100038840`). |
| Disconnect `0x10004FDB8` → `0x100050D84`, saving `0x10007B254` | Before `orderOut:`, saves the frame's center as `WindowCenter` (`NSStringFromPoint`) and `renderScale` as `WindowScale` when the window exists and the device is not rebooting. The two form a new dictionary that replaces `SimulatorWindowGeometry[UUIDString]` for the current screen configuration (`0x100073098`); the device's other configurations stay, and the result is written back to `DevicePreferences[UDID]` (`0x100073844`). The closure takes `isRebooting` when it is created (`0x10004F9F0`). `windowExists` is set when the window controller's `window` getter creates the window (`0x1000493BC`) and cleared when the window is set to nil (`0x1000494CC`). |
| Geometry update `0x10005B4A0` → `0x10004B2E4` | Sizes the window's content to the display's `intrinsicContentSize` plus the gap above the display (`0x100036364`), as wide as the display with no minimum, keeping its bottom-left corner, sets the toolbar style for that width, adds the title bar, applies `NSIntegralRect`, and moves it down when its top is above the visible frame, then `setFrame:display:NO animate:NO`. It never sets `renderScale`. The steps are in [Window layout](#window-layout). |
| Rotation `0x10005BA50` | Outside full screen: keeps `renderScale`, runs the geometry update, and sets the origin to the rounded previous x and previous top less the new height, moved down when the top is above the visible frame. Every caller then moves the window back inside the visible frame (`0x100038840`): the guest's rotation (`0x10004DDB8`), `0x10005151C`, Rotate Left and Right (`0x100053D4C`), and the Orientation items (`0x100053F0C`), which the restart path reaches through `0x100053DAC`. |
| Chrome refresh `0x10005AFFC`, from `DWC.setShowChrome:` `0x100048374` | With a chrome, removes `NSWindowStyleMaskResizable` and clears the background; without one, adds it (`styleMask | 0xF`) and uses black. Runs the geometry update when `fullScreenState == 3` (`0x10005B41C`), so Show Device Bezels keeps the scale. |
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
| Gap `0x10003570C`, uses `0x100036364`, `0x100035814`, `0x1000363A4` | The gap is `10 − (chromeView.chrome?.images.padding.height ?? 0)`, at the scale-1 padding whatever the display's scale. `0x100036364` adds it to a content height while the flag is on; `0x100035814` sets the top constraint's constant to it, or to 0 with the flag off. The chrome refresh sets the flag and calls `0x100035814` (`0x10005B3D4`–`0x10005B3F4`), and `simDisplayView(_:changedChrome:)` (`0x10005F644` → `0x1000363A4`) sets the constant again. Nothing in 16.0 clears the flag. The gap is 10 points without a bezel and for the iPhone 17 Pro's bezel (padding 9 by 0), and 1 point for the iPad bezels (padding 10 by 9). |
| Geometry update `0x10004B2E4(size:origin:)`, from `0x10005B4A0` | A flag ignores calls made while it runs. Without arguments it takes the size and origin of `contentRect(forFrameRect: frame)`. It sets `toolbarStyle`: `unifiedCompact` with `UseCompactTitleBar` (registered NO); otherwise `unified` when `UseMonobar` (registered YES) is on and the width is at least the threshold below, else `expanded`. On macOS 26 and later it hides the toolbar's last item, a flexible space, unless the style is `expanded`. It then reads the title bar as `frame.height − contentView.frame.height`, takes `NSIntegralRect(x, y, width, height + title bar)`, moves the frame down when its top is above the visible frame, calls `setFrame:display:NO animate:NO`, and invalidates the shadow. `0x10005B4A0` passes the display's `intrinsicContentSize` plus the gap (for CarPlay, with an adjusted height). Before that, without a chrome it sets `contentAspectRatio` to the screen's pixel size, turned for landscape, and `contentMinSize` to `size(for:)` at the minimum scale; with a chrome it clears both. |
| Toolbar style threshold `0x100049D38` | `DWC` offset `0x1000DAB68` plus offset `0x1000DABB8` plus 130. The first is the sum, over the toolbar's items whose view is an `NSButton`, of the view's width plus 4 (`0x100049F90`–`0x10004A160`), measured when the chrome refresh first gives the window its toolbar (`0x10005B274`, only while `window.toolbar` is nil and the screen is the default), before the window shows: 31, 32, and 25 points for the iPhone toolbar nib's buttons, and also 27 and 27 for the iPad's. The second is the wider of the title in `NSFont.preferredFont(forTextStyle: .headline)` and the subtitle in `.subheadline` (`0x10005AD00`–`0x10005ADA0`). |
| Title bar corners `0x100036518` | While the display view's `showDeviceChrome` is on outside full screen, rounds the corners of the `NSTitlebarContainerView` above the toolbar view with `maskedCorners` 3 and the window's `_cornerRadius` on macOS 26 and later (10 earlier); otherwise the radius is 0. |

Measured on macOS 26.6 with Simulator.app's own `IndigoiPhoneToolbar.nib`
and `IndigoiPadToolbar.nib` in a window built as above, the title bar is 52
points with the `unified` style and 76 with `expanded`. Right after
`setToolbar:`, before the window shows, the buttons still have the nib's
widths, so the threshold is 317.3 points for an iPhone 17 Pro titled
"iPhone 17 Pro" with the subtitle "iOS 26.5", and 413.4 for an iPad mini
(A17 Pro). AppKit itself gives an `NSWindow` an integral frame: it rounds the
origin down and the size up, which equals `NSIntegralRect` whenever the
origin is integral or the origin's fraction and the size's add up to a whole
point. When a `SimDisplayView` is up to a point larger than `size(for:)` at
its scale, SimulatorKit keeps the bezel, the screen, and the digitizer at
the view's lower-left corner, rounded to half points.

NeoSimulator's window keeps its full-size content view and transparent
unified toolbar; its header, `contentLayoutRect`'s inset, is the same 52
points. The gap, the display filling the window below it, and the fit
checks follow the table above; the differences are listed in the
[design](Design.md#commands-and-menus).

## Bezel corner resizing

The evidence is Simulator.app 16.0 (1063.4) from Xcode 26.6 and SimulatorKit
from Xcode 27.1. Simulator.app's `DeviceWindow` tracks the drag itself; its
window is not resizable while it shows a bezel.

| Reference owner | Observed behavior |
| --- | --- |
| `DeviceWindow.mouseDown:` `0x100037290` → `0x100036E70` | In full screen (`styleMask` bit 14) without a chrome, skips the corners; otherwise looks for the first of `displayView.typedResizeRects` whose `rect` contains `event.locationInWindow` (the display view sits at the window's origin). On a corner: sets `_allowResize`; saves `_initialFrame` (`contentRect(forFrameRect: frame)` with the display view's height), `_initialScale` (`renderScale`), `_initialMouse` (`NSEvent.mouseLocation`), `_resizeRectType`, and `_maxResizeScale` (`0x100037BB0`); calls `beginResize()` and posts `NSWindowWillStartLiveResizeNotification`. Otherwise, with `AllowsMoveByDragOnWindowChrome` (registered YES), calls `performWindowDrag(with:)`. It never calls `super`. |
| Maximum `0x100037BB0` | `scale(for:)` of the size from the opposite corner of `_initialFrame` to the edges of `(screen ?? NSScreen.main).visibleFrame`: width `initial.maxX − visible.minX` for the left corners, `visible.maxX − initial.minX` for the right; height `initial.maxY − visible.minY` for the lower corners, `visible.maxY − initial.minY` for the upper. 1000 without a screen. |
| `DeviceWindow.mouseDragged:` `0x100037860` → `0x100037448` | Without a chrome or `_allowResize`, calls `super`. Otherwise the width is the initial width minus the pointer's x movement (`NSEvent.mouseLocation − _initialMouse`) for the left corners and plus it for the right; the height minus the y movement for the lower corners and plus it for the upper. Sets `renderScale = min(_maxResizeScale, max(minimum, scale(for: size)))` with the minimum of the scale commands (`0x100047884`), then calls the geometry update (`0x10004B2E4`) with the content size of the display's `intrinsicContentSize` plus the gap above the display (`0x1000377CC` → `0x100036364`) and the origin that keeps the display's opposite corner, computed from the display's size alone: `x = initial.maxX − width` for the left corners, else `initial.minX`; `y = initial.maxY − height` for the lower corners, else `initial.minY`. |
| `DeviceWindow.mouseUp:` `0x1000373F8` → `0x1000372E0` | Without a chrome or `_allowResize`, calls `super`. Otherwise calls `endResize()`, clears `_allowResize`, posts `NSWindowDidEndLiveResizeNotification` (so `DWC.windowDidEndLiveResize:` sets `renderScale` from the display view's frame), and runs `0x10003853C`: outside full screen, when the frame does not intersect the visible frame inset by 128 points (`0x100038638`), moves it along each axis until it touches that inset frame. |
| Geometry update `0x10004B2E4(size:origin:)` | Both arguments are optional; without them it uses the current content rect. The frame is the content size plus the title bar at the origin, `NSIntegralRect`, moved down when its top is above the visible frame, then `setFrame:display:NO animate:NO`. A flag ignores calls made while it runs, such as from `windowDidResize:`. |
| Resize cursors: the window's setup `0x100035B50` (from `awakeFromNib` and the initializer), `fullScreenState` `didSet` `0x100036184` | The setup turns `displayView.showResizeCursors` on (`0x100036010`); each full screen change sets it to `fullScreenState == none`, followed by `invalidateCursorRectsForView:`. |

SimulatorKit (Xcode 27.1):

| Owner | Observed behavior |
| --- | --- |
| `typedResizeRects` getter `0x63F7C` | Empty without a chrome. Otherwise one `TypedResizeRect` (`type`, `rect`) per entry of `SimDeviceChrome.resizeRects` (`chrome.json`'s `resizeRects`: `type`, `scales`, `centerPoint`, `size`): the size is multiplied by `renderScale` when `scales` is set, the center plus the chrome images' `padding` by `renderScale`, and a negative center coordinate, whose padding is negated, counts from the view's frame width or height. The rects are in the display view's coordinates. The iPhone 17 Pro's bezel has two rects at each corner, such as 40 by 20 and 20 by 40 points at scale 1. |
| `SimDeviceChrome.ResizeRectType` | Cases `lowerLeft` 0, `lowerRight` 1, `upperRight` 2, `upperLeft` 3, whose raw values are their names. |
| `SimChromeResizeRectsExcludeView`, created in `SimDisplayView.init` (`0x660B8`); `hitTest:` `0x34684` → `0x34504` | Returns itself for a point inside any `typedResizeRects` while the chrome exists, otherwise nil. It does not handle the mouse, so the press reaches the window through the responder chain. |
| `resetCursorRects` `0x6440C` → `0x642D0` | When `showResizeCursors` is on (it starts off), adds `_windowResizeNorthEastSouthWestCursor` over the `lowerLeft` and `upperRight` rects and `_windowResizeNorthWestSouthEastCursor` over the others. |

NeoSimulator reads `typedResizeRects` through ABIBridge: the getter returns
the array as a runtime value, `Array.count` and `Array.subscript` bound to
`TypedResizeRect` read its elements, and `TypedResizeRect.rect`, `type`, and
`ResizeRectType.rawValue` read each one. `DeviceWindow` passes the mouse
events that reach it to `DeviceWindowController`, which tracks the drag as
above. Unlike Simulator.app, it converts the press to the display view's
coordinates, reads the pointer from each event's `CGEvent` location instead of
`NSEvent.mouseLocation`, does not post the live resize notifications, and
starts no drag in full screen. The user-visible differences are listed in the
[design](Design.md#commands-and-menus).

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
| `SimulatorApp.sendEvent:` `0x1000240FC` | For a modifier event, posts `OptionKeyDown` or `OptionKeyUp` for the toolbar; forwards a Command key-up to the key `DeviceWindow`. Every event then takes AppKit's normal route. |
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

## Deferred features

These have viable Xcode 27+ primitives but need a dedicated state/capability
contract before being user-visible:

- status-bar overrides;
- external displays and CarPlay.

## Excluded features

- Standard Edit/Services clipboard routing.
- Global keyboard, pointer, and game-controller capture. The reference app has
  private HID event-filter/event-monitor and TCC entitlements that the companion
  does not have.
- watchOS, tvOS, and visionOS-specific gesture, remote, camera, immersion, and
  viewport commands.
- FaceTime menus.
- Device Manager or any Device Hub URL handoff.

These exclusions are part of the Neo-mode safety boundary, not missing
fallbacks.
