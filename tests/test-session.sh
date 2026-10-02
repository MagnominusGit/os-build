#!/usr/bin/env bash
# Offline test for the gamescope session profile: which shell qforge-session hosts, and with what.
#
#   tests/test-session.sh
#
# WHY THIS EXISTS. The shell is three files that never change together: session.conf names it and
# its gamescope flags, qforge-session turns those into a gamescope command line, and the
# OpenGamepadUI prebuilt pin decides where the shell lands in the image. Each failure is a black or
# frozen panel on a device with no console:
#
#   - OGUI drives gamescope through the Steam-mode X atoms (GAMESCOPECTRL_BASELAYER_APPID,
#     STEAM_OVERLAY, ...). Without --steam gamescope ignores them: the shell paints, but it can never
#     put itself over a game or take focus back for the quick menu.
#   - the pin unpacks a tarball whose root carries a Makefile beside usr/. The wrong strip count
#     either drops the shell at /share/... (nothing finds it) or litters the image root.
#   - Godot's X11 backend dlopen()s libXinerama and refuses to start without it; nothing else in the
#     base pulls it in, so the pin has to.
#
# Runs on the host with no root, no device and no build.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONF="$ROOT/rootfs/overlay/etc/qforge/session.conf"
SESSION="$ROOT/rootfs/overlay/usr/bin/qforge-session"
PIN="$ROOT/packages/opengamepadui/prebuilt.pin"
TRIM="$ROOT/rootfs/conf/trim.list"

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

for f in "$CONF" "$SESSION" "$PIN" "$TRIM"; do
  [ -f "$f" ] || { echo "missing input: $f" >&2; exit 1; }
done

# session.conf is sh, sourced by qforge-session. Source it the same way, in a subshell, and read
# back what the session would see — not a grep for a line that might be commented out.
conf() { (set +u; . "$CONF"; eval "printf '%s' \"\${$1-}\""); }
pin_field() { sed -n "s/^$1:[[:space:]]*//p" "$PIN" | head -1; }

# =================================================================================================
CASE="the shell"
cmd="$(conf QFORGE_SESSION_CMD)"
[ "${cmd%% *}" = "opengamepadui" ] \
  && ok "QFORGE_SESSION_CMD is upstream's launcher, opengamepadui" \
  || bad "QFORGE_SESSION_CMD is '$cmd', not opengamepadui"
# OGUI's update pack is the x86_64 build: applying one at start leaves a black panel on this device,
# and any update pack would override the OS image's shell version.
case " $cmd " in
  *" --skip-update-pack "*) ok "the shell never applies a downloaded update pack (--skip-update-pack)" ;;
  *) bad "QFORGE_SESSION_CMD '$cmd' lacks --skip-update-pack — a downloaded x86_64 update.zip would replace the shell" ;;
esac
sh -n "$CONF" 2>/dev/null && ok "session.conf parses as sh" || bad "session.conf is not valid sh"

# =================================================================================================
CASE="gamescope flags for OGUI"
args=" $(conf QFORGE_GAMESCOPE_SHELL_ARGS) "
case "$args" in *" --steam "*) ok "--steam is passed (OGUI's control atoms need it)";;
                *) bad "no --steam: gamescope would ignore OGUI's focus and overlay atoms";; esac
case "$args" in *" --xwayland-count 2 "*) ok "two nested Xwaylands (shell + game)";;
                *) bad "not --xwayland-count 2: '$args'";; esac
grep -q '\$QFORGE_GAMESCOPE_SHELL_ARGS -R ' "$SESSION" \
  && ok "qforge-session puts the shell args on the gamescope command line, before the handshake" \
  || bad "qforge-session does not apply QFORGE_GAMESCOPE_SHELL_ARGS"
if sed 's,#.*,,' "$SESSION" | grep -q -- '--steam'; then
  bad "qforge-session hard-codes --steam — it belongs to the shell profile in session.conf"
else
  ok "qforge-session itself stays shell-agnostic (no hard-coded --steam)"
fi

# =================================================================================================
CASE="environment for what gamescope hosts"
for kv in QT_QPA_PLATFORM=xcb SDL_VIDEO_MINIMIZE_ON_FOCUS_LOSS=0 vk_xwayland_wait_ready=false; do
  k=${kv%%=*}; v=${kv#*=}
  got="$( (set +u; . "$CONF"; env) | sed -n "s/^$k=//p")"
  [ "$got" = "$v" ] && ok "$k=$v is exported" || bad "$k is '${got:-<not exported>}', want $v"
done

# =================================================================================================
CASE="the OpenGamepadUI pin"
[ "$(pin_field name)" = "opengamepadui" ] && ok "name: opengamepadui" || bad "pin name is '$(pin_field name)'"
case "$(pin_field url)" in
  *"/v$(pin_field version)/opengamepadui-aarch64.tar.gz") ok "url is the aarch64 tarball of the pinned version";;
  *) bad "url does not match version $(pin_field version): $(pin_field url)";;
esac
[[ "$(pin_field sha256)" =~ ^[0-9a-f]{64}$ ]] && ok "sha256 is a full digest" || bad "sha256 is not a 64-hex digest"
[ "$(pin_field strip)" = "2" ] && [ "$(pin_field dest)" = "/usr" ] \
  && ok "strip 2 into /usr: opengamepadui/usr/* lands in /usr, the root-level Makefile is dropped" \
  || bad "strip/dest are '$(pin_field strip)' '$(pin_field dest)', want 2 and /usr"
case " $(pin_field deps) " in *" libxinerama "*) ok "deps carry libxinerama (Godot's X11 backend needs it)";;
                               *) bad "libxinerama is not a dep — Godot's X11 backend will not start";; esac

# =================================================================================================
CASE="no self-updater on a RAUC root"
for row in usr/lib/systemd/user/systemd-sysext-updater.service \
           usr/share/opengamepadui/scripts/update_systemd_ext.sh \
           usr/share/opengamepadui/scripts/make_nice \
           usr/share/polkit-1/actions/org.shadowblip.setcap.policy \
           usr/share/polkit-1/actions/org.shadowblip.nixos_updater.policy; do
  grep -qx "glob $row" "$TRIM" && ok "trimmed: $row" || bad "not trimmed: $row"
done

printf '\ntest-session.sh: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
