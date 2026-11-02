# Migrating from the CLI

[English](MigratingFromCLI.md) | [Japanese](MigratingFromCLI.ja.md)

No manual migration of settings or data is required. The app uses your existing
simulator devices, imports the previous NeoSimulator app preferences on first
launch, and keeps the original Xcode settings saved by the CLI available for
restoration.

1. Quit the old NeoSimulator app, or the Xcode 26 **Simulator** app if you used
   `xcode-simulator-host use legacy`.
2. [Install the new app](../README.md#installation) and choose a **Preferred Display Host** in Settings. Its
   **NeoSimulator** and **Device Hub** choices replace the CLI's host-switching
   commands; Legacy mode is not provided.

Removing the old CLI is optional, and the app doesn't do it automatically. For
the installer's default paths, run:

```bash
rm "$HOME/.local/bin/xcode-simulator-host"
rm -r "$HOME/.local/libexec/xcode-simulator-host"
```

If you chose custom installation paths, remove those copies instead.

Keep `~/Library/Application Support/xcode-simulator-host/state.plist`. It holds
the original Xcode settings saved by the CLI, and the app uses it for
**Restore Original Settings…**.
