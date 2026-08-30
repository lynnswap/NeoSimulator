#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/build-release.sh --version <tag> [--dist-root <dir>]

Builds the arm64 CLI and companion app, then stages them under:
  <dist-root>/arm64/bin/xcode-simulator-host
  <dist-root>/arm64/libexec/xcode-simulator-host/NeoSimulator.app
EOF
}

version=""
dist_root="dist"
arch="arm64"
cli_product="xcode-simulator-host"
host_product="NeoSimulator"
host_bundle_identifier="dev.lynnswap.NeoSimulator"
host_workspace="xcode-simulator-host.xcworkspace"

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
stage_dir=""

cleanup() {
  if [[ -n "$stage_dir" && -d "$stage_dir" ]]; then
    rm -rf "$stage_dir"
  fi
}
trap cleanup EXIT

pushd "$repo_root" >/dev/null

expected_version="${version#v}"
swift build -c release --arch "$arch" --product "$cli_product"
bin_path="$(swift build -c release --arch "$arch" --show-bin-path)"
cli_source_path="$bin_path/$cli_product"

actual_version="$("$cli_source_path" --version)"
if [[ "$actual_version" != "$expected_version" ]]; then
  echo "Binary version does not match release tag." >&2
  echo "Expected: $expected_version" >&2
  echo "Actual:   $actual_version" >&2
  exit 1
fi

host_derived_data="$repo_root/.build/$host_product"
xcodebuild \
  -quiet \
  -workspace "$host_workspace" \
  -scheme "$host_product" \
  -configuration Release \
  -derivedDataPath "$host_derived_data" \
  ARCHS="$arch" \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO \
  MARKETING_VERSION="$expected_version" \
  build
host_source_app="$host_derived_data/Build/Products/Release/$host_product.app"
host_source_path="$host_source_app/Contents/MacOS/$host_product"
host_info_plist="$host_source_app/Contents/Info.plist"

for source_path in "$cli_source_path" "$host_source_path" "$host_info_plist"; do
  if [[ ! -f "$source_path" ]]; then
    echo "Failed to locate release input: $source_path" >&2
    exit 1
  fi
done

if [[ ! -x "$cli_source_path" || ! -x "$host_source_path" ]]; then
  echo "Release products must be executable." >&2
  exit 1
fi

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$host_info_plist" 2>/dev/null || true
}

host_short_version="$(plist_value CFBundleShortVersionString)"
if [[ "$host_short_version" != "$expected_version" ]]; then
  echo "Companion app version does not match release tag." >&2
  echo "Expected: $expected_version" >&2
  echo "Actual:   $host_short_version" >&2
  exit 1
fi
if [[ "$(plist_value CFBundleExecutable)" != "$host_product" ]]; then
  echo "Host Info.plist must declare CFBundleExecutable=$host_product." >&2
  exit 1
fi
if [[ "$(plist_value CFBundleIdentifier)" != "$host_bundle_identifier" ]]; then
  echo "Host Info.plist must declare CFBundleIdentifier=$host_bundle_identifier." >&2
  exit 1
fi
if [[ "$(plist_value CFBundlePackageType)" != "APPL" ]]; then
  echo "Host Info.plist must declare CFBundlePackageType=APPL." >&2
  exit 1
fi

mkdir -p "$dist_base"
stage_dir="$(mktemp -d "${dist_base%/}/.${arch}.stage.XXXXXX")"
bin_out="$stage_dir/bin"
host_app="$stage_dir/libexec/$cli_product/$host_product.app"
host_contents="$host_app/Contents"
host_macos="$host_contents/MacOS"
mkdir -p "$bin_out" "$host_macos"

cli_target_path="$bin_out/$cli_product"
host_target_path="$host_macos/$host_product"
install -m 755 "$cli_source_path" "$cli_target_path"
install -m 755 "$host_source_path" "$host_target_path"
install -m 644 "$host_info_plist" "$host_contents/Info.plist"

if command -v lipo >/dev/null 2>&1; then
  for binary in "$cli_target_path" "$host_target_path"; do
    archs="$(lipo -archs "$binary")"
    if [[ "$archs" != "$arch" ]]; then
      echo "Expected $arch binary, got $archs: $binary" >&2
      exit 1
    fi
  done
fi

if ! command -v codesign >/dev/null 2>&1; then
  echo "codesign is required to build the companion app." >&2
  exit 1
fi
codesign --force --sign - --timestamp=none "$cli_target_path" >/dev/null
codesign --force --sign - --timestamp=none "$host_app" >/dev/null
codesign --verify --strict "$cli_target_path"
codesign --verify --deep --strict "$host_app"

rm -rf "$out_dir"
mv "$stage_dir" "$out_dir"
stage_dir=""

popd >/dev/null

echo "Staged release CLI at: $out_dir/bin/$cli_product"
echo "Staged companion app at: $out_dir/libexec/$cli_product/$host_product.app"
