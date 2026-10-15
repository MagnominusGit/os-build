#!/usr/bin/env bash
# Offline test for the gamescope session profile: which shell retroforge-session hosts, and with what.
#
#   tests/test-session.sh
#
# WHY THIS EXISTS. The shell is three files that never change together: session.conf names it and
# its gamescope flags, retroforge-session turns those into a gamescope command line, and the
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
CONF="$ROOT/rootfs/overlay/etc/retroforge/session.conf"
SESSION="$ROOT/rootfs/overlay/usr/bin/retroforge-session"
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

# session.conf is sh, sourced by retroforge-session. Source it the same way, in a subshell, and read
# back what the session would see — not a grep for a line that might be commented out.
conf() { (set +u; . "$CONF"; eval "printf '%s' \"\${$1-}\""); }
pin_field() { sed -n "s/^$1:[[:space:]]*//p" "$PIN" | head -1; }

# =================================================================================================
CASE="the shell"
cmd="$(conf RETROFORGE_SESSION_CMD)"
[ "${cmd%% *}" = "opengamepadui" ] \
  && ok "RETROFORGE_SESSION_CMD is upstream's launcher, opengamepadui" \
  || bad "RETROFORGE_SESSION_CMD is '$cmd', not opengamepadui"
# OGUI's update pack is the x86_64 build: applying one at start leaves a black panel on this device,
# and any update pack would override the OS image's shell version.
case " $cmd " in
  *" --skip-update-pack "*) ok "the shell never applies a downloaded update pack (--skip-update-pack)" ;;
  *) bad "RETROFORGE_SESSION_CMD '$cmd' lacks --skip-update-pack — a downloaded x86_64 update.zip would replace the shell" ;;
esac
sh -n "$CONF" 2>/dev/null && ok "session.conf parses as sh" || bad "session.conf is not valid sh"
# pam_systemd gives every login session an ambient CAP_WAKE_ALARM; inherited by the shell and its
# games, it made the game's /proc/<pid>/fdinfo unreadable to mangoapp, which aborted every few seconds
# (blinking, frozen Performance Overlay, HW 2026-10-04).
grep -Eq '^setpriv --inh-caps=-all --ambient-caps=-all \$RETROFORGE_SESSION_CMD ' "$SESSION" \
  && ok "the shell starts with no inherited/ambient capabilities (setpriv)" \
  || bad "the shell is not started under setpriv --ambient-caps=-all: games inherit CAP_WAKE_ALARM again"

# =================================================================================================
CASE="gamescope flags for OGUI"
args=" $(conf RETROFORGE_GAMESCOPE_SHELL_ARGS) "
case "$args" in *" --steam "*) ok "--steam is passed (OGUI's control atoms need it)";;
                *) bad "no --steam: gamescope would ignore OGUI's focus and overlay atoms";; esac
case "$args" in *" --xwayland-count 2 "*) ok "two nested Xwaylands (shell + game)";;
                *) bad "not --xwayland-count 2: '$args'";; esac
grep -q '\$RETROFORGE_GAMESCOPE_SHELL_ARGS -R ' "$SESSION" \
  && ok "retroforge-session puts the shell args on the gamescope command line, before the handshake" \
  || bad "retroforge-session does not apply RETROFORGE_GAMESCOPE_SHELL_ARGS"
if sed 's,#.*,,' "$SESSION" | grep -q -- '--steam'; then
  bad "retroforge-session hard-codes --steam — it belongs to the shell profile in session.conf"
else
  ok "retroforge-session itself stays shell-agnostic (no hard-coded --steam)"
fi

# =================================================================================================
CASE="dual-screen boards"
# The second panel (device-env RETROFORGE_SECONDARY_CONNECTOR) becomes gamescope's second output
# (patches/0040). Without the guard a single-panel board would pass a bare --secondary-output and
# gamescope would take the next argument as the connector name.
if grep -Fq 'if [ -n "${RETROFORGE_SECONDARY_CONNECTOR:-}" ]; then' "$SESSION" &&
   grep -Fq 'GS_ARGS="$GS_ARGS --secondary-output $RETROFORGE_SECONDARY_CONNECTOR"' "$SESSION"; then
  ok "--secondary-output is passed only when the board declares a second panel"
else
  bad "retroforge-session does not pass --secondary-output under a RETROFORGE_SECONDARY_CONNECTOR guard"
fi
if grep -Fq 'if [ -n "${RETROFORGE_SECONDARY_TOUCHSCREEN:-}" ]; then' "$SESSION" &&
   grep -Fq 'GS_ARGS="$GS_ARGS --secondary-touch-device $RETROFORGE_SECONDARY_TOUCHSCREEN"' "$SESSION"; then
  ok "--secondary-touch-device is passed only when the board names its second digitizer"
else
  bad "retroforge-session does not pass --secondary-touch-device under a RETROFORGE_SECONDARY_TOUCHSCREEN guard"
fi
grep -q '0043-wlserver-route-the-secondary-touchscreen-to-the-secondary-output.patch' "$ROOT/packages/gamescope/source.pin" \
  && ok "the gamescope build carries --secondary-touch-device (patch 0043 in source.pin)" \
  || bad "--secondary-touch-device is passed but patch 0043 is not in packages/gamescope/source.pin"
grep -Fq 'secondary-output' "$ROOT/packages/gamescope/patches/0040-drm-drive-a-secondary-output.patch" &&
  grep -q '0040-drm-drive-a-secondary-output.patch' "$ROOT/packages/gamescope/source.pin" \
  && ok "the gamescope build carries the flag (patch 0040 in source.pin)" \
  || bad "--secondary-output is passed but patch 0040 is not in packages/gamescope/source.pin"

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

# =================================================================================================
# Behaviour: run the real retroforge-session with a fake gamescope and a fake shell client.
# PAMName= puts the session in the logind scope, so systemd's stop reaches ONLY this script. With
# the client in the foreground, sh held the TERM trap until the client returned, nothing told the
# client to quit, and every `systemctl restart retroforge-session` waited out the 90 s stop timeout
# (HW 2026-10-03). The client must get SIGTERM from the script and the session must end promptly.
CASE="session stop"
T="$(mktemp -d)" && [ -d "$T" ] || { echo "mktemp -d failed" >&2; exit 1; }
spids=()
# Also the fake reapers and games (pid files): a regression orphans them exactly like the real bug.
cleanup_t() {
  [ ${#spids[@]} -gt 0 ] && kill -KILL "${spids[@]}" 2>/dev/null
  [ -n "${T:-}" ] && [ -d "$T" ] || return
  cat "$T"/*.pids 2>/dev/null | xargs -r kill -KILL 2>/dev/null
  rm -rf "$T"
}
trap cleanup_t EXIT
mkdir -p "$T/bin" "$T/run" "$T/home"
# gamescope: answer the startup handshake on the -R fifo, then run until SIGTERM.
cat > "$T/bin/gamescope" <<EOF
#!/bin/bash
trap 'echo gamescope-term >> "$T/log"; exit 0' TERM
echo \$\$ > "$T/gs.pid"
echo "gs-vram=\${ENABLE_MESA_VRAM_REPORT_LIMIT-}\${VK_VRAM_REPORT_LIMIT_HEAP_SIZE-}" >> "$T/log"
while [ \$# -gt 0 ]; do [ "\$1" = -R ] && { r=\$2; shift; }; shift; done
echo ":1 gamescope-0" > "\$r"
while :; do sleep 0.05; done
EOF
# The shell client: logs its stdin, exits 5 when $T/client-exit appears, or 0 on SIGTERM.
cat > "$T/client" <<EOF
#!/bin/bash
echo "stdin=\$(readlink /proc/\$\$/fd/0)" >> "$T/log"
echo "vram=\${ENABLE_MESA_VRAM_REPORT_LIMIT-}:\${VK_VRAM_REPORT_LIMIT_HEAP_SIZE-}:\${VK_VRAM_REPORT_LIMIT_DEVICE_ID-}" >> "$T/log"
trap 'echo client-term >> "$T/log"; exit 0' TERM
if [ -e "$T/with-game" ]; then "$T/reaper" "$T/reaper.sh" & fi
echo client-up >> "$T/log"
while [ ! -e "$T/client-exit" ]; do sleep 0.05; done
exit 5
EOF
# OGUI's reaper is a binary found by its executable path, so the fake is a copy of bash (its
# /proc/PID/exe is then $T/reaper) running a script: start the game in its own session, as
# retroforge-launch starts an emulator, and exit once no child is left.
cp "$(command -v bash)" "$T/reaper"
cat > "$T/reaper.sh" <<EOF
echo \$\$ > "$T/reaper.pid"; echo \$\$ >> "$T/fakes.pids"
setsid "$T/game" &
wait
echo reaper-exit >> "$T/log"
EOF
# The game: on SIGTERM records whether gamescope is still up, takes 0.2 s to "save", exits. With
# $T/game-stubborn it ignores SIGTERM.
cat > "$T/game" <<EOF
#!/bin/bash
if [ -e "$T/game-stubborn" ]; then trap '' TERM
else trap 'kill -0 \$(cat "$T/gs.pid") 2>/dev/null && echo game-term-display-up >> "$T/log" || echo game-term-display-gone >> "$T/log"; sleep 0.2; echo game-exit >> "$T/log"; exit 0' TERM
fi
echo \$\$ >> "$T/fakes.pids"
echo game-up >> "$T/log"
while :; do sleep 0.05; done
EOF
chmod +x "$T/bin/gamescope" "$T/client" "$T/game"
run_session() {
  : > "$T/log"; rm -f "$T/client-exit"
  PATH="$T/bin:$PATH" XDG_RUNTIME_DIR="$T/run" HOME="$T/home" RETROFORGE_SESSION_CMD="$T/client" \
    RETROFORGE_OGUI_REAPER="$T/reaper" RETROFORGE_GAME_STOP_TIMEOUT=1 \
    sh "$SESSION" < "$T/stdin" > "$T/session.out" 2>&1 &
  spid=$!; spids+=("$spid")
}
waitfor() { for _ in $(seq 100); do eval "$1" && return 0; sleep 0.05; done; return 1; }
: > "$T/stdin"
if [ -e /etc/retroforge/session.conf ] || [ -e /usr/lib/retroforge/device-env ]; then
  ok "skipped: this host has RetroForge's session.conf/device-env, which would override the fakes"
else
  run_session
  if waitfor 'grep -qx client-up "$T/log"'; then
    grep -qx "stdin=$T/stdin" "$T/log" \
      && ok "the client keeps the session's stdin (tty1 on the device), not /dev/null" \
      || bad "the client's stdin is $(sed -n 's/^stdin=//p' "$T/log"), not the session's"
    t0=$(date +%s%N); kill -TERM "$spid"
    if waitfor "! kill -0 $spid 2>/dev/null"; then
      ms=$(( ($(date +%s%N) - t0) / 1000000 ))
      wait "$spid"; rc=$?
      ok "SIGTERM to the session ends it in ${ms} ms (was: hung until systemd's 90 s SIGKILL)"
      [ "$rc" = 143 ] && ok "exit status 143 after SIGTERM" || bad "exit status $rc after SIGTERM, not 143"
    else
      bad "the session ignored SIGTERM for 5 s: systemctl stop would wait out TimeoutStopSec"
    fi
    grep -qx client-term "$T/log" && ok "the shell client was sent SIGTERM" || bad "the shell client never got SIGTERM"
    waitfor 'grep -qx gamescope-term "$T/log"' && ok "gamescope was stopped" || bad "gamescope was left running"
    ls -d "$T"/run/gamescope.* >/dev/null 2>&1 && bad "the gamescope rundir was left behind" || ok "the gamescope rundir was removed"
  else
    bad "the fake client never started: $(tail -3 "$T/session.out")"
  fi

  run_session
  if waitfor 'grep -qx client-up "$T/log"'; then
    touch "$T/client-exit"
    waitfor "! kill -0 $spid 2>/dev/null" || { bad "the session did not end after the client exited"; kill -KILL "$spid"; }
    wait "$spid"; rc=$?
    [ "$rc" = 5 ] && ok "a client that exits on its own: the session exits with its status (5)" || bad "session exited $rc, the client 5"
    waitfor 'grep -qx gamescope-term "$T/log"' && ok "...and gamescope is stopped" || bad "gamescope survived the client's exit"
  else
    bad "the fake client never started (second run)"
  fi
fi

# -------------------------------------------------------------------------------------------------
CASE="the shell's VRAM report"
# OGUI (Godot's VMA) reserves blocks sized from the reported heap, so the shell alone gets mesa's
# vram-report-limit layer: 512 MiB below 4 GiB of RAM, 1 GiB up to 6 GiB, nothing above, and
# nothing without device-env's GPU chip id (the layer matches one id).
if [ -e /etc/retroforge/session.conf ] || [ -e /usr/lib/retroforge/device-env ]; then
  ok "skipped: this host has RetroForge's session.conf/device-env, which would override the fakes"
else
  for row in "3386492 0x5143:0x06010000 1:512:0x5143:0x06010000" \
             "4194303 0x5143:0x06010000 1:512:0x5143:0x06010000" \
             "4194304 0x5143:0x06050002 1:1024:0x5143:0x06050002" \
             "5700000 0x5143:0x06050002 1:1024:0x5143:0x06050002" \
             "6291456 0x5143:0x43051401 1:1024:0x5143:0x43051401" \
             "6291457 0x5143:0x43051401 ::" \
             "15826200 0x5143:0x43051401 ::" \
             "3386492 - ::" \
             "missing 0x5143:0x06010000 ::"; do
    read -r kb chip want <<<"$row"
    if [ "$kb" = missing ]; then rm -f "$T/meminfo"; else printf 'MemTotal:       %s kB\n' "$kb" > "$T/meminfo"; fi
    [ "$chip" = - ] && chip=""
    RETROFORGE_MEMINFO="$T/meminfo" RETROFORGE_GPU_CHIP_ID="$chip" run_session
    if waitfor 'grep -qx client-up "$T/log"'; then
      got=$(sed -n 's/^vram=//p' "$T/log")
      [ "$got" = "$want" ] && ok "MemTotal $kb kB, chip '${chip:-none}': shell gets '$want'" \
        || bad "MemTotal $kb kB, chip '${chip:-none}': shell got '$got', want '$want'"
      [ "$kb" = 3386492 ] && [ -n "$chip" ] && { grep -qx 'gs-vram=' "$T/log" \
        && ok "gamescope itself does not get the shell's report" || bad "gamescope got the report: $(grep gs-vram "$T/log")"; }
    else
      bad "the fake client never started ($kb kB)"
    fi
    touch "$T/client-exit"
    waitfor "! kill -0 $spid 2>/dev/null" || kill -KILL "$spid"
    wait "$spid" 2>/dev/null
  done
  rm -f "$T/meminfo"
fi

# -------------------------------------------------------------------------------------------------
CASE="session stop with a game running"
if [ -e /etc/retroforge/session.conf ] || [ -e /usr/lib/retroforge/device-env ]; then
  ok "skipped (host has RetroForge's session.conf/device-env)"
else
  # Index of a line in the log: the order is the point (game before shell before gamescope).
  at() { grep -nx "$1" "$T/log" | head -1 | cut -d: -f1; }
  touch "$T/with-game"; rm -f "$T/game-stubborn"
  run_session
  if waitfor 'grep -qx game-up "$T/log"'; then
    kill -TERM "$spid"
    waitfor "! kill -0 $spid 2>/dev/null" || { bad "the session did not end"; kill -KILL "$spid"; }
    wait "$spid"
    grep -qx game-term-display-up "$T/log" \
      && ok "the game got SIGTERM while gamescope was still up (a clean shutdown, not a lost display)" \
      || bad "the game was not stopped before gamescope ($(grep game-term "$T/log" || echo 'no SIGTERM'))"
    [ -n "$(at game-exit)" ] && [ -n "$(at reaper-exit)" ] && [ -n "$(at client-term)" ] \
      && [ "$(at reaper-exit)" -lt "$(at client-term)" ] \
      && ok "the game and its reaper were gone before the shell was stopped" \
      || bad "order in the log: $(tr '\n' ' ' < "$T/log")"
    waitfor 'grep -qx gamescope-term "$T/log"' && [ "$(at game-exit)" -lt "$(at gamescope-term)" ] \
      && ok "gamescope was stopped last" || bad "gamescope stopped before the game exited"
  else
    bad "the fake game never started: $(tail -3 "$T/session.out")"
  fi

  # The shell exits on its own (a crash) with a game running: the game still goes first.
  run_session
  if waitfor 'grep -qx game-up "$T/log"'; then
    touch "$T/client-exit"
    waitfor "! kill -0 $spid 2>/dev/null" || { bad "the session did not end"; kill -KILL "$spid"; }
    wait "$spid"
    grep -qx game-term-display-up "$T/log" && [ -n "$(at reaper-exit)" ] \
      && ok "shell crashed with a game running: the orphaned game is still stopped cleanly" \
      || bad "a game left behind by an exiting shell was not stopped cleanly: $(tr '\n' ' ' < "$T/log")"
  else
    bad "the fake game never started (crash case)"
  fi

  # A game that ignores SIGTERM is killed after RETROFORGE_GAME_STOP_TIMEOUT (1 s here).
  touch "$T/game-stubborn"
  run_session
  if waitfor 'grep -qx game-up "$T/log"'; then
    kill -TERM "$spid"
    waitfor "! kill -0 $spid 2>/dev/null" || { bad "the session did not end"; kill -KILL "$spid"; }
    wait "$spid"
    rp="$(cat "$T/reaper.pid")"
    grep -q "still running after 1s" "$T/session.out" && ! kill -0 "$rp" 2>/dev/null \
      && ok "a game ignoring SIGTERM is killed after the timeout, and the session still ends" \
      || bad "a stubborn game was not killed (session.out: $(tail -2 "$T/session.out"))"
  else
    bad "the fake game never started (stubborn case)"
  fi
  rm -f "$T/with-game" "$T/game-stubborn"
fi

# -------------------------------------------------------------------------------------------------
# cleanup() must WAIT for gamescope to exit, not just signal it. SDDM's autologin starts the next
# session the moment the script returns; a gamescope still alive holds /dev/dri/card0, the new one's
# logind TakeDevice fails EBUSY, the handshake times out and SDDM does not relogin: one client crash
# becomes a permanently black screen (upstream HW 2026-10-04, the old gamescope took ~0.7 s to go).
#
# cleanup() and gs_running() are extracted from the SHIPPED script by name and run in /bin/sh
# against a fake gamescope started as a CHILD of the same shell -- an exited child stays a zombie
# until reaped, and a zombie still answers `kill -0`, which is what gs_running() has to see through.
CASE="gamescope teardown"
extract() { sed -n "/^$1() {/,/^}/p" "$SESSION"; }
{ extract gs_running; extract cleanup; } > "$T/cleanup.sh"
if [ -z "$(extract gs_running)" ] || [ -z "$(extract cleanup)" ]; then
  bad "could not extract gs_running() and cleanup() from retroforge-session"
else
  # Prints "<elapsed ms> <fake state>", the state read BEFORE anything reaps the child: "gone" or
  # "Z" means its fds are closed (DRM released); anything else means it is still running.
  run_cleanup() {
    /bin/sh -c '
      . "$1"
      GS_RUNDIR="$2/td-rundir"; mkdir -p "$GS_RUNDIR"
      RETROFORGE_GAMESCOPE_STOP_TIMEOUT="$4"
      /bin/sh -c "$3" &
      GS_PID=$!
      fake=$GS_PID   # cleanup() clears GS_PID once it is done with it
      sleep 0.3      # let the fake install its trap
      t0=$(date +%s%N)
      cleanup 2>/dev/null
      t1=$(date +%s%N)
      st=gone
      [ -e "/proc/$fake" ] && st=$(sed -n "s/^State:[[:space:]]*\([A-Z]\).*/\1/p" "/proc/$fake/status")
      echo "$(( (t1 - t0) / 1000000 )) $st"
      kill -KILL "$fake" 2>/dev/null; wait "$fake" 2>/dev/null
      exit 0
    ' sh "$T/cleanup.sh" "$T" "$1" "$2"
  }

  # A gamescope that takes 1 s to wind down after SIGTERM must be gone when cleanup() returns.
  read -r ms st < <(run_cleanup 'trap "sleep 1; exit 0" TERM; while :; do sleep 0.1; done' 10)
  case "$st" in
    gone|Z) ok "a slow gamescope had exited when cleanup() returned (${ms} ms, state $st)" ;;
    *)      bad "cleanup() returned after ${ms} ms with gamescope still running (state $st): the next session gets EBUSY on card0" ;;
  esac

  # gamescope can ignore SIGTERM outright; the script must still exit so SDDM can relogin, and it
  # must not escalate to SIGKILL. Bound 1 s here.
  read -r ms st < <(run_cleanup 'trap "" TERM; while :; do sleep 0.1; done' 1)
  [ "$ms" -ge 900 ] && [ "$ms" -lt 3000 ] \
    && ok "a gamescope ignoring SIGTERM: gave up after ${ms} ms with the 1 s bound" \
    || bad "returned after ${ms} ms with a 1 s bound, expected ~1000"
  case "$st" in
    gone|Z) bad "the TERM-ignoring fake is gone (state $st): cleanup() escalated, which it must not" ;;
    *)      ok "...and did not escalate past SIGTERM (state $st)" ;;
  esac

  # The EXIT trap can run cleanup() after an explicit call; the second must be a clean no-op.
  out="$(/bin/sh -c '
    . "$1"; GS_RUNDIR="$2/td-rundir2"; mkdir -p "$GS_RUNDIR"; RETROFORGE_GAMESCOPE_STOP_TIMEOUT=10
    /bin/sh -c "exit 0" & GS_PID=$!
    cleanup && cleanup && echo twice-ok
  ' sh "$T/cleanup.sh" "$T" 2>&1)"
  [ "$out" = "twice-ok" ] && ok "a second cleanup() is a clean no-op" || bad "second call misbehaved: '${out:-<nothing>}'"
fi

# =================================================================================================
CASE="session unit limits"
UNIT="$ROOT/rootfs/overlay/usr/lib/systemd/system/retroforge-session.service"
grep -qx 'LimitMEMLOCK=infinity' "$UNIT" \
  && ok "no locked-memory cap for the session and its games (RPCS3 mlocks emulated memory)" \
  || bad "retroforge-session.service lacks LimitMEMLOCK=infinity: RPCS3 fails to lock memory at 8 MiB"

printf '\ntest-session.sh: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
