# NeoSimulator

[English](README.md) | [Japanese](README.ja.md)

NeoSimulator is a lightweight simulator app for iPhone, iPad, Apple Watch, Apple TV,
and Apple Vision Pro.

![NeoSimulator showing an iPhone simulator and device settings](Documentation/Images/NeoSimulator.png)

## Requirements

- Apple Silicon Mac
- macOS 26.4 or later
- Xcode 27 or later, with simulator runtimes installed

## Installation

Download the DMG from [Releases](https://github.com/lynnswap/NeoSimulator/releases),
open it, and drag **NeoSimulator.app** to **Applications**.

By default, NeoSimulator displays simulators while the app is open. Your selected
display host is kept after quitting. To use Device Hub, choose it under
**Settings → General → Preferred Display Host**.

## Documentation

- [Documentation home](https://lynnswap.github.io/NeoSimulator/documentation/)
- [User guide](https://lynnswap.github.io/NeoSimulator/documentation/neosimulator/)
- [SDK guide](https://lynnswap.github.io/NeoSimulator/documentation/neosimulator/usingthesdk)
- API reference: [NeoSimulatorKit](https://lynnswap.github.io/NeoSimulator/documentation/neosimulatorkit/) and [NeoSimulatorUI](https://lynnswap.github.io/NeoSimulator/documentation/neosimulatorui/)
- [Migrating from the CLI](Documentation/MigratingFromCLI.md)
- [Development](Documentation/NeoSimulator.docc/Development.md)

## Acknowledgements

Background service control is ported from [simslim](https://github.com/MobAI-App/simslim), including its catalog of services that are safe to stop. Thank you to Interlap and the [simslim contributors](https://github.com/MobAI-App/simslim/graphs/contributors). simslim is available under the MIT License. Its notice and the licenses of NeoSimulator's package dependencies are available in **Settings → Licenses**.

## License

[MIT](LICENSE)
