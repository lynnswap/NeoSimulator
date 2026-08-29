# Advanced configuration

The default workflow requires only:

```console
xcode-simulator-host use neo
```

## Detailed status

```console
xcode-simulator-host status --verbose
```

Verbose status reports:

- the selected Xcode 27+ installation and build;
- whether the packaged Neo host is available;
- the validated SimulatorKit, IDEPlaygroundSimulator, CoreSimulator, CoreDevice,
  `simctl`, `devicectl`, and simulator CoreDevice plugin paths and versions;
- the discovered or explicitly selected Xcode 26 `Simulator.app`;
- restoration receipt state;
- running Xcode, Neo, and legacy Simulator processes;
- exact managed preference values.

`status` and `status --verbose` are read-only. Compact status reports only the
route used by the next Xcode Run. It cannot distinguish Neo from Legacy because
both use the same CoreSimulator preference route.

## Select the Xcode 27+ installation

Commands use `DEVELOPER_DIR` when set and otherwise use `xcode-select -p`.

```bash
DEVELOPER_DIR=/Applications/Xcode_28.app/Contents/Developer \
  xcode-simulator-host status --verbose
```

Use the same environment for a mutation:

```bash
DEVELOPER_DIR=/Applications/Xcode_28.app/Contents/Developer \
  xcode-simulator-host use neo
```

The Neo compatibility gate checks that selected installation and its matching
system resources before changing preferences or processes. There is no option
to bypass the gate.

## Select the Xcode 26 Simulator.app

`use legacy` searches `/Applications` and chooses the highest validated Xcode
26 version. To select an installation elsewhere, or to avoid automatic choice,
pass its absolute path:

```bash
xcode-simulator-host use legacy \
  --legacy-xcode /Volumes/Developer/Xcode_26.6.app
```

Inspect the same candidate without changing state:

```bash
xcode-simulator-host status --verbose \
  --legacy-xcode /Volumes/Developer/Xcode_26.6.app
```

The selected Xcode 27+ remains the Build & Run owner. `--legacy-xcode` chooses
only the Apple `Simulator.app` used to present its CoreSimulator devices.

The outer Xcode and nested Simulator applications must both be intact
Apple-signed bundles. The Xcode version and Simulator `DTXcode` metadata must
identify generation 26. A relative path or a Simulator copied outside its
owning Xcode bundle is rejected.

## Preference scope

The managed Xcode preferences are shared by all installed Xcode versions.
Selecting an installation changes which Xcode supplies Neo's private
frameworks; it does not create installation-specific preference state.

Neo and Legacy share one CoreSimulator preference state. Switching between
them changes process ownership even when no preference write is needed.

## Recovery

Normal recovery restores the exact original tri-state values (`absent`,
`false`, or `true`):

```bash
xcode-simulator-host restore
```

If verbose status reports an external conflict, inspect it before choosing:

```bash
xcode-simulator-host restore --force
```

`--force` lets the saved original Boolean state win over a conflicting live
Boolean state. It still rejects malformed or non-Boolean preferences.

The receipt records preferences, not whether Neo or Legacy was last selected.
Restoring an original CoreSimulator route therefore does not guess which UI
host to launch.

See the [design and safety contract](Design.md) for transaction ownership,
process ordering, and exit behavior.
