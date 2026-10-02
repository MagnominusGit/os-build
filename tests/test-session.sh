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
PKG="$ROOT/packages/opengamepadui"
PIN="$PKG/source.pin"
PKGBUILD="$PKG/PKGBUILD"
BASE="$ROOT/rootfs/customize-base.sh"
TRIM="$ROOT/rootfs/conf/trim.list"

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

for f in "$CONF" "$SESSION" "$PIN" "$PKGBUILD" "$BASE" "$TRIM"; do
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
CASE="the OpenGamepadUI package"
# A local PKGBUILD since 2026-10-02: upstream's aarch64 release with the pck rebuilt from the tagged
# source plus patches, because the released pck crash-loops on devicetree boards (#542) and cannot
# launch games under Godot 4.7 (#540). These checks pin the shape; the build itself is what proves
# the patches still apply (patch failure fails makepkg).
pb() { (set +u; . "$PKGBUILD"; eval "printf '%s\n' \"\${$1[@]}\""); }
[ "$(pin_field name)" = "opengamepadui" ] && [ "$(pin_field pkgbuild_local)" = "PKGBUILD" ] \
  && ok "source.pin: local PKGBUILD named opengamepadui" || bad "source.pin name/pkgbuild_local wrong"
[ "$(pb pkgname)" = "opengamepadui" ] && ok "PKGBUILD pkgname matches the pin" || bad "pkgname is '$(pb pkgname)'"
ver="$(pb pkgver)"
pb source | grep -q "/releases/download/v\${pkgver}/opengamepadui-aarch64.tar.gz\|/releases/download/v$ver/opengamepadui-aarch64.tar.gz" \
  && ok "sources the aarch64 release tarball of pkgver ($ver)" || bad "no aarch64 release tarball for $ver in source=()"
pb source | grep -q "/archive/refs/tags/v$ver.tar.gz" \
  && ok "sources the tagged project source of the same version" || bad "no v$ver source archive in source=()"
nsrc="$(pb source | grep -c .)"; nsum="$(pb sha256sums | grep -cE '^[0-9a-f]{64}$')"
[ "$nsrc" = "$nsum" ] && [ "$nsrc" -gt 0 ] && ok "one full sha256 per source ($nsrc)" \
  || bad "$nsrc sources but $nsum valid sha256sums"
grep -q 'sha256sum -c' "$PKGBUILD" && ok "prepare() verifies the sums itself (build-overlay runs --skipinteg)" \
  || bad "nothing verifies the downloads — makepkg runs with --skipinteg"
grep -q -- '--export-pack "Linux/X11 aarch64"' "$PKGBUILD" && ok "exports the aarch64 preset as a pack" \
  || bad "PKGBUILD does not export the aarch64 preset"
case " $(pb depends | tr '\n' ' ') " in *" libxinerama "*) ok "depends on libxinerama (Godot's X11 backend needs it)";;
                                          *) bad "libxinerama is not a dependency — Godot's X11 backend will not start";; esac
grep -qE '^PKGS=\(.* opengamepadui[ )]' "$BASE" && ok "opengamepadui is in PKGS (overlay packages install only when listed)" \
  || bad "opengamepadui missing from PKGS in customize-base.sh"
for p in $(pin_field patches); do
  [ -s "$PKG/patches/$p" ] && ok "patch present: $p" || bad "listed patch missing: $p"
done

# What each patch must keep doing. Content checks, because a patch rewritten in a later bump can
# still apply cleanly while no longer fixing the bug it was added for.
P1="$PKG/patches/0001-hardware-manager-no-dmi.patch"
grep -q '^+	if not file:' "$P1" && grep -q '^+.*/sys/firmware/devicetree/base/model' "$P1" \
  && ok "0001 guards the null FileAccess and falls back to the devicetree model (#542)" \
  || bad "0001 no longer guards _read_sys / no devicetree fallback — DT boards crash-loop again"
grep -q '^+	var nul := bytes.find(0)' "$P1" \
  && ok "0001 cuts devicetree strings at their NUL (no U+FFFD in the name, no warning per call)" \
  || bad "0001 decodes the devicetree NUL — the product name carries U+FFFD and the log fills with warnings"
P2="$PKG/patches/0002-install-dialogs-rename-custom-maximum-size.patch"
if grep -q '^+.*custom_maximum_size' "$P2"; then
  bad "0002 still ADDS custom_maximum_size — collides with Godot 4.7's Control property (#540)"
elif [ "$(grep -c '^-.*custom_maximum_size' "$P2")" -ge 4 ]; then
  ok "0002 renames every custom_maximum_size in the install dialogs (#540)"
else
  bad "0002 does not rename custom_maximum_size in both dialogs and scenes"
fi

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
