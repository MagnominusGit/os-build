#!/usr/bin/env bash
# Offline test for .github/emu-key-drift.py — the weekly check that an emulator's upstream source
# still knows every settings key RetroForge writes for it (plan emulator-latest, Phase 4).
#
#   tests/test-key-drift.sh
#
# WHY THIS EXISTS. The check is the only thing that sees a key renamed upstream (a seed or an
# options.json choice that silently stops working once players get the newest build). It fails two
# ways, both quiet: it misses a rename (a seed key it never extracted, a match rule too loose), or
# it cries wolf on keys upstreams build at run time, and gets ignored. Both are pinned here with a
# fake emulator and a fake source tree; and every shipped emulator's keys must extract.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KD="$ROOT/.github/emu-key-drift.py"
SOURCES="$ROOT/.github/emu-sources.json"
EMU_DATA="$ROOT/rootfs/overlay/usr/share/retroforge/emulators"
CATALOG="$ROOT/rootfs/overlay/usr/share/retroforge/catalog.json"
[ -f "$KD" ] || { echo "no $KD" >&2; exit 1; }

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }
W="$(mktemp -d)" && [ -d "$W" ] || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$W"' EXIT

# --- a fake emulator and its upstream -------------------------------------------------------------
mkdir -p "$W/data" "$W/src/core" "$W/src/.git"
cat > "$W/data/settings.ini" <<'EOF'
; a comment = not a key
[Main]
Renderer = Vulkan
ISOPath0 = /roms
IR/Up = `Axis 1-`
axisDownAxis = 1
layout_option\default=false
Gone = 1
EOF
cat > "$W/data/config.yml" <<'EOF'
# comment: no
Video:
  Frame limit: 60
  - listed: no
EOF
printf '<?xml version="1.0"?>\n<!-- <commented/> -->\n<content><mlc_path>x</mlc_path></content>\n' > "$W/data/settings.xml"
cat > "$W/data/options.json" <<'EOF'
{"options": [{"id": "a", "choices": [{"value": "x", "set": [{"key": "Scale", "value": "2"}, {"key": "use_vsync\\default", "value": "false"}]}]}]}
EOF
printf '{"not": "a seed"}\n' > "$W/data/emulator.json"
cat > "$W/src/core/config.cpp" <<'EOF'
cfg.get("Renderer"); cfg.get("ISOPath" + n); group("IR"); control("Up");
snprintf(k, 32, "axis%sAxis", name); yaml["Video"]["Frame limit"]; xml("content"); xml("mlc_path");
ini("Scale"); ini("layout_option"); ini("use_vsync"); ini("Main");
EOF
printf 'Gone Renamed' > "$W/src/.git/HEAD"  # .git is never read as source
has() { python3 -c 'import json,sys; sys.exit(sys.argv[2] not in json.loads(sys.argv[1]))' "$@"; }

# =================================================================================================
CASE="keys"
keys="$(python3 "$KD" keys "$W/data")"
for k in Renderer ISOPath0 IR/Up axisDownAxis layout_option Gone "Frame limit" Video content mlc_path Scale use_vsync; do
  has "$keys" "$k" && ok "extracts '$k'" || bad "did not extract '$k': $keys"
done
for k in "a comment" "comment" "listed" "commented" "not" "Main"; do
  has "$keys" "$k" && bad "extracted '$k'" || ok "skips '$k' (comment, list item, section, emulator.json)"
done

CASE="check"
out="$(python3 "$KD" check "$W/data" "$W/src")"
missing="$(python3 -c 'import json,sys; print(" ".join(m["key"] for m in json.loads(sys.argv[1])["missing"]))' "$out")"
[ "$missing" = "Gone" ] && ok "only the key upstream no longer has is reported (composed keys are known)" || bad "missing: '$missing'"
python3 -c 'import json,sys; m=json.loads(sys.argv[1])["missing"][0]; sys.exit(m["files"] != ["settings.ini"])' "$out" \
  && ok "names the file that writes it" || bad "files: $out"
printf '{"fake": {"repo": "o/r", "tag": "v(.*)", "ref": "{0}", "ignore": {"Gone": "read by a migration only"}}}' > "$W/sources.json"
out="$(python3 "$KD" check "$W/data" "$W/src" "$W/sources.json" fake)"
python3 -c 'import json,sys; r=json.loads(sys.argv[1]); sys.exit(r["missing"] != [] or r["ignored"] != ["Gone"])' "$out" \
  && ok "a key in the emulator's ignore list is not reported, and is listed as ignored" || bad "ignore: $out"
mkdir -p "$W/empty"
python3 "$KD" check "$W/data" "$W/empty" >/dev/null 2>&1 && bad "an empty source tree passed" || ok "an empty source tree is an error, never 'nothing missing'"

CASE="ref"
ref() { python3 "$KD" ref "$SOURCES" "$1" "$2" 2>/dev/null; }
[ "$(ref azahar "2126.1.2@2026-10-01_1790876552")" = "azahar-emu/azahar 2126.1.2" ] && ok "pkgforge <ver>@<date>_<id> -> upstream tag <ver>" || bad "azahar ref"
[ "$(ref flycast "2.7@2026-10-01_1790875174")" = "flyinghead/flycast v2.7" ] && ok "flycast -> v<ver>" || bad "flycast ref"
[ "$(ref snes9x "1.63-1@2026-10-01_1790876690")" = "snes9xgit/snes9x 1.63" ] && ok "pkgforge's -<rev> is dropped" || bad "snes9x ref"
[ "$(ref armgba "v1.0")" = "Jacob-Matthew-Cook/armGBA v1.0" ] && ok "an upstream's own release tag is its ref" || bad "armgba ref"
[ "$(ref cemu "nightly-a53cf0ece")" = "cemu-project/Cemu a53cf0ece" ] && ok "a nightly-<commit> -> that commit" || bad "cemu ref"
ref duckstation latest >/dev/null && bad "a tag the rule does not match passed" || ok "a tag the rule does not match is an error"

CASE="shipped emulators"
# Every catalog emulator with settings has a source to check, and its tested tag maps to a ref.
while IFS=$'\t' read -r v msg; do
  [ "$v" = ok ] && ok "$msg" || bad "$msg"
done < <(python3 - "$KD" "$SOURCES" "$CATALOG" "$EMU_DATA" <<'PY'
import json, os, subprocess, sys
kd, sources, catalog, data = sys.argv[1:5]
src = json.load(open(sources))
for emu, e in json.load(open(catalog))["emulators"].items():
    d = os.path.join(data, emu)
    keys = json.loads(subprocess.run([sys.executable, kd, "keys", d], capture_output=True, text=True).stdout or "{}")
    if not keys:
        print(f"ok\t{emu}: no settings keys, nothing to check" if emu not in src
              else f"FAIL\t{emu}: in emu-sources.json but writes no keys")
        continue
    if emu not in src:
        print(f"FAIL\t{emu}: writes {len(keys)} keys but has no upstream source in emu-sources.json")
        continue
    if "sha256" not in e:
        print(f"ok\t{emu}: {len(keys)} keys, no tested tag (the weekly check maps the newest build)")
        continue
    r = subprocess.run([sys.executable, kd, "ref", sources, emu, e["tag"]], capture_output=True, text=True)
    print(f"ok\t{emu}: {len(keys)} keys, tested tag -> {r.stdout.strip()}" if r.returncode == 0
          else f"FAIL\t{emu}: tested tag {e['tag']} maps to no ref: {r.stderr.strip()}")
PY
)

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
