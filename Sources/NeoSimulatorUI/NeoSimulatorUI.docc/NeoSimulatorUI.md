# ``/NeoSimulatorUI``

Present simulators in AppKit windows and view controllers.

## Overview

Create one ``SimulatorScreens`` object for a ``/NeoSimulatorKit/SimulatorContext``, which loads the process's SimulatorKit
UI toolkit. Quit Apple's Simulator and Device Hub first, because only one app can display simulators at a time.

Boot the simulator through the context, open its screen, and choose how to present it:

```swift
let context = try await SimulatorContext.load()
_ = try await context.boot(deviceID)
let screens = try await SimulatorScreens(context: context)
let screen = try await screens.open(deviceID)
try screen.showWindow()
```

Run this code on the main actor, and retain the context, the screens object, and the screen while presenting the device.
A screen's ``SimulatorScreen/session`` provides the device model and guest commands. To embed a screen in your own
interface, create a ``SimulatorScreenViewController`` or call ``SimulatorScreen/embed(in:)``.

Closing a screen leaves its guest running. Call ``/NeoSimulatorKit/SimulatorContext/shutDown(_:)`` to stop the guest. For
a walkthrough, see [Using the SDK](https://lynnswap.github.io/NeoSimulator/documentation/neosimulator/usingthesdk).

## Topics

### Opening screens

- ``SimulatorScreens``

### Presenting screens

- ``SimulatorScreen``
- ``SimulatorScreenViewController``
