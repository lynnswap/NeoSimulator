# Using the SDK

Discover, control, and display simulators in a macOS app.

## Requirements

The SDK requires Apple Silicon, macOS 26.4 or later, Xcode 27 or later, and
Swift 6.4. Install simulator runtimes in Xcode.

Add the [NeoSimulator package](https://github.com/lynnswap/NeoSimulator) to your
project and select the products you need:

| Product | Purpose |
| --- | --- |
| [NeoSimulatorKit](https://lynnswap.github.io/NeoSimulator/documentation/neosimulatorkit) | Discover devices, read their state, and boot or shut them down. |
| [NeoSimulatorUI](https://lynnswap.github.io/NeoSimulator/documentation/neosimulatorui) | Present simulators in AppKit windows or view controllers. |

These two products are the supported API. The package's other products exist for
building and checking the NeoSimulator app, and they are not for use in other
projects.

Kit loads no UI toolkit. Creating [SimulatorScreens](https://lynnswap.github.io/NeoSimulator/documentation/neosimulatorui/simulatorscreens) loads the
process's SimulatorKit UI toolkit. Quit Apple's Simulator and Device Hub before
opening a screen.

## Open a simulator

Run this code on `MainActor` and retain `context`, `screens`, and `screen` while
presenting the device:

```swift
import NeoSimulatorKit
import NeoSimulatorUI

let context = try await SimulatorContext.load()
let devices = try await context.devices()
if let device = devices.first {
    _ = try await context.boot(device.id)
    let screens = try await SimulatorScreens(context: context)
    let screen = try await screens.open(device.id)
    try screen.showWindow()
}
```

[SimulatorScreens.open(_:)](https://lynnswap.github.io/NeoSimulator/documentation/neosimulatorui/simulatorscreens/open%28_%3A%29) attaches to a running guest; boot it
first when needed. Reopening an attached device returns the same screen while you
retain it. Concurrent calls
share the connection, and cancelling one caller ends only that caller's wait.

To embed a screen, create [SimulatorScreenViewController](https://lynnswap.github.io/NeoSimulator/documentation/neosimulatorui/simulatorscreenviewcontroller) or call
`screen.embed(in:)` with your own AppKit container. Use `showWindow()` to move it
back to a window, or `detach()` to remove its presentation while keeping the
connection.

## Read device state and send commands

`screen.session` provides the device model and guest commands, including
`press(_:onFailure:)`, `toggleAppearance()`, and `changeTextSize(by:)`.

For shared observable state, retain a [DeviceRegistry](https://lynnswap.github.io/NeoSimulator/documentation/neosimulatorkit/deviceregistry) and pass
it to `SimulatorContext.load(deviceRegistry:)`. The registry and each session then
use the same [DeviceModel](https://lynnswap.github.io/NeoSimulator/documentation/neosimulatorkit/devicemodel) for a device.

Retain the interest returned by `model.keepCurrent(.settings)` while a view
needs updates. Use `.applications` or other inspection groups to keep
`model.inspection` current. Reading a model property returns its cached value;
`registry.revalidate()` refreshes changes made elsewhere, such as when the app
returns to the foreground.

Screens open before their optional services finish connecting. Check
`session.inputReadiness` and `session.pasteboardReadiness` for progress or
failure. A failed service keeps its selected transport; `session.retryInput()`
retries the input connection.

## Close and shut down

For how each API reports failure, see [NeoSimulatorKit](https://lynnswap.github.io/NeoSimulator/documentation/neosimulatorkit).

`screen.close()` releases one screen. `context.invalidate()` finishes recordings
and releases all of the context's input and display resources. Both leave guests
running; call `context.shutDown(_:)` to stop a guest.

Await cleanup before terminating the app so you can report failures. A close
can throw after marking the screen closed; retry it or invalidate the context
to finish cleanup. If capture work outlasts the wait, the error identifies its
files and the next invalidation joins that work. An unsaved capture continues
to report its failure until resolved or acknowledged with
`context.acknowledgeCaptureFailures()`.

The [MinimalSimulatorApp sample](https://github.com/lynnswap/NeoSimulator/tree/main/Examples/MinimalSimulatorApp)
includes a package manifest, retained state, cleanup, and lifecycle checks.
