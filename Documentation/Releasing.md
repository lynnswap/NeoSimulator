# Releasing NeoSimulator

Once the release is approved, set `version` to its tag (for example, `v1.2.3`),
`notes_file` to the release notes file, and `commit` to the approved full SHA.
That commit must still be the tip of `main` on GitHub.

```sh
python3 scripts/prepare_release.py start \
  --repo lynnswap/NeoSimulator \
  --version "$version" \
  --source-sha "$commit" \
  --notes-file "$notes_file"
```

Add `--prerelease` for a prerelease. This creates the tag and draft release and
starts [Publish Release](https://github.com/lynnswap/NeoSimulator/actions/workflows/release.yml).
Approve the deployment when prompted.
