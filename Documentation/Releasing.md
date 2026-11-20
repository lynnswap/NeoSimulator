# Releasing NeoSimulator

For maintainers: build a validation DMG, publish a release, and set up the
workflows that sign releases and deploy the documentation. To build and test a
change, see [CONTRIBUTING.md](../CONTRIBUTING.md).

## Build a validation DMG

Local DMGs are for validation and are not releases. Packaging needs Python 3.10
or later and the pinned tools in `scripts/release-requirements.txt`; the release
workflows use Python 3.13:

```bash
python3.13 -m venv .build/release-tools
.build/release-tools/bin/pip install -r scripts/release-requirements.txt
scripts/build-release.sh --version v0.0.0-validation --dist-root dist
PATH="$PWD/.build/release-tools/bin:$PATH" \
  scripts/package-release.sh --version v0.0.0-validation --dist-root dist
```

`build-release.sh` signs ad hoc unless you pass `--signing-identity` or set
`CODE_SIGN_IDENTITY`, which also enables secure timestamps. `package-release.sh`
creates the DMG and verifies its files, signatures, architectures, and Finder
layout.

The manager's only entitlement is `com.apple.security.device.camera`, for
physical-device capture, and the renderer has none. The guest-settings helper in
`Resources` stays ad hoc signed, even in releases, with its simulator entitlements
embedded in the binary. Its macOS signing exceptions allow DYLD environment
variables and disable library validation.

## Publish a release

Start a public release only after its version, notes, exact main commit, and
publication plan are approved:

```bash
python3 scripts/prepare_release.py start \
  --repo lynnswap/NeoSimulator \
  --version vX.Y.Z \
  --source-sha <approved-main-commit> \
  --notes-file <approved-release-notes>
```

Add `--prerelease` for a prerelease. The command creates the tag and a draft
release, then dispatches the **Publish Release** workflow. A retry reuses a
matching tag and draft and never moves a conflicting tag. Check Actions before
retrying a dispatch whose result is uncertain. Starting from an existing draft
also creates the tag before building. If you run **Publish Release** manually,
its **prerelease** checkbox must match the draft; a mismatch stops the run before
it creates the tag.

The workflow runs CI and builds the arm64 DMG, then waits for approval of the
`release-signing` environment. It signs with Developer ID and notarizes using a
temporary keychain, keeps the helper's ad hoc signature, and verifies signatures
and entitlements. After stapling and Gatekeeper checks, it uploads the DMG,
`release-info.json`, and `SHA256SUMS`, checks that the tag still points to the
tested commit, and publishes the release. A failure leaves the tag and draft for
a retry.

Only **Publish Release** builds release apps and DMGs. Pushes to main run CI
without producing release artifacts. Release checks also validate the
distribution scripts.

## Configure release signing

Before the first public release, give the `release-signing` environment required
reviewers and these values:

| Kind | Name |
| --- | --- |
| Secret | `DEVELOPER_ID_P12_BASE64` |
| Secret | `DEVELOPER_ID_P12_PASSWORD` |
| Secret | `NOTARY_API_PRIVATE_KEY` |
| Variable | `APPLE_TEAM_ID` |
| Variable | `NOTARY_API_KEY_ID` |
| Variable | `NOTARY_API_ISSUER_ID` |

## Deploy the documentation

The Documentation workflow builds and deploys the site to GitHub Pages on pushes
to main, so the repository's Pages source must be **GitHub Actions**.
