# Configuration and recovery

Select a display host and restore saved Xcode preferences from the app.

## Select a display host

Choose **NeoSimulator** or **Device Hub** under **Display Host** in Settings.
This is an app-wide choice; changing hosts leaves devices running. Routing
preferences apply across Xcode installations.

Startup, catalog updates, and opening device screens use the saved display
choice. Selecting a host in Settings or restoring original settings checks
Xcode's current preferences, including changes made by other tools. macOS may
request access to other apps' data for those explicit operations.

Continue using Xcode for Build & Run. The main window's inspector contains
settings for the selected simulator, separate from the app-wide display host.

## Select the UI framework installation

NeoSimulator loads its display frameworks from the Xcode selected by
`DEVELOPER_DIR`, or by `xcode-select` when that environment variable is unset.
To override that choice, quit NeoSimulator and launch it with:

```bash
open /Applications/NeoSimulator.app --args --xcode /Applications/Xcode_27.1.app
```

This selects the app's SimulatorKit and DeviceKit frameworks for that launch.
It does not limit which simulator runtimes can run or change Xcode's Build & Run
routing. Devices retain their own runtime and connection owner; a newer request
for the same device takes precedence over the previous owner. Changing the UI
framework installation requires restarting NeoSimulator because loaded Apple
frameworks remain registered for the lifetime of the process.

## Recover original preferences

Choose **Restore Original Settings…** in Settings before uninstalling. This
restores the original values saved when host management began, including whether a key
was absent or false. If another tool changed a managed preference, review the
reported conflict. Choose **Restore Saved Values…** and confirm only when you
intend to replace the current routing preferences with the saved originals.

The recovery receipt remains at
`~/Library/Application Support/xcode-simulator-host/state.plist`, including for
installations migrated from the previous CLI. Keep it until recovery is complete.
A host launch failure after committing preferences leaves this receipt available
for restoration. Device-operation failures appear in that device's window and
do not select another host.

## App preferences

**NeoSimulator → Settings…** (Command-,) contains General and Capture settings.
General controls the display host, reopening the last simulator, keeping devices
running when closing or quitting, and touch indicators. Capture controls the
device mask, GIF image size, and the file-size versus animation-smoothness choice.

Renderer preferences use `dev.lynnswap.NeoSimulator.Renderer`. Existing values
are migrated from `dev.lynnswap.NeoSimulator` on first use.
Per-device location choices use `DeviceLocationPreset.<UDID>` in
`dev.lynnswap.NeoSimulator`, shared by the manager and renderers.

| Preference | Effect |
| --- | --- |
| `AttachBootedOnStart` | Attach devices that are already booted at launch. |
| `SessionOnLaunch`, `StartLastDeviceOnLaunch`, `CurrentDeviceUDID` | Reopen the last simulator when launch restoration is enabled. The Settings checkbox updates both launch flags. |
| `DetachOnWindowClose`, `DetachOnAppQuit` | Leave devices running when closing or quitting. |
| `ShowSingleTouches`, `ShowPinches` | Show touch indicators; initially off and on respectively. |
| `ScreenShotSaveLocation`, `ScreenShotUseMask` | Screenshot folder and capture mask. |
| `GifMaxFrameSize`, `GifMaxFramerate` | GIF export size and frame rate. |
| `PasteboardAutomaticSync` | Automatic pasteboard exchange; initially off. |
| `EnableKeyboardSync` | Follow the Mac input-source language; initially on. |
| `UseTrackpadForce` | Use Force Touch pressure. |
| `RecentAudioInputDeviceUIDs`, `RecentAudioOutputDeviceUIDs` | Preferred available audio devices. |
| `LocationMode`, `LocationLatitude`, `LocationLongitude`, `LocationScenario` | Default location for devices without a saved per-device choice. |
| `SlowMotionAnimation`, `GraphicsQualityOverride` | Debug settings applied on connection. |

`ShowPinchPivotPoint` and `HighlightEdgeGestures` can also be changed through
`defaults write`. Preference changes are observed while Neo runs. Hardware
keyboard, external-display choices, and window geometry use independent
`DevicePreferences.<UDID>` records so renderers can save different devices
concurrently. Existing entries in the `DevicePreferences` dictionary remain
readable until that device is next saved. CoreSimulator's
`FramebufferServerGPUPolicy` is shared with other simulator hosts.
