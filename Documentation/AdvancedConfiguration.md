# Advanced configuration

The default workflow does not require any of these options. Use them only when
you need diagnostic details or an Xcode installation outside the normal
selection paths.

## Detailed status

The default status reports only the route used by the next Xcode Run:

```console
xcode-simulator-host status
```

Add `--verbose` to inspect the resolved Xcode installations, managed
preferences, restoration state, and running Xcode processes:

```console
xcode-simulator-host status --verbose
```

## Xcode 27 installation

Commands that validate Xcode 27 use `DEVELOPER_DIR` when it is set and
otherwise use `xcode-select -p`. To inspect a non-default installation:

```bash
DEVELOPER_DIR=/Applications/Xcode_27.app/Contents/Developer \
  xcode-simulator-host status --verbose
```

Set the same environment variable on a mutation command to use that
installation for validation and Device Hub management:

```bash
DEVELOPER_DIR=/Applications/Xcode_27.app/Contents/Developer \
  xcode-simulator-host use legacy
```

## Xcode 26 Simulator

`use legacy` normally selects the newest validated Xcode 26 installation in
`/Applications`. Pass an absolute path when the installation is elsewhere:

```bash
xcode-simulator-host use legacy \
  --legacy-xcode /Applications/Xcode_26.app
```

The same override can be used with detailed status:

```bash
xcode-simulator-host status --verbose \
  --legacy-xcode /Applications/Xcode_26.app
```

## Preference scope

The managed Xcode preferences are shared by all installed Xcode versions.
Selecting an installation changes which Xcode and Device Hub are validated; it
does not create a separate preference state for that installation.

See the [design and safety contract](Design.md) for compatibility checks,
transaction ownership, recovery behavior, and exit codes.
