"""Start a release from approved notes, then publish its verified CI artifacts."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys


VERSION_PATTERN = re.compile(r"v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?")


class ReleaseError(Exception):
    pass


def run(arguments: list[str], *, input: str | None = None) -> str:
    result = subprocess.run(arguments, input=input, capture_output=True, text=True)
    if result.returncode:
        raise ReleaseError(f"{arguments[0]} failed ({result.returncode}): {result.stderr.strip()}")
    return result.stdout


def api(endpoint: str, *, paginate: bool = False):
    arguments = ["gh", "api", "--method", "GET"]
    if paginate:
        arguments += ["--paginate", "--slurp"]
    return json.loads(run([*arguments, endpoint]))


def validate_request(version: str, source_sha: str) -> str:
    if not VERSION_PATTERN.fullmatch(version):
        raise ReleaseError("Version must look like v1.2.3 or v1.2.3-beta.1.")
    if not re.fullmatch(r"[0-9a-f]{40}", source_sha):
        raise ReleaseError("The release source must be a full commit SHA.")
    if os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("GITHUB_REF") != "refs/heads/main":
        raise ReleaseError("Publish Release must run on the main branch in GitHub Actions.")
    if source_sha != os.environ.get("GITHUB_SHA") or run(["git", "rev-parse", "HEAD"]).strip() != source_sha:
        raise ReleaseError("The release source does not match the workflow checkout.")
    repository = os.environ.get("GITHUB_REPOSITORY", "")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ReleaseError("GITHUB_REPOSITORY must identify the release repository.")
    return repository


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def validate_artifacts(directory: Path, version: str, source_sha: str, repository: str, dmg_sha256: str) -> dict[str, str]:
    if not re.fullmatch(r"[0-9a-f]{64}", dmg_sha256):
        raise ReleaseError("Missing or malformed digest from the signing job.")
    dmg_name = f"NeoSimulator_{version[1:]}.dmg"
    expected_names = {dmg_name, "release-info.json", "SHA256SUMS"}
    if {path.name for path in directory.iterdir()} != expected_names:
        raise ReleaseError("The signing artifact does not contain the exact release file set.")
    for name in expected_names:
        path = directory / name
        if path.is_symlink() or not path.is_file():
            raise ReleaseError(f"Release asset must be a regular file: {name}")
    if digest(directory / dmg_name) != dmg_sha256:
        raise ReleaseError("DMG checksum differs from the signing job's output.")
    info = json.loads((directory / "release-info.json").read_text())
    expected = {
        "version": version,
        "source_sha": source_sha,
        "repository": repository,
        "run_id": os.environ["GITHUB_RUN_ID"],
        "build_number": os.environ["GITHUB_RUN_NUMBER"],
        "developer_id_signed": True,
        "notarized": True,
    }
    for key, value in expected.items():
        if info.get(key) != value or type(info.get(key)) is not type(value):
            raise ReleaseError(f"Release metadata mismatch: {key}")
    for key in ("apple_team_id", "signing_certificate_sha1", "notary_submission_id"):
        if not isinstance(info.get(key), str) or not info[key]:
            raise ReleaseError(f"Missing signing metadata: {key}")
    expected_checksums = {dmg_name: dmg_sha256, "release-info.json": digest(directory / "release-info.json")}
    actual_checksums = {}
    for line in (directory / "SHA256SUMS").read_text().splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
        if not match or match[2] in actual_checksums:
            raise ReleaseError("Malformed or duplicate SHA256SUMS entry.")
        actual_checksums[match[2]] = match[1]
    if actual_checksums != expected_checksums:
        raise ReleaseError("Release checksums do not match the signed artifact.")
    return {**expected_checksums, "SHA256SUMS": digest(directory / "SHA256SUMS")}


def matching_releases(repository: str, version: str) -> list[dict]:
    # Drafts are visible only with push access; this runs in the contents:write job.
    pages = api(f"repos/{repository}/releases?per_page=100", paginate=True)
    return [release for page in pages for release in page if release["tag_name"] == version]


def require_absent_tag(repository: str, version: str) -> None:
    refs = api(f"repos/{repository}/git/matching-refs/tags/{version}")
    if any(ref["ref"] == f"refs/tags/{version}" for ref in refs):
        raise ReleaseError(f"Tag {version} already exists; it will not be moved or reused.")


def patch_release(repository: str, release_id: int, fields: dict) -> dict:
    return json.loads(run([
        "gh", "api", "--method", "PATCH", f"repos/{repository}/releases/{release_id}",
        "--input", "-",
    ], input=json.dumps(fields)))


def require_draft(release: dict, version: str, source_sha: str, prerelease: bool | None = None) -> None:
    if release["draft"] is not True or release["tag_name"] != version:
        raise ReleaseError("The selected release is no longer the requested draft.")
    if release["target_commitish"] != source_sha:
        raise ReleaseError("The draft target differs from the tested commit.")
    if prerelease is not None and release["prerelease"] is not prerelease:
        raise ReleaseError("The draft's prerelease setting changed after publication was requested.")
    if not (release.get("body") or "").strip():
        raise ReleaseError("Register the approved release notes before starting publication.")


def prepare_draft(version: str, source_sha: str) -> dict:
    repository = validate_request(version, source_sha)
    releases = matching_releases(repository, version)
    if len(releases) != 1:
        raise ReleaseError("Create one draft with the version and approved notes before starting this workflow.")
    release = releases[0]
    # A UI-created draft can name main; resolve it once to this workflow's commit.
    target = release["target_commitish"]
    if target not in ("main", source_sha):
        raise ReleaseError("The draft must target main or this workflow's exact commit.")
    require_draft({**release, "target_commitish": source_sha}, version, source_sha)
    require_absent_tag(repository, version)
    if target != source_sha:
        release = patch_release(repository, release["id"], {"target_commitish": source_sha})
        require_draft(release, version, source_sha)
    return release


def verify_uploaded_asset(release: dict, name: str, checksum: str) -> None:
    assets = [asset for asset in release["assets"] if asset["name"] == name]
    if len(assets) != 1 or assets[0]["state"] != "uploaded" or assets[0].get("digest") != f"sha256:{checksum}":
        raise ReleaseError(f"Draft asset upload/digest mismatch: {name}")


def verify_uploaded_assets(release: dict, checksums: dict[str, str]) -> None:
    assets = release["assets"]
    if len(assets) != len(checksums) or {asset["name"] for asset in assets} != set(checksums):
        raise ReleaseError("Release asset set differs from the verified artifact.")
    for name, checksum in checksums.items():
        verify_uploaded_asset(release, name, checksum)


def publish_draft(directory: Path, version: str, source_sha: str, dmg_sha256: str,
                  release_id: int, prerelease: bool) -> str:
    repository = validate_request(version, source_sha)
    checksums = validate_artifacts(directory, version, source_sha, repository, dmg_sha256)
    endpoint = f"repos/{repository}/releases/{release_id}"
    release = api(endpoint)
    if release["draft"] is False:
        # A successful publish can lose its response or fail the final read.
        # A retry may confirm the same artifact, but must never mutate a public release.
        return confirm_publication(repository, release, version, source_sha, checksums, prerelease)
    require_draft(release, version, source_sha, prerelease)
    require_absent_tag(repository, version)
    for name, checksum in checksums.items():
        existing = [asset for asset in release["assets"] if asset["name"] == name]
        if existing:
            # Rerunning the failed publish job reuses the same signed artifact.
            # Never overwrite a different upload under the same asset name.
            verify_uploaded_asset(release, name, checksum)
        else:
            run(["gh", "release", "upload", version, str(directory / name), "--repo", repository])
    release = api(endpoint)
    require_draft(release, version, source_sha, prerelease)
    verify_uploaded_assets(release, checksums)
    require_absent_tag(repository, version)
    # Reassert the approved identity in the publishing update so intervening draft
    # edits cannot redirect it. Leave the user's title and notes untouched.
    published = patch_release(repository, release_id, {
        "tag_name": version,
        "target_commitish": source_sha,
        "prerelease": prerelease,
        "draft": False,
    })
    return confirm_publication(repository, published, version, source_sha, checksums, prerelease)


def confirm_publication(repository: str, published: dict, version: str, source_sha: str,
                        checksums: dict[str, str], prerelease: bool) -> str:
    if published["draft"] is not False or published["tag_name"] != version or published["prerelease"] is not prerelease:
        raise ReleaseError("GitHub did not confirm publication; inspect the release before retrying.")
    verify_uploaded_assets(published, checksums)
    tag = api(f"repos/{repository}/git/ref/tags/{version}")["object"]
    while tag["type"] == "tag":
        tag = api(f"repos/{repository}/git/tags/{tag['sha']}")["object"]
    if tag["type"] != "commit" or tag["sha"] != source_sha:
        raise ReleaseError("The published tag differs from the tested commit; inspect the release.")
    url = published["html_url"]
    if summary_path := os.environ.get("GITHUB_STEP_SUMMARY"):
        with Path(summary_path).open("a") as summary:
            summary.write(f"## Release published\n\n[{version}]({url}) targets `{source_sha}`.\n")
    return url


def start_release(repository: str, version: str, source_sha: str, notes_file: Path, prerelease: bool) -> str:
    if not VERSION_PATTERN.fullmatch(version):
        raise ReleaseError("Version must look like v1.2.3 or v1.2.3-beta.1.")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ReleaseError("Repository must be OWNER/REPO.")
    if not notes_file.read_text().strip():
        raise ReleaseError("Release notes must not be empty.")
    if matching_releases(repository, version):
        raise ReleaseError("This release already exists. Use Publish Release to start an existing draft.")
    require_absent_tag(repository, version)
    main_sha = api(f"repos/{repository}/git/ref/heads/main")["object"]["sha"]
    if not re.fullmatch(r"[0-9a-f]{40}", source_sha) or main_sha != source_sha:
        raise ReleaseError("The approved source SHA must be the current main commit.")
    url = run([
        "gh", "release", "create", version, "--repo", repository, "--draft",
        "--target", source_sha, "--title", version, "--notes-file", str(notes_file),
        f"--prerelease={'true' if prerelease else 'false'}",
    ]).strip()
    try:
        run(["gh", "workflow", "run", "release.yml", "--repo", repository,
             "--ref", "main", "-f", f"version={version}"])
    except ReleaseError as error:
        raise ReleaseError(f"Draft saved at {url}, but workflow dispatch was not confirmed. "
                           f"Check Actions before retrying Publish Release: {error}") from error
    return (f"Draft: {url}\nActions: https://github.com/{repository}/actions/workflows/release.yml\n"
            "Approve signing in GitHub; CI then uploads assets and publishes. No local wait is needed.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    start = commands.add_parser("start", help="Save approved notes as a draft and dispatch publication without waiting")
    start.add_argument("--repo", required=True)
    start.add_argument("--version", required=True)
    start.add_argument("--source-sha", required=True)
    start.add_argument("--notes-file", type=Path, required=True)
    start.add_argument("--prerelease", action="store_true")
    for name in ("prepare", "publish"):
        command = commands.add_parser(name)
        command.add_argument("--version", required=True)
        command.add_argument("--source-sha", required=True)
        if name == "publish":
            command.add_argument("--directory", type=Path, required=True)
            command.add_argument("--dmg-sha256", required=True)
            command.add_argument("--release-id", type=int, required=True)
            command.add_argument("--prerelease", choices=("true", "false"), required=True)
    args = parser.parse_args()
    try:
        if args.command == "start":
            print(start_release(args.repo, args.version, args.source_sha, args.notes_file, args.prerelease))
        elif args.command == "prepare":
            release = prepare_draft(args.version, args.source_sha)
            with open(os.environ["GITHUB_OUTPUT"], "a") as output:
                output.write(f"release-id={release['id']}\nprerelease={str(release['prerelease']).lower()}\n")
            print(f"Publishing draft {release['id']}: {args.version} at {args.source_sha}")
        else:
            print(publish_draft(args.directory, args.version, args.source_sha, args.dmg_sha256,
                                args.release_id, args.prerelease == "true"))
    except (ReleaseError, OSError, ValueError, KeyError) as error:
        print(f"Release preparation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
