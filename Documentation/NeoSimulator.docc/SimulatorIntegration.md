# Simulator integration

Private simulator interfaces are validated against the internally resolved Xcode
before use.

## Runtime boundary

Neo loads CoreSimulator, SimulatorKit, and IDEPlaygroundSimulator through
[ABIBridge](https://github.com/lynnswap/ABIBridge). Direct `simctl` and `devicectl`
operations use the resolved installation's validated tools. The app does not
load Simulator.app code or resources and does not modify or re-sign Xcode.

Duo screens in the default device set use DeviceKit's native device composition
from the selected UI framework installation. That composition owns the cover and
inner display providers, bezel, and pointer input. Posture controls send the
device's native hinge commands and follow its reported motion state.

The compatibility gate checks:

- Xcode and component generations, Apple signatures, bundle identities, and
  exact framework and tool paths.
- The `EXPECTED_VERSION` in each tool wrapper against its installed framework.
- The simulator CoreDevice plugin's version and generation, and unexpected
  DeviceKit or Device Hub linkage in the command-line tools and that plugin.
- The packaged renderer and its private runtime contract, including Objective-C
  messages, Swift members, C symbols, and loaded-image provenance.

The embedded renderer's internal `--validate-runtime` mode prepares the required
Simulator interfaces without creating an application or device session. This
required-only mode produces no stdout on success. Add `--include-native-bindings`
to explicitly prepare optional native canvas, pose, app-resize, display-HID,
remote display-geometry, and sidebar Active-state bindings and write their JSON
diagnostic report to stdout after the required checks succeed. Each result records
its preparation stage, any unavailable declaration or failure, and the remaining
device, provider, or service checks. Successful preparation does not establish
device support or working rendering and I/O. Optional preparation failures do
not change the required gate's successful exit status. Normal feature operations
prepare these bindings at their existing lazy boundaries and report their own
failures.

The gate inspects tool wrappers but does not execute them, avoiding their implicit first-launch setup.
Device UI plugins such as `XROS.simdeviceui` load when SimulatorKit connects a
display; their provenance is checked then.

Xcode 27 is the minimum generation. Later versions are accepted only when the
required contracts still match. An unavailable required interface stops the operation;
there is no compatibility bypass or Device Hub fallback.

## Reference evidence

The original behavioral analysis used Simulator.app 16.0 (1063.4) from Xcode
26.5, with window appearance also checked against Xcode 26.6. The following
addresses identify that reference binary only.

| Reference | Observation | Neo implementation |
| --- | --- | --- |
| `DeviceWindow.awakeFromNib`, `0x100035B28` | DarkAqua, transparent window, disabled tabbing, shadow setup | AppKit window shell |
| `DeviceWindowController.setShowChrome:`, `0x100048374` | Sets SimulatorKit display chrome | `SimDisplayView` chrome and key-state forwarding |
| `windowDidResize:`, `0x10004BEF4`; `windowDidEndLiveResize:`, `0x10004C040` | Update geometry and final render scale | Shared display fitting |
| `MainMenu.nib` and platform toolbar nibs | Menu order, actions, shortcuts, and platform variants | `DeviceCommand`, `MenuController`, `DeviceToolbar` |
| Home, `0x1000540EC`; Lock, `0x10005411C` | Send HID button down/up | Session-owned HID input |
| Save Screen, `0x1000570D8`; Record Screen, `0x100058EC4` | Capture options and destinations | Direct `simctl` capture and thumbnail handling |
| Window scale, `0x100054BBC` | Display render scale and size conversion | `WindowScale`, `DisplayFitting` |

The menu archive is a capability superset. Its presence alone does not establish
that a command works for every device or is available to an ad-hoc-signed app.
Command availability follows device capabilities and state. ABI layouts and
callback-lifetime constraints remain documented beside their bindings.

## Boundaries that affect behavior

Simulator.app's Mac input capture depends on Apple-only entitlements. Neo omits
Send Pointer to Device and Send Keyboard Input to Device, along with matching
iPad toolbar controls. Vision's plugin still displays its capture buttons, but
they do not capture Mac input. The ordinary focused keyboard path is supported.
Neo's separate Capture Keyboard command uses a public Quartz event tap with
macOS Accessibility access; see <doc:InputAndPeripherals>.

SimulatorKit owns multi-touch gesture state. A touch can survive a window's
disconnection while its simulator keeps running. The gesture-release guidance
in <doc:InputAndPeripherals> reflects that behavior.

External-display modes are constrained by the guest OS as well as CoreSimulator.
Neo uses 60 Hz, disables the known substituted 640×480 and unsafe older-iPad 4K
configurations, and requires a CarPlay mode for CarPlay. No host can add a
display port that CoreSimulator does not expose. CarPlay's options panel,
Simulator.app's device manager, and Apple-only input capture are unavailable.

## Verification scope

Unit and host tests validate isolated state, command handling, private-interface
lookup, and native window/input behavior; they do not establish simulator E2E
compatibility. See <doc:Development> for the commands.

An early live probe used Xcode 27.0 build `27A5252f` with iOS 26.5 and confirmed
rendering, accessibility, Home, software keyboard, focused typing, resizing,
capture, and framework provenance in an ad-hoc-signed process without Device
Hub. Subsequent development also exercised gestures, pasteboards, audio,
external displays, CarPlay, and Watch/TV/Vision controls. These are historical
observations, not a guarantee for every Xcode/runtime combination. Recheck the
affected device and runtime when changing a private interface.
