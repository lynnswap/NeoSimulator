# Migrating from the CLI

[日本語](MigratingFromCLI.ja.md)

Quit the old NeoSimulator app. If you used `xcode-simulator-host use legacy`,
quit Xcode 26's Simulator app as well. [Install NeoSimulator](../README.md#installation)
and open it. Your simulators and existing NeoSimulator preferences carry over.

You can remove the old CLI. These commands remove the copies in the default installation paths.

```sh
rm "$HOME/.local/bin/xcode-simulator-host"
rm -r "$HOME/.local/libexec/xcode-simulator-host"
```

Keep `~/Library/Application Support/xcode-simulator-host/state.plist`.
**Restore Original Settings…** uses it to restore the Xcode settings saved by the CLI.
