# NeoSimulator

Use CoreSimulator with Xcode 27+ and choose the app that displays your simulators.

| Command | Display host |
| --- | --- |
| `xcode-simulator-host use legacy` | Apple's Simulator.app from Xcode 26. Recommended. |
| `xcode-simulator-host use neo` | The bundled NeoSimulator app. Beta; no Xcode 26 required. |
| `xcode-simulator-host use device-hub` | Device Hub from the selected Xcode. |

Xcode 27+ still handles Build & Run in every mode. Legacy and Neo use the same
CoreSimulator route, with different display hosts.

## Install

Requires Apple Silicon, macOS 26.4+, and Xcode 27+. Legacy also requires Xcode 26.

```bash
curl -fsSL https://github.com/lynnswap/NeoSimulator/releases/latest/download/install.sh | sh
xcode-simulator-host use legacy
```

Follow the installer's PATH instructions if needed. The command finds the newest
validated Xcode 26 in `/Applications`. To choose another installation:

```bash
xcode-simulator-host use legacy --legacy-xcode /Applications/Xcode_26.app
```

To try the beta host, run `xcode-simulator-host use neo`. It supports iPhone,
iPad, Apple Watch, Apple TV, and Apple Vision Pro, with device windows, input,
screen capture, pasteboard exchange, and simulator controls.

Both direct-host modes use undocumented Xcode preferences. Neo also uses private
Apple frameworks. Unsupported installations are rejected before switching hosts.

## Status and recovery

```bash
xcode-simulator-host status --verbose
xcode-simulator-host restore
```

`status` is read-only. `restore` recovers the original preferences; run it before
uninstalling. Use `use device-hub` to explicitly select Xcode's default host.
Run these commands as your normal user, without `sudo`.

## Documentation

[Read the documentation](https://lynnswap.github.io/NeoSimulator/documentation/neosimulator/)
for the [Neo user guide](Documentation/NeoSimulator.docc/UsingNeoSimulator.md),
[input and peripherals](Documentation/NeoSimulator.docc/InputAndPeripherals.md),
[configuration and recovery](Documentation/NeoSimulator.docc/Configuration.md),
and [architecture](Documentation/NeoSimulator.docc/Architecture.md).
The DocC sources live in [Documentation](Documentation/NeoSimulator.docc).

## Development

Source builds require Swift 6.4+ and Xcode 27+.

```bash
git clone https://github.com/lynnswap/NeoSimulator.git
cd NeoSimulator
scripts/build-local.sh
.build/local/arm64/bin/xcode-simulator-host --help
```

Open `NeoSimulator.xcworkspace` to work on the app and CLI. See
[Development](Documentation/NeoSimulator.docc/Development.md) for tests,
documentation builds, and release tooling.

## License

[MIT](LICENSE)
