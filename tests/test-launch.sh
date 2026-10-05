#!/usr/bin/env bash
# Offline test for qforge-launch: how a ROM card starts an emulator AppImage, and how it stops.
#
#   tests/test-launch.sh
#
# WHY THIS EXISTS. Each rule in qforge-launch was a crash on hardware (DuckStation, Pocket Max,
# 2026-10-03), and none of them shows in a quick manual run that never presses Exit:
#
#   - exec'ing the AppImage / AppRun: Qt finds no platform plugin and aborts at start.
#   - the emulator inside the launcher's process group: OGUI's Reaper.reap() reaches it twice
#     (`kill -- -<launcher>` after `kill <emulator>`), DuckStation reads the second SIGTERM as
#     "force quit" and abort()s on Exit.
#   - forwarding SIGTERM from the launcher: the same second signal.
#   - the mount dying with SIGTERM: the emulator's files vanish while it shuts down.
#   - no sweep: a double Exit (SIGKILL) leaves a dead mount behind.
#
# The AppImage, the emulator and fusermount3 are fakes that record what happened. OGUI's Exit is
# replayed exactly as reaper.gd does it. Runs on the host with no root, no device and no build.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LAUNCH="$ROOT/rootfs/overlay/usr/bin/qforge-launch"
LAUNCH_CONF="$ROOT/rootfs/overlay/etc/qforge/launch.conf"
EMU_CONF="$ROOT/rootfs/overlay/etc/qforge/emulators/duckstation.conf"
SEED_DIR="$ROOT/rootfs/overlay/usr/share/qforge/emulators"
DS_SEED="$SEED_DIR/duckstation/settings.ini"
LAYOUT="$ROOT/rootfs/overlay/usr/share/user-tmpfiles.d/qforge-home.conf"

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

for f in "$LAUNCH" "$LAUNCH_CONF" "$EMU_CONF" "$DS_SEED" "$LAYOUT"; do
  [ -f "$f" ] || { echo "missing input: $f" >&2; exit 1; }
done
command -v setsid >/dev/null || { echo "setsid (util-linux) is required" >&2; exit 1; }

T="$(mktemp -d)" && [ -d "$T" ] || { echo "mktemp -d failed" >&2; exit 1; }
# Every launcher and fake records its PID in $T/pids; cleanup kills exactly those, never by pattern.
cleanup() {
  [ -n "${T:-}" ] && [ -d "$T" ] || return
  [ -f "$T/pids" ] && xargs -r kill -KILL < "$T/pids" 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT
mkdir -p "$T/bin" "$T/emus/duckstation" "$T/roms/psx"

# --- fakes --------------------------------------------------------------------------------------
# $T/mounts stands in for /proc/mounts: the fake AppImage adds its mount, fusermount3 removes it.
# fusermount3: record the call, drop the mount point from the table, succeed.
cat > "$T/bin/fusermount3" <<EOF
#!/bin/bash
echo "\$*" >> "$T/fusermount.log"
m="\${!#}"
awk -v m="\$m" '\$2 != m' "$T/mounts" > "$T/mounts.new" && mv "$T/mounts.new" "$T/mounts"
EOF

# The emulator: records how it was started, then runs until $T/stop-emu appears (exit 7) or it
# gets SIGTERM. On SIGTERM it shuts down "gracefully" for 0.3 s and then checks its own file is
# still there — what a real emulator reading from the mount needs.
cat > "$T/fake-emu" <<EOF
#!/bin/bash
log="$T/emu.log"
echo \$\$ >> "$T/pids"
read -r _ _ _ _ pgid sid _< <(cut -d' ' -f1-7 /proc/\$\$/stat)
{ echo "pid=\$\$"; echo "pgid=\$pgid"; echo "sid=\$sid"; echo "self=\$0"; printf 'arg=%s\n' "\$@"; } >> "\$log"
on_term() {
  echo term >> "\$log"
  sleep 0.3
  [ -e "\$0" ] && echo mount-alive >> "\$log" || echo mount-gone >> "\$log"
  exit 0
}
trap on_term TERM
echo up >> "\$log"
while [ ! -e "$T/stop-emu" ]; do sleep 0.05; done
exit 7
EOF

# The AppImage: with --appimage-mount it "mounts" (a directory holding the emulator), prints the
# path and serves until SIGHUP, like the type-2 runtime. A bash script cannot trap a signal it
# inherited as ignored, so it keeps qforge-launch's SIGTERM disposition just as the real runtime
# does; its SigIgn mask is logged to check that. Anything else is an exec of the AppImage itself.
cat > "$T/emus/duckstation/0.1-test.AppImage" <<EOF
#!/bin/bash
if [ "\${1-}" != "--appimage-mount" ]; then echo "exec-appimage \$*" >> "$T/appimage.log"; exit 1; fi
echo \$\$ >> "$T/pids"
mnt="$T/mnt.\$\$"; mkdir -p "\$mnt/usr/bin"; cp "$T/fake-emu" "\$mnt/usr/bin/duckstation-qt"
ln -s usr/bin/duckstation-qt "\$mnt/AppRun"
echo "0.1-test.AppImage \$mnt fuse.0.1-test.AppImage ro,nosuid,nodev 0 0" >> "$T/mounts"
echo "runtime=\$\$" >> "$T/appimage.log"
grep SigIgn /proc/\$\$/status >> "$T/appimage.log"
trap 'echo hup >> "$T/appimage.log"; rm -rf "\$mnt"; exit 0' HUP
echo "\$mnt"
while :; do sleep 0.05; done
EOF
chmod +x "$T/bin/fusermount3" "$T/fake-emu" "$T/emus/duckstation/0.1-test.AppImage"
ln -s 0.1-test.AppImage "$T/emus/duckstation/current"
: > "$T/mounts"

ROM="$T/roms/psx/Crash Team Racing (USA).chd"
: > "$ROM"

export PATH="$T/bin:$PATH"
export QFORGE_LAUNCH_CONF="$LAUNCH_CONF" QFORGE_EMU_CONF_DIR="$(dirname "$EMU_CONF")"
export QFORGE_EMU_DIR="$T/emus" QFORGE_MOUNTS="$T/mounts" QFORGE_EMU_SEED_DIR="$SEED_DIR"
# The launcher seeds first-run settings into $HOME: never let a test run reach the real one.
export HOME="$T/home"
unset XDG_CONFIG_HOME  # the player conf must be found under $HOME/.config
export QFORGE_LAUNCH_STATUS="$T/launch.status.default"
mkdir -p "$HOME"

reset_logs() { rm -f "$T"/{emu,appimage,fusermount}.log "$T/stop-emu"; }
field() { sed -n "s/^$1=//p" "$T/emu.log" | head -1; }
wait_for() { for _ in $(seq 100); do eval "$1" && return 0; sleep 0.05; done; return 1; }
emu_up() { grep -qx up "$T/emu.log" 2>/dev/null; }
# Start a launcher in the background and track it for cleanup; its PID lands in $lpid.
start_launcher() { "$LAUNCH" psx "$ROM" 2>"$T/launch.err" & lpid=$!; echo "$lpid" >> "$T/pids"; }
# Wait for a launcher with a deadline: a hung launcher must FAIL the suite, not hang `make test`.
reap_launcher() {
  wait_for "! kill -0 $1 2>/dev/null" || { bad "the launcher did not exit; killing it"; kill -KILL "$1" 2>/dev/null; }
  wait "$1"
}
# Descendants of a PID, depth first, like reaper.gd's pstree().
kids() { local c; for c in $(ps -o pid= --ppid "$1"); do echo "$c"; kids "$c"; done; }
# OpenGamepadUI Reaper.reap(pid, TERM): leaves inward, `kill -TERM -- -p` then `kill -TERM -- p`,
# each its own process; the reaper PID itself is skipped.
ogui_reap() {
  local pids p i; pids=($(kids "$1"))
  for ((i=${#pids[@]}-1; i>=0; i--)); do
    p=${pids[i]}
    /usr/bin/env kill -TERM -- "-$p" 2>/dev/null
    /usr/bin/env kill -TERM -- "$p" 2>/dev/null
  done
}

# =================================================================================================
CASE="bad invocations"
code() { "$LAUNCH" "$@" >/dev/null 2>&1; echo $?; }
[ "$(code)" = 2 ] && ok "no arguments: exit 2" || bad "no arguments did not exit 2"
[ "$(code psx)" = 2 ] && ok "one argument: exit 2" || bad "one argument did not exit 2"
[ "$(code 'psx;rm' "$ROM")" = 2 ] && ok "a system name with shell characters: exit 2" || bad "accepted system 'psx;rm'"
[ "$(code psx "$T/roms/psx/missing.chd")" = 2 ] && ok "a missing ROM: exit 2" || bad "a missing ROM did not exit 2"
[ "$(code nosuchsystem "$ROM")" = 2 ] && ok "a system launch.conf does not map: exit 2" || bad "an unmapped system did not exit 2"
[ "$(QFORGE_EMU_DIR="$T/none" code psx "$ROM")" = 3 ] \
  && ok "emulator not installed (no current): exit 3" || bad "a missing emulator did not exit 3"

# =================================================================================================
CASE="launch failure status (for the plugin's popup)"
# OGUI runs games through its reaper and never sees qforge-launch's exit code, so an exit-3 failure
# is also written to $QFORGE_LAUNCH_STATUS; the plugin's EXIT hook reads it and shows a popup.
ST="$T/launch.status"
echo "stale" > "$ST"
QFORGE_LAUNCH_STATUS="$ST" QFORGE_EMU_DIR="$T/none" "$LAUNCH" psx "$ROM" >/dev/null 2>&1
[ "$(cat "$ST" 2>/dev/null)" = "not-installed duckstation" ] \
  && ok "emulator not installed: status 'not-installed duckstation'" || bad "status was '$(cat "$ST" 2>/dev/null)'"
echo "stale" > "$ST"
QFORGE_LAUNCH_STATUS="$ST" QFORGE_EMU_DIR="$T/none" "$LAUNCH" --gui duckstation >/dev/null 2>&1
[ "$(cat "$ST" 2>/dev/null)" = "not-installed duckstation" ] \
  && ok "--gui of a missing emulator: same status" || bad "status was '$(cat "$ST" 2>/dev/null)'"
echo "stale" > "$ST"
QFORGE_LAUNCH_STATUS="$ST" "$LAUNCH" psx "$T/roms/psx/missing.chd" >/dev/null 2>&1
[ ! -e "$ST" ] && ok "a bad invocation (exit 2) clears the status and writes none" || bad "status left: '$(cat "$ST")'"

# =================================================================================================
CASE="config shipped in the image"
grep -qx 'psx=duckstation' "$LAUNCH_CONF" && ok "launch.conf maps psx to duckstation" || bad "launch.conf does not map psx=duckstation"
( set +u; BINARY= ARGS=(); . "$EMU_CONF"
  [ "$BINARY" = usr/bin/duckstation-qt ] || exit 1
  case " ${ARGS[*]} " in *" -batch "*) ;; *) exit 2 ;; esac
  [ "${ARGS[-1]}" = "--" ] || exit 3 )
case $? in
  0) ok "duckstation.conf: real binary (not AppRun), -batch, options end with --" ;;
  1) bad "duckstation.conf BINARY is not usr/bin/duckstation-qt" ;;
  2) bad "duckstation.conf lacks -batch: closing the game would leave DuckStation's UI, not OGUI" ;;
  *) bad "duckstation.conf ARGS do not end with -- (a ROM named '-x' would be read as an option)" ;;
esac

# DuckStation reads INI values as "key = value"; check the keys the hardware test needed.
ini() { awk -v sec="[$1]" -v key="$2" '$0 == sec {in_s=1; next} /^\[/ {in_s=0}
  in_s { split($0, kv, " = "); if (kv[1] == key) { print kv[2]; exit } }' "$DS_SEED"; }
[ "$(ini Main SetupWizardIncomplete)" = false ] && ok "duckstation seed: setup wizard skipped" || bad "duckstation seed does not skip the setup wizard"
[ "$(ini Main ConfirmPowerOff)" = false ] && ok "duckstation seed: no exit confirmation (a SIGTERM would wait on a dialog)" \
  || bad "duckstation seed lacks ConfirmPowerOff = false: OGUI's Exit and a session stop hang on 'are you sure?'"
[ "$(ini Main SaveStateOnExit)" = true ] && ok "duckstation seed: resume state saved on exit (off by default)" \
  || bad "duckstation seed lacks SaveStateOnExit = true: closing a game keeps no save state"
[ "$(ini AutoUpdater CheckAtStartup)" = false ] && ok "duckstation seed: self-updater off (QForge ships the version)" || bad "duckstation seed leaves DuckStation's auto-updater on"
[ "$(ini GPU Renderer)" = Vulkan ] && ok "duckstation seed: Vulkan (Turnip)" || bad "duckstation seed renderer is not Vulkan"
[ "$(ini InputSources SDL)" = true ] && [ "$(ini Pad1 Cross)" = SDL-0/A ] && [ "$(ini Pad1 Start)" = SDL-0/Start ] \
  && ok "duckstation seed: Port 1 mapped to the InputPlumber pad (SDL-0)" || bad "duckstation seed has no SDL-0 mapping for Port 1 (the wizard that would make one is skipped)"
[ "$(ini Hotkeys OpenPauseMenu)" = "SDL-0/Back & SDL-0/Start" ] \
  && ok "duckstation seed: Select+Start opens the pause menu (default is keyboard Escape only)" \
  || bad "duckstation seed: no controller binding for OpenPauseMenu, so Exit is unreachable with a pad"
grep -q 'SDL-0/Guide' "$DS_SEED" && bad "duckstation seed binds Guide, which OpenGamepadUI owns" || ok "duckstation seed leaves Guide to OGUI"

# The player folder layout (user tmpfiles): every system an emulator serves has its folders, and
# the seed points DuckStation at them (the player home is /home/player).
layout_has() { grep -Eq "^d[[:space:]]+%h/$1[[:space:]]" "$LAYOUT"; }
for sys in $(sed -n 's/^\([a-z0-9_]*\)=.*/\1/p' "$LAUNCH_CONF"); do
  missing=""
  for top in roms bios saves states; do layout_has "$top/$sys" || missing="$missing $top/$sys"; done
  [ -z "$missing" ] && ok "layout has roms/bios/saves/states for system '$sys'" || bad "layout lacks:$missing (system '$sys' is in launch.conf)"
done
for d in bios emulators; do layout_has "$d" && ok "layout has ~/$d" || bad "layout lacks ~/$d"; done
[ "$(ini BIOS SearchDirectory)" = /home/player/bios/psx ] && [ "$(ini GameList RecursivePaths)" = /home/player/roms/psx ] \
  && [ "$(ini MemoryCards Directory)" = /home/player/saves/psx ] && [ "$(ini Folders SaveStates)" = /home/player/states/psx ] \
  && ok "duckstation seed: BIOS, ROMs, memory cards and states in the shared layout" \
  || bad "duckstation seed folders do not match the layout"

# =================================================================================================
CASE="first-run settings (SEED)"
seeded="$HOME/.local/share/duckstation/settings.ini"
rm -rf "$HOME"; mkdir -p "$HOME"
reset_logs
start_launcher
wait_for emu_up || bad "the emulator never started: $(cat "$T/launch.err")"
cmp -s "$DS_SEED" "$seeded" && ok "first launch copies the image's settings.ini into ~/.local/share/duckstation" \
  || bad "first launch did not seed $seeded"
touch "$T/stop-emu"; reap_launcher "$lpid"
echo "player changed this" > "$seeded"
reset_logs
start_launcher
wait_for emu_up || bad "the emulator never started"
touch "$T/stop-emu"; reap_launcher "$lpid"
[ "$(cat "$seeded")" = "player changed this" ] && ok "an existing settings file is never overwritten" \
  || bad "a later launch overwrote the player's settings"
mkdir -p "$T/conf-bad"; cp "$LAUNCH_CONF" "$T/conf-bad/launch.conf"
for entry in "settings.ini:/etc/passwd" "settings.ini:../../escape" "settings.ini:" "settings.ini"; do
  printf 'BINARY=usr/bin/duckstation-qt\nARGS=(--)\nSEED=(%q)\n' "$entry" > "$T/conf-bad/duckstation.conf"
  [ "$(QFORGE_EMU_CONF_DIR="$T/conf-bad" code psx "$ROM")" = 2 ] \
    && ok "SEED entry '$entry' is refused (exit 2)" || bad "SEED entry '$entry' was accepted"
done
printf 'BINARY=usr/bin/duckstation-qt\nARGS=(--)\nSEED=(missing.ini:.config/x.ini)\n' > "$T/conf-bad/duckstation.conf"
[ "$(QFORGE_EMU_CONF_DIR="$T/conf-bad" code psx "$ROM")" = 2 ] && [ ! -e "$HOME/.config/x.ini" ] \
  && ok "a seed file the image lacks is an error, not a silent skip" || bad "a missing seed file was ignored"

# =================================================================================================
CASE="normal run, game closed by the emulator"
reset_logs
start_launcher
wait_for emu_up || bad "the emulator never started: $(cat "$T/launch.err")"
grep -q exec-appimage "$T/appimage.log" 2>/dev/null \
  && bad "the AppImage was exec'd (its AppRun would start the emulator: Qt aborts)" \
  || ok "the AppImage is only mounted, never exec'd"
self="$(field self)"
case "$self" in
  "$T"/mnt.*/usr/bin/duckstation-qt) ok "the emulator runs as <mount>/usr/bin/duckstation-qt" ;;
  *) bad "the emulator ran as '$self'" ;;
esac
mapfile -t args < <(sed -n 's/^arg=//p' "$T/emu.log")
[ "${args[*]}" = "-batch -fullscreen -- $ROM" ] && [ "${args[3]}" = "$ROM" ] \
  && ok "arguments: duckstation.conf ARGS, then the ROM path as ONE argument (spaces kept)" \
  || bad "arguments were: $(printf '[%s] ' "${args[@]}")"
[ "$(field pid)" = "$(field sid)" ] \
  && ok "the emulator leads its own session (setsid)" || bad "the emulator is not a session leader"
lpgid="$(ps -o pgid= -p "$lpid" | tr -d ' ')"
[ "$(field pgid)" != "$lpgid" ] \
  && ok "the emulator is outside the launcher's process group" || bad "the emulator shares the launcher's process group"
ign="$(sed -n 's/^SigIgn:[[:space:]]*//p' "$T/appimage.log")"
[ -n "$ign" ] && (( (16#$ign >> 14) & 1 )) \
  && ok "the mount runtime starts with SIGTERM ignored" || bad "the mount runtime does not ignore SIGTERM (SigIgn=${ign:-?})"
touch "$T/stop-emu"
reap_launcher "$lpid"; rc=$?
[ "$rc" = 7 ] && ok "the launcher exits with the emulator's status" || bad "launcher exited $rc, the emulator 7"
[ ! -e "$QFORGE_LAUNCH_STATUS" ] && ok "a launch that ran leaves no failure status" || bad "status after a normal run: $(cat "$QFORGE_LAUNCH_STATUS")"
# The fake fusermount3 succeeds at once, so the launcher may exit before the fake runtime has run
# its HUP trap (the real fusermount3 -u fails until the runtime is gone, which the launcher waits for).
wait_for 'grep -qx hup "$T/appimage.log"' \
  && ok "the mount runtime got SIGHUP after the emulator exited" || bad "the mount runtime was never released"
mnt="${self%/usr/bin/duckstation-qt}"
grep -qx -- "-u $mnt" "$T/fusermount.log" 2>/dev/null \
  && ok "fusermount3 -u <mount> after the emulator exited" || bad "no fusermount3 -u $mnt (log: $(cat "$T/fusermount.log" 2>/dev/null))"

# =================================================================================================
CASE="OGUI Exit (Reaper.reap replayed)"
reset_logs
# A stand-in for OGUI's reaper: the parent whose tree reap() walks, skipped itself. The launcher is
# made a process-group leader under it (setsid -w), the worst case: reap() then also signals
# `-<launcher>`, and anything left in the launcher's group would get a THIRD SIGTERM.
setsid bash -c 'echo $$ >> "$2/pids"; setsid -w "$0" psx "$1"; echo "launcher-rc=$?" >> "$2/appimage.log"' \
  "$LAUNCH" "$ROM" "$T" 2>"$T/launch.err" &
reaper=$!
echo "$reaper" >> "$T/pids"
wait_for emu_up || bad "the emulator never started: $(cat "$T/launch.err")"
ogui_reap "$reaper"
wait_for 'grep -q "^launcher-rc=" "$T/appimage.log" 2>/dev/null' || bad "the launcher did not exit after reap"
n_term="$(grep -cx term "$T/emu.log")"
# reap() aims two kills at a group-leader emulator (its own -pid and pid, back to back; DuckStation
# sees them coalesced). More means it also shares a signalled group. A COUNT cannot tell "back to
# back" from "one more, later through -<launcher>" — that is what crashed — so the guard against it
# is the session/group check in the normal-run case above; this one bounds the count and checks the
# mount outlives the shutdown.
[ "$n_term" -ge 1 ] && [ "$n_term" -le 2 ] \
  && ok "the emulator got OGUI's SIGTERM ($n_term delivered, at most reap()'s own two)" \
  || bad "the emulator got $n_term SIGTERMs from one reap (expected 1-2)"
grep -qx mount-alive "$T/emu.log" \
  && ok "the mount stayed up while the emulator shut down" || bad "the mount vanished during the emulator's shutdown"
wait_for 'grep -qx hup "$T/appimage.log"' \
  && ok "the mount was released afterwards (SIGHUP)" || bad "the mount was not released after reap"

# =================================================================================================
CASE="no forwarding"
reset_logs
start_launcher
wait_for emu_up || bad "the emulator never started"
kill -TERM "$lpid"; sleep 0.4
grep -qx term "$T/emu.log" \
  && bad "SIGTERM to the launcher reached the emulator (a second Ctrl+C on OGUI's Exit)" \
  || ok "SIGTERM to the launcher alone is not forwarded to the emulator"
kill -0 "$lpid" 2>/dev/null && ok "the launcher keeps waiting for the emulator after SIGTERM" || bad "the launcher exited on SIGTERM, leaving the emulator and mount behind"
touch "$T/stop-emu"; reap_launcher "$lpid"

# =================================================================================================
CASE="CPU pinning (--cpus big)"
# A fake /sys/devices/system/cpu: online list + per-CPU cpu_capacity (offline CPUs have none).
mkcpus() {  # mkcpus <online> <cpu:capacity>...
  rm -rf "$T/cpu"; mkdir -p "$T/cpu"; echo "$1" > "$T/cpu/online"; shift
  local e; for e in "$@"; do mkdir -p "$T/cpu/cpu${e%%:*}"; echo "${e#*:}" > "$T/cpu/cpu${e%%:*}/cpu_capacity"; done
}
# taskset: record the CPU list, then run the rest like the real one (exec keeps the PID).
cat > "$T/bin/taskset" <<EOF
#!/bin/bash
[ "\$1" = -c ] || { echo "taskset: unexpected \$*" >> "$T/taskset.log"; exit 1; }
echo "cpus=\$2" >> "$T/taskset.log"; shift 2; exec "\$@"
EOF
chmod +x "$T/bin/taskset"
pinned_run() {  # one launch with --cpus big and the fake topology; prints the taskset list or "none"
  rm -f "$T/taskset.log"; reset_logs
  QFORGE_CPU_ROOT="$T/cpu" "$LAUNCH" --cpus big psx "$ROM" 2>"$T/launch.err" & lpid=$!; echo "$lpid" >> "$T/pids"
  wait_for emu_up || bad "the emulator never started: $(cat "$T/launch.err")"
  touch "$T/stop-emu"; reap_launcher "$lpid" >/dev/null
  sed -n 's/^cpus=//p' "$T/taskset.log" 2>/dev/null | grep . || echo none
}
# SM8250 (MANGMI Pocket Max, measured): 4 little 284, 3 big 871, 1 prime 1024.
mkcpus 0-7 0:284 1:284 2:284 3:284 4:871 5:871 6:871 7:1024
[ "$(pinned_run)" = "4,5,6,7" ] && ok "SM8250: pinned to cpu4-7 (big + prime, not the prime core alone)" || bad "SM8250 pinned to '$(sed -n 's/^cpus=//p' "$T/taskset.log")'"
[ "$(field pid)" = "$(field sid)" ] && ok "pinned, the emulator still leads its own session (taskset execs)" || bad "taskset broke the emulator's session"
# Fast cores numbered first (not every SoC numbers slowest-first): capacity decides, not the index.
mkcpus 0-5 0:1024 1:1024 2:512 3:512 4:512 5:512
[ "$(pinned_run)" = "0,1" ] && ok "fast cores numbered first are still found (by capacity, not CPU number)" || bad "pinned to the wrong cores when fast ones come first"
# PowerStation's core count of 4 offlines the fast cores first: nothing fast is online.
mkcpus 0-3 0:284 1:284 2:284 3:284
[ "$(pinned_run)" = none ] && grep -q "not pinning" "$T/launch.err" \
  && ok "core-count limit left only little cores: not pinned, and says why" || bad "pinned with no fast core online"
# Partly limited: online list with gaps.
mkcpus 0-3,7 0:284 1:284 2:284 3:284 7:1024
[ "$(pinned_run)" = "7" ] && ok "online list with gaps (0-3,7) is parsed" || bad "gap in the online list mis-parsed"
# Homogeneous SoC: nothing to prefer.
mkcpus 0-3 0:1024 1:1024 2:1024 3:1024
[ "$(pinned_run)" = none ] && ok "all cores alike: not pinned" || bad "pinned on a homogeneous SoC"
# Without --cpus (and nothing in the image can ask for it) nothing is pinned.
mkcpus 0-7 0:284 1:284 2:284 3:284 4:871 5:871 6:871 7:1024
rm -f "$T/taskset.log"; reset_logs
QFORGE_CPU_ROOT="$T/cpu" start_launcher; wait_for emu_up; touch "$T/stop-emu"; reap_launcher "$lpid"
[ ! -e "$T/taskset.log" ] && ok "no --cpus: no taskset (pinning is never the default)" || bad "pinned without --cpus"
[ "$(code --cpus fast psx "$ROM")" = 2 ] && ok "--cpus fast (unknown value) is refused: exit 2" || bad "accepted --cpus fast"
[ "$(code --cpus)" = 2 ] && ok "--cpus with no value: exit 2" || bad "accepted a bare --cpus"
[ "$(code --cpus big psx)" = 2 ] && ok "--cpus big with a missing ROM argument: exit 2" || bad "accepted --cpus big psx"
grep -rqs '^CPUS=' "$(dirname "$EMU_CONF")" && bad "an emulator conf in the image sets CPUS: pinning must stay the player's choice" \
  || ok "no emulator conf in the image pins anything"

# =================================================================================================
CASE="player's emulator default (CPUS=)"
# Settings > Emulators writes ~/.config/qforge/emulators/<emu>.conf; a game's --cpus overrides it
# (Game settings > QForge: emulator default / on = --cpus big / off = --cpus all).
PCONF="$HOME/.config/qforge/emulators/duckstation.conf"
cpus_run() {  # one launch with the given arguments and the fake topology; prints the taskset list or "none"
  rm -f "$T/taskset.log"; reset_logs
  QFORGE_CPU_ROOT="$T/cpu" "$LAUNCH" "$@" 2>"$T/launch.err" & lpid=$!; echo "$lpid" >> "$T/pids"
  wait_for emu_up || bad "the emulator never started: $(cat "$T/launch.err")"
  touch "$T/stop-emu"; reap_launcher "$lpid" >/dev/null
  sed -n 's/^cpus=//p' "$T/taskset.log" 2>/dev/null | grep . || echo none
}
mkcpus 0-7 0:284 1:284 2:284 3:284 4:871 5:871 6:871 7:1024
mkdir -p "$(dirname "$PCONF")"
rm -f "$PCONF"
[ "$(cpus_run psx "$ROM")" = none ] && ok "no player conf: not pinned" || bad "pinned with no player conf"
echo "CPUS=all" > "$PCONF"
[ "$(cpus_run psx "$ROM")" = none ] && ok "CPUS=all: not pinned" || bad "pinned with CPUS=all"
printf '# set by Settings > Emulators\nCPUS=big\n' > "$PCONF"
[ "$(cpus_run psx "$ROM")" = "4,5,6,7" ] && ok "CPUS=big: a game with no override is pinned" || bad "CPUS=big did not pin a ROM launch"
[ "$(cpus_run --gui duckstation)" = "4,5,6,7" ] && ok "CPUS=big: Open (--gui) is pinned too" || bad "CPUS=big did not pin --gui"
[ "$(cpus_run --cpus all psx "$ROM")" = none ] && ok "a game's --cpus all beats the emulator's CPUS=big" || bad "--cpus all did not override CPUS=big"
echo "CPUS=all" > "$PCONF"
[ "$(cpus_run --cpus big psx "$ROM")" = "4,5,6,7" ] && ok "a game's --cpus big beats the emulator's CPUS=all" || bad "--cpus big did not override CPUS=all"
printf 'CPUS=fast\n' > "$PCONF"
[ "$(cpus_run psx "$ROM")" = none ] && grep -q "ignoring" "$T/launch.err" \
  && ok "an unknown CPUS value is ignored (not pinned) and reported" || bad "a bad CPUS value was not ignored with a warning"
printf 'CPUS=big\n$(touch %s/pwned)\n' "$T" > "$PCONF"
cpus_run psx "$ROM" >/dev/null
[ ! -e "$T/pwned" ] && ok "the player conf is read, never run as shell" || bad "the player conf was executed"
rm -f "$PCONF"

# =================================================================================================
CASE="emulator GUI (--gui)"
# The plugin store's Open: the emulator's own UI with no ROM, for the settings OGUI does not expose.
# Same mount / setsid / exit handling as a ROM; GUI_ARGS from the emulator conf instead of ARGS.
[ "$(code --gui)" = 2 ] && ok "--gui with no emulator: exit 2" || bad "accepted a bare --gui"
[ "$(code --gui 'duck;rm')" = 2 ] && ok "--gui with shell characters in the name: exit 2" || bad "accepted --gui 'duck;rm'"
[ "$(code --gui ../duckstation)" = 2 ] && ok "--gui with a path in the name: exit 2" || bad "accepted --gui ../duckstation"
[ "$(code --gui nosuchemu)" = 2 ] && ok "--gui with no conf for the emulator: exit 2" || bad "accepted an unknown emulator"
[ "$(code --gui duckstation "$ROM")" = 2 ] && ok "--gui with a ROM too: exit 2" || bad "accepted --gui duckstation <rom>"
[ "$(QFORGE_EMU_DIR="$T/none" code --gui duckstation)" = 3 ] \
  && ok "--gui of an emulator that is not installed: exit 3" || bad "--gui of a missing emulator did not exit 3"
( set +u; BINARY= ARGS=() GUI_ARGS=(); . "$EMU_CONF"
  [ ${#GUI_ARGS[@]} -gt 0 ] || exit 1
  case " ${GUI_ARGS[*]} " in *" -batch "*) exit 2 ;; esac
  case " ${GUI_ARGS[*]} " in *" -bigpicture "*) ;; *) exit 3 ;; esac )
case $? in
  0) ok "duckstation.conf GUI_ARGS: Big Picture (pad-driven), no -batch" ;;
  1) bad "duckstation.conf sets no GUI_ARGS" ;;
  2) bad "duckstation.conf GUI_ARGS has -batch: with no game, DuckStation would quit at once" ;;
  *) bad "duckstation.conf GUI_ARGS lacks -bigpicture: the desktop UI needs a mouse" ;;
esac
rm -rf "$HOME"; mkdir -p "$HOME"
reset_logs
"$LAUNCH" --gui duckstation 2>"$T/launch.err" & lpid=$!; echo "$lpid" >> "$T/pids"
wait_for emu_up || bad "the emulator never started: $(cat "$T/launch.err")"
cmp -s "$DS_SEED" "$HOME/.local/share/duckstation/settings.ini" \
  && ok "--gui seeds first-run settings too (the GUI may be the first start)" || bad "--gui did not seed settings.ini"
self="$(field self)"
case "$self" in
  "$T"/mnt.*/usr/bin/duckstation-qt) ok "--gui runs <mount>/usr/bin/duckstation-qt, not the AppImage" ;;
  *) bad "--gui ran '$self'" ;;
esac
mapfile -t args < <(sed -n 's/^arg=//p' "$T/emu.log")
( set +u; GUI_ARGS=(); . "$EMU_CONF"; [ "${args[*]}" = "${GUI_ARGS[*]}" ] ) \
  && ok "--gui arguments are exactly the conf's GUI_ARGS (no ROM, no -batch)" \
  || bad "--gui arguments were: $(printf '[%s] ' "${args[@]}")"
[ "$(field pid)" = "$(field sid)" ] && ok "--gui: the emulator leads its own session (setsid)" || bad "--gui: not a session leader"
touch "$T/stop-emu"
reap_launcher "$lpid"; rc=$?
[ "$rc" = 7 ] && ok "--gui: the launcher exits with the emulator's status" || bad "--gui: launcher exited $rc, the emulator 7"
wait_for 'grep -qx hup "$T/appimage.log"' && grep -q -- "^-u $T/mnt" "$T/fusermount.log" 2>/dev/null \
  && ok "--gui: the mount is released after the emulator exits" || bad "--gui: the mount was not released"
rm -f "$T/taskset.log"; reset_logs
QFORGE_CPU_ROOT="$T/cpu" "$LAUNCH" --cpus big --gui duckstation 2>"$T/launch.err" & lpid=$!; echo "$lpid" >> "$T/pids"
wait_for emu_up || bad "the emulator never started: $(cat "$T/launch.err")"
touch "$T/stop-emu"; reap_launcher "$lpid"
[ "$(sed -n 's/^cpus=//p' "$T/taskset.log" 2>/dev/null)" = "4,5,6,7" ] \
  && ok "--cpus big --gui pins the GUI like a game" || bad "--cpus big --gui was not pinned"

# =================================================================================================
CASE="stale mounts"
reset_logs
printf '%s\n' \
  "0.1-test.AppImage $T/mnt.dead fuse.0.1-test.AppImage ro,nosuid,nodev 0 0" \
  "Other.AppImage $T/mnt.other fuse.Other.AppImage ro,nosuid,nodev 0 0" > "$T/mounts"
start_launcher
wait_for emu_up || bad "the emulator never started"
touch "$T/stop-emu"; reap_launcher "$lpid"
grep -qx -- "-uz $T/mnt.dead" "$T/fusermount.log" \
  && ok "a dead mount of this AppImage is lazily unmounted before mounting" || bad "the dead mount was not swept"
grep -q "mnt.other" "$T/fusermount.log" \
  && bad "another AppImage's mount was touched" || ok "other AppImages' mounts are left alone"
: > "$T/mounts"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
