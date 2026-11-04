# MinimalSimulatorApp

This independent Swift package imports only the public `NeoSimulatorKit` product.
It lists simulators, opens one in a window or an AppKit view controller, and releases
its display resources when the app quits.

Requirements match NeoSimulator: Apple Silicon, macOS 26.4, and Xcode 27 with a
simulator runtime installed. Quit Apple's Simulator and Device Hub before opening
a screen.

From this directory:

```sh
swift run MinimalSimulatorApp
swift run MinimalSimulatorApp --device SIMULATOR_UDID
swift run MinimalSimulatorApp --device SIMULATOR_UDID --embed
```

Without `--device`, the executable prints the available devices and exits. With a
device, it boots the guest if necessary. Quitting closes its screen and shuts down
only a guest that this run found shut down and booted itself.

Add `--exercise` to open a screen, press Home, close and reopen the screen, and
finish the session automatically. Use an iPhone or iPad simulator for this check.

The package intentionally does not import `XcodeSimulatorHost`, use an SPI import,
or depend on NeoSimulator's renderer executable.
