# Using the SDK

Open a simulator in your own macOS app.

Add the [NeoSimulator package](https://github.com/lynnswap/NeoSimulator) to an
app targeting macOS 26.4 or later on Apple silicon. Use Xcode 27 or later with
Swift 6.4 or later and install the simulator runtime you want to use.

[NeoSimulatorKit](https://lynnswap.github.io/NeoSimulator/documentation/neosimulatorkit)
provides device discovery, state, and commands. Add
[NeoSimulatorUI](https://lynnswap.github.io/NeoSimulator/documentation/neosimulatorui)
if you also want to show a screen in AppKit.

## Open a simulator

Load a context on the main actor and use `context.devices()` to get device IDs.
Before creating a presenter, quit Apple's Simulator and Device Hub.

```swift
import NeoSimulatorKit
import NeoSimulatorUI

let context = try await SimulatorContext.load()
let devices = try await context.devices()
let screens = try await SimulatorScreens(context: context)
```

Choose a `deviceID` from that list, then boot the simulator and present its screen.

```swift
_ = try await context.boot(deviceID)
let screen = try await screens.open(deviceID)
try screen.showWindow()
```

Keep the context, presenter, and screen while you use them. To show the
screen in your own window, use `SimulatorScreenViewController(screen:)`
or `screen.embed(in:)`. Call `screen.detach()` to remove its presentation
while keeping the connection.

## Read device state and send commands

Use `screen.session` for guest commands and `screen.session.deviceModel` for
observable state. To keep settings current, retain the interest returned by
`model.keepCurrent(.settings)` for as long as the view needs updates. To share
models with a device browser, create a `DeviceRegistry` and pass it to
`SimulatorContext.load(deviceRegistry:)`.

Input and pasteboard services can still be connecting when the screen opens.
Check `session.inputReadiness` and `session.pasteboardReadiness` before relying
on them. If input fails to connect, call `session.retryInput()`.

## Close and shut down

`try await screen.close()` closes one screen. To stop its guest too, call
`try await context.shutDown(deviceID)`. Before your app quits, call
`try await context.invalidate()` to finish recordings and release its
connections. If a capture failed to save, recover the file at the path in the
error, or report the failure and call `context.acknowledgeCaptureFailures()`.
Retry invalidation to finish outstanding work.

The [MinimalSimulatorApp sample](https://github.com/lynnswap/NeoSimulator/tree/main/Examples/MinimalSimulatorApp)
shows how to retain a screen and finish cleanup when an AppKit app quits.
