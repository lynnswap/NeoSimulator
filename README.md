# xcode-simulator-host

Switch Xcode 27 iOS Simulator runs between Device Hub and the classic Simulator
app from Xcode 26 while Xcode remains open.

This is an experimental tool built around undocumented Xcode preferences. It
checks the selected Xcode 27 installation, Device Hub, and managed preference
keys for the expected compatibility markers before `use` changes anything.
`use legacy` additionally requires an Apple-signed Xcode 26 and Simulator.

Requires macOS 26.4 or later and Xcode 27. Prebuilt releases are for Apple
Silicon. The legacy route also requires an installed Xcode 26; source builds
require Swift 6.4.

## Quick Start

```bash
curl -fsSL https://github.com/lynnswap/xcode-simulator-host/releases/latest/download/install.sh | sh
```

Inspect the current configuration, then switch to the Xcode 26 Simulator:

```bash
xcode-simulator-host status
xcode-simulator-host use legacy
```

Leave Xcode 27 open. After the command opens Simulator, use **Build & Run** in
Xcode as usual.

Switch back to Xcode 27's Device Hub route:

```bash
xcode-simulator-host use device-hub
```

Restore the exact preference state saved before the tool's first change:

```bash
xcode-simulator-host restore
```

`use device-hub` selects Xcode 27's default route by removing both overrides.
`restore` instead preserves whether each original preference was absent,
explicitly `false`, or explicitly `true`.

## Selecting Xcode Installations

The Xcode 27 installation comes from `DEVELOPER_DIR`, or from `xcode-select -p`
when `DEVELOPER_DIR` is unset:

```bash
DEVELOPER_DIR=/Applications/Xcode_27.app/Contents/Developer \
  xcode-simulator-host status
```

`use legacy` selects the newest validated Xcode 26 in `/Applications`. Pass an
absolute path when the installation is elsewhere:

```bash
xcode-simulator-host use legacy \
  --legacy-xcode /Applications/Xcode_26.app
```

The managed Xcode preference is shared by all installed Xcode versions. The
selected Xcode 27 determines which installation is validated, not a separate
preference domain.

## Install Options

<details>
<summary>Custom install directory</summary>

Install into a custom directory:

```bash
curl -fsSL https://github.com/lynnswap/xcode-simulator-host/releases/latest/download/install.sh | sh -s -- --bindir "$HOME/bin"
```

</details>

The installer verifies the release checksum and never edits shell profiles.
Use `xcode-simulator-host --help` for the complete command and option list.

## Safety and Recovery

`use` validates the selected Xcode before changing preferences, serializes
transitions, verifies every write, and rolls back a failed transition. `restore`
remains available without that compatibility check so the saved values can be
recovered. The tool only requests normal termination of the exact Device Hub
inside the selected Xcode; it never force-quits Xcode or Device Hub.

The original preference state and any in-progress transition are stored at:

```text
~/Library/Application Support/xcode-simulator-host/state.plist
```

If the tool detects that another process changed a managed preference, it stops
rather than guessing which value should win. Inspect `status` before using
`restore --force`, which explicitly gives the saved original state precedence
over conflicting Boolean values. If Device Hub termination or Simulator launch
fails after the preference transaction commits, the command reports partial
success; check `status` before retrying or restoring.

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
