#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
xcodebuild \
  -workspace "$repo_root/NeoSimulator.xcworkspace" \
  -scheme NeoSimulator \
  -skipPackagePluginValidation \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$repo_root/.build/host-tests" \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGN_STYLE=Manual \
  test
