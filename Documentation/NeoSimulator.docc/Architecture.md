# Architecture

NeoSimulator has a manager app and a renderer for each Xcode installation it uses.

The manager owns the device browser and windows. It loads one copy of
SimulatorKit and DeviceKit for its lifetime. Switching the Xcode that supplies
these frameworks requires restarting the manager.

The bundled renderer also acts as a windowless bridge. In renderer mode it
handles simulator lifecycle operations for one Xcode. In bridge mode it receives
the device URLs that Xcode would send to Device Hub.

Within a process, the browser, inspector, and screens share a `DeviceRegistry`.
It keeps one observable `DeviceModel` per device. A simulator's identifier
includes its device set so Xcode's parallel testing devices stay distinct.
Physical devices and VMs use their CoreDevice identifiers.

The Swift package exposes `NeoSimulatorKit` and `NeoSimulatorUI` as its SDK.
When changing target dependencies, update both `Package.swift` and the graph
in `scripts/check-module-graph.py`.
