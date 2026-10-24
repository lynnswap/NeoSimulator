#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/package-release.sh --version <tag> [--dist-root <dir>] [--output-dir <dir>] [--signing-identity <identity>] [--notary-profile <profile>]

Requires Python 3.10+ with scripts/release-requirements.txt installed.
Without Developer ID signing and notarization, the DMG is for validation only.
EOF
}

version=""
dist_root="dist"
output_dir="release"
signing_identity="${CODE_SIGN_IDENTITY:-}"
notary_profile="${NOTARYTOOL_KEYCHAIN_PROFILE:-}"
app_name="NeoSimulator"

require_value() {
  if [[ $# -lt 2 || -z "$2" || "$2" == --* ]]; then
    echo "Missing value for $1." >&2
    usage >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      require_value "$@"
      version="${2:-}"
      shift 2
      ;;
    --dist-root)
      require_value "$@"
      dist_root="${2:-}"
      shift 2
      ;;
    --output-dir)
      require_value "$@"
      output_dir="${2:-}"
      shift 2
      ;;
    --signing-identity)
      require_value "$@"
      signing_identity="${2:-}"
      shift 2
      ;;
    --notary-profile)
      require_value "$@"
      notary_profile="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$version" ]]; then
  echo "--version is required." >&2
  usage
  exit 1
fi
if [[ ! "$version" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*)?(\+[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*)?$ ]]; then
  echo "--version must be a release version such as v1.2.3 or v1.2.3-beta.1." >&2
  exit 1
fi
if [[ -n "$notary_profile" && -z "$signing_identity" ]]; then
  echo "--notary-profile requires --signing-identity so the DMG can be signed before notarization." >&2
  usage
  exit 1
fi
if [[ -n "$notary_profile" && "$signing_identity" != Developer\ ID\ Application:* ]]; then
  echo "--notary-profile requires a Developer ID Application signing identity." >&2
  echo "Apple Development identities are only valid for local development builds." >&2
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

app_path="$dist_base/arm64/${app_name}.app"
binary_path="$app_path/Contents/MacOS/${app_name}"
asset_version="${version#v}"
archive_name="${app_name}_${asset_version}.dmg"
archive_path="$output_base/$archive_name"

for path in "$app_path" "$binary_path"; do
  if [[ ! -e "$path" ]]; then
    echo "Missing staged artifact: $path" >&2
    exit 1
  fi
done

if [[ "$(lipo -archs "$binary_path")" != "arm64" ]]; then
  echo "${app_name} is not arm64-only." >&2
  exit 1
fi

if ! codesign --verify --deep --strict "$app_path"; then
  echo "${app_name}.app has an invalid code signature." >&2
  exit 1
fi
app_signature="$(codesign -dv --verbose=4 "$app_path" 2>&1)"
if ! grep -q '^Authority=Developer ID Application:' <<<"$app_signature"; then
  if [[ -n "$notary_profile" ]]; then
    echo "${app_name}.app must be Developer ID signed before packaging for notarization." >&2
    exit 1
  fi
  echo "Warning: ${app_name}.app is not Developer ID signed. This archive is for validation only." >&2
fi

python3 - "$app_path" "$output_base" <<'PYTHON'
import sys
from pathlib import Path

if sys.version_info < (3, 10):
    raise SystemExit("DMG packaging requires Python 3.10 or newer.")
try:
    import dmgbuild
    import ds_store
except ImportError as error:
    raise SystemExit(
        "Missing DMG packaging dependency. Install scripts/release-requirements.txt "
        "into the Python environment before packaging."
    ) from error
if Path(sys.argv[2]).resolve().is_relative_to(Path(sys.argv[1]).resolve()):
    raise SystemExit("The output directory must be outside the source app.")
PYTHON

mkdir -p "$output_base"
package_root="$(mktemp -d "$output_base/.package-release.XXXXXX")"
cleanup() {
  rm -rf "$package_root"
}
trap cleanup EXIT

pending_archive="$package_root/$archive_name"
python3 "$repo_root/scripts/build_dmg.py" "$app_path" "$pending_archive"

if [[ -n "$signing_identity" ]]; then
  codesign \
    --force \
    --timestamp \
    --sign "$signing_identity" \
    "$pending_archive"
  codesign --verify --verbose=2 "$pending_archive"
else
  echo "Warning: ${app_name} DMG was not signed. This archive is for validation only." >&2
fi

if [[ -n "$notary_profile" ]]; then
  xcrun notarytool submit "$pending_archive" --keychain-profile "$notary_profile" --wait
  xcrun stapler staple "$pending_archive"
  xcrun stapler validate "$pending_archive"
  spctl -a -vv -t open --context context:primary-signature "$pending_archive"
else
  echo "Warning: ${app_name} DMG was not notarized and is for validation only, not public distribution." >&2
fi

mv -f "$pending_archive" "$archive_path"
echo "Created release archive: $archive_path"
