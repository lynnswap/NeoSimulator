# Configuration and recovery

Select a display host and restore saved Xcode preferences from the app.

## Select a display host

Choose **NeoSimulator** or **Device Hub** in **Settings → General → Preferred
Display Host**. New installations default to NeoSimulator; existing choices are
preserved. Changes apply across Xcode installations and leave devices running.

Startup applies the saved choice; quitting keeps it. NeoSimulator does not launch
automatically. For future Xcode runs, choose Device Hub or **Restore Original
Settings…** to recover the preferences saved before Neo first changed them.

NeoSimulator checks Xcode's current preferences after showing its main window
at startup, and before selecting a host or restoring original settings. This
includes changes made by other tools. macOS may request access to other apps' data. If
access is denied, the alert offers **Copy Command** without quitting the app.
Run the copied command in Terminal, then reopen NeoSimulator to request access
again. The command resets only NeoSimulator's app-data
permission. Catalog updates and opening device screens use local
state. If startup cannot apply NeoSimulator, the settings keep your preference
and show **Use NeoSimulator** to retry after resolving the reported error.

Continue using Xcode for Build & Run. The main window's inspector contains
settings for the selected simulator, separate from the app-wide display host.

## Select the UI framework installation

Choose **UI Frameworks** in **Settings → General**. **Default (xcode-select)**
uses `DEVELOPER_DIR` when set, or the Xcode selected by `xcode-select` otherwise.
Select an installed Xcode to save an override, then choose **Restart to Apply**.
NeoSimulator restarts while keeping simulator devices running and reopening
their displayed screens.

This selects SimulatorKit and DeviceKit together. Devices retain their own runtime
and connection owner; a newer request for the same device takes precedence.
Restart is required because loaded frameworks stay registered for the process
lifetime. **Default (xcode-select)** removes the override.

## Recover original preferences

Choose **Restore Original Settings…** in Settings before uninstalling. This
restores the original values saved when host management began, including whether a key
was absent or false. If another tool changed a managed preference, review the
reported conflict. Choose **Restore Saved Values…** and confirm only when you
intend to replace the current routing preferences with the saved originals.

Original settings are stored in
`~/Library/Application Support/xcode-simulator-host/state.plist`, shared with the
previous CLI. No migration is needed. Keep it for restoration even after removing
the CLI.
A host launch failure after committing preferences leaves this receipt available
for restoration. Device-operation failures appear in that device's window and
do not select another host.

## App preferences

**NeoSimulator → Settings…** (Command-,) contains General, Devices, and Capture
settings.
General controls the preferred display host, UI framework installation, reopening the last simulator, keeping devices
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
| `PasteboardAutomaticSync` | Automatic pasteboard exchange; initially on. |
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
