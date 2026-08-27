#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/build-release.sh --version <tag> [--dist-root <dir>]

Builds the arm64 release binary and stages it under:
  <dist-root>/arm64/bin/
EOF
}

version=""
dist_root="dist"
arch="arm64"
product="xcode-simulator-host"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      version="${2:-}"
      shift 2
      ;;
    --dist-root)
      dist_root="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ ! "$version" =~ ^v[0-9]+[.][0-9]+[.][0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "Release tag must look like v1.2.3 or v1.2.3-rc.1." >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$dist_root" = /* ]]; then
  dist_base="$dist_root"
else
  dist_base="$repo_root/$dist_root"
fi

out_dir="$dist_base/$arch"
bin_out="$out_dir/bin"

pushd "$repo_root" >/dev/null

swift build -c release --arch "$arch" --product "$product"
bin_path="$(swift build -c release --arch "$arch" --show-bin-path)"
source_path="$bin_path/$product"
if [[ ! -f "$source_path" ]]; then
  echo "Failed to locate built binary: $source_path" >&2
  exit 1
fi

actual_version="$("$source_path" --version)"
expected_version="${version#v}"
if [[ "$actual_version" != "$expected_version" ]]; then
  echo "Binary version does not match release tag." >&2
  echo "Expected: $expected_version" >&2
  echo "Actual:   $actual_version" >&2
  exit 1
fi

rm -rf "$out_dir"
mkdir -p "$bin_out"
target_path="$bin_out/$product"
cp "$source_path" "$target_path"
chmod +x "$target_path"

if command -v lipo >/dev/null 2>&1; then
  archs="$(lipo -archs "$target_path")"
  if [[ "$archs" != "$arch" ]]; then
    echo "Expected $arch binary for $product, got: $archs" >&2
    exit 1
  fi
fi

if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "$target_path" >/dev/null
fi

popd >/dev/null

echo "Staged release binary at: $target_path"
