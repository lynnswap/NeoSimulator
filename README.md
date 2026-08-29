# xcode-simulator-host

Use iOS Simulator through CoreSimulator from Xcode 27 or later, without running
Device Hub.

## Why

Xcode 27 routes simulator runs through Device Hub by default. Device Hub also
owns integrations such as continuous pasteboard synchronization, which can
interfere with simulator workflows that only need the traditional CoreSimulator
display and input path.

`xcode-simulator-host` selects the direct CoreSimulator route and supplies its
own lightweight simulator window. Xcode can remain open while the route changes.

## What

Legacy mode provides:

- one resizable window for each booted iOS simulator;
- device bezel, touch, accessibility, and focused keyboard input;
- Home, Save Screen, Rotate Right, and Software Keyboard controls in the
  window header;
- File, Device, I/O, Features, and Window menus modeled after Simulator.app;
- Home, Lock, Shake, rotation, appearance, bezel, Stay on Top, Fit Screen, and
  standard window commands;
- exact restoration of the preferences that existed before the first change.

Legacy mode does not launch Device Hub, load DeviceKit, or create a continuous
pasteboard-sync session. If Device Hub appears while the standalone host is
active, the host disconnects its simulator displays and exits.

## Requirements

- macOS 26.4 or later
- Xcode 27 or later
- Apple Silicon when installing a prebuilt release
- Swift 6.4 when building from source

Later Xcode versions are accepted only when their private CoreSimulator,
SimulatorKit, CoreDevice, and command-tool surfaces still pass the compatibility
gate. An incompatible version fails closed; legacy mode never falls back to
Device Hub.

## Quick Start

Install the latest prebuilt release:

```bash
curl -fsSL https://github.com/lynnswap/xcode-simulator-host/releases/latest/download/install.sh | sh
```

Follow the printed PATH guidance if needed, then run:

```bash
xcode-simulator-host use legacy
```

Keep Xcode open and use **Build & Run** as usual. The standalone host waits for
booted iOS simulators and opens their windows automatically.

Running `use legacy` again is safe. It restarts the exact packaged host with the
currently selected Xcode, so switching between compatible Xcode 27+ installs
cannot leave a host using frameworks from the previous selection.

## Return to Device Hub

```bash
xcode-simulator-host use device-hub
```

The standalone host closes before the default Device Hub route is enabled.

## Restore the Original Settings

```bash
xcode-simulator-host restore
```

Use `restore` to undo the tool's changes instead of explicitly choosing a route.

## Inspect the Current Route

```bash
xcode-simulator-host status
```

For selected Xcode details, compatibility-checked private components,
preferences, restoration state, and running processes:

```bash
xcode-simulator-host status --verbose
```

Both commands are read-only. See
[Advanced configuration](Documentation/AdvancedConfiguration.md) for
`DEVELOPER_DIR` and recovery details.

## Safety and Recovery

> [!IMPORTANT]
> This is an experimental tool built on undocumented Apple frameworks and Xcode
> preferences.

Before changing preferences, `use legacy` verifies:

- the selected Xcode is version 27 or later and intact Apple-signed code;
- the required preference keys and private framework symbols still exist;
- the installed CoreSimulator and CoreDevice generations match that Xcode;
- direct `simctl`, `devicectl`, and the simulator CoreDevice plugin are intact
  Apple-signed components with no DeviceKit or Device Hub linkage;
- the packaged standalone host has the expected identity and location.

The symbol check runs the exact packaged host in a non-UI validation mode, so
the preflight and the GUI launch use the same private-runtime contract.

Preference changes are journaled and verified. A conflicting external change is
left untouched unless the user explicitly runs `restore --force`.

The restoration receipt is stored at:

```text
~/Library/Application Support/xcode-simulator-host/state.plist
```

Do not run mutation commands with `sudo`; preferences and recovery state are
per-user. Run `restore` before uninstalling the command or deleting its state.

See the [design and safety contract](Documentation/Design.md), the
[standalone host contract](Documentation/StandaloneHost.md), and the
[Simulator.app analysis](Documentation/SimulatorAppAnalysis.md) for the exact
owners and exclusions.

## Install to a Custom Directory

```bash
curl -fsSL https://github.com/lynnswap/xcode-simulator-host/releases/latest/download/install.sh \
  | sh -s -- --bindir "$HOME/bin"
```

The installer keeps the CLI and companion app in a fixed relative layout. It
resolves a symlinked bindir to its physical directory, then stages and verifies
both before replacing an existing installation.

## Build from Source

```bash
git clone https://github.com/lynnswap/xcode-simulator-host.git
cd xcode-simulator-host
scripts/build-local.sh
.build/local/arm64/bin/xcode-simulator-host --help
```

The source build uses SwiftPM for the CLI and the
`XcodeSimulatorLegacyHost` app target in
`xcode-simulator-host.xcworkspace` for the companion. The staging script puts
both products in the same relative layout used by releases, so the source-built
command can also run `use legacy`.

Run the isolated test suite with:

```bash
swift test
```

## License

xcode-simulator-host is available under the [MIT License](LICENSE).
