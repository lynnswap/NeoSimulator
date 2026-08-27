# xcode-simulator-host design

## Consumer contract

`xcode-simulator-host` is a macOS command-line tool for selecting the UI host
used alongside Xcode 27 simulator runs.

```console
xcode-simulator-host status
xcode-simulator-host use legacy [--legacy-xcode /Applications/Xcode.app]
xcode-simulator-host use device-hub
xcode-simulator-host restore [--force]
```

- `status` is read-only.
- `use legacy` configures Xcode for a CoreSimulator-only session, prevents an
  already-running Device Hub from automatically starting a live view, and
  opens the validated Simulator app from Xcode 26.
- `use device-hub` removes both overrides so Xcode 27 uses its default Device
  Hub route.
- `restore` restores the exact preference state from before the tool first
  changed it, including the distinction between an absent key and an explicit
  Boolean value.
- `restore --force` is the explicit recovery path that lets the saved original
  values win over a conflicting live Boolean state.

The selected Xcode comes from `DEVELOPER_DIR` when set and otherwise from
`xcode-select -p`. The preference domain is shared by every installed Xcode;
selecting an Xcode only chooses the installation to validate.

## Package topology

The package has one executable product, one executable target, and one test
target. There is no library consumer and no independent release or dependency
boundary that justifies another product or implementation target.

```text
xcode-simulator-host (executable product)
  -> XcodeSimulatorHost (composition root and all internal owners)
XcodeSimulatorHostTests
  -> XcodeSimulatorHost
```

The CLI surface uses Apple's `swift-argument-parser` 1.8.2. Persistence and system
integration use Foundation, AppKit, and Darwin directly; no additional runtime
dependency is required.

## Owner map

| Responsibility | Owner |
| --- | --- |
| Parse commands and options | `ArgumentParser` command types |
| Execute fixed system commands | `SystemCommandRunner` |
| Read and mutate the two Boolean preferences | `DefaultsStore` |
| Persist the original state and in-flight mutation | `ReceiptStore` |
| Resolve and validate Xcode 27 | `InstallationInspector` |
| Resolve and validate a legacy Simulator host | `InstallationInspector` |
| Validate the legacy Simulator code signature | `CodeSignatureValidator` |
| Serialize preference transitions and rollback | `HostModeController` |
| Render output and select an exit category | `XcodeSimulatorHostApplication` |

The current preference values remain the source of truth for the effective
mode. The receipt owns only restoration and interruption recovery metadata.

## Managed preferences

```text
domain: com.apple.dt.Xcode
key:    DVTiPhoneSimulatorAlwaysLaunchInCoreSimulatorSession

domain: com.apple.dt.Devices
key:    disableAutoStartLiveDeviceView
```

Each value is modeled as one of `absent`, `false`, or `true`. Any other stored
type is a configuration error and is never guessed or overwritten.

The `defaults` command is the live adapter. Direct `CFPreferences` access from
this unsandboxed tool cannot observe the Device Hub container preference, while
`defaults` resolves that domain to its application container.

## Transition transaction

The receipt is stored under the user's Application Support directory. It
contains:

- schema and tool identifiers;
- the original two-key state;
- the state the tool most recently verified;
- an optional pending mutation with `before` and `target` states;
- the Xcode version and build validated at capture time.

The first successful management attempt creates the receipt before changing a
preference. Later mode switches never replace the original state.

For every `use` transition, `HostModeController`:

1. acquires an exclusive operation lock;
2. validates compatibility and confirms all Xcode GUI processes are closed;
3. reads the current preference state;
4. saves a pending `before -> target` mutation;
5. confirms the state still equals `before`, applies both keys, and reads them back;
6. finalizes the verified state in the receipt.

If applying or verifying either key fails, the controller restores the state
from immediately before that operation and verifies the rollback. A rollback
failure is reported as an inconsistent state and the receipt is retained.

On the next `use` or `restore` invocation, a pending mutation is finalized when
the live state equals its `before` or `target` value. A state matching the
possible value after writing only the Xcode key is ambiguous: it could be an
interrupted tool write or an external change made after the journal was saved.
It is never rolled back automatically. Any other third value is also an
external conflict, and no mutation proceeds.

`status` takes the same operation lock while reading preferences and the
receipt, so it cannot combine two different transaction snapshots. It does not
recover pending state or change a preference or receipt.

`restore` first checks whether a receipt exists. Without one it is a no-op and
does not read the managed preferences. With one it requires all Xcode GUI
processes to be closed, recovers an interrupted journal if necessary, restores
the exact original state, and verifies the read-back. It does not require the
currently selected Xcode to pass the compatibility gate.

After inspecting a conflict, `restore --force` records the observed Boolean
state as a new rollback point, writes and verifies the saved original values,
then deletes the receipt. It still refuses non-Boolean preference values and
still requires Xcode to be closed.

Opening the legacy Simulator is a separate failure boundary after a successful
preference transaction. Failure to open it is reported as a partial success;
the selected mode remains configured and can be restored normally.

`restore` remains available when the currently selected Xcode is unsupported.
Like `use`, it refuses to mutate preferences while Xcode is running. It deletes
the receipt only after the original values are read back.

## Compatibility gate

`use` support is deliberately limited to Xcode 27. A target installation
must have:

- bundle identifier `com.apple.dt.Xcode` and major version 27;
- `Contents/Applications/DeviceHub.app` with identifier
  `com.apple.dt.Devices`, a launchable bundle executable, and its expected
  internal implementation executable;
- the expected `IDEiOSSupportCore` binary containing the exact Xcode key;
- the Device Hub implementation binary containing the exact auto-start key.

A legacy host must come from Xcode 26 and contain an executable Simulator app
with bundle identifier `com.apple.iphonesimulator`. Before launch, the complete
Simulator bundle must pass strict static code validation for the requirement
`identifier "com.apple.iphonesimulator" and anchor apple`. Automatic discovery
checks Xcode applications in `/Applications` and `~/Applications` and chooses
the highest validated version. `--legacy-xcode` selects an explicit candidate
but does not bypass signature validation.

No alternative binary path, preference key, or application is guessed when a
gate fails. Xcode 28 and later require a new verified compatibility profile.

## Failure semantics

The executable follows BSD `sysexits` categories:

| Code | Meaning |
| ---: | --- |
| 0 | success or documented no-op |
| 64 | invalid invocation |
| 69 | unavailable or unsupported Xcode/Simulator |
| 70 | internal invariant failure |
| 73 | receipt or lock cannot be created |
| 74 | preference or state I/O failed |
| 75 | Xcode is running or another operation holds the lock |
| 78 | invalid preference, corrupt receipt, or external conflict |

ArgumentParser owns invocation diagnostics. Operational errors use stable
identifiers on stderr. Successful transition reports use stdout. `status`
always writes its report to stdout and exits 78 when a receipt conflicts with
the live preferences.

## Non-goals

- Modifying, replacing, re-signing, or deleting Xcode and Device Hub bundles.
- Killing or automatically restarting Xcode, Device Hub, or Simulator.
- Booting, shutting down, creating, or deleting simulator devices.
- Making the shared Xcode preference installation-specific.
- Claiming that the undocumented behavior is supported by Apple.
- Guessing support for Xcode 28 or a different legacy Simulator generation.
- Providing a public Swift library API, JSON output, or shell completion in the
  initial release.

## Validation

Unit tests use a scripted command runner, fake Xcode bundles, and isolated
temporary receipt directories. They never write the real Xcode or Device Hub
domains or launch applications. Coverage includes parsing, compatibility
gates, tri-state round trips, pending-mutation recovery, idempotence, external
conflicts, rollback, and restore.

The only live smoke test during development is `status`, which is read-only.
Changing the real preferences and verifying Xcode's GUI Run behavior is a
separate, explicitly controlled A/B test.
