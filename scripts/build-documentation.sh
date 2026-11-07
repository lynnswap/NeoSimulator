#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
hosting_base_path="${1-NeoSimulator}"
output_path="$repo_root/.build/documentation"
work_path="$repo_root/.build/documentation-work"
archives="$work_path/archives"

convert() {
  local name="$1" catalog="$2"
  shift 2
  xcrun docc convert "$catalog" \
    --fallback-display-name "$name" \
    --fallback-bundle-identifier "dev.lynnswap.$name" \
    --fallback-bundle-version 1 \
    --hosting-base-path "$hosting_base_path" \
    --output-path "$archives/$name.doccarchive" \
    --warnings-as-errors \
    "$@"
}

rm -rf "$output_path" "$work_path/symbol-graphs" "$work_path/catalogs" "$archives"
mkdir -p "$archives"

# Article-only archives cannot resolve module symbol links. Keep their ordinary links in this build,
# so local previews and deployments below a different hosting path do not open the published site.
python3 - "$repo_root" "$work_path/catalogs" "$hosting_base_path" <<'PYTHON'
from pathlib import Path
import shutil
import sys

root, catalogs = map(Path, sys.argv[1:3])
prefix = "/" + sys.argv[3].strip("/") if sys.argv[3].strip("/") else ""
for name, source in {
    "NeoSimulator": root / "Documentation/NeoSimulator.docc",
    "NeoSimulatorKit": root / "Sources/NeoSimulatorKit/NeoSimulatorKit.docc",
    "NeoSimulatorUI": root / "Sources/NeoSimulatorUI/NeoSimulatorUI.docc",
}.items():
    destination = catalogs / (name + ".docc")
    shutil.copytree(source, destination)
    for page in destination.rglob("*.md"):
        page.write_text(page.read_text().replace("https://lynnswap.github.io/NeoSimulator", prefix))
PYTHON

swift package --package-path "$repo_root" --scratch-path "$work_path/package" \
  dump-symbol-graph --minimum-access-level public --skip-synthesized-members

# Only these modules are supported API, so only their symbols reach the site.
for module in NeoSimulatorKit NeoSimulatorUI; do
  graphs="$work_path/symbol-graphs/$module"
  mkdir -p "$graphs"
  find "$work_path/package" -type f \( -name "$module.symbols.json" -o -name "$module@*.symbols.json" \) \
    -exec cp {} "$graphs" \;
  if [[ ! -f "$graphs/$module.symbols.json" ]]; then
    echo "error: no symbol graph for $module under $work_path/package" >&2
    exit 1
  fi
done

# Each archive resolves links only into archives built before it: UI depends on Kit, and the guide links to both.
convert NeoSimulatorKit "$work_path/catalogs/NeoSimulatorKit.docc" \
  --additional-symbol-graph-dir "$work_path/symbol-graphs/NeoSimulatorKit" \
  --enable-experimental-external-link-support
convert NeoSimulatorUI "$work_path/catalogs/NeoSimulatorUI.docc" \
  --additional-symbol-graph-dir "$work_path/symbol-graphs/NeoSimulatorUI" \
  --dependency "$archives/NeoSimulatorKit.doccarchive" \
  --enable-experimental-external-link-support
convert NeoSimulator "$work_path/catalogs/NeoSimulator.docc" \
  --dependency "$archives/NeoSimulatorKit.doccarchive" \
  --dependency "$archives/NeoSimulatorUI.doccarchive"

xcrun docc merge \
  "$archives/NeoSimulator.doccarchive" \
  "$archives/NeoSimulatorKit.doccarchive" \
  "$archives/NeoSimulatorUI.doccarchive" \
  --synthesized-landing-page-name NeoSimulator \
  --output-path "$output_path"

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
