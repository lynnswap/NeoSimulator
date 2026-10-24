from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import sign_release


class ReleaseSigningTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.mount = Path(self.directory.name)
        self.app = self.mount / "NeoSimulator.app"
        self.renderer = self.app / "Contents/Applications/NeoSimulatorRenderer.app"
        for bundle, name, identifier in (
            (self.app, "NeoSimulator", sign_release.APP_IDENTIFIER),
            (self.renderer, "NeoSimulatorRenderer", sign_release.RENDERER_IDENTIFIER),
        ):
            (bundle / "Contents/MacOS").mkdir(parents=True)
            (bundle / f"Contents/MacOS/{name}").write_bytes(bytes.fromhex("cffaedfe") + b"fixture")
            (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": identifier, "CFBundleExecutable": name,
                "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "1.2.3",
                "CFBundleVersion": "7",
            }))
        self.tools = sign_release.NativeTools()

    @staticmethod
    def native_result(arguments, operation, **kwargs):
        stdout = b"arm64" if arguments[0] == "/usr/bin/lipo" else b""
        return sign_release.NativeResult(stdout, b"", 0)

    def test_validates_the_embedded_renderer_as_part_of_the_app(self):
        with patch.object(self.tools, "run", side_effect=self.native_result):
            result = sign_release.validate_app(self.tools, self.mount, "v1.2.3", "7")
        self.assertEqual(result, self.app)

    def test_rejects_a_renderer_from_a_different_release(self):
        info_path = self.renderer / "Contents/Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        info["CFBundleVersion"] = "6"
        info_path.write_bytes(plistlib.dumps(info))
        with patch.object(self.tools, "run", side_effect=self.native_result):
            with self.assertRaisesRegex(sign_release.ReleaseError, "renderer CFBundleVersion"):
                sign_release.validate_app(self.tools, self.mount, "v1.2.3", "7")



if __name__ == "__main__":
    unittest.main()
