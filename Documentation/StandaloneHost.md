# Xcode 27+ standalone simulator host

## Why

Legacy mode exists so an Xcode Run can use CoreSimulator directly without a
Device Hub process. Device Hub is not an acceptable display host for this mode:
starting it can activate clipboard synchronization and other device-management
behavior that changes the simulator session.

Xcode Previews demonstrates the intended boundary. Its interactive canvas
connects a `SimulatorKit.SimDisplayView` directly to a CoreSimulator screen and
adds its own chrome and scaling. It does not use DeviceKit or launch Device Hub.

## What

Legacy mode provides a dedicated AppKit host with these guarantees:

- it uses only the selected Xcode 27 or later installation and the matching
  CoreSimulator system resources installed with Xcode;
- it never opens the Device Hub URL scheme or loads
  `DeviceKit.framework`;
- it does not create a clipboard synchronization owner;
- it displays each booted iOS simulator and forwards touch, accessibility, and
  focused keyboard input;
- it provides Home, Save Screen, Rotate Right, and Software Keyboard controls
  in the header, plus validated Simulator-style menus;
- its windows resize the hosted display without changing the simulated
  device's logical screen size;
- it fails closed if Device Hub is already running or launches while the host
  is active.

There is no fallback to Device Hub from legacy mode. An unsupported Xcode build,
missing private symbol, display connection failure, or process conflict is
reported as an unavailable legacy host.

## How

```text
xcode-simulator-host use legacy
  -> validate the selected Xcode 27+ and standalone host components
  -> commit the CoreSimulator-only preference route
  -> normally terminate the exact Device Hub from that Xcode
  -> verify Device Hub is absent
  -> launch XcodeSimulatorLegacyHost.app and wait for its startup result

XcodeSimulatorLegacyHost.app
  -> CoreSimulator SimServiceContext / default device set
  -> observe booted iOS SimDevice instances
  -> IDEPlaygroundSimulator display factory
  -> SimulatorKit SimDisplayView in a resizable AppKit window
  -> SimDeviceLegacyHIDClient for Home, Lock, and Software Keyboard
  -> typed direct simctl/devicectl operations for screenshot and rotation
```

### Owner map

| Responsibility | Owner |
| --- | --- |
| Route preferences and restoration | `HostModeController` |
| Exact Device Hub termination and host launch | `WorkspaceClient` |
| Xcode and private-component compatibility gate | `InstallationInspector` |
| Private runtime classes, selectors, and Swift thunks | `XSHPrivateRuntime` |
| Booted-device membership | standalone host device-set observer |
| One display connection and HID session | standalone host device session |
| Window, toolbar, focus, and scaling | standalone host AppKit window controller |
| Menu construction and active-window routing | standalone host menu controller |
| Screenshot and rotation subprocesses | per-window typed device-tool runner |
| Clipboard synchronization | deliberately no owner |

The CLI and GUI host exchange only the selected Xcode application path. Private
CoreSimulator and SimulatorKit objects never cross the process boundary.

### Private component boundary

The host dynamically loads these components after validating their paths and
required symbols:

- `/Library/Developer/PrivateFrameworks/CoreSimulator.framework`
- `Xcode.app/Contents/SharedFrameworks/SimulatorKit.framework`
- `Xcode.app/Contents/Frameworks/IDEPlaygroundSimulator.framework`

Before any preference or process change, the CLI runs the exact packaged host
in its non-UI `--validate-runtime` mode. That mode constructs
`XSHPrivateRuntime`, exercising the same `dlopen`, `dlsym`, private-class,
selector, and loaded-image checks used by the GUI launch, then exits without
creating `NSApplication`, a device set, or a display session. It deliberately
does not reject an already-running Device Hub; the mutation flow terminates the
validated Device Hub later, after the route is committed.

`CoreSimulator.framework` is installed by Xcode's
`com.apple.pkg.XcodeSystemResources` package. `SimulatorKit` links to that
system resource; the host must reject an incompatible or missing installation.
The selected Xcode major version and the installed CoreSimulator `DTXcode`
generation must match.

The display factory is
`IDEPlaygroundSimulator.IDESimulatorPlaygroundUntil`
`createSimDisplayViewWithDevice:simScreenID:`. The host discovers the default
integrated `SimDeviceScreen`; it must not assume screen ID zero.

Home, Lock, and Software Keyboard use one `SimDeviceLegacyHIDClient` per
displayed device and `IndigoHIDMessageForButton` with values verified on the
baseline Xcode 27 build:

| Input | Button | Down | Up | Target |
| --- | ---: | ---: | ---: | ---: |
| Home | `0` | `1` | `2` | `0x33` |
| Lock | `1` | `1` | `2` | `0x33` |
| Software Keyboard | `0x3f0` | `1` | `2` | `0x33` |

Save Screen runs the direct, compatibility-checked CoreSimulator `simctl`
binary and atomically installs a validated PNG chosen through `NSSavePanel`.
Rotate Left/Right runs the direct, compatibility-checked CoreDevice
`devicectl` binary. The session reads its actual JSON orientation on attachment
and after every relative rotation before updating the display chrome. Both
operations are typed and single-flight, with drained output, a bounded timeout,
and cancellation on window close.

### Device Hub invariant

Before the GUI host connects to CoreSimulator, it verifies that no running
application has bundle identifier `com.apple.dt.Devices`. It observes workspace
launches while active. If Device Hub appears, the host disconnects every display
and exits instead of allowing both hosts to own the same simulator session.

`use legacy` keeps `disableAutoStartLiveDeviceView = true` and normally
terminates only a Device Hub whose resolved bundle URL matches the selected
Xcode. The standalone host never imports DeviceKit, loads a DeviceKit plugin, or
opens a `devices:` URL.

CoreSimulator transitively maps `SimPasteboardPlus.framework`; merely mapping
that dependency is not a synchronization session. The standalone host does not
instantiate or call any pasteboard type, and validation checks that neither
DeviceKit nor Device Hub is loaded.

### Lifecycle

- `use legacy` is idempotent: it normally terminates the exact packaged host and
  starts it again with the currently selected Xcode after validating the route
  and Device Hub absence.
- LaunchServices process creation is not treated as readiness. The CLI returns
  success only after the host has created its private runtime and device-set
  owners and atomically written the per-launch startup result.
- The host stays alive without a booted device so it can display a simulator
  started by a later Xcode Run.
- Device-set notifications add windows for newly booted iOS devices and remove
  their sessions after shutdown.
- Closing a device window suppresses reopening it until that device leaves the
  booted state. Running `use legacy` again restarts the exact packaged host and
  reconstructs windows for currently booted devices.
- Switching to Device Hub, or restoring a Device Hub route, closes the standalone
  host before enabling that route.

### Failure semantics

- Missing or changed private components: unavailable, no host launch.
- Device Hub cannot terminate or is observed at host startup: temporary
  conflict, no display connection.
- A device has no discoverable default integrated screen: that device gets no
  window and the host surfaces the connection error.
- HID creation fails: the device window is not opened with nonfunctional
  controls.
- Device Hub launches while connected: disconnect all sessions and exit.

## Verified baseline

The live probe used Xcode 27.0 build `27A5252f` and an iOS 26.5 simulator. It
confirmed all of the following in an ordinary, ad-hoc-signed process:

- framebuffer rendering and guest accessibility through `SimDisplayView`;
- guest UI updates without Device Hub;
- Home from Safari to SpringBoard;
- Software Keyboard hide and show;
- focused macOS keyboard input reaching a guest Safari field;
- window resize from `460x900` to `320x620` while preserving rendering and
  accessibility;
- Simulator-style menus, Save Screen PNG output, appearance, and rotation in
  both directions, including an initially landscape device;
- source-built and release-layout app bundles passing the same non-UI runtime
  validation and startup acknowledgement;
- only `/Applications/Xcode_27.app` supplied Xcode frameworks;
- no Device Hub process or launch log during the probe;
- no `DeviceKit.framework` mapping and no pasteboard-session log.

Xcode 27 is the minimum supported generation, not the only supported version.
Later Xcode versions are accepted when the selected installation and its
matching CoreSimulator resources still satisfy every required preference,
class, selector, and C-symbol check. A later major version that changes this
private surface fails the compatibility gate instead of falling back to Device
Hub.

## Progress

- [x] Static owner analysis, including Xcode Previews and macOS private
  frameworks
- [x] Focused live probe for display, input, controls, resize, and Device Hub
  absence
- [x] Packaged AppKit host
- [x] CLI lifecycle integration and status reporting
- [x] Simulator.app window and menu analysis
- [x] Unit and packaging validation
- [x] Final integrated live regression and review
