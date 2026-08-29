# Advanced configuration

The default workflow requires only `xcode-simulator-host use legacy`.

## Detailed status

```console
xcode-simulator-host status --verbose
```

Verbose status reports:

- the selected Xcode and build;
- whether the packaged standalone host is available;
- the validated SimulatorKit, IDEPlaygroundSimulator, CoreSimulator, CoreDevice,
  `simctl`, `devicectl`, and simulator CoreDevice plugin paths and versions;
- restoration receipt state;
- running Xcode and standalone-host processes;
- exact managed preference values.

`status` and `status --verbose` are read-only. Compact status does not require
Xcode discovery and answers only which route the next Run uses.

## Select an Xcode 27+ installation

Commands use `DEVELOPER_DIR` when set and otherwise use `xcode-select -p`.

```bash
DEVELOPER_DIR=/Applications/Xcode_28.app/Contents/Developer \
  xcode-simulator-host status --verbose
```

Use the same environment on a mutation command:

```bash
DEVELOPER_DIR=/Applications/Xcode_28.app/Contents/Developer \
  xcode-simulator-host use legacy
```

The compatibility gate checks the selected installation and the matching
system resources before changing preferences or processes. There is no option
to bypass this gate or provide a Simulator.app from an older Xcode.

## Preference scope

The managed Xcode preferences are shared by all installed Xcode versions.
Selecting an installation changes which Xcode supplies the private frameworks;
it does not create installation-specific preference state.

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

See the [design and safety contract](Design.md) for transaction ownership,
process ordering, and exit codes.
