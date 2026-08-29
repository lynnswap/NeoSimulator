# xcode-simulator-host design

## Consumer contract

`xcode-simulator-host` is a macOS command-line tool for selecting the UI host
used alongside Xcode 27 simulator runs.

```console
xcode-simulator-host status [--verbose]
xcode-simulator-host use legacy [--legacy-xcode /Applications/Xcode.app]
xcode-simulator-host use device-hub
xcode-simulator-host restore [--force]
```

- `status` is read-only. Its default output is only the simulator route used by
  the next Run; `--verbose` adds installations, preferences, restoration state,
  and running processes.
- `use legacy` configures Xcode for a CoreSimulator-only session, prevents an
  already-running Device Hub from automatically starting a live view, normally
  terminates the verified Device Hub, and opens the validated Simulator app
  from Xcode 26. Xcode itself remains open.
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
| Observe Xcode, terminate the exact Device Hub, and open Simulator | `WorkspaceClient` |
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
2. validates compatibility while allowing Xcode GUI processes to remain open;
3. reads the current preference state;
4. saves a pending `before -> target` mutation;
5. brackets every individual preference write with full-state verification;
6. finalizes the verified state in the receipt.

If applying or verifying either key fails, the controller restores the state
from immediately before that operation using the same guarded step sequence.
If a pre-write or post-write check detects a different state, no automatic
rollback runs over that state; the pending receipt is retained and the
forward transition is reported as a conflict. A deviation detected during
rollback, or a different rollback failure, is reported as an inconsistent
state and the receipt is retained.

The `defaults` command does not provide a conditional compare-and-swap. The
operation lock serializes this tool's processes, while full-state reads
immediately before and after each write detect cooperating or slower external
changes. An external write in the narrow interval between a check and the
managed write can be indistinguishable if the managed write replaces it with
the intended value.

On the next `use` or `restore` invocation, a pending mutation is finalized when
the live state equals its `before` or `target` value. A state matching the
possible value after writing only the Xcode key is ambiguous: it could be an
interrupted tool write or an external change made after the journal was saved.
It is never rolled back automatically. Any other third value is also an
external conflict, and no mutation proceeds.

`status` does not create the state directory or operation lock. Before the
first mutation it takes an optimistic snapshot and confirms that the state
directory stayed absent. Creating that directory is the first, monotonic step
of every mutating operation, so if it appears during the read, `status` retries
the complete snapshot under the existing operation lock. Once state exists,
`status` always uses that existing lock. It does not recover pending state or
change a preference, receipt, or state artifact.

`restore` first checks the monotonic state directory marker. If it is absent,
the command is a no-op and does not create state or read the managed
preferences. If state exists, `restore` acquires the existing operation lock
before deciding whether a receipt exists. It then recovers an interrupted
journal if necessary, restores the exact original state, and verifies the
read-back while Xcode may remain open. It does not require the currently
selected Xcode to pass the compatibility gate.

After inspecting a conflict, `restore --force` records the observed Boolean
state as a new rollback point, writes and verifies the saved original values,
then deletes the receipt. It still refuses non-Boolean preference values.

Device Hub termination and opening the legacy Simulator are separate failure
boundaries after a successful preference transaction, but remain inside the
same exclusive operation lock. `WorkspaceClient` only terminates running
applications whose resolved bundle URL exactly matches the validated Device Hub
inside the selected Xcode. It requests normal termination, observes
`isTerminated` through KVO, and re-enumerates the current `NSWorkspace`
inventory until no matching process remains within one 10-second operation
deadline. It never force-terminates Device Hub.

`HostModeController` holds the operation lock from compatibility validation
through preference commit, Device Hub termination, final legacy-state
verification, and `NSWorkspace.openApplication` completion. A concurrent
switch or restore therefore cannot commit while an older legacy operation is
still applying process lifecycle side effects. Termination and launch failures
are reported as partial success; the selected mode remains configured and can
be restored.

`restore` remains available when the currently selected Xcode is unsupported or
running. It deletes the receipt only after the original values are read back.

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
outer Xcode and nested Simulator bundles must pass strict static code validation
for their respective identifiers and `anchor apple`. The signed Simulator
`DTXcode` value must also identify Xcode major 26. Automatic discovery checks
Xcode applications in `/Applications` and chooses the highest validated
version. `--legacy-xcode` selects an explicit candidate elsewhere but does not
bypass signature or generation validation.

No alternative binary path, preference key, or application is guessed when a
gate fails. Xcode 28 and later require a new verified compatibility profile.

## Distribution

GitHub Releases distribute one ad-hoc-signed arm64 archive containing
`bin/xcode-simulator-host`. Each release also contains `SHA256SUMS.txt` and a
version-pinned `install.sh`. The installer downloads the archive and checksum
from the same tag, verifies the archive before extraction, and installs to
`~/.local/bin` by default. `--prefix` and `--bindir` select another destination.
It prints PATH guidance but never edits a shell profile.

The build script rejects a release tag whose semantic version does not match
the binary's `--version`. The packaging verifier checks the exact asset set,
checksums, rendered installer, and archive entries. `release.yml` runs package
tests, builds and verifies the assets on GitHub's arm64 Xcode 27 runner,
transfers the archive digest across jobs, and creates or repairs a draft
release. Publishing the draft remains a manual action. A version with a
prerelease suffix is marked as a GitHub prerelease and explicitly excluded from
`releases/latest`.

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
| 75 | another operation holds the lock, or Device Hub does not terminate normally |
| 78 | invalid preference, corrupt receipt, or external conflict |

ArgumentParser owns invocation diagnostics. Operational errors use stable
identifiers on stderr. Successful transition reports use stdout. `status`
always writes its report to stdout and exits 78 when a receipt conflicts with
the live preferences.

## Non-goals

- Modifying, replacing, re-signing, or deleting Xcode and Device Hub bundles.
- Force-killing or automatically restarting Xcode, Device Hub, or Simulator.
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

The live A/B test keeps one Xcode 27 process running while switching from the
default Device Hub route to the Xcode 26 Simulator route and back. It verifies
the host application and launched demo at each step, then restores the exact
preferences, scheme, destination, app, Device Hub, and simulator-device state.
