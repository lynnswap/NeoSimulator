# Configuration and recovery

NeoSimulator manages simulator display routing while it is open and restores the
original settings when you quit.

## Display routing

**View Screen** and other screen-opening commands display devices in NeoSimulator.
No display-host selection is required. Each launch registers NeoSimulator's display
bridges, including when an older version saved Device Hub as the preferred host.

Opening Device Hub directly from the Dock or Finder temporarily hands screens to
it. NeoSimulator observes that process and registers its bridges again when Device
Hub quits. Opening a screen from NeoSimulator also resumes its display session.
Neither operation saves a display-host preference.

NeoSimulator checks Xcode's routing preferences at startup, when handing screens
to Device Hub, and when restoring the original settings. This includes changes
made by other tools. macOS may request access to other apps' data. If access is
denied, the alert offers **Copy Command** without quitting the app. Run the copied
command in Terminal, then reopen NeoSimulator to request access again. The command
resets only NeoSimulator's app-data permission. Catalog updates read local recovery
metadata rather than other apps' preferences.

Continue using Xcode for Build & Run. The main window's inspector contains
settings for the selected simulator.

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

Quitting restores the original values saved when host management began.
**Restore Original Settings…** in Settings also releases routing while the app is
open, including whether a key
was absent or false. If another tool changed a managed preference, review the
reported conflict. Quitting leaves those external changes intact and reports that
restoration was not completed; the saved values remain available for recovery.
Choose **Restore Saved Values…** and confirm only when you intend to replace the
current routing preferences with the saved originals.

Original settings are stored in
`~/Library/Application Support/xcode-simulator-host/state.plist`, shared with the
previous CLI. No migration is needed. Keep it for restoration even after removing
the CLI.
A host launch failure after committing preferences leaves this receipt available
for restoration. Device-operation failures appear in that device's window and
do not select another host.

## App preferences

**NeoSimulator → Settings…** (Command-,) contains General, Devices, Capture,
Service Profiles, and Licenses settings; Debug builds also show Debug.
General controls the UI framework installation, keeping devices running when closing or
quitting, and touch indicators. Capture controls the
device mask, GIF image size, and the file-size versus animation-smoothness choice.

Renderer preferences use `dev.lynnswap.NeoSimulator.Renderer`. Existing values
are migrated from `dev.lynnswap.NeoSimulator` on first use.
Per-device location choices use `DeviceLocationPreset.<UDID>` in
`dev.lynnswap.NeoSimulator`, shared by the manager and renderers.

| Preference | Effect |
| --- | --- |
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
