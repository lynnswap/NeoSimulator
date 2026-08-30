#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
arch="arm64"
cli_product="xcode-simulator-host"
dist_root="$repo_root/.build/local"

pushd "$repo_root" >/dev/null
swift build -c release --arch "$arch" --product "$cli_product"
bin_path="$(swift build -c release --arch "$arch" --show-bin-path)"
version="$("$bin_path/$cli_product" --version)"
popd >/dev/null

"$repo_root/scripts/build-release.sh" \
  --version "v$version" \
  --dist-root "$dist_root"

echo "Run the source-built command at:"
echo "  $dist_root/$arch/bin/$cli_product"
