#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/build-release.sh --version <tag> [--build-number <positive-integer>] [--dist-root <dir>] [--signing-identity <identity>]

Builds the arm64 NeoSimulator.app, including its renderer and guest settings helper.
Signing defaults to ad hoc (-). Use --signing-identity or CODE_SIGN_IDENTITY
to sign the app and its nested code with a certificate name or SHA-1 hash.
Public Developer ID signing and notarization run separately in release.yml.
USAGE
}

version=""
build_number="1"
dist_root="dist"
signing_identity="${CODE_SIGN_IDENTITY:--}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version|--build-number|--dist-root|--signing-identity)
      if [[ $# -lt 2 || -z "$2" || "$2" == --* ]]; then
        echo "Missing value for $1." >&2
        exit 1
      fi
      case "$1" in
        --version) version="$2" ;;
        --build-number) build_number="$2" ;;
        --dist-root) dist_root="$2" ;;
        --signing-identity) signing_identity="$2" ;;
      esac
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done
if [[ ! "$version" =~ ^v([0-9]+[.][0-9]+[.][0-9]+)(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "Release tag must look like v1.2.3 or v1.2.3-rc.1." >&2
  exit 1
fi
marketing_version="${BASH_REMATCH[1]}"
if [[ ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
  echo "--build-number must be a positive integer." >&2
  exit 1
fi
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$dist_root" != /* ]]; then dist_root="$repo_root/$dist_root"; fi
derived_data="$repo_root/.build/NeoSimulator"
mkdir -p "$dist_root"
staging="$(mktemp -d "$dist_root/.arm64.stage.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
# Xcode can retain resources removed from a target in an existing app bundle.
# Recreate the bundles while keeping compiled dependencies in DerivedData.
rm -rf "$derived_data/Build/Products/Release/NeoSimulator.app" \
  "$derived_data/Build/Products/Release/NeoSimulatorRenderer.app"
xcodebuild \
  -quiet \
  -workspace "$repo_root/NeoSimulator.xcworkspace" \
  -scheme NeoSimulator \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$derived_data" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  MARKETING_VERSION="$marketing_version" \
  CURRENT_PROJECT_VERSION="$build_number" \
  build
app="$staging/NeoSimulator.app"
ditto "$derived_data/Build/Products/Release/NeoSimulator.app" "$app"
renderer="$app/Contents/Applications/NeoSimulatorRenderer.app"
helper="$app/Contents/Helpers/NeoSimulatorGuestSettings"
if [[ "$(lipo -archs "$helper")" != arm64 ]]; then
  echo "Expected an arm64 guest settings helper." >&2
  exit 1
fi
# The simulator authorizes guest service requests from this Mach-O section; the
# macOS signature applied below cannot provide those entitlements.
guest_entitlements="$staging/guest-entitlements.plist"
segedit "$helper" -extract __TEXT __entitlements "$guest_entitlements"
if ! cmp -s "$guest_entitlements" "$repo_root/App/NeoSimulatorGuestSettings/GuestVirtual.entitlements"; then
  echo "Expected the guest settings helper to embed GuestVirtual.entitlements." >&2
  exit 1
fi
rm "$guest_entitlements"
timestamp_option="--timestamp=none"
if [[ "$signing_identity" != - ]]; then timestamp_option="--timestamp"; fi
# Simulator executables need DYLD_ROOT_PATH to select their runtime libraries.
codesign --force --options runtime --identifier NeoSimulatorGuestSettings \
  --entitlements "$repo_root/App/NeoSimulatorGuestSettings/GuestSettings.entitlements" \
  --sign "$signing_identity" "$timestamp_option" "$helper"
for bundle in "$renderer" "$app"; do
  executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$bundle/Contents/Info.plist")"
  if [[ "$(lipo -archs "$bundle/Contents/MacOS/$executable")" != arm64 ]]; then
    echo "Expected an arm64 executable in $bundle." >&2
    exit 1
  fi
  codesign --force --options runtime --sign "$signing_identity" "$timestamp_option" "$bundle"
done
codesign --verify --deep --strict "$app"
rm -rf "$dist_root/arm64"
mv "$staging" "$dist_root/arm64"
trap - EXIT
echo "Staged app: $dist_root/arm64/NeoSimulator.app"
