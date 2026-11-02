# Getting started

Install NeoSimulator.app, choose where simulators appear, and keep using Xcode
for Build & Run.

## Requirements

- Apple Silicon Mac with macOS 26.4 or later.
- Xcode 27 or later, selected with `xcode-select`.
- Simulator runtimes installed through Xcode.

## Install

1. Download a `.dmg` asset from [Releases](https://github.com/lynnswap/NeoSimulator/releases).
2. Open it and drag **NeoSimulator.app** to **Applications**.
3. Open NeoSimulator and choose **NeoSimulator** or **Device Hub** in
   **Settings → General → Display Host**.

If you already use the CLI, follow
[Migrating from the CLI](https://github.com/lynnswap/NeoSimulator/blob/main/Documentation/MigratingFromCLI.md).

## Open a simulator

In NeoSimulator mode, select a device in the main window and choose
**View Screen** to display it in the center pane. **Switch to Compact Window**
moves the screen to a separate window; **Show in Main Window** brings it back.
You can also open **Device** in the Dock menu or **File → Open Simulator** and
choose its OS version and name.

Use Xcode for Build & Run as usual. Change **Display Host** in Settings to
switch to Device Hub or back to NeoSimulator. Switching leaves simulator devices
running, and NeoSimulator stays in the Dock in either mode.

See <doc:UsingNeoSimulator> for device controls, screen capture, and app
management.

## Update

Quit NeoSimulator, open the new DMG, and drag **NeoSimulator.app** to
**Applications**, choosing **Replace**. Reopen the app. Restoring Xcode settings
is not required for an update.

## Uninstall

Choose **Restore Original Settings…** in **Settings → General** if available
to restore the saved Xcode routing preferences. Then quit NeoSimulator and remove the app from
Applications. Your simulator devices are kept. See <doc:Configuration> if
restoration reports a conflict.

If you previously installed the CLI, its files remain until you remove them.
See [Migrating from the CLI](https://github.com/lynnswap/NeoSimulator/blob/main/Documentation/MigratingFromCLI.md)
for the cleanup commands and the settings record that should be kept.
