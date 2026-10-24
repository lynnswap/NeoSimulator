# NeoSimulator

Display and control simulators with Xcode 27+, and switch between NeoSimulator
and Xcode's Device Hub from one Mac app. Xcode continues to handle Build & Run.

## Install

Requires Apple Silicon, macOS 26.4+, and Xcode 27+.

1. Download the DMG from [Releases](https://github.com/lynnswap/NeoSimulator/releases).
2. Open it and drag **NeoSimulator.app** to **Applications**.
3. Open NeoSimulator and choose **NeoSimulator** or **Device Hub** in Settings.

The app stays in the Dock in either mode. Choose **Display Host** in Settings
to switch hosts while leaving simulator devices running.
To update, quit NeoSimulator, replace the app in Applications, and reopen it.

NeoSimulator supports iPhone, iPad, Apple Watch, Apple TV, and Apple Vision Pro,
with device windows, input, screen capture, pasteboard exchange, and simulator
controls. Select a device in the main window and choose **View Screen** to open
its simulator window. You can also choose **Device** in the Dock menu or
**File → Open Simulator** to start a device or bring its window forward. The
menus group devices by OS version.

Use the main window's right inspector to view device information, manage
installed apps and profiles, or export and replace app data. Choose **Settings**,
**Content**, or **Info** in its toolbar. Available actions depend on the selected
device; see the [user guide](Documentation/NeoSimulator.docc/UsingNeoSimulator.md).

NeoSimulator uses private Apple frameworks and undocumented Xcode preferences.
Compatibility is checked before switching. Choose **Restore Original Settings…**
in Settings before uninstalling to restore the saved preference values.

## Migrating from the CLI

The app replaces the `xcode-simulator-host` command and Legacy mode. It reuses
the previous preference-recovery receipt, so existing settings can be restored
from the app. An older CLI installation is not removed automatically. If you
used the installer's default location, quit the old NeoSimulator first, then
remove these obsolete files after installing the app:

```bash
rm "$HOME/.local/bin/xcode-simulator-host"
rm -r "$HOME/.local/libexec/xcode-simulator-host"
```

Keep `~/Library/Application Support/xcode-simulator-host/state.plist` until you
have restored preferences or no longer need the saved original values. Custom
CLI installation paths must be removed from the location you selected.

## Documentation

[Read the documentation](https://lynnswap.github.io/NeoSimulator/documentation/neosimulator/)
for the [user guide](Documentation/NeoSimulator.docc/UsingNeoSimulator.md),
[input and peripherals](Documentation/NeoSimulator.docc/InputAndPeripherals.md),
[configuration and recovery](Documentation/NeoSimulator.docc/Configuration.md),
and [architecture](Documentation/NeoSimulator.docc/Architecture.md).

## Development

Source builds require Swift 6.4+ and Xcode 27+.

```bash
git clone https://github.com/lynnswap/NeoSimulator.git
cd NeoSimulator
scripts/build-local.sh
open .build/local/arm64/NeoSimulator.app
```

For a local app you keep using, sign each update with the same identity to keep
its signing requirement stable across builds. Pass a certificate name or SHA-1
hash from your keychain:

```bash
scripts/build-local.sh --signing-identity 'Developer ID Application: Your Name (TEAMID)'
```

You can also set `CODE_SIGN_IDENTITY` explicitly. Without either option, local
and validation builds continue to use an ad-hoc signature.

Open `NeoSimulator.xcworkspace` to work on the app, renderer, and host-switching
library. See [Development](Documentation/NeoSimulator.docc/Development.md) for
tests, documentation builds, and DMG release tooling.

## License

[MIT](LICENSE)
