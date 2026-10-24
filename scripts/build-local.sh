#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="v0.0.0-dev.$(git -C "$repo_root" rev-parse --short HEAD)"
"$repo_root/scripts/build-release.sh" --version "$version" --dist-root .build/local
echo "Open the source-built app with:"
echo "  open '$repo_root/.build/local/arm64/NeoSimulator.app'"
