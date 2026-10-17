#!/usr/bin/env bash
# Offline test for what Steam Remote Play needs from the image: the "Steam" library card, Valve's Steam
# Input udev rules, and the video codec links.
#
#   tests/test-steam-remoteplay.sh
#
# WHY THIS EXISTS. Each of these fails silently on a device:
#   - the card: OGUI's desktop library (library_desktop.gd, v0.46.1) drops an entry without Name, Exec
#     or the Game category, and runs Exec split on spaces. A steam://rungameid/ launch is treated as one
#     game and Steam is SIGTERMed once only its own windows remain, which would end a Remote Play
#     stream; -steamframe/-deckard switch on Frame-only paths. "steam steam://open/friends" is OGUI's
#     default blacklist.
#   - Valve's rules must stay verbatim below their header (the header names the upstream blob), or a
#     hand edit hides behind "Valve's file".
#   - the codec links must name both drivers' decoder and encoder (iris on SM8250/8550/8650, venus on
#     SM6115), or one SoC loses /dev/video-dec0 with no other symptom.
#   - udev syntax is checked with `udevadm verify` where the host has it (systemd >= 255).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DESKTOP="$ROOT/rootfs/overlay/usr/share/applications/retroforge-steam.desktop"
INPUT="$ROOT/rootfs/overlay/usr/lib/udev/rules.d/60-steam-input.rules"
CODEC="$ROOT/rootfs/overlay/usr/lib/udev/rules.d/70-retroforge-video-codec.rules"
for f in "$DESKTOP" "$INPUT" "$CODEC"; do [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }; done

PASS=0; FAIL=0; SKIP=0; CASE=""
ok()   { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }
skip() { SKIP=$((SKIP+1)); printf '  skip %s -- %s\n' "$CASE" "$1"; }
# The git blob id of stdin ("blob <size>\0" + content, sha1), without git: the suite also runs from
# exports and containers where there is no usable repository.
blob_id() {
  local tmp; tmp="$(mktemp)"; cat >"$tmp"
  { printf 'blob %d\0' "$(wc -c <"$tmp" | tr -d ' ')"; cat "$tmp"; } \
    | { sha1sum 2>/dev/null || shasum -a 1; } | cut -c1-40
  rm -f "$tmp"
}

# ================================================================================================
CASE="Steam card"
# Parsed the way library_desktop.gd does: line prefixes, Exec split on single spaces.
name="$(sed -n 's/^Name=//p' "$DESKTOP" | head -1)"
exec_line="$(sed -n 's/^Exec=//p' "$DESKTOP" | head -1)"
cats="$(sed -n 's/^Categories=//p' "$DESKTOP" | head -1)"
read -r -a argv <<<"$exec_line"
[ "$name" = Steam ] && ok "Name=Steam" || bad "Name='$name'"
case ";$cats;" in *";Game;"*) ok "in the Game category (OGUI lists only those)" ;; *) bad "Categories='$cats'" ;; esac
[ "${argv[0]-}" = steam ] && ok "runs /usr/bin/steam" || bad "command '${argv[0]-}'"
[[ " ${argv[*]} " == *" steam://open/bigpicture "* ]] && ok "opens Big Picture" || bad "Exec='$exec_line'"
[[ "$exec_line" != *rungameid* ]] && ok "no steam://rungameid/ (OGUI would SIGTERM Steam and end a stream)" || bad "Exec='$exec_line'"
[[ "$exec_line" != *-steamframe* && "$exec_line" != *-deckard* ]] && ok "no Frame-only flags" || bad "Exec='$exec_line'"
[ "$exec_line" != "steam steam://open/friends" ] && ok "not OGUI's default blacklist entry" || bad "blacklisted"
[[ "$exec_line" != *%* && "$exec_line" != *\"* ]] && ok "no field codes or quotes (OGUI does not expand them)" || bad "Exec='$exec_line'"

CASE="Valve's rules"
blob="$(sed -n 's/^# .*(git blob \([0-9a-f]\{12\}\)).*/\1/p' "$INPUT" | head -1)"
start="$(grep -n '^# ---- upstream 60-steam-input.rules' "$INPUT" | cut -d: -f1)"
if [ -n "$blob" ] && [ -n "$start" ]; then
  got="$(tail -n +"$((start + 1))" "$INPUT" | blob_id)"
  [ "${got:0:12}" = "$blob" ] && ok "verbatim below the header (blob $blob)" || bad "body hashes to ${got:0:12}, header says $blob"
else
  bad "no blob in the header or no upstream marker"
fi
grep -q "Copyright (c) 2018 Valve Software" "$INPUT" && grep -q "Permission is hereby granted" "$INPUT" \
  && ok "carries Valve's MIT notice" || bad "MIT notice missing"
rules="$(tail -n +"$((start + 1))" "$INPUT" | grep -vcE '^\s*(#|$)')"
grants="$(tail -n +"$((start + 1))" "$INPUT" | grep -vE '^\s*(#|$)' | grep -c 'TAG+="uaccess"')"
[ "$rules" -gt 50 ] && [ $((rules - grants)) -le 2 ] && ok "$grants of $rules rules grant uaccess (the rest: wakeup)" \
  || bad "$grants of $rules rules grant uaccess"

CASE="codec links"
for n in qcom-iris-decoder qcom-venus-decoder; do
  grep -qE "ATTR\{name\}==\"$n\".*SYMLINK\+=\"video-dec0\"" "$CODEC" && ok "$n -> /dev/video-dec0" || bad "no rule for $n"
done
for n in qcom-iris-encoder qcom-venus-encoder; do
  grep -qE "ATTR\{name\}==\"$n\".*SYMLINK\+=\"video-enc0\"" "$CODEC" && ok "$n -> /dev/video-enc0" || bad "no rule for $n"
done

CASE="udev syntax"
if udevadm verify --help >/dev/null 2>&1; then
  out="$(udevadm verify --no-style "$INPUT" "$CODEC" 2>&1)" && ok "udevadm verify: both files" || bad "udevadm verify: $out"
else
  skip "no udevadm verify on this host"
fi

echo
echo "$PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
