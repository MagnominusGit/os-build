#!/usr/bin/env bash
# Offline test for the QForge OpenGamepadUI plugin's packaging (plan Phase 4).
#
#   tests/test-plugin.sh
#
# WHY THIS EXISTS. OGUI loads a plugin with no feedback when it is subtly wrong, and none of it
# shows until a card fails to appear on a device:
#
#   - a zip without plugins/<id>/plugin.json, or a plugin.json missing one of the fields
#     PluginLoader requires, is skipped with a warning nobody sees;
#   - a min-api-version OGUI's API (2.0.0 in v0.46.1) is not feature-compatible with: skipped;
#   - an entrypoint that is not in the zip: "Unable to load plugin";
#   - a script that overrides _init() replaces its base class's constructor: Library._init is what
#     registers a library on ready, so the ROM library silently never loaded (HW, 2026-10-04).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/apps/ogui-qforge-plugin/plugin"
BUILD="$ROOT/apps/ogui-qforge-plugin/build.sh"
OGUI_API="2.0.0"   # PluginLoader.PLUGIN_API_VERSION in the pinned OGUI (packages/opengamepadui)

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

[ -f "$SRC/plugin.json" ] && [ -x "$BUILD" ] || { echo "missing plugin sources or build.sh" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }
T="$(mktemp -d)" && [ -d "$T" ] || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT

# =================================================================================================
CASE="plugin.json"
meta() { python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); print(m.get(sys.argv[2], ""))' "$SRC/plugin.json" "$1"; }
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$SRC/plugin.json" 2>/dev/null \
  && ok "is valid JSON" || bad "does not parse"
for field in plugin.id plugin.name plugin.version plugin.min-api-version entrypoint; do
  [ -n "$(meta "$field")" ] && ok "has $field (PluginLoader requires it)" || bad "lacks $field: OGUI skips the plugin"
done
[ "$(meta plugin.id)" = qforge ] && ok "id is qforge (the zip must be qforge.zip)" || bad "id is '$(meta plugin.id)'"
[[ $(meta plugin.version) =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && ok "version is semver (upgrades compare it)" || bad "version '$(meta plugin.version)' is not x.y.z"
# SemanticVersion.is_feature_compatible: same major, and min-api minor/patch not above OGUI's.
api="$(meta plugin.min-api-version)"
python3 - "$api" "$OGUI_API" <<'PY' && ok "min-api-version $api works with OGUI's API $OGUI_API" || bad "min-api-version $api is not compatible with OGUI's API $OGUI_API"
import sys
want, have = ([int(x) for x in v.split(".")] for v in sys.argv[1:3])
sys.exit(0 if want[0] == have[0] and want[1:] <= have[1:] else 1)
PY
[ -f "$SRC/$(meta entrypoint)" ] && ok "entrypoint $(meta entrypoint) exists" || bad "entrypoint $(meta entrypoint) is not in plugin/"

# =================================================================================================
CASE="scripts"
for gd in "$SRC"/*.gd; do
  name="$(basename "$gd")"
  head -1 "$gd" | grep -Eq '^extends ' && ok "$name starts with extends" || bad "$name has no extends line"
  grep -Eq '^func _init\(' "$gd" \
    && bad "$name overrides _init(): it replaces the base constructor (Library._init registers the library)" \
    || ok "$name does not override _init()"
done
grep -q '^extends Plugin$' "$SRC/$(meta entrypoint)" && ok "the entrypoint extends Plugin" || bad "the entrypoint does not extend Plugin"

# =================================================================================================
CASE="zip"
"$BUILD" "$T" >/dev/null && [ -f "$T/qforge.zip" ] && ok "build.sh writes qforge.zip" || bad "build.sh failed"
sum1="$(sha256sum "$T/qforge.zip" | cut -d' ' -f1)"
mapfile -t files < <(python3 -c 'import sys,zipfile; print("\n".join(zipfile.ZipFile(sys.argv[1]).namelist()))' "$T/qforge.zip")
want=(); for f in "$SRC"/*; do want+=("plugins/qforge/$(basename "$f")"); done
[ "$(printf '%s\n' "${files[@]}" | sort)" = "$(printf '%s\n' "${want[@]}" | sort)" ] \
  && ok "holds exactly plugin/* under plugins/qforge/ (where PluginLoader looks)" \
  || bad "zip contents: ${files[*]}"
"$BUILD" "$T" >/dev/null
[ "$(sha256sum "$T/qforge.zip" | cut -d' ' -f1)" = "$sum1" ] \
  && ok "rebuilding gives the same bytes (store sha256 stays valid)" || bad "the zip changes between builds"

# =================================================================================================
# OGUI keys its library by item name across every provider: two ROMs with the same name became one
# card and the second ROM was lost; a rescan never dropped a deleted ROM. rom_names.gd has no OGUI
# types, so a stock Godot runs it (QFORGE_GODOT=<godot 4 binary>, or godot on PATH; skipped without).
CASE="rom names"
GODOT="${QFORGE_GODOT:-$(command -v godot || true)}"
if [ -z "$GODOT" ]; then
  printf '  skip %s -- no Godot (set QFORGE_GODOT to a Godot 4 binary)\n' "$CASE"
else
  cat >"$T/names_test.gd" <<GD
extends SceneTree

const RomNames := preload("$SRC/rom_names.gd")
const SYSTEMS := {"psx": "PlayStation", "ps2": "PlayStation 2"}
var failed := 0

func check(what: String, got, want) -> void:
	if got == want:
		print("  ok   $CASE -- ", what)
	else:
		failed += 1
		print("  FAIL $CASE -- ", what, ": got ", got, ", want ", want)

func names(roms: Array) -> PackedStringArray:
	var list := []
	for r in roms:
		list.append({"system": r[0], "path": "/home/player/roms/%s/%s" % r})
	return RomNames.names_for(list, SYSTEMS)

func _init() -> void:
	check("a unique ROM keeps its file name",
		names([["psx", "Crash Bandicoot.chd"], ["ps2", "Jak.iso"]]),
		PackedStringArray(["Crash Bandicoot", "Jak"]))
	check("the same name on two systems gets the system",
		names([["psx", "Tetris.chd"], ["ps2", "Tetris.iso"]]),
		PackedStringArray(["Tetris (PlayStation)", "Tetris (PlayStation 2)"]))
	check("the same name in one system gets the extension",
		names([["psx", "Tetris.cue"], ["psx", "Tetris.chd"]]),
		PackedStringArray(["Tetris (CUE)", "Tetris (CHD)"]))
	check("names differing only in case collide (OGUI settings are lower-cased)",
		names([["psx", "tetris.chd"], ["ps2", "TETRIS.iso"]]),
		PackedStringArray(["tetris (PlayStation)", "TETRIS (PlayStation 2)"]))
	check("both rules together stay unique",
		names([["psx", "T.cue"], ["psx", "T.chd"], ["ps2", "T.iso"]]),
		PackedStringArray(["T (PlayStation) (CUE)", "T (PlayStation) (CHD)", "T (PlayStation 2)"]))
	check("names still equal after both rules are numbered",
		names([["psx", "A.chd"], ["psx", "a.chd"], ["psx", "B (CUE).chd"], ["psx", "B.cue"], ["psx", "B.chd"]]),
		PackedStringArray(["A (CHD)", "a (CHD) (2)", "B (CUE)", "B (CUE) (2)", "B (CHD)"]))
	check("a ROM still there is kept",
		RomNames.stale({"A": "/r/A.chd"}, {"A": "/r/A.chd", "B": "/r/B.chd"}), PackedStringArray())
	check("a deleted ROM is dropped",
		RomNames.stale({"A": "/r/A.chd", "B": "/r/B.chd"}, {"A": "/r/A.chd"}), PackedStringArray(["B"]))
	check("a name now meaning another file is dropped (re-added with the new ROM)",
		RomNames.stale({"A": "/r/A.cue"}, {"A": "/r/A.chd"}), PackedStringArray(["A"]))
	quit(1 if failed else 0)
GD
  out="$("$GODOT" --headless --script "$T/names_test.gd" 2>&1)"; rc=$?
  printf '%s\n' "$out" | grep -E '^  (ok|FAIL) '
  n_ok="$(printf '%s\n' "$out" | grep -c '^  ok ')"; n_bad="$(printf '%s\n' "$out" | grep -c '^  FAIL ')"
  PASS=$((PASS + n_ok)); FAIL=$((FAIL + n_bad))
  if [ "$rc" -ne 0 ] && [ "$n_bad" -eq 0 ]; then
    bad "Godot failed: $(printf '%s\n' "$out" | grep -E 'ERROR|error' | head -3)"
  fi
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
