#!/usr/bin/env bash
# Offline test for /usr/bin/retroforge-steam-proton (Steam's default Proton on ARMv8.0 CPUs) and the
# channel pin of /usr/lib/retroforge/steam-compat-tools.
#
#   tests/test-steam-proton.sh
#
# Rules: a CPU with LSE atomics changes nothing; on ARMv8.0 the player's channel (stable unless
# PROTON_CHANNEL=experimental) is installed in the background, and once it is, it becomes entry "0" of
# config.vdf's CompatToolMapping while the client is not running, and each installed Windows-only game's
# own entry unless the game is set to another tool (our other channel's build follows the channel); the
# rest of config.vdf stays byte for byte; a missing section is created; an unreadable appinfo.vdf leaves
# the default alone; steam-compat-tools takes the channel's pin.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/rootfs/overlay/usr/bin/retroforge-steam-proton"
HELPER="$ROOT/rootfs/overlay/usr/lib/retroforge/steam-compat-tools"
LIBRARY="$ROOT/rootfs/overlay/usr/lib/retroforge/steam-library"
for f in "$CLI" "$HELPER" "$LIBRARY"; do [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }; done

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

T="$(mktemp -d)" && [ -d "$T" ] || { echo "mktemp -d failed" >&2; exit 1; }
CLIENT=""
trap '[ -n "$CLIENT" ] && kill "$CLIENT" 2>/dev/null; rm -rf "$T"' EXIT

S="$T/home/.local/share/Steam"; VDF="$S/config/config.vdf"; TOOLS="$S/compatibilitytools.d"
printf 'processor\t: 0\nFeatures\t: fp asimd evtstrm aes pmull sha1 sha2 crc32 cpuid\n' >"$T/v80"
printf 'processor\t: 0\nFeatures\t: fp asimd aes pmull sha1 sha2 crc32 atomics fphp cpuid\n' >"$T/v82"
printf '#!/bin/sh\necho "$@" >>"%s/started"\n' "$T" >"$T/start"; chmod +x "$T/start"

vdf() {  # a config.vdf like the client's, with Steam's own default and one game's tool
  mkdir -p "${VDF%/*}"
  cat >"$VDF" <<'EOF'
"InstallConfigStore"
{
	"Software"
	{
		"Valve"
		{
			"Steam"
			{
				"AutoUpdateWindowEnabled"		"0"
				"CompatToolMapping"
				{
					"0"
					{
						"name"		"proton-experimental-arm64"
						"config"		""
						"priority"		"75"
					}
					"1145360"
					{
						"name"		"proton_11_arm64"
						"config"		""
						"priority"		"250"
					}
				}
			}
		}
	}
}
EOF
}
tool() { mkdir -p "$TOOLS/$1"; : >"$TOOLS/$1/.retroforge-pin"; : >"$TOOLS/$1/proton"; : >"$TOOLS/$1/compatibilitytool.vdf"; }
run() {  # run <cpuinfo> <args>: OUT, ERR, RC
  rm -f "$T/started"
  OUT="$(HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_DATA_HOME="$T/home/.local/share" \
         RETROFORGE_STEAM_ROOT="$S" RETROFORGE_CPUINFO="$1" RETROFORGE_STEAM_COMPAT_TOOLS="$T/helper" \
         RETROFORGE_STEAM_PROTON_START="$T/start" RETROFORGE_STEAM_LIBRARY="$LIBRARY" python3 "$CLI" "${@:2}" 2>"$T/err")"; RC=$?
  ERR="$(cat "$T/err")"
  for _ in $(seq 20); do [ -e "$T/started" ] && break; sleep 0.05; done
}
default_of() { python3 -c 'import re, sys; t = open(sys.argv[1]).read(); m = re.search(r"\"CompatToolMapping\"\s*\{\s*\"0\"\s*\{\s*\"name\"\s*\"([^\"]*)\"", t); print(m.group(1) if m else "")' "$VDF"; }
others() { grep -v '"name"' "$1"; }  # everything but the tool names
tool_of() {  # tool_of <key>: "name priority" of that CompatToolMapping entry, "" without one
  python3 - "$VDF" "$1" <<'PY2'
import re, sys
m = re.search(r'"CompatToolMapping"\s*\{(.*)', open(sys.argv[1]).read(), re.S)
e = m and re.search(r'"%s"\s*\{\s*"name"\s*"([^"]*)"\s*"config"\s*"[^"]*"\s*"priority"\s*"([^"]*)"' % sys.argv[2], m.group(1))
print(f"{e.group(1)} {e.group(2)}" if e else "")
PY2
}
game() {  # game <appid> <name> <type> <oslist>: an installed app and its appinfo.vdf entry
  mkdir -p "$S/steamapps"
  printf '"AppState"\n{\n\t"appid"\t\t"%s"\n\t"name"\t\t"%s"\n\t"StateFlags"\t\t"4"\n\t"installdir"\t\t"%s"\n}\n' "$1" "$2" "$2" >"$S/steamapps/appmanifest_$1.acf"
  printf '%s\t%s\t%s\t%s\n' "$@" >>"$T/apps"
}
appinfo() {  # appcache/appinfo.vdf (v28) of the games game() listed
  python3 - "$T/apps" "$S/appcache/appinfo.vdf" <<'PY2'
import os, struct, sys
def kv(tree):
    return b"".join(b"\x00" + k.encode() + b"\0" + kv(v) + b"\x08" if isinstance(v, dict)
                    else b"\x01" + k.encode() + b"\0" + v.encode() + b"\0" for k, v in tree.items())
body = b""
for line in open(sys.argv[1]):
    appid, name, kind, oslist = line.rstrip("\n").split("\t")
    data = kv({"appinfo": {"appid": appid, "common": {"name": name, "type": kind, "oslist": oslist}}}) + b"\x08"
    head = struct.pack("<IIQ", 2, 1700000000, 0) + b"\x11" * 20 + struct.pack("<I", 7) + b"\x22" * 20
    body += struct.pack("<II", int(appid), len(head) + len(data)) + head + data
os.makedirs(os.path.dirname(sys.argv[2]), exist_ok=True)
open(sys.argv[2], "wb").write(struct.pack("<II", 0x07564428, 1) + body + struct.pack("<I", 0))
PY2
}

CASE="a CPU with LSE atomics"
vdf; cp "$VDF" "$T/orig"
run "$T/v82" status; [ "$OUT" = steam ] && ok "status: steam" || bad "out=$OUT"
run "$T/v82" apply; [ "$OUT" = steam ] && [ ! -e "$T/started" ] && cmp -s "$VDF" "$T/orig" && ok "apply: nothing installed, config.vdf untouched" || bad "out=$OUT err=$ERR"
run "$T/v82" set experimental; [ "$OUT" = steam ] && [ ! -e "$T/home/.config/retroforge/steam.conf" ] && ok "set: nothing saved" || bad "out=$OUT"

CASE="ARMv8.0, nothing installed"
run "$T/v80" status; [ "$OUT" = stable ] && ok "status: stable by default" || bad "out=$OUT"
run "$T/v80" apply
[ "$OUT" = stable ] && grep -qx "$T/helper install" "$T/started" && cmp -s "$VDF" "$T/orig" && grep -q "not installed yet" <<<"$ERR" \
  && ok "the install starts; config.vdf untouched until it is in" || bad "out=$OUT started=$(cat "$T/started" 2>&1) err=$ERR"

CASE="ARMv8.0, stable installed"
tool proton-armv8-retroforge
run "$T/v80" apply
[ "$(default_of)" = proton-armv8-retroforge ] && ok "Steam's default is our build" || bad "default=$(default_of) err=$ERR"
[ "$(others "$VDF")" = "$(others "$T/orig")" ] && grep -q '"proton_11_arm64"' "$VDF" && ok "the rest kept, the game's own tool too" || bad "$(diff "$T/orig" "$VDF")"
cmp -s "$VDF.before-retroforge-proton" "$T/orig" && ok "the original kept as config.vdf.before-retroforge-proton" || bad "no backup"
cp "$VDF" "$T/once"; run "$T/v80" apply
cmp -s "$VDF" "$T/once" && ok "again: unchanged" || bad "$(diff "$T/once" "$VDF")"

CASE="experimental"
printf 'KEEP_RUNNING=off\nPROTON_CHANNEL=stable\n' >"$T/home/.config/retroforge/steam.conf" 2>/dev/null || { mkdir -p "$T/home/.config/retroforge"; printf 'KEEP_RUNNING=off\nPROTON_CHANNEL=stable\n' >"$T/home/.config/retroforge/steam.conf"; }
tool proton-armv8-experimental-retroforge
run "$T/v80" set experimental
[ "$OUT" = experimental ] && [ "$(default_of)" = proton-armv8-experimental-retroforge ] && ok "set: saved and applied" || bad "out=$OUT default=$(default_of) err=$ERR"
[ "$(cat "$T/home/.config/retroforge/steam.conf")" = "$(printf 'KEEP_RUNNING=off\nPROTON_CHANNEL=experimental')" ] && ok "steam.conf: one line rewritten, the others kept" || bad "$(cat "$T/home/.config/retroforge/steam.conf")"

CASE="the client running"
vdf; cp "$VDF" "$T/orig"
mkdir -p "$T/fake/steamrtarm64"; bash -c "exec -a '$S/steamrtarm64/steam' sleep 30" & CLIENT=$!; sleep 0.3
run "$T/v80" apply
cmp -s "$VDF" "$T/orig" && grep -q "client is running" <<<"$ERR" && ok "config.vdf not written while it runs" || bad "err=$ERR"
kill "$CLIENT"; wait "$CLIENT" 2>/dev/null; CLIENT=""

CASE="no CompatToolMapping yet"
printf '"InstallConfigStore"\n{\n\t"Software"\n\t{\n\t\t"Valve"\n\t\t{\n\t\t\t"Steam"\n\t\t\t{\n\t\t\t\t"AutoUpdateWindowEnabled"\t\t"0"\n\t\t\t}\n\t\t}\n\t}\n}\n' >"$VDF"
run "$T/v80" apply
[ "$(default_of)" = proton-armv8-experimental-retroforge ] && grep -q '"AutoUpdateWindowEnabled"' "$VDF" && ok "the section is created" || bad "$(cat "$VDF")"

CASE="each Windows game"
vdf; rm -f "$T/apps"
sed -i.b 's/^PROTON_CHANNEL=.*/PROTON_CHANNEL=stable/' "$T/home/.config/retroforge/steam.conf"
game 1145360 Hades game windows      # the player set proton_11_arm64 (vdf)
game 2000 "Win Game" game windows
game 3000 "Both Game" game "windows,linux"
game 4000 "Old Pick" game windows    # set to our experimental build earlier
game 5000 Redist tool windows
appinfo
python3 - "$VDF" <<'PY2'
import sys
p = sys.argv[1]; t = open(p).read()
t = t.replace('\t\t\t\t\t"1145360"', '\t\t\t\t\t"4000"\n\t\t\t\t\t{\n\t\t\t\t\t\t"name"\t\t"proton-armv8-experimental-retroforge"\n\t\t\t\t\t\t"config"\t\t""\n\t\t\t\t\t\t"priority"\t\t"250"\n\t\t\t\t\t}\n\t\t\t\t\t"1145360"', 1)
open(p, "w").write(t)
PY2
run "$T/v80" apply
[ "$(default_of)" = proton-armv8-retroforge ] && [ "$(tool_of 2000)" = "proton-armv8-retroforge 250" ] && grep -q "Win Game" <<<"$ERR" \
  && ok "a Windows game gets our build as its own tool" || bad "default=$(default_of) 2000=$(tool_of 2000) err=$ERR"
[ -z "$(tool_of 3000)" ] && [ -z "$(tool_of 5000)" ] && ok "a game with a Linux build and a tool are left to Steam" || bad "3000=$(tool_of 3000) 5000=$(tool_of 5000)"
[ "$(tool_of 1145360)" = "proton_11_arm64 250" ] && ok "a game set to another tool keeps it" || bad "1145360=$(tool_of 1145360)"
[ "$(tool_of 4000)" = "proton-armv8-retroforge 250" ] && ok "a game set to our other channel follows the channel" || bad "4000=$(tool_of 4000)"
cp "$VDF" "$T/once"; run "$T/v80" apply
cmp -s "$VDF" "$T/once" && [ -z "$ERR" ] && ok "again: unchanged and quiet" || bad "err=$ERR $(diff "$T/once" "$VDF")"
run "$T/v80" set experimental
[ "$(tool_of 2000)" = "proton-armv8-experimental-retroforge 250" ] && [ "$(tool_of 4000)" = "proton-armv8-experimental-retroforge 250" ] \
  && [ "$(tool_of 1145360)" = "proton_11_arm64 250" ] && ok "a channel switch moves our games, not the player's" \
  || bad "2000=$(tool_of 2000) 4000=$(tool_of 4000) 1145360=$(tool_of 1145360)"

CASE="an unreadable appinfo.vdf"
vdf; printf 'junk' >"$S/appcache/appinfo.vdf"
run "$T/v80" apply
[ "$RC" = 0 ] && [ "$(default_of)" = proton-armv8-experimental-retroforge ] && [ -z "$(tool_of 2000)" ] && grep -q "could not read" <<<"$ERR" \
  && ok "the default is still set" || bad "rc=$RC default=$(default_of) err=$ERR"
rm -rf "$S/steamapps" "$S/appcache"

CASE="usage"
run "$T/v80" set nightly; [ "$RC" = 2 ] && ok "an unknown channel is refused" || bad "rc=$RC"

CASE="steam-compat-tools: the channel's pin"
mkdir -p "$T/pins"
for p in proton-armv8 proton-armv8-experimental; do
  printf 'name: %s\nreleases: http://127.0.0.1:9/none\nasset: %s-*.tar.zst\nsidecar: .sha512\ndir: %s-retroforge\ndisplay_name: x\n' "$p" "$p" "$p" >"$T/pins/$p.pin"
done
for ch in stable experimental; do
  sed -i.b "s/^PROTON_CHANNEL=.*/PROTON_CHANNEL=$ch/" "$T/home/.config/retroforge/steam.conf"
  E="$(HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" RETROFORGE_STEAM_ROOT="$T/s2" RETROFORGE_STEAM_PINS="$T/pins" \
       RETROFORGE_CPUINFO="$T/v80" RETROFORGE_STEAM_SAREK=off python3 "$HELPER" install 2>&1)"
  want=proton-armv8; [ "$ch" = experimental ] && want=proton-armv8-experimental
  grep -q "no $want is installed" <<<"$E" && ok "$ch: $want.pin" || bad "$ch: $E"
done

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
