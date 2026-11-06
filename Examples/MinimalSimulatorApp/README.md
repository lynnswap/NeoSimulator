# MinimalSimulatorApp

This independent Swift package imports only the public `NeoSimulatorKit` product.
It lists simulators, opens one in a window or an AppKit view controller, and releases
its display resources when the app quits.

The application retains one `DeviceRegistry` and passes it to `SimulatorContext.load`.
Its inventory and each screen's `deviceModel` share the same observable object.
Keep a `DeviceReadInterest` returned by `model.keepCurrent(.settings)` while a settings
view needs updates; returning to a device reuses its values. Call `registry.revalidate()`
when the application returns to the foreground to refresh changes made elsewhere.

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

Add `--exercise` to exercise concurrent opening, cancellation of a caller, Home,
detach and window presentation, overlapping close/reopen, and overlapping close
and shutdown. Use a shut-down iPhone or iPad simulator for this check.

`--exercise-callback` checks that a shutdown requested from the screen's close
callback stops the guest. It also requires a shut-down simulator.

`--exercise-external-shutdown` stops the guest with `simctl` and checks that the
screen reports `deviceStopping` or `deviceStopped` consistently with its state.
