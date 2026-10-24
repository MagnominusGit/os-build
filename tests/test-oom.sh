#!/usr/bin/env bash
# Offline test of the OOM victim order: a running game is the first process either OOM killer takes.
#
#   tests/test-oom.sh
#
# WHY THIS EXISTS. On the MANGMI Air X (3.5 GB, zram) MGLRU's min_ttl_ms guard
# (usr/lib/tmpfiles.d/retroforge-mm.conf) called the kernel's OOM killer 16 times in one boot, long
# before earlyoom's thresholds. The kernel ranks by oom_score_adj before size. A GOG game (GRIP) ran at
# the session's 0 while systemd ran pipewire, wireplumber and the session bus at 200, so it killed
# those, the session restarted, and the game lived (2026-10-24). Two halves keep that from coming back:
#   every command the plugin starts a game with is a launcher whose own suite asserts the game starts
#     at 900: retroforge-launch (test-launch.sh), /usr/bin/steam (Steam's own wrapper, or
#     retroforge-steam-direct: test-steam-direct.sh) and the store tool (test-store.sh). A new launch
#     command fails here until it is one of them or does the same;
#   the session spine runs at the session's 0. user@.service.d puts the user manager there (an
#     unprivileged manager cannot set a service below itself, and systemd ignores that silently), each
#     spine unit's drop-in sets 0, below the 100 every other user service then gets, and each is a name
#     earlyoom's --avoid or --ignore protects, so the two killers agree.
# systemd-analyze, where installed, checks the drop-ins' keys as test-units.sh checks units.
# Runs on the host with no root and no device.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OV="$ROOT/rootfs/overlay"
PLUGIN="$ROOT/apps/ogui-retroforge-plugin/plugin"
USER_AT="$OV/usr/lib/systemd/system/user@.service.d/10-retroforge-oom.conf"
SESSION="$OV/usr/lib/systemd/system/retroforge-session.service"
EARLYOOM="$OV/usr/lib/systemd/system/earlyoom.service.d/retroforge.conf"
# The spine: unit:its daemon's comm, the name earlyoom matches.
SPINE=(pipewire:pipewire pipewire-pulse:pipewire-pulse wireplumber:wireplumber dbus-broker:dbus-broker)
for f in "$USER_AT" "$SESSION" "$EARLYOOM" "$PLUGIN/library_roms.gd"; do [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }; done

PASS=0; FAIL=0; SKIP=0; CASE=""
ok()   { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }
skip() { SKIP=$((SKIP+1)); printf '  skip %s -- %s\n' "$CASE" "$1"; }

T="$(mktemp -d)" && [ -d "$T" ] || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT

adj() { sed -n 's/^OOMScoreAdjust=//p' "$1" 2>/dev/null | tail -n1; }  # the file's OOMScoreAdjust=, "" for none

# ================================================================================================
CASE="launch paths"
n=0
while IFS= read -r line; do
  n=$((n+1))
  file="${line%%:*}"; name="$(basename "$file")"; rhs="${line##*.command = }"
  case "$name:$rhs" in
    *:LAUNCHER) launcher=/usr/bin/retroforge-launch; suite=test-launch.sh
                grep -q "^const LAUNCHER := \"$launcher\"" "$file" || launcher="" ;;
    *:'"steam"') launcher=/usr/bin/steam; suite=test-steam-direct.sh ;;
    library_store.gd:tool_path) launcher=/usr/lib/retroforge/store; suite=test-store.sh
                grep -q "^const TOOL := \"$launcher\"" "$file" || launcher="" ;;
    *) launcher="" ;;
  esac
  if [ -n "$launcher" ] && grep -q "oom_score_adj 900" "$ROOT/tests/$suite"; then
    ok "$name: $rhs is $launcher, whose game starts at oom_score_adj 900 ($suite)"
  else
    bad "$name: '$rhs' is a launch this test does not know: start its game at oom_score_adj 900, assert it, add it here"
  fi
done < <(grep -n '\.command = ' "$PLUGIN"/*.gd | sed 's/[[:space:]]*$//')
[ "$n" -gt 0 ] || bad "no launch command found in $PLUGIN"

# ================================================================================================
CASE="session spine"
session="$(adj "$SESSION")"; session="${session:-0}"  # none: PID 1's 0, which the session inherits
floor="$(adj "$USER_AT")"
if [ -n "$floor" ] && [ "$floor" -le "$session" ]; then
  ok "user@.service at $floor, the session's ($session) at most: its services can be there too"
else
  bad "user@.service drop-in OOMScoreAdjust='$floor', the session's is $session"
fi
others=$(( ${floor:-100} + 100 ))  # a user manager's DefaultOOMScoreAdjust: its own + 100
ignore="$(sed -n '/^Environment=/s/.*--ignore \([^ "]*\).*/\1/p' "$EARLYOOM")"
avoid="$(sed -n '/^Environment=/s/.*--avoid \([^ "]*\).*/\1/p' "$EARLYOOM")"
[ -n "$ignore" ] && [ -n "$avoid" ] || bad "earlyoom's --ignore/--avoid not found in $EARLYOOM"
for pair in "${SPINE[@]}"; do
  unit="${pair%%:*}.service"; comm="${pair#*:}"
  v="$(adj "$OV/usr/lib/systemd/user/$unit.d/10-retroforge-oom.conf")"
  if [ -n "$v" ] && [ -n "$floor" ] && [ "$v" -ge "$floor" ] && [ "$v" -le "$session" ] && [ "$v" -lt "$others" ]; then
    ok "$unit at $v: not below its manager's $floor, the session's at most, under the $others of other user services"
  else
    bad "$unit OOMScoreAdjust='$v' (manager $floor, session $session, other user services $others)"
  fi
  # bash's =~ is POSIX extended regcomp, as earlyoom matches its lists.
  if [[ "$comm" =~ $ignore ]] || [[ "$comm" =~ $avoid ]]; then
    ok "$comm is on earlyoom's --ignore or --avoid list too"
  else
    bad "$comm matches neither --ignore $ignore nor --avoid $avoid"
  fi
done

# ================================================================================================
CASE="drop-in keys"
if command -v systemd-analyze >/dev/null 2>&1; then
  for f in "$USER_AT" "$OV"/usr/lib/systemd/user/*.service.d/10-retroforge-oom.conf; do
    u="$T/retroforge-oom-check.service"
    { printf '[Service]\nExecStart=/bin/true\n'; cat "$f"; } >"$u"
    systemd-analyze verify "$u" >"$T/out" 2>&1 || true
    if grep -Eq 'Unknown key|Unknown section|Failed to parse|Invalid |Assignment outside of section' "$T/out"; then
      bad "${f#"$OV"/}: $(grep -E 'Unknown|Failed|Invalid|Assignment' "$T/out" | head -n1)"
    else
      ok "${f#"$OV"/}"
    fi
  done
else
  skip "systemd-analyze not installed -- drop-in keys unverified"
fi

printf '\n%s: %d passed, %d failed, %d skipped\n' "$(basename "$0")" "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
