#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/verify-release-assets.sh --version <tag> --repo <owner/repo> [--release-dir <dir>] [--archive-sha256 <sha256>]
EOF
}

version=""
release_repo=""
release_dir="release"
archive_sha256=""
archive_asset="xcode-simulator-host-darwin-arm64.tar.gz"
checksum_asset="SHA256SUMS.txt"
installer_asset="install.sh"
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
    --release-dir)
      release_dir="${2:-}"
      shift 2
      ;;
    --archive-sha256)
      archive_sha256="${2:-}"
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

if [[ -n "$archive_sha256" && ! "$archive_sha256" =~ ^[0-9A-Fa-f]{64}$ ]]; then
  echo "Archive SHA256 must be a 64-character hex digest." >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$release_dir" = /* ]]; then
  release_base="$release_dir"
else
  release_base="$repo_root/$release_dir"
fi

if [[ ! -d "$release_base" ]]; then
  echo "Missing release directory: $release_base" >&2
  exit 1
fi

expected_assets=(
  "$archive_asset"
  "$checksum_asset"
  "$installer_asset"
)
for asset in "${expected_assets[@]}"; do
  if [[ ! -f "$release_base/$asset" ]]; then
    echo "Expected release asset was not created: $asset" >&2
    exit 1
  fi
done

expected_asset_list="$(printf '%s\n' "${expected_assets[@]}" | sort)"
actual_asset_list="$(
  cd "$release_base"
  for path in *; do
    [[ -f "$path" ]] && printf '%s\n' "$path"
  done | sort
)"
if [[ "$actual_asset_list" != "$expected_asset_list" ]]; then
  echo "Release asset set is not expected." >&2
  printf 'Expected:\n%s\n' "$expected_asset_list" >&2
  printf 'Actual:\n%s\n' "$actual_asset_list" >&2
  exit 1
fi

tmp_root="${TMPDIR:-/tmp}"
tmp_dir="$(mktemp -d "${tmp_root%/}/xcode-simulator-host-verify.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT
expected_checksums="$tmp_dir/SHA256SUMS.expected"
(
  cd "$release_base"
  shasum -a 256 "$archive_asset" "$installer_asset" > "$expected_checksums"
)
if ! cmp -s "$expected_checksums" "$release_base/$checksum_asset"; then
  echo "SHA256SUMS.txt does not match the expected release assets." >&2
  diff -u "$expected_checksums" "$release_base/$checksum_asset" || true
  exit 1
fi

(
  cd "$release_base"
  shasum -a 256 -c "$checksum_asset"
)

if [[ -n "$archive_sha256" ]]; then
  actual_archive_sha256="$(shasum -a 256 "$release_base/$archive_asset" | awk '{ print $1 }')"
  expected_archive_sha256="$(printf '%s' "$archive_sha256" | tr 'A-F' 'a-f')"
  if [[ "$actual_archive_sha256" != "$expected_archive_sha256" ]]; then
    echo "Archive SHA256 does not match the trusted build output." >&2
    echo "Expected: $expected_archive_sha256" >&2
    echo "Actual:   $actual_archive_sha256" >&2
    exit 1
  fi
fi

sh -n "$release_base/$installer_asset"
"$repo_root/scripts/render-install-script.sh" \
  --version "$version" \
  --repo "$release_repo" \
  --output "$tmp_dir/install.expected.sh"
if ! cmp -s "$tmp_dir/install.expected.sh" "$release_base/$installer_asset"; then
  echo "install.sh does not match the generated installer for $version." >&2
  diff -u "$tmp_dir/install.expected.sh" "$release_base/$installer_asset" || true
  exit 1
fi

expected_entries="$(printf '%s\n' \
  "bin/" \
  "bin/$cli_product" \
  "libexec/" \
  "libexec/$cli_product/" \
  "libexec/$cli_product/$host_product.app/" \
  "libexec/$cli_product/$host_product.app/Contents/" \
  "libexec/$cli_product/$host_product.app/Contents/Info.plist" \
  "libexec/$cli_product/$host_product.app/Contents/MacOS/" \
  "libexec/$cli_product/$host_product.app/Contents/MacOS/$host_product" \
  "libexec/$cli_product/$host_product.app/Contents/_CodeSignature/" \
  "libexec/$cli_product/$host_product.app/Contents/_CodeSignature/CodeResources" |
  LC_ALL=C sort)"
actual_entries="$(tar -tzf "$release_base/$archive_asset" | LC_ALL=C sort)"
if [[ "$actual_entries" != "$expected_entries" ]]; then
  echo "Release archive contents are not expected." >&2
  printf 'Expected:\n%s\n' "$expected_entries" >&2
  printf 'Actual:\n%s\n' "$actual_entries" >&2
  exit 1
fi

extracted_root="$tmp_dir/extracted"
mkdir -p "$extracted_root"
tar -C "$extracted_root" -xzf "$release_base/$archive_asset"
extracted_cli="$extracted_root/bin/$cli_product"
extracted_app="$extracted_root/libexec/$cli_product/$host_product.app"
extracted_host="$extracted_app/Contents/MacOS/$host_product"
expected_files="$(printf '%s\n' \
  "bin/$cli_product" \
  "libexec/$cli_product/$host_product.app/Contents/Info.plist" \
  "libexec/$cli_product/$host_product.app/Contents/MacOS/$host_product" \
  "libexec/$cli_product/$host_product.app/Contents/_CodeSignature/CodeResources" | LC_ALL=C sort)"
actual_files="$(
  cd "$extracted_root"
  find bin libexec -type f -print | LC_ALL=C sort
)"
if [[ "$actual_files" != "$expected_files" ]]; then
  echo "Release archive file types are not expected." >&2
  printf 'Expected:\n%s\n' "$expected_files" >&2
  printf 'Actual:\n%s\n' "$actual_files" >&2
  exit 1
fi
if [[ ! -x "$extracted_cli" || ! -x "$extracted_host" ]]; then
  echo "Release archive executables are not executable." >&2
  exit 1
fi

if [[ "$(uname -s)" == "Darwin" ]]; then
  install_root="$tmp_dir/install-root"
  mkdir -p \
    "$install_root/bin" \
    "$install_root/libexec/$cli_product/$host_product.app"
  printf 'previous cli\n' > "$install_root/bin/$cli_product"
  printf 'previous app\n' > \
    "$install_root/libexec/$cli_product/$host_product.app/previous-version"
  XCODE_SIMULATOR_HOST_BASE_URL="file://$release_base" \
    sh "$release_base/$installer_asset" --bindir "$install_root/bin"
  installed_app="$install_root/libexec/$cli_product/$host_product.app"
  cmp -s \
    "$install_root/bin/$cli_product" \
    "$extracted_cli"
  cmp -s \
    "$installed_app/Contents/Info.plist" \
    "$extracted_app/Contents/Info.plist"
  cmp -s \
    "$installed_app/Contents/MacOS/$host_product" \
    "$extracted_host"
  cmp -s \
    "$installed_app/Contents/_CodeSignature/CodeResources" \
    "$extracted_app/Contents/_CodeSignature/CodeResources"
  installed_app_files="$(
    cd "$installed_app"
    find . -type f -print | LC_ALL=C sort
  )"
  expected_app_files="$(printf '%s\n' \
    "./Contents/Info.plist" \
    "./Contents/MacOS/$host_product" \
    "./Contents/_CodeSignature/CodeResources" | LC_ALL=C sort)"
  if [[ "$installed_app_files" != "$expected_app_files" ]]; then
    echo "Installed companion app file set is not expected." >&2
    printf 'Expected:\n%s\n' "$expected_app_files" >&2
    printf 'Actual:\n%s\n' "$installed_app_files" >&2
    exit 1
  fi
  codesign --verify --deep --strict "$installed_app"
  codesign --verify --strict "$install_root/bin/$cli_product"
  if [[ "$(lipo -archs "$extracted_cli")" != "arm64" ||
        "$(lipo -archs "$extracted_host")" != "arm64" ]]; then
    echo "Release archive must contain arm64-only executables." >&2
    exit 1
  fi
  installed_version="$("$install_root/bin/$cli_product" --version)"
  if [[ "$installed_version" != "${version#v}" ]]; then
    echo "Installed binary version does not match release tag." >&2
    echo "Expected: ${version#v}" >&2
    echo "Actual:   $installed_version" >&2
    exit 1
  fi

  physical_root="$tmp_dir/symlink-physical"
  linked_root="$tmp_dir/symlink-entry"
  mkdir -p "$physical_root/bin" "$linked_root"
  ln -s "$physical_root/bin" "$linked_root/bin"
  XCODE_SIMULATOR_HOST_BASE_URL="file://$release_base" \
    sh "$release_base/$installer_asset" --bindir "$linked_root/bin"
  physical_app="$physical_root/libexec/$cli_product/$host_product.app"
  cmp -s "$physical_root/bin/$cli_product" "$extracted_cli"
  cmp -s "$physical_app/Contents/Info.plist" "$extracted_app/Contents/Info.plist"
  cmp -s "$physical_app/Contents/MacOS/$host_product" "$extracted_host"
  if [[ -e "$linked_root/libexec" ]]; then
    echo "A symlinked bindir installed the companion relative to the logical path." >&2
    exit 1
  fi

  verify_interrupted_backup_rollback() {
    local interrupted_artifact="$1"
    local interrupted_root="$tmp_dir/interrupted-$interrupted_artifact"
    local interrupted_app
    local fake_bin
    local marker
    local interrupt_source
    local real_mv

    mkdir -p \
      "$interrupted_root/bin" \
      "$interrupted_root/libexec/$cli_product/$host_product.app" \
      "$interrupted_root/fake-bin"
    interrupted_root="$(cd -P "$interrupted_root" && pwd)"
    interrupted_app="$interrupted_root/libexec/$cli_product/$host_product.app"
    fake_bin="$interrupted_root/fake-bin"
    marker="$interrupted_root/interrupted"
    printf 'previous cli\n' > "$interrupted_root/bin/$cli_product"
    printf 'previous app\n' > "$interrupted_app/previous-version"
    if [[ "$interrupted_artifact" == "app" ]]; then
      interrupt_source="$interrupted_app"
    else
      interrupt_source="$interrupted_root/bin/$cli_product"
    fi
    real_mv="$(command -v mv)"
    printf '%s\n' \
      '#!/bin/sh' \
      '"$XSH_REAL_MV" "$@"' \
      'if [ "$1" = "$XSH_INTERRUPT_SOURCE" ] && [ ! -e "$XSH_INTERRUPT_MARKER" ]; then' \
      '  : > "$XSH_INTERRUPT_MARKER"' \
      '  kill -TERM "$PPID"' \
      'fi' > "$fake_bin/mv"
    chmod 755 "$fake_bin/mv"

    if PATH="$fake_bin:$PATH" \
      XSH_REAL_MV="$real_mv" \
      XSH_INTERRUPT_SOURCE="$interrupt_source" \
      XSH_INTERRUPT_MARKER="$marker" \
      XCODE_SIMULATOR_HOST_BASE_URL="file://$release_base" \
      sh "$release_base/$installer_asset" --bindir "$interrupted_root/bin"; then
      echo "Interrupted $interrupted_artifact backup unexpectedly completed." >&2
      exit 1
    fi

    if ! grep -qxF 'previous cli' "$interrupted_root/bin/$cli_product" ||
       ! grep -qxF 'previous app' "$interrupted_app/previous-version" ||
       [[ -e "$interrupted_app/Contents" ]]; then
      echo "Interrupted $interrupted_artifact backup did not restore the previous installation." >&2
      exit 1
    fi
    if find "$interrupted_root" -maxdepth 1 \
      -name '.xcode-simulator-host-install.*' -print -quit | grep -q .; then
      echo "Interrupted $interrupted_artifact backup left a completed rollback transaction." >&2
      exit 1
    fi
  }

  verify_interrupted_backup_rollback app
  verify_interrupted_backup_rollback cli
fi
