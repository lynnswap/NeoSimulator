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
import prepare_release as release


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
        helper = self.app / "Contents/Resources/NeoSimulatorGuestSettings"
        helper.parent.mkdir(parents=True)
        helper.write_bytes(bytes.fromhex("cffaedfe") + b"fixture")
        self.helper = helper
        self.tools = sign_release.NativeTools()

    @staticmethod
    def native_result(arguments, operation, **kwargs):
        stdout = b"arm64" if arguments[0] == "/usr/bin/lipo" else b""
        stderr = b""
        if "--verbose=4" in arguments and Path(arguments[-1]).name == "NeoSimulatorGuestSettings":
            stderr = b"Identifier=NeoSimulatorGuestSettings\nSignature=adhoc\nflags=0x10002\n"
        if "--entitlements" in arguments and Path(arguments[-1]).name == "NeoSimulatorGuestSettings":
            stdout = plistlib.dumps(dict.fromkeys(sign_release.GUEST_SETTINGS_ENTITLEMENTS, True))
        if "--entitlements" in arguments and Path(arguments[-1]).name == "NeoSimulator.app":
            stdout = plistlib.dumps(dict.fromkeys(sign_release.MANAGER_ENTITLEMENTS, True))
        if arguments[0] == "/usr/bin/segedit":
            Path(arguments[-1]).write_bytes(plistlib.dumps(dict.fromkeys(sign_release.GUEST_SETTINGS_SIMULATOR_ENTITLEMENTS, True)))
        return sign_release.NativeResult(stdout, stderr, 0)

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

    def test_rejects_entitlements_outside_each_signing_profile(self):
        allow_dyld_only = {"com.apple.security.cs.allow-dyld-environment-variables": True}
        camera = dict.fromkeys(sign_release.MANAGER_ENTITLEMENTS, True)
        for path, values in ((self.helper, {}), (self.helper, allow_dyld_only), (self.app, {}),
                             (self.app, {**camera, **dict.fromkeys(sign_release.GUEST_SETTINGS_ENTITLEMENTS, True)}),
                             (self.renderer, camera)):
            with self.subTest(path=path.name, values=sorted(values)):
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

    def test_rejects_developer_id_signing_of_the_simulator_helper(self):
        def result(arguments, operation, **kwargs):
            if "--verbose=4" in arguments and Path(arguments[-1]) == self.helper:
                return sign_release.NativeResult(b"", b"Identifier=NeoSimulatorGuestSettings\nSignature size=9000\nflags=0x10000\n", 0)
            return self.native_result(arguments, operation, **kwargs)
        with patch.object(self.tools, "run", side_effect=result):
            with self.assertRaisesRegex(sign_release.ReleaseError, "ad hoc"):
                sign_release.validate_app(self.tools, self.mount, "v1.2.3", "7")

    def test_resigning_applies_each_signing_profile(self):
        credentials = sign_release.SigningCredentials(Path("fixture.keychain"), "A" * 40, Path("fixture.p8"))
        identifiers = {self.helper: "NeoSimulatorGuestSettings-generated-uuid", self.renderer: sign_release.RENDERER_IDENTIFIER,
                       self.app: sign_release.APP_IDENTIFIER}
        profiles = {}
        flags = {}
        identities = {}
        def result(arguments, operation, **kwargs):
            path = Path(arguments[-1])
            if "--sign" in arguments:
                if "--identifier" in arguments:
                    identifiers[path] = arguments[arguments.index("--identifier") + 1]
                profiles[path] = plistlib.loads(Path(arguments[arguments.index("--entitlements") + 1]).read_bytes()) if "--entitlements" in arguments else {}
                identities[path] = arguments[arguments.index("--sign") + 1]
                flags[path] = "0x10000" if "--options" in arguments and arguments[arguments.index("--options") + 1] == "runtime" else "0x0"
            if "--verbose=4" in arguments:
                signature = "Signature=adhoc\n" if identities[path] == "-" else ""
                metadata = f"Identifier={identifiers[path]}\n{signature}TeamIdentifier=ABCDEFGHIJ\nAuthority=Developer ID Application: Fixture (ABCDEFGHIJ)\nTimestamp=2026-10-29\nflags={flags[path]}\n"
                return sign_release.NativeResult(b"", metadata.encode(), 0)
            if "--display" in arguments and "--entitlements" in arguments:
                return sign_release.NativeResult(plistlib.dumps(profiles[path]), b"", 0)
            return self.native_result(arguments, operation, **kwargs)
        with patch.object(self.tools, "run", side_effect=result) as run:
            sign_release.sign_application(self.tools, self.app, credentials, "ABCDEFGHIJ")
        signing = [call.args[0] for call in run.call_args_list if "--sign" in call.args[0]]
        self.assertEqual([Path(call[-1]) for call in signing], [self.helper, self.renderer, self.app])
        self.assertEqual(signing[0][signing[0].index("--sign") + 1], "-")
        self.assertTrue(all(call[call.index("--sign") + 1] == credentials.certificate_sha1 for call in signing[1:]))
        self.assertEqual(Path(signing[0][signing[0].index("--entitlements") + 1]), sign_release.GUEST_SETTINGS_ENTITLEMENTS_PATH)
        self.assertEqual(signing[0][signing[0].index("--identifier") + 1], sign_release.GUEST_SETTINGS_NAME)
        self.assertEqual(Path(signing[2][signing[2].index("--entitlements") + 1]), sign_release.MANAGER_ENTITLEMENTS_PATH)
        self.assertTrue(all("--identifier" not in call for call in signing[1:]))


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
        (root / "App/NeoSimulator").mkdir()
        shutil.copy2(sign_release.MANAGER_ENTITLEMENTS_PATH, root / "App/NeoSimulator/NeoSimulator.entitlements")
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
    marketing_version = next(value.split("=", 1)[1] for value in args if value.startswith("MARKETING_VERSION="))
    (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": name, "CFBundleVersion": build_number, "CFBundleShortVersionString": marketing_version}))
helper = app / "Contents/Resources/NeoSimulatorGuestSettings"
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
            ("build-release.sh", ["--version", "v1.2.3-rc.1", "--build-number", "17"], None, "-", None),
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
                for bundle in [staged_app, staged_app / "Contents/Applications/NeoSimulatorRenderer.app"]:
                    info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
                    self.assertEqual(info["CFBundleVersion"], "17" if "--build-number" in arguments else "1")
                    self.assertEqual(info["CFBundleShortVersionString"], "1.2.3" if script == "build-release.sh" else "0.0.0")
                calls = [json.loads(line) for line in log.read_text().splitlines()]
                signing = [call for call in calls if "--sign" in call]
                self.assertEqual(len(signing), 3)
                self.assertEqual([Path(call[-1]).name for call in signing],
                                 ["NeoSimulatorGuestSettings", "NeoSimulatorRenderer.app", "NeoSimulator.app"])
                for index, call in enumerate(signing):
                    identity = "-" if index == 0 else expected_identity
                    self.assertEqual(call[call.index("--sign") + 1], identity)
                    self.assertEqual(call[call.index("--options") + 1], "runtime")
                    self.assertIn("--timestamp=none" if identity == "-" else "--timestamp", call)
                    self.assertNotIn("--timestamp" if identity == "-" else "--timestamp=none", call)
                entitlements = root / "App/NeoSimulatorGuestSettings/GuestSettings.entitlements"
                self.assertEqual(Path(signing[0][signing[0].index("--entitlements") + 1]), entitlements)
                self.assertEqual(plistlib.loads(entitlements.read_bytes()), dict.fromkeys(sign_release.GUEST_SETTINGS_ENTITLEMENTS, True))
                self.assertEqual(plistlib.loads(entitlements.with_name("GuestVirtual.entitlements").read_bytes()),
                                 dict.fromkeys(sign_release.GUEST_SETTINGS_SIMULATOR_ENTITLEMENTS, True))
                self.assertEqual(signing[0][signing[0].index("--identifier") + 1], sign_release.GUEST_SETTINGS_NAME)
                self.assertTrue(all("--identifier" not in call for call in signing[1:]))
                self.assertNotIn("--entitlements", signing[1])
                self.assertEqual(Path(signing[2][signing[2].index("--entitlements") + 1]),
                                 root / "App/NeoSimulator/NeoSimulator.entitlements")
                self.assertEqual(calls[-1][:-1], ["--verify", "--deep", "--strict"])

    def test_rejects_a_helper_without_its_simulator_entitlements(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result, _ = self.run_build(root, "build-release.sh", ["--version", "v1.2.3"],
                                       guest_section="GuestSettings.entitlements")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Expected the guest settings helper to embed GuestVirtual.entitlements.", result.stderr)
            self.assertFalse((root / "dist/arm64").exists())



class ReleaseTagTests(unittest.TestCase):
    def setUp(self):
        self.repository = "lynnswap/NeoSimulator"
        self.sha = "a" * 40
        self.version = "v1.2.3"
        self.tag = {"ref": f"refs/tags/{self.version}", "object": {"type": "commit", "sha": self.sha}}
        self.draft = {"id": 42, "draft": True, "tag_name": self.version,
                      "target_commitish": self.sha, "body": "Approved notes", "prerelease": False,
                      "html_url": "https://example.invalid/draft", "assets": []}
        self.addCleanup(patch.stopall)
        patch.object(release, "validate_request", return_value=self.repository).start()

    def test_start_creates_tag_before_dispatch_and_reuses_matching_draft(self):
        with tempfile.TemporaryDirectory() as directory:
            notes = Path(directory) / "notes.md"
            notes.write_text(self.draft["body"])
            for prerelease in (False, True):
                for existing in (False, True):
                    with self.subTest(prerelease=prerelease, existing=existing):
                        draft = {**self.draft, "prerelease": prerelease}
                        responses = [{"object": {"sha": self.sha}}, [[draft]] if existing else [[]]]
                        responses += [[self.tag]] if existing else [[], [], [self.tag]]
                        with patch.object(release, "api", side_effect=responses), \
                                patch.object(release, "run", return_value=draft["html_url"]) as run:
                            release.start_release(self.repository, self.version, self.sha, notes, prerelease)
                        calls = [call.args[0] for call in run.call_args_list]
                        self.assertEqual(calls[-1][:4], ["gh", "workflow", "run", "release.yml"])
                        self.assertEqual(calls[-1][-2:], ["-f", f"prerelease={str(prerelease).lower()}"])
                        if existing:
                            self.assertEqual(len(calls), 1)
                        else:
                            self.assertEqual(calls[0][:4], ["gh", "release", "create", self.version])
                            self.assertIn(f"--prerelease={str(prerelease).lower()}", calls[0])
                            self.assertEqual(json.loads(run.call_args_list[1].kwargs["input"]),
                                             {"ref": f"refs/tags/{self.version}", "sha": self.sha})

    def test_start_with_uploaded_assets_requires_original_run(self):
        with tempfile.TemporaryDirectory() as directory:
            notes = Path(directory) / "notes.md"
            notes.write_text(self.draft["body"])
            with patch.object(release, "api", side_effect=[{"object": {"sha": self.sha}}, [[{**self.draft, "assets": [{"name": "previous.dmg"}]}]]]), patch.object(release, "run") as run:
                with self.assertRaisesRegex(release.ReleaseError, "Rerun the failed publication job"):
                    release.start_release(self.repository, self.version, self.sha, notes, False)
                run.assert_not_called()

    def test_prepare_pins_ui_draft_and_creates_tag_before_checks(self):
        for prerelease in (False, True):
            with self.subTest(prerelease=prerelease):
                draft = {**self.draft, "prerelease": prerelease}
                with patch.object(release, "api", side_effect=[[[{**draft, "target_commitish": "main"}]], [], [self.tag]]), \
                        patch.object(release, "patch_release", return_value=draft) as update, \
                        patch.object(release, "run") as run:
                    self.assertEqual(release.prepare_draft(self.version, self.sha, prerelease), draft)
                update.assert_called_once_with(self.repository, 42, {"target_commitish": self.sha})
                self.assertEqual(json.loads(run.call_args.kwargs["input"]),
                                 {"ref": f"refs/tags/{self.version}", "sha": self.sha})

    def test_prepare_rejects_a_different_release_kind_before_creating_a_tag(self):
        for prerelease in (False, True):
            with self.subTest(prerelease=prerelease), \
                    patch.object(release, "api", return_value=[[{**self.draft, "prerelease": not prerelease}]]), \
                    patch.object(release, "run") as run, patch.object(release, "patch_release") as update:
                with self.assertRaisesRegex(release.ReleaseError, "prerelease setting"):
                    release.prepare_draft(self.version, self.sha, prerelease)
                run.assert_not_called()
                update.assert_not_called()

    def test_prepare_reuses_annotated_tag_and_rejects_conflict(self):
        annotated = {**self.tag, "object": {"type": "tag", "sha": "c" * 40}}
        with patch.object(release, "run") as run:
            with patch.object(release, "api", side_effect=[[[self.draft]], [annotated], {"object": self.tag["object"]}]):
                release.prepare_draft(self.version, self.sha, False)
            with patch.object(release, "api", side_effect=[[[{**self.draft, "target_commitish": "main"}]], [{**self.tag, "object": {"type": "commit", "sha": "b" * 40}}]]), patch.object(release, "patch_release") as update:
                with self.assertRaisesRegex(release.ReleaseError, "differs"):
                    release.prepare_draft(self.version, self.sha, False)
                update.assert_not_called()
            run.assert_not_called()

    def test_publish_requires_tag_before_upload_and_after_upload(self):
        with patch.object(release, "validate_artifacts", return_value={}), \
                patch.object(release, "run") as run, patch.object(release, "patch_release") as update:
            for responses in ([self.draft, []], [self.draft, [self.tag], self.draft, []]):
                with patch.object(release, "api", side_effect=responses):
                    with self.assertRaisesRegex(release.ReleaseError, "missing or differs"):
                        release.publish_draft(Path("unused"), self.version, self.sha, "unused", 42, False)
            run.assert_not_called()
            update.assert_not_called()


if __name__ == "__main__":
    unittest.main()
