#!/usr/bin/env bash
# Offline test for /usr/bin/retroforge-steam-proton (Steam's default Proton on ARMv8.0 CPUs) and the
# channel pin of /usr/lib/retroforge/steam-compat-tools.
#
#   tests/test-steam-proton.sh
#
# Rules: a CPU with LSE atomics changes nothing; on ARMv8.0 the player's channel (stable unless
# PROTON_CHANNEL=experimental) is installed in the background, and once it is, it becomes entry "0" of
# config.vdf's CompatToolMapping while the client is not running; the rest of config.vdf, a game's own
# entry included, stays byte for byte; a missing section is created; steam-compat-tools takes the
# channel's pin.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/rootfs/overlay/usr/bin/retroforge-steam-proton"
HELPER="$ROOT/rootfs/overlay/usr/lib/retroforge/steam-compat-tools"
for f in "$CLI" "$HELPER"; do [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }; done

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
         RETROFORGE_STEAM_PROTON_START="$T/start" python3 "$CLI" "${@:2}" 2>"$T/err")"; RC=$?
  ERR="$(cat "$T/err")"
  for _ in $(seq 20); do [ -e "$T/started" ] && break; sleep 0.05; done
}
default_of() { python3 -c 'import re, sys; t = open(sys.argv[1]).read(); m = re.search(r"\"CompatToolMapping\"\s*\{\s*\"0\"\s*\{\s*\"name\"\s*\"([^\"]*)\"", t); print(m.group(1) if m else "")' "$VDF"; }
others() { grep -v '"name"' "$1"; }  # everything but the tool names

CASE="a CPU with LSE atomics"
vdf; cp "$VDF" "$T/orig"
run "$T/v82" status; [ "$OUT" = steam ] && ok "status: steam" || bad "out=$OUT"
run "$T/v82" apply; [ "$OUT" = steam ] && [ ! -e "$T/started" ] && cmp -s "$VDF" "$T/orig" && ok "apply: nothing installed, config.vdf untouched" || bad "out=$OUT err=$ERR"
run "$T/v82" set experimental; [ "$OUT" = steam ] && [ ! -e "$T/home/.config/retroforge/steam.conf" ] && ok "set: nothing saved" || bad "out=$OUT"

CASE="ARMv8.0, nothing installed"
run "$T/v80" status; [ "$OUT" = stable ] && ok "status: stable by default" || bad "out=$OUT"
run "$T/v80" apply
[ "$OUT" = stable ] && grep -qx "$T/helper on" "$T/started" && cmp -s "$VDF" "$T/orig" && grep -q "not installed yet" <<<"$ERR" \
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
       RETROFORGE_CPUINFO="$T/v80" python3 "$HELPER" on 2>&1)"
  want=proton-armv8; [ "$ch" = experimental ] && want=proton-armv8-experimental
  grep -q "no $want is installed" <<<"$E" && ok "$ch: $want.pin" || bad "$ch: $E"
done

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
