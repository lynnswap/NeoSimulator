# ``/NeoSimulatorUI``

Present simulators in AppKit windows and view controllers.

## Overview

Quit Apple's Simulator and Device Hub before creating a ``SimulatorScreens``
presenter for your ``/NeoSimulatorKit/SimulatorContext``. Boot the guest through
the context, then call ``SimulatorScreens/open(_:)`` to get its screen.

Call ``SimulatorScreen/showWindow()`` to give the simulator its own window,
or embed the screen with ``SimulatorScreenViewController``. Keep the screen
while it is open and use its ``SimulatorScreen/session`` to send guest commands.

For setup and sample code, see
[Using the SDK](https://lynnswap.github.io/NeoSimulator/documentation/neosimulator/usingthesdk).

## Topics

### Opening screens

- ``SimulatorScreens``

### Presenting screens

- ``SimulatorScreen``
- ``SimulatorScreenViewController``
