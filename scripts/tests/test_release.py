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
        helper = self.app / "Contents/Helpers/NeoSimulatorGuestSettings"
        helper.parent.mkdir(parents=True)
        helper.write_bytes(bytes.fromhex("cffaedfe") + b"fixture")
        self.helper = helper
        self.tools = sign_release.NativeTools()

    @staticmethod
    def native_result(arguments, operation, **kwargs):
        stdout = b"arm64" if arguments[0] == "/usr/bin/lipo" else b""
        if "--entitlements" in arguments and Path(arguments[-1]).name == "NeoSimulatorGuestSettings":
            stdout = plistlib.dumps(dict.fromkeys(sign_release.GUEST_SETTINGS_ENTITLEMENTS, True))
        if arguments[0] == "/usr/bin/segedit":
            Path(arguments[-1]).write_bytes(plistlib.dumps(dict.fromkeys(sign_release.GUEST_SETTINGS_SIMULATOR_ENTITLEMENTS, True)))
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

    def test_rejects_a_missing_helper_exception_or_an_exception_on_the_manager(self):
        allow_dyld_only = {"com.apple.security.cs.allow-dyld-environment-variables": True}
        for path, values in ((self.helper, {}), (self.helper, allow_dyld_only),
                             (self.app, dict.fromkeys(sign_release.GUEST_SETTINGS_ENTITLEMENTS, True))):
            with self.subTest(path=path.name):
                def result(arguments, operation, **kwargs):
                    if "--entitlements" in arguments and Path(arguments[-1]) == path:
                        return sign_release.NativeResult(plistlib.dumps(values), b"", 0)
                    return self.native_result(arguments, operation, **kwargs)
                with patch.object(self.tools, "run", side_effect=result):
                    with self.assertRaises(sign_release.ReleaseError):
                        sign_release.validate_app(self.tools, self.mount, "v1.2.3", "7")

    def test_rejects_a_helper_without_both_simulator_service_entitlements(self):
        def result(arguments, operation, **kwargs):
            if arguments[0] == "/usr/bin/segedit":
                Path(arguments[-1]).write_bytes(plistlib.dumps({"com.apple.frontboard.launchapplications": True}))
                return sign_release.NativeResult(b"", b"", 0)
            return self.native_result(arguments, operation, **kwargs)
        with patch.object(self.tools, "run", side_effect=result):
            with self.assertRaisesRegex(sign_release.ReleaseError, "simulator service entitlements"):
                sign_release.validate_app(self.tools, self.mount, "v1.2.3", "7")

    def test_resigning_uses_the_helper_profile_without_app_exceptions(self):
        credentials = sign_release.SigningCredentials(Path("fixture.keychain"), "A" * 40, Path("fixture.p8"))
        identifiers = {self.helper: "NeoSimulatorGuestSettings-generated-uuid", self.renderer: sign_release.RENDERER_IDENTIFIER,
                       self.app: sign_release.APP_IDENTIFIER}
        profiles = {}
        flags = {}
        def result(arguments, operation, **kwargs):
            path = Path(arguments[-1])
            if "--sign" in arguments:
                if "--identifier" in arguments:
                    identifiers[path] = arguments[arguments.index("--identifier") + 1]
                profiles[path] = plistlib.loads(Path(arguments[arguments.index("--entitlements") + 1]).read_bytes()) if "--entitlements" in arguments else {}
                flags[path] = "0x10000" if "--options" in arguments and arguments[arguments.index("--options") + 1] == "runtime" else "0x0"
            if "--verbose=4" in arguments:
                metadata = f"Identifier={identifiers[path]}\nTeamIdentifier=ABCDEFGHIJ\nAuthority=Developer ID Application: Fixture (ABCDEFGHIJ)\nTimestamp=2026-10-29\nflags={flags[path]}\n"
                return sign_release.NativeResult(b"", metadata.encode(), 0)
            if "--display" in arguments and "--entitlements" in arguments:
                return sign_release.NativeResult(plistlib.dumps(profiles[path]), b"", 0)
            return self.native_result(arguments, operation, **kwargs)
        with patch.object(self.tools, "run", side_effect=result) as run:
            sign_release.sign_application(self.tools, self.app, credentials, "ABCDEFGHIJ")
        signing = [call.args[0] for call in run.call_args_list if "--sign" in call.args[0]]
        self.assertEqual([Path(call[-1]) for call in signing], [self.helper, self.renderer, self.app])
        self.assertEqual(Path(signing[0][signing[0].index("--entitlements") + 1]), sign_release.GUEST_SETTINGS_ENTITLEMENTS_PATH)
        self.assertEqual(signing[0][signing[0].index("--identifier") + 1], sign_release.GUEST_SETTINGS_NAME)
        self.assertTrue(all("--identifier" not in call and "--entitlements" not in call for call in signing[1:]))


class BuildScriptSigningTests(unittest.TestCase):
    def run_build(self, root, script, arguments, environment_identity=None, *, guest_section="GuestVirtual.entitlements"):
        scripts = root / "scripts"
        scripts.mkdir()
        for name in ("build-local.sh", "build-release.sh"):
            shutil.copy2(Path(__file__).resolve().parents[1] / name, scripts / name)
        guest = root / "App/NeoSimulatorGuestSettings"
        guest.mkdir(parents=True)
        for name in ("GuestSettings.entitlements", "GuestVirtual.entitlements"):
            shutil.copy2(sign_release.GUEST_SETTINGS_ENTITLEMENTS_PATH.with_name(name), guest / name)
        tools = root / "tools"
        tools.mkdir()
        bodies = {
            "git": 'print("abc123")',
            "lipo": 'print("arm64")',
            "codesign": 'import json, os, sys\nwith open(os.environ["FIXTURE_SIGNING_LOG"], "a") as log: log.write(json.dumps(sys.argv[1:]) + "\\n")',
            "segedit": 'import shutil, sys\nshutil.copyfile(sys.argv[1], sys.argv[-1])',
            "xcodebuild": '''import os, pathlib, plistlib, shutil, sys
args = sys.argv[1:]
products = pathlib.Path(args[args.index("-derivedDataPath") + 1]) / "Build/Products/Release"
app = products / "NeoSimulator.app"
for bundle, name in [(app, "NeoSimulator"), (app / "Contents/Applications/NeoSimulatorRenderer.app", "NeoSimulatorRenderer")]:
    (bundle / "Contents/MacOS").mkdir(parents=True)
    (bundle / "Contents/MacOS" / name).write_bytes(b"fixture")
    build_number = next(value.split("=", 1)[1] for value in args if value.startswith("CURRENT_PROJECT_VERSION="))
    (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": name, "CFBundleVersion": build_number}))
helper = app / "Contents/Helpers/NeoSimulatorGuestSettings"
helper.parent.mkdir(parents=True)
# The fake segedit extracts the whole helper as its linked entitlements section.
shutil.copyfile(os.environ["FIXTURE_GUEST_SECTION"], helper)
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
        environment["FIXTURE_GUEST_SECTION"] = str(guest / guest_section)
        environment.pop("CODE_SIGN_IDENTITY", None)
        if environment_identity is not None:
            environment["CODE_SIGN_IDENTITY"] = environment_identity
        result = subprocess.run(["bash", str(scripts / script), *arguments], env=environment,
                                capture_output=True, text=True)
        return result, log

    def test_signing_choice_reaches_renderer_and_manager(self):
        identity = "Developer ID Application: Fixture Identity (ABCDEFGHIJ)"
        cases = [
            ("build-release.sh", ["--version", "v1.2.3"], None, "-", None),
            ("build-local.sh", ["--signing-identity", identity], "ignored-environment-identity", identity, None),
            ("build-release.sh", ["--version", "v1.2.3"], "A" * 40, "A" * 40, None),
            ("build-local.sh", ["--build-number", "17"], None, "-", False),
            ("build-local.sh", [], None, "-", True),
        ]
        for script, arguments, environment_identity, expected_identity, absolute_staging in cases:
            with self.subTest(script=script, identity=expected_identity, absolute_staging=absolute_staging), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                destination = root / ("dist" if script == "build-release.sh" else ".build/local")
                if absolute_staging is not None:
                    destination = root / "custom staging"
                    arguments = [*arguments, "--dist-root", str(destination) if absolute_staging else "custom staging"]
                result, log = self.run_build(root, script, arguments, environment_identity)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                staged_app = destination / "arm64/NeoSimulator.app"
                self.assertIn(f"Staged app: {staged_app}", result.stdout.splitlines())
                for line in result.stdout.splitlines():
                    if line.startswith("  open "):
                        self.assertEqual(line, f"  open '{staged_app}'")
                info = plistlib.loads((staged_app / "Contents/Info.plist").read_bytes())
                self.assertEqual(info["CFBundleVersion"], "17" if "--build-number" in arguments else "1")
                calls = [json.loads(line) for line in log.read_text().splitlines()]
                signing = [call for call in calls if "--sign" in call]
                self.assertEqual(len(signing), 3)
                self.assertEqual([Path(call[-1]).name for call in signing],
                                 ["NeoSimulatorGuestSettings", "NeoSimulatorRenderer.app", "NeoSimulator.app"])
                for call in signing:
                    self.assertEqual(call[call.index("--sign") + 1], expected_identity)
                    self.assertEqual(call[call.index("--options") + 1], "runtime")
                    self.assertIn("--timestamp=none" if expected_identity == "-" else "--timestamp", call)
                    self.assertNotIn("--timestamp" if expected_identity == "-" else "--timestamp=none", call)
                entitlements = root / "App/NeoSimulatorGuestSettings/GuestSettings.entitlements"
                self.assertEqual(Path(signing[0][signing[0].index("--entitlements") + 1]), entitlements)
                self.assertEqual(plistlib.loads(entitlements.read_bytes()), dict.fromkeys(sign_release.GUEST_SETTINGS_ENTITLEMENTS, True))
                self.assertEqual(plistlib.loads(entitlements.with_name("GuestVirtual.entitlements").read_bytes()),
                                 dict.fromkeys(sign_release.GUEST_SETTINGS_SIMULATOR_ENTITLEMENTS, True))
                self.assertEqual(signing[0][signing[0].index("--identifier") + 1], sign_release.GUEST_SETTINGS_NAME)
                self.assertTrue(all("--identifier" not in call and "--entitlements" not in call for call in signing[1:]))
                self.assertEqual(calls[-1][:-1], ["--verify", "--deep", "--strict"])

    def test_rejects_a_helper_without_its_simulator_entitlements(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result, _ = self.run_build(root, "build-release.sh", ["--version", "v1.2.3"],
                                       guest_section="GuestSettings.entitlements")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Expected the guest settings helper to embed GuestVirtual.entitlements.", result.stderr)
            self.assertFalse((root / "dist/arm64").exists())



if __name__ == "__main__":
    unittest.main()
