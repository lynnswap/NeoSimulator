#!/usr/bin/env python3
"""Sign a verified CI image and prepare notarized release assets without building code."""

from __future__ import annotations

import argparse
import base64
import binascii
from contextlib import contextmanager
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import uuid


APP_NAME = "NeoSimulator"
APP_BUNDLE = f"{APP_NAME}.app"
APP_IDENTIFIER = "dev.lynnswap.NeoSimulator"
RENDERER_NAME = "NeoSimulatorRenderer"
RENDERER_IDENTIFIER = f"{APP_IDENTIFIER}.Renderer"
GUEST_SETTINGS_NAME = "NeoSimulatorGuestSettings"
# Hardened-runtime exceptions for the helper only: DYLD_ROOT_PATH selects the simulator runtime, and iOS 27
# runtimes supply system frameworks only through their Apple-signed simulator dyld shared cache, which library
# validation prevents this helper from mapping. The helper loads only that runtime's frameworks, not plug-ins.
GUEST_SETTINGS_ENTITLEMENTS = ("com.apple.security.cs.allow-dyld-environment-variables",
                               "com.apple.security.cs.disable-library-validation")
GUEST_SETTINGS_ENTITLEMENTS_PATH = Path(__file__).resolve().parents[1] / "App" / GUEST_SETTINGS_NAME / "GuestSettings.entitlements"
# Simulator Security reads these from the helper's __TEXT,__entitlements section
# and does not merge them with the macOS signature.
GUEST_SETTINGS_SIMULATOR_ENTITLEMENTS = ("com.apple.frontboard.launchapplications", "com.apple.frontboard.shutdown")
APPLICATIONS_LINK = "\u200b"
SECRET_NAMES = ("DEVELOPER_ID_P12_BASE64", "DEVELOPER_ID_P12_PASSWORD", "NOTARY_API_PRIVATE_KEY")
VERSION_PATTERN = r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*)?"
MACHO_MAGICS = {bytes.fromhex(value) for value in (
    "feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca",
)}


class ReleaseError(Exception):
    """An actionable failure whose message contains no native command or credentials."""


@dataclass
class NativeResult:
    stdout: bytes
    stderr: bytes
    returncode: int | None


class NativeTools:
    """Own child environments and keep command arguments out of error reporting."""

    def __init__(self):
        self.redactions: list[str] = []

    def run(self, arguments: list[str], operation: str, *, allow_failure=False, timeout=300) -> NativeResult:
        environment = {name: os.environ[name] for name in os.environ if name not in SECRET_NAMES}
        try:
            completed = subprocess.run(arguments, capture_output=True, env=environment, timeout=timeout)
            result = NativeResult(completed.stdout, completed.stderr, completed.returncode)
        except subprocess.TimeoutExpired as error:
            result = NativeResult(error.stdout or b"", error.stderr or b"", None)
        except OSError:
            raise ReleaseError(f"{operation}: could not start the native tool.") from None
        if not allow_failure and result.returncode != 0:
            reason = "timed out" if result.returncode is None else f"failed with exit code {result.returncode}"
            detail = " ".join(self.redact(result.stderr.decode("utf-8", errors="replace")).split())[:4000]
            raise ReleaseError(f"{operation}: {reason}." + (f" {detail}" if detail else "")) from None
        return result

    def redact(self, value):
        if isinstance(value, str):
            for secret in self.redactions:
                value = value.replace(secret, "[REDACTED]")
                value = value.replace(json.dumps(secret)[1:-1], "[REDACTED]")
            return value
        if isinstance(value, list):
            return [self.redact(item) for item in value]
        if isinstance(value, dict):
            return {self.redact(key): self.redact(item) for key, item in value.items()}
        return value


def digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def parse_plist(payload: bytes, operation: str) -> dict:
    try:
        value = plistlib.loads(payload)
    except (ValueError, plistlib.InvalidFileException):
        raise ReleaseError(f"{operation}: invalid property list.") from None
    if not isinstance(value, dict):
        raise ReleaseError(f"{operation}: expected a property list dictionary.")
    return value


def require_empty_output(path: Path) -> None:
    if path.is_symlink() or (path.exists() and (not path.is_dir() or any(path.iterdir()))):
        raise ReleaseError("The output directory must be new or empty.")


def preflight(arguments: argparse.Namespace) -> dict[str, str]:
    if not re.fullmatch(VERSION_PATTERN, arguments.version):
        raise ReleaseError("The version must be vMAJOR.MINOR.PATCH with an optional prerelease suffix.")
    if not re.fullmatch(r"[0-9a-f]{40}", arguments.source_sha):
        raise ReleaseError("The source SHA must be a full lowercase Git commit SHA.")
    expected_environment = {
        "GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted",
        "GITHUB_REF": "refs/heads/main", "GITHUB_SHA": arguments.source_sha,
    }
    for name, expected in expected_environment.items():
        if os.environ.get(name) != expected:
            raise ReleaseError(f"{name} does not identify the trusted main workflow run.")
    configuration = {}
    for name, pattern in {
        "GITHUB_REPOSITORY": r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+",
        "GITHUB_RUN_ID": r"[1-9][0-9]*", "GITHUB_RUN_ATTEMPT": r"[1-9][0-9]*", "GITHUB_RUN_NUMBER": r"[1-9][0-9]*",
        "APPLE_TEAM_ID": r"[A-Z0-9]{10}", "NOTARY_API_KEY_ID": r"[A-Z0-9]{10,}",
        "NOTARY_API_ISSUER_ID": r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}",
    }.items():
        value = os.environ.get(name, "")
        if not re.fullmatch(pattern, value):
            raise ReleaseError(f"{name} is missing or malformed.")
        configuration[name] = value
    require_empty_output(arguments.output_directory)
    if not re.fullmatch(r"[0-9a-fA-F]{64}", arguments.input_sha256):
        raise ReleaseError("The input SHA-256 must contain exactly 64 hexadecimal digits.")
    if arguments.input_dmg.is_symlink() or not arguments.input_dmg.is_file():
        raise ReleaseError("The input DMG must be a regular file.")
    if digest(arguments.input_dmg) != arguments.input_sha256.lower():
        raise ReleaseError("The input DMG SHA-256 does not match the build artifact.")
    diagnostics = os.environ.get("RELEASE_DIAGNOSTICS_DIRECTORY")
    if diagnostics and Path(diagnostics).resolve().is_relative_to(arguments.output_directory.resolve()):
        raise ReleaseError("Release diagnostics must be outside the release output directory.")
    return configuration


def image_information(tools: NativeTools, image: Path, expected_format: str) -> int:
    information = parse_plist(tools.run(
        ["/usr/bin/hdiutil", "imageinfo", "-plist", str(image)], "Inspect image format",
    ).stdout, "Inspect image format")
    partitions = information.get("partitions", {})
    filesystems = [
        item.get("partition-filesystems")
        for item in partitions.get("partitions", []) if "partition-filesystems" in item
    ]
    capacity = information.get("Size Information", {}).get("Total Bytes")
    if (information.get("Format") != expected_format or partitions.get("partition-scheme") != "GUID"
            or len(filesystems) != 1 or set(filesystems[0]) != {"HFS+"}
            or not isinstance(capacity, int) or capacity <= 0
            or information.get("Properties", {}).get("Encrypted") is not False):
        raise ReleaseError("The image must have one HFS+ filesystem on GPT with the expected unencrypted format.")
    return capacity


@contextmanager
def mounted_image(tools: NativeTools, image: Path, mount: Path, *, readonly: bool):
    mount.mkdir()
    attached = parse_plist(tools.run([
        "/usr/bin/hdiutil", "attach", "-plist", "-nobrowse", "-noautoopen",
        "-readonly" if readonly else "-readwrite", "-mountpoint", str(mount), str(image),
    ], "Attach release image").stdout, "Attach release image")
    entities = attached.get("system-entities", [])
    devices = [item["dev-entry"] for item in entities if re.fullmatch(r"/dev/disk[0-9]+", item.get("dev-entry", ""))]
    if len(devices) != 1:
        raise ReleaseError("Image attachment did not identify exactly one owned disk.")
    try:
        mounts = [item["mount-point"] for item in entities if "mount-point" in item]
        if mounts != [str(mount.resolve())]:
            raise ReleaseError("The release image did not mount only at the requested private directory.")
        yield mount
    finally:
        tools.run(["/usr/bin/hdiutil", "detach", "-force", devices[0]], "Detach release image")


def layout_contents(mount: Path) -> dict[str, bytes | str]:
    layout = {}
    for name in (".DS_Store", ".background.png"):
        path = mount / name
        if path.is_symlink() or not path.is_file():
            raise ReleaseError(f"The DMG layout requires a regular {name} file.")
        layout[name] = path.read_bytes()
    link = mount / APPLICATIONS_LINK
    if not link.is_symlink() or os.readlink(link) != "/Applications":
        raise ReleaseError("The DMG Applications link has an unexpected target.")
    layout[APPLICATIONS_LINK] = os.readlink(link)
    return layout


def validate_app(tools: NativeTools, mount: Path, version: str, build_number: str) -> Path:
    app = mount / APP_BUNDLE
    executable = app / "Contents" / "MacOS" / APP_NAME
    info_path = app / "Contents" / "Info.plist"
    if app.is_symlink() or not app.is_dir() or info_path.is_symlink() or not info_path.is_file():
        raise ReleaseError("The DMG does not contain the expected regular app bundle.")
    info = parse_plist(info_path.read_bytes(), "Read app metadata")
    numeric_version = version[1:].split("-", 1)[0]
    for name, expected in {
        "CFBundleIdentifier": APP_IDENTIFIER, "CFBundleExecutable": APP_NAME, "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": numeric_version, "CFBundleVersion": build_number,
    }.items():
        if info.get(name) != expected:
            raise ReleaseError(f"The app {name} does not match the release contract.")
    machos = []
    for path in app.rglob("*"):
        mode = path.lstat().st_mode
        if stat.S_ISLNK(mode):
            if not path.resolve().is_relative_to(app.resolve()):
                raise ReleaseError("The app contains a symlink outside its bundle.")
        elif stat.S_ISREG(mode):
            with path.open("rb") as source:
                if source.read(4) in MACHO_MAGICS:
                    machos.append(path)
        elif not stat.S_ISDIR(mode):
            raise ReleaseError("The app contains an unsupported filesystem entry.")
    renderer = app / "Contents" / "Applications" / f"{RENDERER_NAME}.app"
    renderer_executable = renderer / "Contents" / "MacOS" / RENDERER_NAME
    renderer_info = parse_plist((renderer / "Contents" / "Info.plist").read_bytes(), "Read renderer metadata")
    for name, expected in {
        "CFBundleIdentifier": RENDERER_IDENTIFIER, "CFBundleExecutable": RENDERER_NAME,
        "CFBundlePackageType": "APPL", "CFBundleShortVersionString": numeric_version,
        "CFBundleVersion": build_number,
    }.items():
        if renderer_info.get(name) != expected:
            raise ReleaseError(f"The renderer {name} does not match the release contract.")
    helper = app / "Contents" / "Helpers" / "NeoSimulatorGuestSettings"
    if set(machos) != {executable, renderer_executable, helper}:
        raise ReleaseError("The app must contain its manager, renderer, and guest settings helper executables.")
    for bundle, binary in ((helper, helper), (renderer, renderer_executable), (app, executable)):
        architectures = tools.run(["/usr/bin/lipo", "-archs", str(binary)], "Validate app architecture").stdout.strip()
        if architectures != b"arm64":
            raise ReleaseError("The release app must be arm64-only.")
        tools.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(bundle)], "Validate app signature")
        validate_entitlements(tools, bundle, guest_helper=bundle == helper)
    return app


def validate_entitlements(tools: NativeTools, path: Path, *, guest_helper: bool = False) -> None:
    data = tools.run(
        ["/usr/bin/codesign", "--display", "--entitlements", ":-", str(path)], "Inspect app entitlements",
    ).stdout
    values = parse_plist(data, "Inspect app entitlements") if data else {}
    if guest_helper:
        if set(values) != set(GUEST_SETTINGS_ENTITLEMENTS) or any(values[name] is not True for name in GUEST_SETTINGS_ENTITLEMENTS):
            raise ReleaseError("The guest settings helper requires only its allow-DYLD environment and library-validation exceptions.")
        with tempfile.TemporaryDirectory(prefix="guest-entitlements-") as directory:
            section = Path(directory) / "entitlements.plist"
            tools.run(["/usr/bin/segedit", str(path), "-extract", "__TEXT", "__entitlements", str(section)],
                      "Inspect guest settings simulator entitlements")
            simulated = parse_plist(section.read_bytes(), "Inspect guest settings simulator entitlements")
        if (set(simulated) != set(GUEST_SETTINGS_SIMULATOR_ENTITLEMENTS)
                or any(simulated[name] is not True for name in GUEST_SETTINGS_SIMULATOR_ENTITLEMENTS)):
            raise ReleaseError("The guest settings helper requires only its simulator service entitlements.")
    elif values:
        raise ReleaseError("The manager and renderer signing profiles do not use entitlements.")


def make_writable_image(tools: NativeTools, source: Path, destination: Path, capacity: int, executable_size: int) -> None:
    tools.run(["/usr/bin/hdiutil", "convert", str(source), "-format", "UDRW", "-o", str(destination)], "Convert writable image")
    # codesign writes a full .cstemp executable next to the original. The input
    # DMG is tightly sized, so merely converting its format cannot support signing.
    megabyte = 1024 * 1024
    expanded = max(capacity * 2, capacity + executable_size + 64 * megabyte)
    expanded = (expanded + megabyte - 1) // megabyte * megabyte
    tools.run(["/usr/bin/hdiutil", "resize", "-size", str(expanded), str(destination)], "Expand image for signing")
    if image_information(tools, destination, "UDRW") < expanded:
        raise ReleaseError("The writable release image did not expand to the required capacity.")


def compress_image(tools: NativeTools, source: Path, destination: Path) -> None:
    tools.run([
        "/usr/bin/hdiutil", "convert", str(source), "-format", "UDZO", "-imagekey", "zlib-level=9", "-o", str(destination),
    ], "Compress release image")
    tools.run(["/usr/bin/hdiutil", "verify", str(destination)], "Verify compressed image")
    image_information(tools, destination, "UDZO")


@dataclass(frozen=True)
class SigningCredentials:
    keychain: Path
    certificate_sha1: str
    notary_key: Path


def signing_identity(output: bytes, team: str) -> str:
    text = output.decode("utf-8", errors="replace")
    identities = re.findall(r'^\s*\d+\)\s+([A-Fa-f0-9]{40})\s+"([^"\r\n]+)"\s*$', text, re.MULTILINE)
    if (len(identities) != 1 or not re.search(r"^\s*1 valid identities found\s*$", text, re.MULTILINE)
            or not identities[0][1].startswith("Developer ID Application: ")
            or not identities[0][1].endswith(f" ({team})")):
        raise ReleaseError("The temporary keychain must contain exactly one valid Developer ID Application identity for APPLE_TEAM_ID.")
    return identities[0][0].upper()


@contextmanager
def searchable_keychain(tools: NativeTools, keychain: Path):
    original = shlex.split(tools.run(
        ["/usr/bin/security", "list-keychains", "-d", "user"], "Read keychain search list",
    ).stdout.decode("utf-8"))
    try:
        # An explicit codesign --keychain still requires membership in the user's search list.
        tools.run([
            "/usr/bin/security", "list-keychains", "-d", "user", "-s", *original, str(keychain),
        ], "Include temporary signing keychain")
        yield
    finally:
        tools.run([
            "/usr/bin/security", "list-keychains", "-d", "user", "-s", *original,
        ], "Restore keychain search list")


@contextmanager
def temporary_credentials(tools: NativeTools, parent: Path, configuration: dict[str, str]):
    with tempfile.TemporaryDirectory(prefix="credentials-", dir=parent) as directory:
        root = Path(directory)
        keychain = root / "signing.keychain-db"
        created = False
        try:
            values = {}
            for name in SECRET_NAMES:
                value = os.environ.pop(name, "")
                if not value:
                    raise ReleaseError(f"{name} is required for release signing.")
                values[name] = value
                tools.redactions.append(value)
            try:
                encoded_p12 = "".join(values["DEVELOPER_ID_P12_BASE64"].split())
                if not encoded_p12:
                    raise ReleaseError("DEVELOPER_ID_P12_BASE64 is empty.")
                tools.redactions.append(encoded_p12)
                p12_bytes = base64.b64decode(encoded_p12, validate=True)
            except (ValueError, binascii.Error):
                raise ReleaseError("DEVELOPER_ID_P12_BASE64 must contain valid base64.") from None
            pem = values["NOTARY_API_PRIVATE_KEY"].strip()
            if not (pem.startswith("-----BEGIN PRIVATE KEY-----\n") and pem.endswith("\n-----END PRIVATE KEY-----")):
                raise ReleaseError("NOTARY_API_PRIVATE_KEY must contain a PKCS#8 PEM private key.")
            tools.redactions.append(pem)
            p12 = root / "identity.p12"
            notary_key = root / "notary.p8"
            for path, data in ((p12, p12_bytes), (notary_key, (pem + "\n").encode())):
                with path.open("xb") as output:
                    path.chmod(0o600)
                    output.write(data)
            password = secrets.token_urlsafe(48)
            tools.redactions.append(password)
            tools.run(["/usr/bin/security", "create-keychain", "-p", password, str(keychain)], "Create temporary signing keychain")
            created = True
            tools.run(["/usr/bin/security", "set-keychain-settings", "-lut", "21600", str(keychain)], "Configure temporary signing keychain")
            tools.run(["/usr/bin/security", "unlock-keychain", "-p", password, str(keychain)], "Unlock temporary signing keychain")
            tools.run([
                "/usr/bin/security", "import", str(p12), "-k", str(keychain), "-f", "pkcs12", "-x",
                "-P", values["DEVELOPER_ID_P12_PASSWORD"], "-T", "/usr/bin/codesign",
            ], "Import release signing identity")
            p12.unlink()
            identity = signing_identity(tools.run([
                "/usr/bin/security", "find-identity", "-v", "-p", "codesigning", str(keychain),
            ], "Validate imported signing identity").stdout, configuration["APPLE_TEAM_ID"])
            tools.run([
                "/usr/bin/security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:",
                "-s", "-k", password, str(keychain),
            ], "Authorize codesign for the imported key")
            with searchable_keychain(tools, keychain):
                yield SigningCredentials(keychain, identity, notary_key)
        finally:
            try:
                if created or keychain.exists():
                    tools.run(["/usr/bin/security", "delete-keychain", str(keychain)], "Delete temporary signing keychain")
            finally:
                for name in SECRET_NAMES:
                    os.environ.pop(name, None)


def sign(tools: NativeTools, path: Path, credentials: SigningCredentials, *, app: bool, entitlements: Path | None = None,
         identifier: str | None = None) -> None:
    arguments = ["/usr/bin/codesign", "--force", "--timestamp", "--keychain", str(credentials.keychain),
                 "--sign", credentials.certificate_sha1]
    arguments += ["--options", "runtime"] if app else ["--identifier", f"{APP_IDENTIFIER}.dmg"]
    if identifier:
        arguments += ["--identifier", identifier]
    if entitlements:
        arguments += ["--entitlements", str(entitlements)]
    tools.run([*arguments, str(path)], "Sign release app" if app else "Sign release DMG")


def verify_developer_id(tools: NativeTools, path: Path, team: str, *, app: bool, identifier: str | None = None) -> None:
    tools.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(path)], "Verify Developer ID signature")
    result = tools.run(["/usr/bin/codesign", "--display", "--verbose=4", str(path)], "Inspect Developer ID signature")
    text = result.stderr.decode("utf-8", errors="replace")
    identifier = identifier or (APP_IDENTIFIER if app else f"{APP_IDENTIFIER}.dmg")
    fields = text.splitlines()
    authorities = [line.removeprefix("Authority=") for line in fields if line.startswith("Authority=")]
    flags = re.search(r"flags=0x([A-Fa-f0-9]+)", text)
    if (f"Identifier={identifier}" not in fields or f"TeamIdentifier={team}" not in fields
            or not authorities or not authorities[0].startswith("Developer ID Application: ")
            or not authorities[0].endswith(f" ({team})")
            or not any(line.startswith("Timestamp=") and line.removeprefix("Timestamp=") not in ("", "none") for line in fields)
            or (app and (not flags or not int(flags[1], 16) & 0x10000))):
        raise ReleaseError("The signed product lacks the required identifier, Developer ID team, secure timestamp, or runtime flag.")


def sign_application(tools: NativeTools, app: Path, credentials: SigningCredentials, team: str) -> None:
    renderer = app / "Contents" / "Applications" / f"{RENDERER_NAME}.app"
    # Seal nested code before its containing bundle; --deep signing can silently
    # apply the manager's signing profile to the renderer.
    helper = app / "Contents" / "Helpers" / "NeoSimulatorGuestSettings"
    for bundle, identifier in ((helper, "NeoSimulatorGuestSettings"), (renderer, RENDERER_IDENTIFIER), (app, APP_IDENTIFIER)):
        entitlements = GUEST_SETTINGS_ENTITLEMENTS_PATH if bundle == helper else None
        sign(tools, bundle, credentials, app=True, entitlements=entitlements,
             identifier=GUEST_SETTINGS_NAME if bundle == helper else None)
        verify_developer_id(tools, bundle, team, app=True, identifier=identifier)
        validate_entitlements(tools, bundle, guest_helper=bundle == helper)


def parse_json(payload: bytes) -> dict | None:
    try:
        value = json.loads(payload)
    except (ValueError, UnicodeDecodeError):
        return None
    return value if isinstance(value, dict) else None


def diagnostic(tools: NativeTools, name: str, value: dict) -> None:
    directory = os.environ.get("RELEASE_DIAGNOSTICS_DIRECTORY")
    if directory:
        root = Path(directory)
        root.mkdir(parents=True, exist_ok=True)
        (root / name).write_text(json.dumps(tools.redact(value), indent=2, sort_keys=True) + "\n")


def notarize(tools: NativeTools, image: Path, credentials: SigningCredentials, configuration: dict[str, str]) -> str:
    authentication = ["--key", str(credentials.notary_key), "--key-id", configuration["NOTARY_API_KEY_ID"],
                      "--issuer", configuration["NOTARY_API_ISSUER_ID"]]
    submitted = tools.run([
        "/usr/bin/xcrun", "notarytool", "submit", str(image), *authentication,
        "--wait", "--timeout", "30m", "--output-format", "json",
    ], "Submit image for notarization", allow_failure=True, timeout=2100)
    response = parse_json(submitted.stdout)
    diagnostic(tools, "notary-submission.json", {
        "exit_code": submitted.returncode, "response": response,
        "stderr": submitted.stderr.decode("utf-8", errors="replace"),
        "unparsed_stdout": submitted.stdout.decode("utf-8", errors="replace") if response is None else None,
    })
    submission_id = response.get("id") if response else None
    try:
        if not isinstance(submission_id, str) or str(uuid.UUID(submission_id)) != submission_id:
            raise ValueError
    except ValueError:
        raise ReleaseError("Notarization did not return a valid submission ID. Inspect diagnostics before any manual retry.") from None
    status = response.get("status")
    if status in ("Accepted", "Invalid"):
        logged = tools.run([
            "/usr/bin/xcrun", "notarytool", "log", submission_id, *authentication,
        ], "Retrieve notarization log", allow_failure=True)
        log = parse_json(logged.stdout)
        diagnostic(tools, "notary-log.json", {
            "exit_code": logged.returncode, "log": log,
            "stderr": logged.stderr.decode("utf-8", errors="replace"),
            "unparsed_stdout": logged.stdout.decode("utf-8", errors="replace") if log is None else None,
        })
        if logged.returncode != 0 or not log:
            raise ReleaseError(f"Could not retrieve the notarization log for submission {submission_id}.")
        if log.get("jobId") != submission_id or log.get("status") != status or log.get("sha256") != digest(image):
            raise ReleaseError("The notarization log does not match the submitted image and result.")
    if submitted.returncode != 0 or status != "Accepted":
        raise ReleaseError(f"Notarization was not successfully Accepted for submission {submission_id}. No automatic resubmission was attempted.")
    tools.run(["/usr/bin/xcrun", "stapler", "staple", str(image)], "Staple notarization ticket")
    tools.run(["/usr/bin/xcrun", "stapler", "validate", str(image)], "Validate notarization ticket")
    return submission_id


def prepare_release(arguments: argparse.Namespace) -> Path:
    configuration = preflight(arguments)
    tools = NativeTools()
    output = arguments.output_directory.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    filename = f"{APP_NAME}_{arguments.version[1:]}.dmg"
    with tempfile.TemporaryDirectory(prefix=".release-ready-", dir=output.parent) as staging_directory:
        staging = Path(staging_directory)
        final_image = staging / filename
        with tempfile.TemporaryDirectory(prefix=".release-signing-", dir=output.parent) as scratch_directory:
            scratch = Path(scratch_directory)
            tools.run(["/usr/bin/hdiutil", "verify", str(arguments.input_dmg)], "Verify input image")
            capacity = image_information(tools, arguments.input_dmg, "UDZO")
            with mounted_image(tools, arguments.input_dmg, scratch / "input-mount", readonly=True) as mount:
                app = validate_app(tools, mount, arguments.version, configuration["GITHUB_RUN_NUMBER"])
                layout = layout_contents(mount)
                executable_size = (app / "Contents" / "MacOS" / APP_NAME).stat().st_size
            writable = scratch / "writable.dmg"
            make_writable_image(tools, arguments.input_dmg, writable, capacity, executable_size)
            with temporary_credentials(tools, scratch, configuration) as credentials:
                with mounted_image(tools, writable, scratch / "signing-mount", readonly=False) as mount:
                    app = validate_app(tools, mount, arguments.version, configuration["GITHUB_RUN_NUMBER"])
                    sign_application(tools, app, credentials, configuration["APPLE_TEAM_ID"])
                    if layout_contents(mount) != layout:
                        raise ReleaseError("Signing modified the DMG layout.")
                compress_image(tools, writable, final_image)
                sign(tools, final_image, credentials, app=False)
                verify_developer_id(tools, final_image, configuration["APPLE_TEAM_ID"], app=False)
                submission = notarize(tools, final_image, credentials, configuration)
                verify_developer_id(tools, final_image, configuration["APPLE_TEAM_ID"], app=False)
                tools.run(["/usr/bin/hdiutil", "verify", str(final_image)], "Verify notarized image integrity")
                with mounted_image(tools, final_image, scratch / "final-mount", readonly=True) as mount:
                    app = validate_app(tools, mount, arguments.version, configuration["GITHUB_RUN_NUMBER"])
                    verify_developer_id(tools, app, configuration["APPLE_TEAM_ID"], app=True)
                    verify_developer_id(tools, app / "Contents" / "Applications" / f"{RENDERER_NAME}.app",
                                        configuration["APPLE_TEAM_ID"], app=True, identifier=RENDERER_IDENTIFIER)
                    verify_developer_id(tools, app / "Contents" / "Helpers" / GUEST_SETTINGS_NAME,
                                        configuration["APPLE_TEAM_ID"], app=True, identifier=GUEST_SETTINGS_NAME)
                    if layout_contents(mount) != layout:
                        raise ReleaseError("The final image did not preserve the original DMG layout.")
                tools.run([
                    "/usr/sbin/spctl", "--assess", "--verbose=2", "--type", "open",
                    "--context", "context:primary-signature", str(final_image),
                ], "Assess notarized image with Gatekeeper")
                certificate = credentials.certificate_sha1
        information = {
            "version": arguments.version, "source_sha": arguments.source_sha,
            "repository": configuration["GITHUB_REPOSITORY"], "run_id": configuration["GITHUB_RUN_ID"],
            "run_attempt": configuration["GITHUB_RUN_ATTEMPT"], "apple_team_id": configuration["APPLE_TEAM_ID"],
            "build_number": configuration["GITHUB_RUN_NUMBER"],
            "signing_certificate_sha1": certificate, "notary_submission_id": submission,
            "developer_id_signed": True, "notarized": True,
        }
        info_path = staging / "release-info.json"
        info_path.write_text(json.dumps(information, indent=2, sort_keys=True) + "\n")
        image_digest = digest(final_image)
        (staging / "SHA256SUMS").write_text(f"{image_digest}  {filename}\n{digest(info_path)}  release-info.json\n")
        require_empty_output(output)
        staging.rename(output)
        try:
            if os.environ.get("GITHUB_OUTPUT"):
                with Path(os.environ["GITHUB_OUTPUT"]).open("a") as github_output:
                    github_output.write(f"dmg-sha256={image_digest}\ndmg-filename={filename}\n")
        except OSError:
            shutil.rmtree(output)
            raise ReleaseError("Could not export the completed release outputs.") from None
    return output / filename


def handle_termination(signum, frame):
    raise SystemExit(128 + signum)


def main() -> int:
    if sys.version_info < (3, 10):
        print("Release signing requires Python 3.10 or newer.", file=sys.stderr)
        return 1
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input-dmg", required=True, type=Path)
    parser.add_argument("--input-sha256", required=True)
    parser.add_argument("--output-directory", required=True, type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--source-sha", required=True)
    arguments = parser.parse_args()
    previous_handler = signal.signal(signal.SIGTERM, handle_termination)
    try:
        result = prepare_release(arguments)
    except (ReleaseError, OSError) as error:
        # OSError filenames can come from private temporary files; only our
        # deliberately authored ReleaseError messages are safe to print.
        message = str(error) if isinstance(error, ReleaseError) else "Release preparation failed during a filesystem operation."
        print(message, file=sys.stderr)
        return 1
    finally:
        signal.signal(signal.SIGTERM, previous_handler)
    print(f"Prepared signed and notarized release asset: {result.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
