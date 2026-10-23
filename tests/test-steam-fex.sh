#!/usr/bin/env bash
# Offline test for /usr/bin/retroforge-steam-fex (our ARMv8.0 FEX for x86 Linux games on ARMv8.0 CPUs) and
# its pin, /usr/share/retroforge/steam/fex-armv8.pin.
#
#   tests/test-steam-fex.sh
#
# Rules: a CPU with LSE atomics changes nothing; nothing happens before Steam has installed its FEX tool
# (app 3127680), found through its app manifest in any library; then Valve's fex-compat-tool and unshare.py
# are copied into our tool (and again when Valve's change), our binaries replace Valve's while both
# VERSIONS.txt name the same version (each by a rename: a FEX that runs keeps its file), Valve's stay for
# another version, a swap is redone after Steam puts Valve's back, and the update runs in the background;
# install runs steam-compat-tools with the FEX pin, then the same steps.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/rootfs/overlay/usr/bin/retroforge-steam-fex"
PIN_REAL="$ROOT/rootfs/overlay/usr/share/retroforge/steam/fex-armv8.pin"
for f in "$CLI" "$PIN_REAL"; do [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }; done

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

T="$(mktemp -d)" && [ -d "$T" ] || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT

S="$T/home/.local/share/Steam"; VALVE="$S/steamapps/common/FEX-Emu"; OURS="$S/compatibilitytools.d/fex-armv8-retroforge"
BINS="usr/bin/FEX usr/bin/FEXServer usr/bin/FEXOfflineCompiler usr/bin/FEXGetConfig usr/bin/FEXBash usr/bin/FEXpidof usr/bin/FEXServerManager FEXCompatTool"
printf 'processor\t: 0\nFeatures\t: fp asimd evtstrm aes pmull sha1 sha2 crc32 cpuid\n' >"$T/v80"
printf 'processor\t: 0\nFeatures\t: fp asimd aes pmull sha1 sha2 crc32 atomics fphp cpuid\n' >"$T/v82"
printf '#!/bin/sh\necho "$@" >>"%s/started"\n' "$T" >"$T/start"; chmod +x "$T/start"

tool() {  # tool <dir> <who> <version>: a FEX tool's binaries ("<who> <file>") and VERSIONS.txt
  mkdir -p "$1/usr/bin"
  for b in $BINS; do echo "$2 $b" >"$1/$b"; chmod +x "$1/$b"; done
  printf 'FEX describe\t%s\nFEX bash\t0123456789abcdef\n' "$3" >"$1/VERSIONS.txt"
}
valve() {  # valve [version]: Steam's FEX tool, installed in the main library
  rm -rf "$VALVE"; tool "$VALVE" valve "${1:-FEX-2607-76-g37265b1}"
  echo "valve compat tool" >"$VALVE/fex-compat-tool"; echo "valve unshare" >"$VALVE/unshare.py"
  printf '"AppState"\n{\n\t"appid"\t\t"3127680"\n\t"installdir"\t\t"FEX-Emu"\n}\n' >"$S/steamapps/appmanifest_3127680.acf"
}
ours() {  # our tool as steam-compat-tools leaves it
  rm -rf "$OURS"; tool "$OURS" ours FEX-2607-76-g37265b1
  printf 'name: fex-armv8\ntag: fex-armv8-FEX-2607-76-g37265b1\n' >"$OURS/.retroforge-pin"
}
fex() {  # fex <cpuinfo> <args>
  OUT="$(env -u XDG_DATA_HOME HOME="$T/home" RETROFORGE_STEAM_ROOT="$S" RETROFORGE_CPUINFO="$1" RETROFORGE_STEAM_PINS="$T/pins" \
         RETROFORGE_STEAM_COMPAT_TOOLS="$T/helper" RETROFORGE_STEAM_FEX_START="$T/start" python3 "$CLI" "${@:2}" 2>"$T/err")"; RC=$?
  ERR="$(cat "$T/err")"
}
whose() { cut -d' ' -f1 "$VALVE/$1"; }  # whose <binary>: valve or ours
all_whose() { local w=""; for b in $BINS; do w="$w $(whose "$b")"; done; echo $w | tr ' ' '\n' | sort -u | tr '\n' ' '; }
mkdir -p "$S/steamapps"

# ================================================================================================
CASE="a CPU with atomics"
valve; ours; rm -f "$T/started"
fex "$T/v82" apply
[ "$RC" = 0 ] && [ "$OUT" = steam ] && [ "$(all_whose)" = "valve " ] && [ ! -e "$T/started" ] && [ ! -e "$OURS/fex-compat-tool" ] \
  && ok "nothing changes, nothing starts" || bad "rc=$RC out=$OUT whose=$(all_whose) err=$ERR"
fex "$T/v82" status
[ "$OUT" = steam ] && ok "status: steam" || bad "out=$OUT"

CASE="Steam's FEX tool not installed"
rm -f "$S/steamapps/appmanifest_3127680.acf"; rm -f "$T/started"
fex "$T/v80" apply
[ "$RC" = 0 ] && [ "$OUT" = none ] && [ ! -e "$T/started" ] && grep -q "has not installed its FEX tool" <<<"$ERR" \
  && ok "nothing to do yet, and that is said" || bad "rc=$RC out=$OUT err=$ERR"
fex "$T/v80" install
[ "$RC" = 0 ] && [ ! -e "$T/helper.calls" ] && ok "install does nothing either" || bad "rc=$RC"

CASE="the same version"
valve; ours; rm -f "$T/started"
exec 3<"$VALVE/usr/bin/FEX"
fex "$T/v80" apply
[ "$RC" = 0 ] && [ "$OUT" = ours ] && [ "$(all_whose)" = "ours " ] && grep -q "runs our ARMv8.0 binaries (8 put in)" <<<"$ERR" \
  && ok "our eight binaries replace Valve's" || bad "rc=$RC out=$OUT whose=$(all_whose) err=$ERR"
[ "$(cat <&3)" = "valve usr/bin/FEX" ] && ok "a FEX that runs keeps its file (a rename, not a write)" || bad "fd 3 reads something else"
exec 3<&-
[ -x "$VALVE/usr/bin/FEX" ] && [ -z "$(find "$VALVE" -name '.*.retroforge')" ] && ok "executable, nothing half-written left" || bad "$(ls -la "$VALVE/usr/bin")"
[ "$(cat "$OURS/fex-compat-tool")" = "valve compat tool" ] && [ "$(cat "$OURS/unshare.py")" = "valve unshare" ] \
  && ok "Valve's fex-compat-tool and unshare.py in our tool" || bad "$(ls "$OURS")"
[ "$(cat "$T/started" 2>/dev/null)" = "$CLI install" ] && ok "the update starts in the background" || bad "started: $(cat "$T/started" 2>&1)"
fex "$T/v80" apply
[ "$OUT" = ours ] && ! grep -q "put in" <<<"$ERR" && ok "a second apply has nothing to put in" || bad "out=$OUT err=$ERR"

CASE="Steam puts Valve's back"
for b in $BINS; do echo "valve $b" >"$VALVE/$b"; done
fex "$T/v80" status
[ "$OUT" = valve ] && ok "status: valve" || bad "out=$OUT"
fex "$T/v80" apply
[ "$OUT" = ours ] && [ "$(all_whose)" = "ours " ] && ok "the next apply puts ours in again" || bad "out=$OUT whose=$(all_whose)"

CASE="Valve's scripts change"
echo "valve compat tool 2" >"$VALVE/fex-compat-tool"
fex "$T/v80" apply
[ "$(cat "$OURS/fex-compat-tool")" = "valve compat tool 2" ] && grep -q "took Valve's fex-compat-tool" <<<"$ERR" \
  && ok "our copy follows" || bad "$(cat "$OURS/fex-compat-tool") err=$ERR"

CASE="another version"
valve FEX-2608-3-gabcdef0
fex "$T/v80" apply
[ "$OUT" = valve ] && [ "$(all_whose)" = "valve " ] && grep -q "Valve's FEX is FEX-2608-3-gabcdef0, ours FEX-2607-76-g37265b1: Valve's binaries stay" <<<"$ERR" \
  && ok "Valve's binaries stay, and that is said" || bad "out=$OUT whose=$(all_whose) err=$ERR"

CASE="install"
valve; rm -rf "$OURS"; mkdir -p "$T/pins"
printf '#!/bin/sh\necho "$RETROFORGE_STEAM_COMPAT_PIN $*" >>"%s/helper.calls"\n' "$T" >"$T/helper"
printf 'mkdir -p "%s" && cp -a "%s/." "%s/"\n' "$OURS" "$T/template" "$OURS" >>"$T/helper"; chmod +x "$T/helper"
tool "$T/template" ours FEX-2607-76-g37265b1; printf 'name: fex-armv8\n' >"$T/template/.retroforge-pin"
fex "$T/v80" install
[ "$RC" = 0 ] && [ "$(cat "$T/helper.calls")" = "$T/pins/fex-armv8.pin on" ] && ok "steam-compat-tools on, with the FEX pin" || bad "rc=$RC calls=$(cat "$T/helper.calls" 2>&1) err=$ERR"
[ "$(all_whose)" = "ours " ] && [ -f "$OURS/fex-compat-tool" ] && ok "then Valve's scripts in, and ours swapped in" || bad "whose=$(all_whose)"

CASE="another library"
LIB="$T/sdcard"; mkdir -p "$LIB/steamapps/common"
mv "$VALVE" "$LIB/steamapps/common/FEX-Emu"; mv "$S/steamapps/appmanifest_3127680.acf" "$LIB/steamapps/"
printf '"libraryfolders"\n{\n\t"0"\n\t{\n\t\t"path"\t\t"%s"\n\t}\n\t"1"\n\t{\n\t\t"path"\t\t"%s"\n\t}\n}\n' "$S" "$LIB" >"$S/steamapps/libraryfolders.vdf"
for b in $BINS; do echo "valve $b" >"$LIB/steamapps/common/FEX-Emu/$b"; done
fex "$T/v80" apply
[ "$OUT" = ours ] && [ "$(cut -d' ' -f1 "$LIB/steamapps/common/FEX-Emu/usr/bin/FEX")" = ours ] && ok "found through libraryfolders.vdf" || bad "out=$OUT err=$ERR"

CASE="the real pin"
python3 - "$PIN_REAL" <<'PY' && ok "proton-armv8's releases, fex-armv8-*.tar.zst with .sha512, one folder, FEXCompatTool" || bad "fex-armv8.pin is not that"
import re, sys
f = dict(re.findall(r"^(\w+):[ \t]*(.*?)[ \t]*$", open(sys.argv[1]).read(), re.M))
assert f["name"] == "fex-armv8" and f["releases"] == "https://api.github.com/repos/sunshineinabox/proton-armv8/releases", f
assert f["asset"] == "fex-armv8-*.tar.zst" and f["sidecar"] == ".sha512" and f["entry"] == "FEXCompatTool", f
assert f["dir"] == "fex-armv8-retroforge" and f["display_name"] == "FEX ARMv8.0 (RetroForge)" and "tag" not in f, f
PY

CASE="usage"
fex "$T/v80" frobnicate
[ "$RC" = 2 ] && ok "a bad invocation is exit 2" || bad "rc=$RC"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
