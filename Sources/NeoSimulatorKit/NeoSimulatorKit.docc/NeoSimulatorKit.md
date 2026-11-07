# ``NeoSimulatorKit``

Discover devices, read and change their state, and boot or shut down simulators.

## Overview

NeoSimulatorKit loads no UI toolkit, so it can run in a process that displays nothing.

Load a ``SimulatorContext`` to list, boot, and shut down the simulators of one Xcode installation. Create a
``DeviceRegistry`` to list simulators and CoreDevice devices, and to share one observable ``DeviceModel`` for each
device in the process.

To display a simulator, add the `NeoSimulatorUI` product. Its `SimulatorScreens` type opens screens, and each screen
has a ``SimulatorDeviceSession`` for sending commands to the guest. For a walkthrough, see
[Using the SDK](https://lynnswap.github.io/NeoSimulator/documentation/neosimulator/usingthesdk).

### Keep objects alive

Contexts, sessions, registries, and device models are isolated to the main actor. Retain the ones you use:

- A ``SimulatorContext`` owns its connections. Releasing it ends its sessions.
- A ``DeviceRegistry`` retains the model of each listed device.
- A ``DeviceReadInterest`` keeps state groups current until you release it.

Closing a session, invalidating a context, and releasing a context all leave guests running. Call
``SimulatorContext/shutDown(_:)`` to stop a guest. Await ``SimulatorContext/invalidate()`` before terminating the app
so you can report cleanup failures.

### Handle errors

How a failure reaches you depends on the API:

| API | How it reports failure |
| --- | --- |
| Context instance methods and session commands | Throw ``SimulatorError`` or `CancellationError`. |
| ``SimulatorContext/load(xcodeURL:deviceRegistry:)`` and ``SimulatorContext/selectDisplayXcode(_:)`` | Throw errors that describe themselves through `localizedDescription`. |
| Changes through ``DeviceSettingsState``, ``BackgroundServicesState``, and ``DeviceInspectionState`` | Throw ``SimulatorError/operation(_:)``, `CancellationError`, or errors that describe themselves through `localizedDescription`. |
| Reads of cached device state | Never throw. Check ``DeviceReadStatus`` and ``DeviceModel/lastIssue``. |
| ``DeviceRegistry/refresh()`` | Throws only `CancellationError`. A source that cannot be read keeps the devices it last listed. |
| Work that no call is waiting for | Reports to ``SimulatorContext/onError``. |

``SimulatorError/outcomeUnknown(_:underlying:)`` means that a change may still apply. Read the device's state before
repeating the request.

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
