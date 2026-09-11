#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
developer_dir="$(xcode-select -p)"
xcode_app="$(cd "$developer_dir/../.." && pwd)"
output_dir="$repo_root/.build/input-focus-tests"
mkdir -p "$output_dir"

xcrun --sdk macosx clang \
  -arch arm64 \
  -fobjc-arc \
  -Wall -Wextra -Werror \
  -I "$repo_root/Sources/NeoSimulator" \
  -framework AppKit \
  -framework UniformTypeIdentifiers \
  "$repo_root/Tests/NeoSimulatorInputTests/InputFocusTests.m" \
  "$repo_root/Sources/NeoSimulator/DeviceWindowController.m" \
  "$repo_root/Sources/NeoSimulator/DeviceToolRunner.m" \
  "$repo_root/Sources/NeoSimulator/HostLogging.m" \
  "$repo_root/Sources/NeoSimulator/PrivateRuntime.m" \
  "$repo_root/Sources/NeoSimulator/SwiftABI.S" \
  -o "$output_dir/InputFocusTests"

"$output_dir/InputFocusTests" "$xcode_app"
