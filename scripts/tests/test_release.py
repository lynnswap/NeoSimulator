from pathlib import Path
import plistlib
import json
import os
import shutil
import subprocess
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


class BuildScriptSigningTests(unittest.TestCase):
    def test_signing_choice_reaches_renderer_and_manager(self):
        identity = "Developer ID Application: Fixture Identity (ABCDEFGHIJ)"
        cases = [
            ("build-release.sh", ["--version", "v1.2.3"], None, "-"),
            ("build-local.sh", ["--signing-identity", identity], "ignored-environment-identity", identity),
            ("build-release.sh", ["--version", "v1.2.3"], "A" * 40, "A" * 40),
        ]
        for script, arguments, environment_identity, expected_identity in cases:
            with self.subTest(script=script, identity=expected_identity), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                scripts = root / "scripts"
                scripts.mkdir()
                for name in ("build-local.sh", "build-release.sh"):
                    shutil.copy2(Path(__file__).resolve().parents[1] / name, scripts / name)
                tools = root / "tools"
                tools.mkdir()
                bodies = {
                    "git": 'print("abc123")',
                    "lipo": 'print("arm64")',
                    "codesign": 'import json, os, sys\nwith open(os.environ["FIXTURE_SIGNING_LOG"], "a") as log: log.write(json.dumps(sys.argv[1:]) + "\\n")',
                    "xcodebuild": '''import pathlib, plistlib, sys
args = sys.argv[1:]
products = pathlib.Path(args[args.index("-derivedDataPath") + 1]) / "Build/Products/Release"
app = products / "NeoSimulator.app"
for bundle, name in [(app, "NeoSimulator"), (app / "Contents/Applications/NeoSimulatorRenderer.app", "NeoSimulatorRenderer")]:
    (bundle / "Contents/MacOS").mkdir(parents=True)
    (bundle / "Contents/MacOS" / name).write_bytes(b"fixture")
    (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": name}))
''',
                }
                for name, body in bodies.items():
                    path = tools / name
                    path.write_text(f"#!{sys.executable}\n{body}\n")
                    path.chmod(0o755)
                log = root / "signing.jsonl"
                environment = os.environ.copy()
                environment["PATH"] = str(tools) + os.pathsep + os.defpath
                environment["FIXTURE_SIGNING_LOG"] = str(log)
                environment.pop("CODE_SIGN_IDENTITY", None)
                if environment_identity is not None:
                    environment["CODE_SIGN_IDENTITY"] = environment_identity
                result = subprocess.run(["bash", str(scripts / script), *arguments], env=environment,
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                calls = [json.loads(line) for line in log.read_text().splitlines()]
                signing = [call for call in calls if "--sign" in call]
                self.assertEqual(len(signing), 2)
                self.assertEqual([Path(call[-1]).name for call in signing],
                                 ["NeoSimulatorRenderer.app", "NeoSimulator.app"])
                for call in signing:
                    self.assertEqual(call[call.index("--sign") + 1], expected_identity)
                    self.assertEqual(call[call.index("--options") + 1], "runtime")
                    self.assertIn("--timestamp=none" if expected_identity == "-" else "--timestamp", call)
                    self.assertNotIn("--timestamp" if expected_identity == "-" else "--timestamp=none", call)
                self.assertEqual(calls[-1][:-1], ["--verify", "--deep", "--strict"])



if __name__ == "__main__":
    unittest.main()
