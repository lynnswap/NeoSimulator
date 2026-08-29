# xcode-simulator-host

Use CoreSimulator for iOS Simulator runs from Xcode 27 without quitting Xcode.

## What It Does

`xcode-simulator-host` lets you:

- Run iOS Simulator from Xcode 27 through CoreSimulator.
- Return to Xcode 27's default Device Hub route.
- Restore the exact configuration from before the tool's first change.
- Switch routes without quitting Xcode.

## Requirements

- macOS 26.4 or later
- Xcode 27
- Xcode 26 when using the CoreSimulator route
- Apple Silicon when installing a prebuilt release
- Swift 6.4 when building from source

## How to Use

### Install

Install the latest prebuilt release:

```bash
curl -fsSL https://github.com/lynnswap/xcode-simulator-host/releases/latest/download/install.sh | sh
```

The installer places the command in `~/.local/bin` by default, verifies the
release checksum, and prints PATH guidance when needed. Follow that guidance
before continuing; the installer never edits shell profiles.

<details>
<summary>Install to a custom directory</summary>

```bash
curl -fsSL https://github.com/lynnswap/xcode-simulator-host/releases/latest/download/install.sh | sh -s -- --bindir "$HOME/bin"
```

</details>

Use `xcode-simulator-host --help` for the command list and
`xcode-simulator-host help <subcommand>` for subcommand options.

### Quick Start

Keep Xcode 27 open and run:

```bash
xcode-simulator-host use legacy
```

When Simulator opens, use **Build & Run** in Xcode as usual.

You can run `use legacy` again when the CoreSimulator route is already selected.
It leaves the selected route unchanged and opens or activates Simulator.

### Return to Device Hub

Select Xcode 27's default Device Hub route:

```bash
xcode-simulator-host use device-hub
```

The next Run uses Device Hub.

### Restore the Original Settings

Restore the exact configuration captured before the tool's first change:

```bash
xcode-simulator-host restore
```

Use `restore` to undo the tool's changes instead of explicitly choosing a route.

## Inspect the Current Route

Check the simulator route used by the next Run:

```bash
xcode-simulator-host status
```

For Xcode installations, preferences, restoration state, and running processes:

```bash
xcode-simulator-host status --verbose
```

Both commands are read-only. See
[Advanced configuration](Documentation/AdvancedConfiguration.md) for detailed
diagnostics, `DEVELOPER_DIR`, and non-default Xcode installations.

## Safety and Recovery

> [!IMPORTANT]
> This is an experimental tool built around undocumented Xcode preferences.

`use` validates compatibility before changing managed preferences, serializes
transitions, and verifies every write. It rolls back a failed write when the
previous state can be safely restored; external changes are never overwritten.
`restore` remains available without the compatibility check so the saved values
can be recovered.

The tool requests normal termination only for the exact Device Hub inside the
selected Xcode. It never force-quits Xcode or Device Hub.

The original preference state and any in-progress transition are stored at:

```text
~/Library/Application Support/xcode-simulator-host/state.plist
```

If the tool detects that another process changed a managed preference, it stops
rather than guessing which value should win. Inspect `status --verbose` before
using `restore --force`, which explicitly gives the saved original state
precedence over conflicting Boolean values.

If Device Hub termination or Simulator launch fails after the preference
transaction commits, the command reports partial success. Check the detailed
output from `status --verbose` before retrying or restoring.

Do not run mutation commands with `sudo`; preferences and recovery state are
per-user. Run `restore` before uninstalling the command or deleting its state
file.

See [Design and safety contract](Documentation/Design.md) for compatibility
checks, transaction ownership, partial-success behavior, and exit codes.

## Build from Source

```bash
git clone https://github.com/lynnswap/xcode-simulator-host.git
cd xcode-simulator-host
swift build -c release
.build/release/xcode-simulator-host --help
```

Run the isolated test suite with:

```bash
swift test
```

## License

xcode-simulator-host is available under the [MIT License](LICENSE).
