# Configuration and recovery

Select Xcode, inspect host state, and restore saved preferences.

## Select Xcode

Commands use `DEVELOPER_DIR`, falling back to `xcode-select -p`:

```bash
DEVELOPER_DIR=/Applications/Xcode_27.app/Contents/Developer \
  xcode-simulator-host use neo
```

The selection supplies Neo's private frameworks and Xcode's Build & Run tools.
`--legacy-xcode` chooses only the Legacy UI:

```bash
xcode-simulator-host use legacy \
  --legacy-xcode /Volumes/Developer/Xcode_26.app
```

Use an absolute path to an intact Apple-signed Xcode 26 bundle. A Simulator.app
copied outside that bundle is not accepted. The selected Xcode 27+ remains the
Build & Run owner. Managed preferences are shared across Xcode installations.

## Read status

```bash
xcode-simulator-host status
xcode-simulator-host status --verbose
```

Both commands are read-only. Compact status shows the CoreSimulator or Device
Hub route. It cannot distinguish Legacy from Neo: they share the same route.
Verbose status includes selected Xcode and component versions, host availability,
running processes, managed preferences, and receipt state. Add `--legacy-xcode`
to inspect a specific Legacy candidate without selecting it.

## Recover original preferences

```bash
xcode-simulator-host restore
```

The receipt at
`~/Library/Application Support/xcode-simulator-host/state.plist` records original
and expected values, including the difference between an absent key and false.
Run restore before deleting the receipt or uninstalling. Commands must run as
your normal user, without `sudo`.

If another tool changed a managed preference, inspect verbose status first.
To deliberately replace that conflicting Boolean value with the saved original:

```bash
xcode-simulator-host restore --force
```

`--force` does not accept malformed or non-Boolean preferences. If the saved
route is CoreSimulator, restore leaves the choice of display host to you.
To explicitly return to Xcode's default route, use `use device-hub`.

## Neo preferences

**NeoSimulator → Settings…** (Command-,) exposes launch, close, quit, touch
indicator, capture-mask, and animated-GIF preferences. The app's defaults domain
is `dev.lynnswap.NeoSimulator`.

| Preference | Effect |
| --- | --- |
| `AttachBootedOnStart` | Attach devices that are already booted at launch. |
| `SessionOnLaunch`, `StartLastDeviceOnLaunch`, `CurrentDeviceUDID` | Control whether launch starts the last device when no windows attach. |
| `DetachOnWindowClose`, `DetachOnAppQuit` | Leave devices running when closing or quitting. |
| `ShowSingleTouches`, `ShowPinches` | Show touch indicators; initially off and on respectively. |
| `ScreenShotSaveLocation`, `ScreenShotUseMask` | Screenshot folder and capture mask. |
| `GifMaxFrameSize`, `GifMaxFramerate` | GIF export size and frame rate. |
| `PasteboardAutomaticSync` | Automatic pasteboard exchange; initially off. |
| `EnableKeyboardSync` | Follow the Mac input-source language; initially on. |
| `UseTrackpadForce` | Use Force Touch pressure. |
| `RecentAudioInputDeviceUIDs`, `RecentAudioOutputDeviceUIDs` | Preferred available audio devices. |
| `LocationMode`, `LocationLatitude`, `LocationLongitude`, `LocationScenario` | Last simulated location. |
| `SlowMotionAnimation`, `GraphicsQualityOverride` | Debug settings applied on connection. |

`ShowPinchPivotPoint` and `HighlightEdgeGestures` can also be changed through
`defaults write`. Preference changes are observed while Neo runs. Hardware
keyboard and external-display choices are per-device entries in
`DevicePreferences`. CoreSimulator's `FramebufferServerGPUPolicy` is shared with
other simulator hosts.

## Command failures

| Exit code | Meaning |
| ---: | --- |
| 0 | Success or documented no-op |
| 64 | Invalid invocation |
| 69 | Unavailable Xcode, host, framework, symbol, tool, or plugin |
| 70 | Internal invariant failure |
| 73 | Cannot create receipt or lock |
| 74 | Preference or state I/O failure |
| 75 | Operation locked, or a managed app did not terminate |
| 78 | Malformed configuration or conflicting state |

A host launch failure after preference commit is reported as partial completion.
The receipt remains available for restore. Optional device-operation failures
appear in that device's window and do not select another host.
