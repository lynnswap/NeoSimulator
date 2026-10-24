# Getting started

Install NeoSimulator.app and choose the host that displays your simulators.

## Requirements

- Apple Silicon Mac with macOS 26.4 or later.
- Xcode 27 or later, selected with `xcode-select`.
- Simulator runtimes installed through Xcode.

## Install and choose a host

Download the DMG from [Releases](https://github.com/lynnswap/NeoSimulator/releases),
open it, and drag **NeoSimulator.app** to **Applications**. Launch the app and
choose **NeoSimulator** or **Device Hub** under **Display Host** in Settings.

Use Xcode for Build & Run as usual. NeoSimulator remains in the Dock while
Device Hub displays devices, so you can switch back at any time.
Switching hosts leaves devices running for the next host to attach.

Select a device in the main window and choose **View Screen** to open it.
You can also open **Device** in the Dock menu or **File → Open Simulator** and
choose its OS version and name. Selecting an already-running device brings its
window forward.

## Update or uninstall

Quit NeoSimulator, replace the app in Applications with the new version, and
reopen it. Before uninstalling, choose **Restore Original Settings…** in Settings
to restore the original preferences saved when host management began. See
<doc:Configuration> for recovery and the receipt location.

The app replaces the previous CLI distribution and Legacy mode. It keeps the
existing recovery receipt. For exact cleanup paths for an older CLI install,
see the [migration instructions](https://github.com/lynnswap/NeoSimulator#migrating-from-the-cli).
