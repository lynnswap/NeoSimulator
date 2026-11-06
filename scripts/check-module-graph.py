#!/usr/bin/env python3
"""Checks NeoSimulator's module graph.

SwiftPM's --explicit-target-dependency-import-check does not catch an import of a transitive target (SwiftBuild #9620), so
this compares what the compiler's import pre-scan finds with the manifest:

- every import of a module this package or its dependencies define has a direct edge in the manifest,
- the manifest's edges between source targets are the agreed graph, and
- the layers below the presentation do not import AppKit or SwiftUI.
"""

import argparse
import json
import pathlib
import subprocess
import sys

GRAPH = {
    "NeoSimulatorNative": {"ABIBridge"},
    "NeoSimulatorDeviceIO": {"NeoSimulatorNative", "ABIBridge"},
    "NeoSimulatorKit": {"NeoSimulatorDeviceIO"},
    "NeoSimulatorPresentationAdapters": {
        "NeoSimulatorKit", "NeoSimulatorDeviceIO", "NeoSimulatorNative", "ABIBridge", "ObservationBridge",
    },
    "NeoSimulatorUI": {"NeoSimulatorKit", "NeoSimulatorPresentationAdapters", "ObservationBridge"},
    "NeoSimulatorHostSupport": {
        "NeoSimulatorUI", "NeoSimulatorPresentationAdapters", "NeoSimulatorKit", "NeoSimulatorDeviceIO", "ObservationBridge",
    },
    "NeoSimulatorApp": {
        "NeoSimulatorHostSupport", "NeoSimulatorUI", "NeoSimulatorPresentationAdapters", "NeoSimulatorKit",
        "NeoSimulatorDeviceIO", "ObservationBridge",
    },
    "NeoSimulatorService": {"NeoSimulatorHostSupport", "NeoSimulatorKit"},
    "CoreDeviceInventoryProbe": {"NeoSimulatorKit"},
}
PRESENTATION_FREE = {"NeoSimulatorNative", "NeoSimulatorDeviceIO", "NeoSimulatorKit"}
PRESENTATION_FRAMEWORKS = {"AppKit", "SwiftUI"}


def run(*command):
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode:
        sys.exit(f"{command[0]} {command[1]} failed: {result.stderr}")
    return result.stdout


def swift_package(root, options, *arguments):
    return json.loads(run("swift", "package", "--package-path", str(root), *options, *arguments))


def dependency_edges(target):
    """The names of a target's direct dependencies, and the products among them."""
    names, products = set(), set()
    for dependency in target["dependencies"]:
        for kind, values in dependency.items():
            names.add(values[0])
            if kind == "product":
                products.add(values[0])
    return names, products


def external_packages(root, options):
    """The manifests of every package this one depends on, directly or not."""
    manifests, pending = [], swift_package(root, options, "show-dependencies", "--format", "json")["dependencies"]
    while pending:
        package = pending.pop()
        manifests.append(swift_package(package["path"], [], "dump-package"))
        pending.extend(package["dependencies"])
    return manifests


def source_files(root, target):
    folder = root / (target.get("path") or (("Tests/" if target["type"] == "test" else "Sources/") + target["name"]))
    return sorted(str(path) for path in folder.rglob("*.swift"))


def scanned_imports(target, sources):
    """What the compiler finds these sources import. `#if` chooses among imports, so both DEBUG and release count."""
    imports = set()
    for extra in ([], ["-D", "DEBUG"]):
        scan = run("xcrun", "swiftc", "-frontend", "-scan-dependencies", "-import-prescan", "-module-name", target, *extra, *sources)
        imports.update(json.loads(scan)["imports"])
    return imports


def check(root, options):
    manifest = swift_package(root, options, "dump-package")
    targets = {target["name"]: target for target in manifest["targets"]}
    externals = external_packages(root, options)
    external_modules = {target["name"] for package in externals for target in package["targets"]}
    product_modules = {product["name"]: set(product["targets"]) for package in externals for product in package["products"]}

    failures = []
    for name in sorted(GRAPH.keys() - targets.keys()):
        failures.append(f"{name} is in the agreed graph but not in the manifest")
    for name, target in sorted(targets.items()):
        edges, products = dependency_edges(target)
        if target["type"] != "test" and edges != GRAPH.get(name):
            failures.append(f"{name} depends on {sorted(edges)}, but the agreed graph has {sorted(GRAPH.get(name, set()))}")
        sources = source_files(root, target)
        if not sources:
            continue
        imports = scanned_imports(name, sources)
        allowed = {name}
        for edge in edges:
            allowed |= product_modules.get(edge, {edge}) if edge in products else {edge}
        for module in sorted((imports & (targets.keys() | external_modules)) - allowed):
            failures.append(f"{name} imports {module} without a direct dependency on it")
        if name in PRESENTATION_FREE:
            for module in sorted(imports & PRESENTATION_FRAMEWORKS):
                failures.append(f"{name} imports {module}, which only the presentation layers may use")
    return failures


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--package-path", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parent.parent)
    parser.add_argument("--scratch-path", help="SwiftPM's scratch path, passed to the commands that resolve packages")
    parser.add_argument("--cache-path", help="SwiftPM's cache path, passed to the commands that resolve packages")
    arguments = parser.parse_args()
    options = []
    if arguments.scratch_path:
        options += ["--scratch-path", arguments.scratch_path]
    if arguments.cache_path:
        options += ["--cache-path", arguments.cache_path]
    failures = check(arguments.package_path.resolve(), options)
    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    print("The module graph matches the manifest and its imports.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
