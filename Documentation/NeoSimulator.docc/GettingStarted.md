# Getting started

Install the CLI and select a display host.

## Requirements

- Apple Silicon and macOS 26.4 or later.
- Xcode 27 or later for Build & Run.
- Xcode 26 for Legacy mode.
- Swift 6.4 or later for source builds.

## Install and select a host

```bash
curl -fsSL https://github.com/lynnswap/NeoSimulator/releases/latest/download/install.sh | sh
```

Follow any PATH instructions printed by the installer, then choose a host:

| Command | Host | Use |
| --- | --- | --- |
| `xcode-simulator-host use legacy` | Xcode 26 Simulator.app | Recommended; Apple's complete Simulator UI. |
| `xcode-simulator-host use neo` | Bundled NeoSimulator | Beta; works without Xcode 26. |
| `xcode-simulator-host use device-hub` | Selected Xcode's Device Hub | Return to Xcode's default host. |

Keep Xcode 27+ selected and use Build & Run as usual. Legacy supplies only the
Simulator UI. It automatically chooses the newest validated Xcode 26 under
`/Applications`; use `--legacy-xcode` to choose another installation:

```bash
xcode-simulator-host use legacy --legacy-xcode /Applications/Xcode_26.app
```

Repeating `use legacy` or `use neo` revalidates and restarts that host, even when
the CoreSimulator preferences are already correct. This also applies a changed
Xcode selection to Neo's loaded frameworks.

## Inspect or undo the change

```bash
xcode-simulator-host status --verbose
xcode-simulator-host restore
```

Status is read-only. Restore recovers the preferences saved before the first
change. Run it before uninstalling the CLI or deleting its state. For Xcode
selection and conflict recovery, see <doc:Configuration>.

Both direct-host modes use undocumented Xcode preferences, and Neo uses private
Apple frameworks. Each installation must pass compatibility checks. A failed
check stops the switch; the tool does not fall back to Device Hub.

## Choose an install directory

```bash
curl -fsSL https://github.com/lynnswap/NeoSimulator/releases/latest/download/install.sh \
  | sh -s -- --bindir "$HOME/bin"
```

The installer keeps the CLI and app in a fixed relative layout. It resolves a
symlinked destination, stages both products, and verifies them before replacing
an existing installation. Move or install them together.
