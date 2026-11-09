#!/usr/bin/env bash
# Offline test for /usr/bin/retroforge-cheevos -- the RetroAchievements sign-in behind Settings >
# Library > RetroAchievements (plan retroarch Phase 3).
#
#   tests/test-cheevos.sh
#
# WHY THIS EXISTS. The player's RetroAchievements password must never be kept, shown or leaked:
#
#   - it reaches the tool on stdin, and curl reads it from stdin too (-K -): never in any argv, where
#     every process of the player could read it from /proc;
#   - only the token RetroAchievements hands back is written, into RetroArch's retroarch.cfg, which
#     is 0600 before the token is in it; cheevos_password stays empty;
#   - a refused sign-in (wrong password) is told apart from a network failure, and changes nothing;
#   - RetroArch rewrites retroarch.cfg from memory when it exits, so a change made while it runs
#     would be lost: the tool refuses it (exit 5) instead of pretending;
#   - a home where RetroArch never ran gets the image's seed first: a retroarch.cfg holding only the
#     sign-in would stop the seed (never copied over an existing file) and RetroArch would run with
#     its defaults (no pad, the Online Updater back).
#
# HOW: the shipped tool with its seams (RETROFORGE_CURL, RETROFORGE_EMU_DATA_DIR, RETROFORGE_PROC,
# HOME) pointing into a sandbox; curl is a stub that answers like retroachievements.org's login2. No
# network.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$ROOT/rootfs/overlay/usr/bin/retroforge-cheevos"
SEED="$ROOT/rootfs/overlay/usr/share/retroforge/emulators/retroarch/retroarch.cfg"
[ -f "$TOOL" ] || { echo "no retroforge-cheevos: $TOOL" >&2; exit 1; }

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

W="$(mktemp -d)" && [ -d "$W" ] || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/proc" "$W/data/retroarch"
cp "$SEED" "$W/data/retroarch/retroarch.cfg"
PW='p4ss "word" \with\ quotes'

# The curl stub: logs its argv and the config it read on stdin; answers like login2. A good login is
# user Player1 + $PW (RetroAchievements spells the name its own way: "player1" -> "Player1").
cat > "$W/bin/curl" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$W/curl.argv"
cfg="\$(cat)"
printf '%s\n' "\$cfg" >> "$W/curl.stdin"
[ -f "$W/offline" ] && exit 6
if [ -f "$W/server-error" ]; then printf '<html>busy</html>\n503'; exit 0; fi
user=\$(sed -n 's/^data-urlencode = "u=\(.*\)"\$/\1/p' <<<"\$cfg")
pass=\$(sed -n 's/^data-urlencode = "p=\(.*\)"\$/\1/p' <<<"\$cfg")
if [ "\${user,,}" = player1 ] && [ "\$pass" = 'p4ss \"word\" \\\\with\\\\ quotes' ]; then
  printf '{"Success":true,"User":"Player1","Token":"AbCdEf0123456789","Score":10}\n200'
else
  printf '{"Success":false,"Status":401,"Code":"invalid_credentials","Error":"Invalid user/password combination. Please try again."}\n401'
fi
EOF
chmod +x "$W/bin/curl"

H="$W/home"; CFG="$H/.config/retroarch/retroarch.cfg"
run() {  # run [stdin] -- <args...>: sets OUT, ERR, RC
  local input="$1"; shift; [ "$1" = -- ] && shift
  OUT="$(printf '%s' "$input" | HOME="$H" RETROFORGE_CURL="$W/bin/curl" RETROFORGE_EMU_DATA_DIR="$W/data" \
    RETROFORGE_PROC="$W/proc" python3 "$TOOL" "$@" 2>"$W/err")"
  RC=$?; ERR="$(cat "$W/err")"
}
reset() { rm -rf "$H" "$W/curl.argv" "$W/curl.stdin" "$W/offline" "$W/server-error" "$W/proc"/*; mkdir -p "$H"; }
cfg() { sed -n "s/^$1 = \"\(.*\)\"\$/\1/p" "$CFG" 2>/dev/null; }
mode() { stat -c %a "$CFG" 2>/dev/null; }
retroarch_running() { mkdir -p "$W/proc/4242"; printf '/tmp/.mount_x/bin/retroarch\0--config\0%s\0' "$CFG" > "$W/proc/4242/cmdline"; }

# =================================================================================================
CASE="bad invocations"
reset
run "" --;                    [ "$RC" = 2 ] && ok "no command: exit 2" || bad "exit $RC"
run "$PW" -- login;           [ "$RC" = 2 ] && ok "login without a user: exit 2" || bad "exit $RC"
run "" -- login Player1;      [ "$RC" = 2 ] && ok "login without a password on stdin: exit 2" || bad "exit $RC"
run "$PW" -- login 'a"b';     [ "$RC" = 2 ] && ok "a user name with a quote: exit 2" || bad "exit $RC"
run "$PW" -- login Player1 "$PW"; [ "$RC" = 2 ] && ok "a password on the command line is refused" || bad "exit $RC"
run "" -- hardcore maybe;     [ "$RC" = 2 ] && ok "hardcore needs on or off" || bad "exit $RC"
[ ! -e "$W/curl.argv" ] && ok "nothing reached the network" || bad "curl ran"

# =================================================================================================
CASE="sign in, on a home where RetroArch never ran"
reset
run "$PW" -- login player1
[ "$RC" = 0 ] && ok "exit 0" || bad "exit $RC: $ERR"
[ "$(cfg cheevos_username)" = Player1 ] && ok "cheevos_username is the name RetroAchievements gave back" || bad "username '$(cfg cheevos_username)'"
[ "$(cfg cheevos_token)" = AbCdEf0123456789 ] && ok "cheevos_token is the token" || bad "token '$(cfg cheevos_token)'"
grep -q '^cheevos_password = ""$' "$CFG" && ok "cheevos_password stays empty" || bad "password line: $(grep cheevos_password "$CFG")"
! grep -rqF 'p4ss' "$H" && ok "the password is nowhere in the home" || bad "the password was written: $(grep -rlF p4ss "$H")"
[ "$(mode)" = 600 ] && ok "retroarch.cfg is 0600 (it holds the token)" || bad "mode $(mode)"
grep -q '^menu_show_core_updater = "false"$' "$CFG" && grep -q '^input_menu_toggle_gamepad_combo = "4"$' "$CFG" \
  && ok "the image's seed came first (a sign-in alone would keep the seed out for good)" || bad "seed missing from the new retroarch.cfg"
! grep -qF 'p4ss' "$W/curl.argv" && ok "the password is not in curl's argv" || bad "password in argv: $(cat "$W/curl.argv")"
grep -q -- '-K -' "$W/curl.argv" && grep -q 'https://retroachievements.org/dorequest.php' "$W/curl.stdin" \
  && ok "curl reads its URL and data from stdin" || bad "curl argv: $(cat "$W/curl.argv")"
grep -q -- '--proto =https' "$W/curl.argv" && ok "https only, redirects included" || bad "no --proto =https"
grep -q '^user-agent = "RetroForge' "$W/curl.stdin" && ok "it says who it is (User-Agent RetroForge)" || bad "user agent: $(grep -i agent "$W/curl.stdin")"
run "" -- status
python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); sys.exit(d != {"signed_in": True, "user": "Player1", "hardcore": False, "retroarch_running": False})' "$OUT" \
  && ok "status: signed in as Player1, hardcore off" || bad "status: $OUT"
! grep -q AbCdEf <<<"$OUT" && ok "status never prints the token" || bad "token in status"

# =================================================================================================
CASE="a refused sign-in"
reset; mkdir -p "$(dirname "$CFG")"; cp "$SEED" "$CFG"; before="$(cat "$CFG")"
run "wrong" -- login Player1
[ "$RC" = 7 ] && ok "wrong password: exit 7" || bad "exit $RC"
grep -q "Invalid user/password" <<<"$ERR" && ok "stderr gives RetroAchievements' reason" || bad "stderr: $ERR"
[ "$(cat "$CFG")" = "$before" ] && ok "retroarch.cfg unchanged" || bad "retroarch.cfg changed"

CASE="network and server failures"
reset; touch "$W/offline"
run "$PW" -- login Player1
[ "$RC" = 3 ] && ok "offline: exit 3" || bad "exit $RC"
reset; touch "$W/server-error"
run "$PW" -- login Player1
[ "$RC" = 8 ] && ok "an answer that is not login2's JSON: exit 8" || bad "exit $RC"
[ ! -e "$CFG" ] && ok "nothing written" || bad "retroarch.cfg written"

# =================================================================================================
CASE="hardcore, sign out"
reset; run "$PW" -- login Player1
run "" -- hardcore on
[ "$RC" = 0 ] && [ "$(cfg cheevos_hardcore_mode_enable)" = true ] && ok "hardcore on" || bad "exit $RC, '$(cfg cheevos_hardcore_mode_enable)'"
run "" -- hardcore off
[ "$(cfg cheevos_hardcore_mode_enable)" = false ] && ok "hardcore off" || bad "'$(cfg cheevos_hardcore_mode_enable)'"
run "" -- logout
[ "$RC" = 0 ] && [ -z "$(cfg cheevos_username)" ] && [ -z "$(cfg cheevos_token)" ] && ok "logout empties the name and the token" || bad "exit $RC"
grep -q '^menu_show_core_updater = "false"$' "$CFG" && ok "the rest of retroarch.cfg is kept" || bad "seed lost on logout"
run "" -- status
python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); sys.exit(d["signed_in"] or d["user"] is not None)' "$OUT" \
  && ok "status: signed out" || bad "status: $OUT"

# =================================================================================================
CASE="RetroArch running"
reset; run "$PW" -- login Player1; retroarch_running; before="$(cat "$CFG")"
run "" -- logout
[ "$RC" = 5 ] && grep -qi 'RetroArch is running' <<<"$ERR" && ok "logout refused while it runs (exit 5, said why)" || bad "exit $RC: $ERR"
run "" -- hardcore on
[ "$RC" = 5 ] && ok "hardcore refused while it runs" || bad "exit $RC"
run "$PW" -- login Player1
[ "$RC" = 5 ] && [ "$(grep -c . "$W/curl.argv")" = 1 ] && ok "login refused before asking RetroAchievements" || bad "exit $RC"
[ "$(cat "$CFG")" = "$before" ] && ok "retroarch.cfg untouched" || bad "changed while RetroArch runs"
run "" -- status
python3 -I -c 'import json,sys; sys.exit(not json.loads(sys.argv[1])["retroarch_running"])' "$OUT" \
  && ok "status says RetroArch is running" || bad "status: $OUT"

CASE="RetroArch run through a bundled ld.so"
reset; run "$PW" -- login Player1; mkdir -p "$W/proc/77"
printf '/tmp/.mount_x/lib/ld-linux-aarch64.so.1\0/tmp/.mount_x/shared/bin/retroarch\0--config\0x\0' > "$W/proc/77/cmdline"
run "" -- hardcore on
[ "$RC" = 5 ] && ok "its binary as ld.so's argument counts as running" || bad "exit $RC"
rm -rf "$W/proc/77"; mkdir -p "$W/proc/78"; printf '/x/ld.so\0retroarch\0' > "$W/proc/78/cmdline"; printf 'retroarch\n' > "$W/proc/78/comm"
run "" -- hardcore on
[ "$RC" = 5 ] && ok "a process the kernel names retroarch counts as running" || bad "exit $RC"
rm -rf "$W/proc/78"

CASE="files the tool makes"
reset; run "$PW" -- login Player1
[ "$(stat -c %a "$(dirname "$CFG")")" = 700 ] && ok "a retroarch folder it creates is 0700 (umask 077)" || bad "folder mode $(stat -c %a "$(dirname "$CFG")")"
[ -z "$(find "$H" -name '*.retroforge-*')" ] && ok "no temporary file left beside retroarch.cfg" || bad "leftover: $(find "$H" -name '*.retroforge-*')"
grep -q -- '^-q ' "$W/curl.argv" && ok "curl runs with -q first (no ~/.curlrc)" || bad "curl argv: $(head -1 "$W/curl.argv")"

CASE="an existing retroarch.cfg"
reset; mkdir -p "$(dirname "$CFG")"; printf 'video_driver = "glcore"\nmenu_driver = "rgui"\n' > "$CFG"; chmod 644 "$CFG"
run "$PW" -- login Player1
[ "$(mode)" = 600 ] && ok "tightened to 0600 before the token goes in" || bad "mode $(mode)"
grep -q '^video_driver = "glcore"$' "$CFG" && ! grep -q 'menu_show_core_updater' "$CFG" \
  && ok "the player's own file is patched, never replaced by the seed" || bad "file replaced"

echo
echo "test-cheevos: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
