#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/package-release.sh --version <tag> [--repo <owner/repo>] [--dist-root <dir>] [--output-dir <dir>]

Requires:
  <dist-root>/arm64/bin/xcode-simulator-host
  <dist-root>/arm64/libexec/xcode-simulator-host/XcodeSimulatorNeoHost.app

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
cli_product="xcode-simulator-host"
host_product="XcodeSimulatorNeoHost"

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

source_root="$dist_base/arm64"
cli_source_path="$source_root/bin/$cli_product"
host_source_app="$source_root/libexec/$cli_product/$host_product.app"
host_source_binary="$host_source_app/Contents/MacOS/$host_product"
for source_path in "$cli_source_path" "$host_source_app/Contents/Info.plist" "$host_source_binary" "$host_source_app/Contents/_CodeSignature/CodeResources"; do
  if [[ ! -e "$source_path" ]]; then
    echo "Missing staged release input: $source_path" >&2
    exit 1
  fi
done

expected_files="$(printf '%s\n' \
  "bin/$cli_product" \
  "libexec/$cli_product/$host_product.app/Contents/Info.plist" \
  "libexec/$cli_product/$host_product.app/Contents/MacOS/$host_product" \
  "libexec/$cli_product/$host_product.app/Contents/_CodeSignature/CodeResources" | LC_ALL=C sort)"
actual_files="$(
  cd "$source_root"
  find bin libexec -type f -print | LC_ALL=C sort
)"
if [[ "$actual_files" != "$expected_files" ]]; then
  echo "Staged release file set is not expected." >&2
  printf 'Expected:\n%s\n' "$expected_files" >&2
  printf 'Actual:\n%s\n' "$actual_files" >&2
  exit 1
fi

tmp_root="${TMPDIR:-/tmp}"
tmp_dir="$(mktemp -d "${tmp_root%/}/xcode-simulator-host-package.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$output_base"
archive="$output_base/$archive_name"
install_script="$output_base/install.sh"
rm -f "$archive" "$output_base/SHA256SUMS.txt" "$install_script"

cp -R "$source_root/bin" "$tmp_dir/bin"
cp -R "$source_root/libexec" "$tmp_dir/libexec"
chmod +x "$tmp_dir/bin/$cli_product"
chmod +x "$tmp_dir/libexec/$cli_product/$host_product.app/Contents/MacOS/$host_product"
if command -v lipo >/dev/null 2>&1; then
  for binary in \
    "$tmp_dir/bin/$cli_product" \
    "$tmp_dir/libexec/$cli_product/$host_product.app/Contents/MacOS/$host_product"; do
    archs="$(lipo -archs "$binary")"
    if [[ "$archs" != "arm64" ]]; then
      echo "Expected arm64 binary, got $archs: $binary" >&2
      exit 1
    fi
  done
fi
if command -v codesign >/dev/null 2>&1; then
  codesign --verify --strict "$tmp_dir/bin/$cli_product"
  codesign --verify --deep --strict \
    "$tmp_dir/libexec/$cli_product/$host_product.app"
fi

COPYFILE_DISABLE=1 tar -C "$tmp_dir" -czf "$archive" bin libexec

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
