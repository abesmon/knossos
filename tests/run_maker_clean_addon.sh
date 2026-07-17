#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/vrweb-maker-clean.XXXXXX")"
mkdir -p "$work/addons" "$work/home" "$work/assets" "$work/asset_fixtures"
cp "$repo/tests/fixtures/maker_clean_project/project.godot" "$work/project.godot"
cp "$repo/tests/fixtures/maker_clean_project/test.gd" "$work/test.gd"
cp "$repo/tests/fixtures/maker_clean_project/test.tscn" "$work/test.tscn"
cp "$repo/tests/fixtures/maker_clean_project/unsupported.tscn" "$work/unsupported.tscn"
cp "$repo/tests/fixtures/maker_clean_project/launcher_test.gd" "$work/launcher_test.gd"
cp "$repo/tests/fixtures/maker_clean_project/launcher_test.tscn" "$work/launcher_test.tscn"
cp "$repo/tests/fixtures/maker_clean_project/asset_test.gd" "$work/asset_test.gd"
cp "$repo/tests/fixtures/maker_clean_project/asset_test.tscn" "$work/asset_test.tscn"
cp "$repo/tests/fixtures/maker_clean_project/published_verifier_test.gd" "$work/published_verifier_test.gd"
cp "$repo/tests/fixtures/maker_clean_project/published_verifier_test.tscn" "$work/published_verifier_test.tscn"
cp "$repo/tests/fixtures/maker_clean_project/editable.html" "$work/editable.html"
cp "$repo/tests/fixtures/maker_clean_project/html_portable_test.gd" "$work/html_portable_test.gd"
cp "$repo/tests/fixtures/maker_clean_project/html_portable_test.tscn" "$work/html_portable_test.tscn"
cp "$repo/tests/fixtures/maker_clean_project/asset_fixtures/.gdignore" "$work/asset_fixtures/.gdignore"
cp "$repo/tests/fixtures/maker_clean_project/asset_fixtures/local_model.gltf" "$work/asset_fixtures/local_model.gltf"
cp "$repo/tests/fixtures/maker_clean_project/asset_fixtures/local_model.bin" "$work/asset_fixtures/local_model.bin"
cp "$repo/tests/fixtures/maker_clean_project/asset_fixtures/local_model.png" "$work/asset_fixtures/local_model.png"
cp "$repo/templates/vrweb_maker_starter/world.tscn" "$work/world.tscn"
cp "$repo/templates/vrweb_maker_starter/assets/starter-image.svg" "$work/assets/starter-image.svg"

cp -R "$repo/addons/vrweb_tools" "$work/addons/vrweb_tools"

HOME="$work/home" "${GODOT:-godot}" --headless --quiet --path "$work" --import
HOME="$work/home" "${GODOT:-godot}" --headless --quiet --path "$work" res://test.tscn
HOME="$work/home" "${GODOT:-godot}" --headless --quiet --path "$work" res://launcher_test.tscn
HOME="$work/home" "${GODOT:-godot}" --headless --quiet --path "$work" res://asset_test.tscn
HOME="$work/home" "${GODOT:-godot}" --headless --quiet --path "$work" res://published_verifier_test.tscn
HOME="$work/home" "${GODOT:-godot}" --headless --quiet --path "$work" res://html_portable_test.tscn
HOME="$work/home" "${GODOT:-godot}" --headless --quiet --path "$work" \
  --script res://addons/vrweb_tools/vrweb_cli.gd -- \
  --scene=res://world.tscn --output=res://dist/world.html --profile=strict \
  --mode=exclusive --report=res://dist/report.json
test -s "$work/dist/world.html"
test -s "$work/dist/report.json"
test -s "$work/dist/world.assets.json"
cp "$work/dist/world.html" "$work/world.first.html"
cp "$work/dist/world.assets.json" "$work/assets.first.json"
HOME="$work/home" "${GODOT:-godot}" --headless --quiet --path "$work" \
  --script res://addons/vrweb_tools/vrweb_cli.gd -- \
  --scene=res://world.tscn --output=res://dist/world.html --profile=strict \
  --mode=exclusive --report=res://dist/report.json
cmp "$work/world.first.html" "$work/dist/world.html"
cmp "$work/assets.first.json" "$work/dist/world.assets.json"
if HOME="$work/home" "${GODOT:-godot}" --headless --quiet --path "$work" \
  --script res://addons/vrweb_tools/vrweb_cli.gd -- \
  --scene=res://unsupported.tscn --output=res://dist/unsupported.html \
  --profile=strict --report=res://dist/unsupported-report.json; then
  echo "strict CLI unexpectedly accepted unsupported scene" >&2
  exit 1
fi
test -s "$work/dist/unsupported-report.json"
test ! -e "$work/dist/unsupported.html"
echo "clean maker addon project: $work"
