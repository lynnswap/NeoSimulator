#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
hosting_base_path="${1-NeoSimulator}"
output_path="$repo_root/.build/documentation"

mkdir -p "$(dirname "$output_path")"
xcrun docc convert "$repo_root/Documentation/NeoSimulator.docc" \
  --fallback-display-name NeoSimulator \
  --fallback-bundle-identifier dev.lynnswap.NeoSimulator \
  --fallback-bundle-version 1 \
  --hosting-base-path "$hosting_base_path" \
  --output-path "$output_path" \
  --warnings-as-errors

cat > "$output_path/index.html" <<'HTML'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>NeoSimulator documentation</title>
  <meta http-equiv="refresh" content="0;url=./documentation/neosimulator/">
</head>
<body><a href="./documentation/neosimulator/">NeoSimulator documentation</a></body>
</html>
HTML
