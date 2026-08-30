# NeoSimulator

Use iOS Simulator from Xcode 27+ through CoreSimulator, without making
Device Hub the display host.

> [!IMPORTANT]
> `use legacy` with Apple's `Simulator.app` from Xcode 26 is the recommended
> host. The packaged `NeoSimulator` host is under active development and is
> currently in beta.

## Why

Xcode 27 no longer bundles `Simulator.app`. Its default simulator UI is Device
Hub, but CoreSimulator still owns the simulated devices used by Build & Run.
This package makes that direct CoreSimulator route usable again and lets you
choose the UI that presents it.

## Host Choices

NeoSimulator provides three explicit host choices through the
`xcode-simulator-host` command:

| Command | UI host | Status and intended use |
| --- | --- | --- |
| `use legacy` | Apple's `Simulator.app` from Xcode 26 | **Recommended.** Keep the complete Simulator UI while using Xcode 27+ for Build & Run |
| `use neo` | Packaged `NeoSimulator` app | **Beta.** Try the standalone host under active development without needing an older Xcode |
| `use device-hub` | Device Hub from the selected Xcode | Return to Xcode's default behavior |

Legacy and Neo both select the same direct CoreSimulator preference route; the
difference is the process that presents the simulator. The restoration receipt
therefore owns preference recovery, not a remembered UI-host choice.

## Requirements

- macOS 26.4+
- Apple Silicon
- Xcode 27+
- Xcode 26 (`use legacy`)
- Swift 6.4+ (source builds)

## Recommended Quick Start: Simulator.app from Xcode 26

Install the latest prebuilt release:

```bash
curl -fsSL https://github.com/lynnswap/NeoSimulator/releases/latest/download/install.sh | sh
```

Follow the printed PATH guidance if needed, then run:

```bash
xcode-simulator-host use legacy
```

When Xcode 26 is installed in `/Applications`, the highest validated Xcode 26
version is selected automatically. Keep the selected Xcode 27+ installation
open and use **Build & Run** as usual; Xcode 26 supplies only the Simulator UI.

Running `use legacy` again is safe. The exact validated `Simulator.app` is
closed and reopened without rewriting an already-correct CoreSimulator route.

### Choose a Specific Xcode 26 Installation

To use an Xcode 26 installation outside `/Applications`, or to choose one
explicitly:

```bash
xcode-simulator-host use legacy \
  --legacy-xcode /Applications/Xcode_26.app
```

`--legacy-xcode` selects only the legacy UI host. Build & Run still uses the
Xcode 27+ installation selected through `DEVELOPER_DIR` or `xcode-select`.

## Try NeoSimulator (Beta)

`NeoSimulator` is an alternative host currently in beta and under active
development. It uses the selected Xcode 27+ installation and does not require
Xcode 26.

```bash
xcode-simulator-host use neo
```

Neo currently provides:

- one resizable window for each booted iOS simulator;
- device bezel, touch, accessibility, and focused keyboard input;
- Home, Save Screen, Rotate Right, and Software Keyboard controls in the
  window header;
- File, Device, I/O, Features, and Window menus modeled after Simulator.app;
- Home, Lock, Shake, rotation, appearance, bezel, Stay on Top, Fit Screen, and
  standard window commands.

Later Xcode versions are accepted only when their private CoreSimulator,
SimulatorKit, CoreDevice, and command-tool surfaces pass the compatibility gate.
An incompatible version fails closed; Neo never falls back to Device Hub.

Running `use neo` again is safe. It revalidates and restarts the exact packaged
host with the currently selected Xcode, so switching between compatible Xcode
27+ installations cannot leave a host using frameworks from the previous
selection.

## Return to Device Hub

```bash
xcode-simulator-host use device-hub
```

Validated legacy Simulator and Neo processes close before the default Device
Hub route is enabled.

## Restore the Original Settings

```bash
xcode-simulator-host restore
```

Use `restore` to undo the tool's preference changes instead of guessing which
route was originally configured. If the saved original route is CoreSimulator,
`restore` does not guess whether Legacy or Neo should be opened.

## Inspect the Current Route

```bash
xcode-simulator-host status
```

Compact status reports `CoreSimulator` or `Device Hub`. It cannot distinguish
Legacy from Neo because those hosts intentionally share the same preference
route.

For host availability, selected Xcode details, compatibility-checked private
components, preferences, restoration state, and running processes:

```bash
xcode-simulator-host status --verbose
```

Both commands are read-only. See
[Advanced configuration](Documentation/AdvancedConfiguration.md) for
`DEVELOPER_DIR`, `--legacy-xcode`, and recovery details.

## Safety and Recovery

> [!IMPORTANT]
> Both direct-host modes use undocumented Xcode preferences. Legacy launches an
> intact Apple-signed `Simulator.app` from a validated Xcode 26 installation.
> The beta Neo host also uses undocumented Apple frameworks.

Neither `use legacy` nor `use neo` launches Device Hub. If the exact Device Hub
process cannot be closed, the requested UI host is not opened. While Neo is
running, it also exits if Device Hub or a legacy `Simulator.app` appears, so two
UI hosts cannot own the same simulator session.

Before changing preferences, every `use` command validates the selected Xcode
27+ installation, the preference surfaces, and the exact Device Hub identity.
Additional host-specific gates run before any process or preference mutation:

- `use legacy` validates the outer Xcode 26 application, its version and Apple
  signature, and the nested `Simulator.app` identity, `DTXcode`, executable,
  and Apple signature;
- `use neo` validates the installed CoreSimulator/CoreDevice generations,
  direct tools and plugin, the packaged NeoSimulator identity, and the exact
  private runtime contract used by the GUI process.

Preference changes are journaled and verified. A conflicting external change
is left untouched unless the user explicitly runs `restore --force`.

The restoration receipt is stored at:

```text
~/Library/Application Support/xcode-simulator-host/state.plist
```

Do not run mutation commands with `sudo`; preferences and recovery state are
per-user. Run `restore` before uninstalling the command or deleting its state.

See the [design and safety contract](Documentation/Design.md), the
[Simulator.app analysis](Documentation/SimulatorAppAnalysis.md), and the
[NeoSimulator contract](Documentation/StandaloneHost.md) for exact owners and
exclusions.

## Install to a Custom Directory

```bash
curl -fsSL https://github.com/lynnswap/NeoSimulator/releases/latest/download/install.sh \
  | sh -s -- --bindir "$HOME/bin"
```

The installer keeps the CLI and bundled beta NeoSimulator app in a fixed
relative layout. It resolves a symlinked bindir to its physical directory, then
stages and verifies both before replacing an existing installation.

## Build from Source

```bash
git clone https://github.com/lynnswap/NeoSimulator.git
cd NeoSimulator
scripts/build-local.sh
.build/local/arm64/bin/xcode-simulator-host --help
```

The source build uses SwiftPM for the CLI and the beta `NeoSimulator` app
target in `NeoSimulator.xcworkspace`. The staging script puts both
products in the same relative layout used by releases.

Build and switch to the recommended Legacy host in one command:

```bash
scripts/build-local.sh && .build/local/arm64/bin/xcode-simulator-host use legacy
```

This runs from the repo-local staging directory; it does not install the command
into `PATH`. Use `use neo` instead to try the locally built beta host.

Run the isolated test suite with:

```bash
swift test
```

## License

NeoSimulator is available under the [MIT License](LICENSE).
