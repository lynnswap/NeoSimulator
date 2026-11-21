# ``NeoSimulatorKit``

Discover devices, read and change their state, and boot or shut down simulators.

## Overview

Use a ``SimulatorContext`` on the main actor to manage the simulators of one
Xcode installation. For a device browser, a ``DeviceRegistry`` lists simulators
and CoreDevice devices and keeps one observable ``DeviceModel`` per device.

Model properties return cached values. Retain a ``DeviceReadInterest`` for the
groups you display, and check ``DeviceReadStatus`` and ``DeviceModel/lastIssue`` if
a read fails. If a command throws ``SimulatorError/outcomeUnknown(_:underlying:)``,
read the device's state before repeating it. Use ``SimulatorContext/onError``
for failures reported after a call returns.

To add a screen to an AppKit app, see
[Using the SDK](https://lynnswap.github.io/NeoSimulator/documentation/neosimulator/usingthesdk).

## Topics

### Simulators

- ``SimulatorContext``
- ``SimulatorDeviceSnapshot``
- ``SimulatorDeviceIdentifier``
- ``SimulatorDeviceFamily``
- ``SimulatorDeviceState``
- ``SimulatorBootOutcome``

### Open sessions

- ``SimulatorDeviceSession``
- ``SimulatorButton``
- ``CADebugOption``
- ``SimulatorServiceReadiness``
- ``SimulatorScreenEnd``

### Shared device state

- ``DeviceRegistry``
- ``DeviceModel``
- ``DeviceInventoryID``
- ``DeviceInventoryKind``
- ``DeviceStateGroups``
- ``DeviceReadInterest``
- ``DeviceReadStatus``

### Settings

- ``DeviceSettingsState``
- ``DeviceSettingChange``
- ``DeviceSettingsGroup``
- ``DeviceAppearance``
- ``DeviceContentSize``
- ``DeviceLocationMode``
- ``SimulatorLookAndFeel``
- ``SimulatorColorFilter``
- ``SimulatorDisplayZoomMode``
- ``SimulatorAudioDevice``
- ``SimulatorLocationScenario``

### Background services

- ``BackgroundServicesState``
- ``ServiceConfiguration``
- ``SimulatorBackgroundServices``
- ``SimulatorBackgroundServiceCategory``
- ``SimulatorBackgroundService``
- ``SimulatorRequiredBackgroundService``
- ``SimulatorBackgroundServiceState``
- ``SimulatorBackgroundServiceTarget``

### Applications, profiles, and reports

- ``DeviceInspectionState``
- ``DeviceInfoValue``
- ``DeviceApplication``
- ``DeviceProfile``
- ``DeviceProfileKind``
- ``DeviceReport``

### Errors

- ``SimulatorError``
