from __future__ import annotations

import hashlib
import os
import plistlib
import stat
import struct
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path

import dmgbuild
from ds_store import DSStore


APP_NAME = "NeoSimulator"
APP_BUNDLE = f"{APP_NAME}.app"
APPLICATIONS_LINK = "\u200b"
ICON_LOCATIONS = {APP_BUNDLE: (240, 122), APPLICATIONS_LINK: (240, 387)}


def generate_background(output_path: Path) -> None:
    width, height = 480, 540
    white = (255, 255, 255)
    panel = (220, 228, 250)

    def inside_rounded_rect(x, y, left, top, right, bottom, radius):
        if x < left or x >= right or y < top or y >= bottom:
            return False
        cx = left + radius if x < left + radius else right - radius - 1 if x >= right - radius else x
        cy = top + radius if y < top + radius else bottom - radius - 1 if y >= bottom - radius else y
        dx = x - cx
        dy = y - cy
        return dx * dx + dy * dy <= radius * radius

    def inside_triangle(x, y, points):
        (x1, y1), (x2, y2), (x3, y3) = points
        denominator = (y2 - y3) * (x1 - x3) + (x3 - x2) * (y1 - y3)
        a = ((y2 - y3) * (x - x3) + (x3 - x2) * (y - y3)) / denominator
        b = ((y3 - y1) * (x - x3) + (x1 - x3) * (y - y3)) / denominator
        c = 1 - a - b
        return a >= 0 and b >= 0 and c >= 0

    def inside_arrow_cutout(x, y):
        shaft = 229 <= x <= 251 and 285 <= y <= 306
        head = inside_triangle(x, y, ((215, 307), (265, 307), (240, 332)))
        return shaft or head

    rows = []
    for y in range(height):
        row = bytearray()
        for x in range(width):
            color = white
            if inside_rounded_rect(x, y, 90, 285, 390, 485, 4):
                color = panel
            if inside_arrow_cutout(x, y):
                color = white
            row.extend(color)
        rows.append(b"\x00" + bytes(row))

    def chunk(kind, payload):
        return (
            struct.pack(">I", len(payload))
            + kind
            + payload
            + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)
        )

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(b"".join(rows), 9))
    png += chunk(b"IEND", b"")
    output_path.write_bytes(png)


def app_manifest(app_path: Path) -> dict[str, tuple]:
    manifest = {}
    for path in [app_path, *app_path.rglob("*")]:
        mode = path.lstat().st_mode
        relative_path = str(path.relative_to(app_path))
        if stat.S_ISLNK(mode):
            content = os.readlink(path)
        elif stat.S_ISREG(mode):
            digest = hashlib.sha256()
            with path.open("rb") as source:
                for block in iter(lambda: source.read(1024 * 1024), b""):
                    digest.update(block)
            content = digest.hexdigest()
        elif stat.S_ISDIR(mode):
            content = None
        else:
            raise ValueError(f"Unsupported app entry: {path}")
        manifest[relative_path] = (mode, content)
    return manifest


def validate_layout(mount: Path, background: Path) -> None:
    if os.readlink(mount / APPLICATIONS_LINK) != "/Applications":
        raise ValueError("The DMG Applications link has an unexpected target.")
    if (mount / ".background.png").read_bytes() != background.read_bytes():
        raise ValueError("The DMG background was not preserved.")
    with DSStore.open(str(mount / ".DS_Store"), "r") as layout:
        window = layout["."]["bwsp"]
        if window["WindowBounds"] != "{{120, 100}, {480, 540}}":
            raise ValueError("The DMG window bounds were not preserved.")
        for flag in ("ShowStatusBar", "ShowTabView", "ShowToolbar", "ShowPathbar", "ShowSidebar"):
            if window[flag]:
                raise ValueError(f"The DMG layout unexpectedly enables {flag}.")
        view = layout["."]["icvp"]
        if view["iconSize"] != 128 or view["backgroundType"] != 2 or not view["backgroundImageAlias"]:
            raise ValueError("The DMG icon view or background metadata is invalid.")
        for name, position in ICON_LOCATIONS.items():
            if layout[name]["Iloc"] != position:
                raise ValueError(f"The DMG icon position is invalid: {name!r}.")


def validate_image(archive: Path, expected_app: dict[str, tuple], background: Path) -> None:
    subprocess.run(["hdiutil", "verify", str(archive)], check=True)
    with tempfile.TemporaryDirectory(prefix="neosimulator-verify-") as directory:
        mount = Path(directory)
        try:
            subprocess.run(
                ["hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", str(mount), str(archive)],
                check=True,
            )
            app = mount / APP_BUNDLE
            if app_manifest(app) != expected_app:
                # dmgbuild 1.6.7 does not check ditto's exit status. A valid
                # signature alone also does not prove every app entry survived.
                raise ValueError("The packaged app contents differ from the source app.")
            subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
            for bundle, name in ((app, APP_NAME), (app / "Contents" / "Applications" / "NeoSimulatorRenderer.app", "NeoSimulatorRenderer")):
                architectures = subprocess.check_output(
                    ["lipo", "-archs", str(bundle / "Contents" / "MacOS" / name)], text=True
                ).strip()
                if architectures != "arm64":
                    raise ValueError("The packaged app is not arm64-only.")
            helper = app / "Contents" / "Helpers" / "NeoSimulatorGuestSettings"
            if subprocess.check_output(["lipo", "-archs", str(helper)], text=True).strip() != "arm64":
                raise ValueError("The packaged guest settings helper is not arm64-only.")
            validate_layout(mount, background)
        finally:
            if os.path.ismount(mount):
                subprocess.run(["hdiutil", "detach", "-force", str(mount)], check=True)


def build_image(app: Path, archive: Path) -> None:
    expected_app = app_manifest(app)
    with tempfile.TemporaryDirectory(prefix="neosimulator-dmg-") as directory:
        background = Path(directory) / "background.png"
        generate_background(background)
        created_images = []
        build_mount = None

        def track_mount(event):
            nonlocal created_images, build_mount
            if event["type"] == "command::finished" and event["command"] == "hdiutil::create" and not event["ret"]:
                created_images = [Path(path).resolve() for path in event["output"]]
            elif event["type"] == "command::finished" and event["command"] == "hdiutil::attach" and not event["ret"]:
                created_image, = created_images
                entities = event["output"]["system-entities"]
                device = next(entity["dev-entry"] for entity in entities if "mount-point" in entity)
                build_mount = (created_image, device)
            elif event["type"] == "command::finished" and event["command"] == "hdiutil::detach" and not event["ret"]:
                build_mount = None

        try:
            dmgbuild.build_dmg(
                str(archive),
                APP_NAME,
                settings={
                    "format": "UDZO",
                    "filesystem": "HFS+",
                    "compression_level": 9,
                    "files": [str(app)],
                    "symlinks": {APPLICATIONS_LINK: "/Applications"},
                    "background": str(background),
                    "window_rect": ((120, 100), (480, 540)),
                    "grid_spacing": 64,
                    "icon_size": 128,
                    "icon_locations": ICON_LOCATIONS,
                    "show_status_bar": False,
                    "show_tab_view": False,
                    "show_toolbar": False,
                    "show_pathbar": False,
                    "show_sidebar": False,
                },
                lookForHiDPI=False,
                callback=track_mount,
            )
        finally:
            # dmgbuild can raise after attaching but outside its detach handler
            # (for example, when sync fails). Only detach this build's device.
            if build_mount is not None:
                created_image, device = build_mount
                attached = plistlib.loads(subprocess.check_output(["hdiutil", "info", "-plist"]))
                if any(
                    Path(image["image-path"]).resolve() == created_image and entity.get("dev-entry") == device
                    for image in attached["images"]
                    for entity in image["system-entities"]
                ):
                    subprocess.run(["hdiutil", "detach", "-force", device], check=True)
        if app_manifest(app) != expected_app:
            raise ValueError("The source app changed during DMG creation.")
        validate_image(archive, expected_app, background)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("Usage: build_dmg.py <source.app> <output.dmg>")
    build_image(Path(sys.argv[1]), Path(sys.argv[2]))
