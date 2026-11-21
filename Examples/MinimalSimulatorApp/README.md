# MinimalSimulatorApp

An AppKit example that lists simulators, boots a device, and opens its screen
in a window or view controller. See [Using the SDK](../../Documentation/NeoSimulator.docc/UsingTheSDK.md)
for package requirements and API usage.

From this directory, list devices and copy the UDID of a simulator in the default device set.

```sh
swift run MinimalSimulatorApp
```

Quit Apple's Simulator and Device Hub, then replace `SIMULATOR_UDID` with that UDID.

```sh
swift run MinimalSimulatorApp --device SIMULATOR_UDID
swift run MinimalSimulatorApp --device SIMULATOR_UDID --embed
```

When you quit, the sample shuts down the guest only if it booted it.
