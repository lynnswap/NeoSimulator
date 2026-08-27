#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/package-release.sh --version <tag> [--repo <owner/repo>] [--dist-root <dir>] [--output-dir <dir>]

Requires:
  <dist-root>/arm64/bin/xcode-simulator-host

Outputs:
  <output-dir>/xcode-simulator-host-darwin-arm64.tar.gz
  <output-dir>/SHA256SUMS.txt
  <output-dir>/install.sh
EOF
}

version=""
release_repo="lynnswap/xcode-simulator-host"
dist_root="dist"
output_dir="release"
archive_name="xcode-simulator-host-darwin-arm64.tar.gz"
product="xcode-simulator-host"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      version="${2:-}"
      shift 2
      ;;
    --repo)
      release_repo="${2:-}"
      shift 2
      ;;
    --dist-root)
      dist_root="${2:-}"
      shift 2
      ;;
    --output-dir)
      output_dir="${2:-}"
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

if [[ ! "$release_repo" =~ ^[0-9A-Za-z_.-]+/[0-9A-Za-z_.-]+$ ]]; then
  echo "Release repo must look like owner/repo." >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$dist_root" = /* ]]; then
  dist_base="$dist_root"
else
  dist_base="$repo_root/$dist_root"
fi
if [[ "$output_dir" = /* ]]; then
  output_base="$output_dir"
else
  output_base="$repo_root/$output_dir"
fi

source_path="$dist_base/arm64/bin/$product"
if [[ ! -f "$source_path" ]]; then
  echo "Missing staged binary: $source_path" >&2
  exit 1
fi

tmp_root="${TMPDIR:-/tmp}"
tmp_dir="$(mktemp -d "${tmp_root%/}/xcode-simulator-host-package.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$output_base" "$tmp_dir/bin"
archive="$output_base/$archive_name"
install_script="$output_base/install.sh"
rm -f "$archive" "$output_base/SHA256SUMS.txt" "$install_script"

cp "$source_path" "$tmp_dir/bin/$product"
chmod +x "$tmp_dir/bin/$product"
if command -v lipo >/dev/null 2>&1; then
  archs="$(lipo -archs "$tmp_dir/bin/$product")"
  if [[ "$archs" != "arm64" ]]; then
    echo "Expected arm64 binary for $product, got: $archs" >&2
    exit 1
  fi
fi

tar -C "$tmp_dir" -czf "$archive" bin

"$repo_root/scripts/render-install-script.sh" \
  --version "$version" \
  --repo "$release_repo" \
  --output "$install_script"

(
  cd "$output_base"
  shasum -a 256 "$archive_name" install.sh > SHA256SUMS.txt
)

echo "Created release package: $archive"
echo "Created checksum file: $output_base/SHA256SUMS.txt"
echo "Created install script: $install_script"
