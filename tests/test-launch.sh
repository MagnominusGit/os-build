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
SEED_DIR="$ROOT/rootfs/overlay/usr/share/qforge/emulators"
DS_DEF="$SEED_DIR/duckstation/emulator.json"
DS_SEED="$SEED_DIR/duckstation/settings.ini"
AX_SEED="$SEED_DIR/armsx2/PCSX2.ini"
LAYOUT="$ROOT/rootfs/overlay/usr/share/user-tmpfiles.d/qforge-home.conf"

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }
# jget <emulator.json> <key>: the key's value as JSON (lists as ["a", "b"]).
jget() { python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])).get(sys.argv[2])))' "$1" "$2"; }

for f in "$LAUNCH" "$LAUNCH_CONF" "$DS_DEF" "$DS_SEED" "$AX_SEED" "$LAYOUT"; do
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
{ echo "pid=\$\$"; echo "pgid=\$pgid"; echo "sid=\$sid"; echo "self=\$0"; echo "vk=\${VK_DRIVER_FILES-}"
  echo "sharun_sys=\${SHARUN_ALLOW_SYS_VKICD-}"; echo "no_updates=\${DISABLE_AUTO_UPDATES-}"; echo "core=\$(ulimit -c)"
  printf 'arg=%s\n' "\$@"; } >> "\$log"
if [ "\${1-}" = --fake-install ]; then  # an install step (emulator.json "install"), not a game
  echo "install \$*" >> "$T/install.log"
  echo "core-limit=\$(ulimit -c)" >> "$T/install.log"
  if [ -f "$T/install-crash" ]; then  # RPCS3: installs, then aborts in a destructor on its way out
    mkdir -p "\$HOME/.config/fake"; : > "\$HOME/.config/fake/fw-ok"; kill -ABRT \$\$
  fi
  if [ -f "$T/install-slow" ]; then  # a long install that finishes cleanly on SIGTERM (marker written)
    trap 'mkdir -p "\$HOME/.config/fake"; : > "\$HOME/.config/fake/slow-ok"; exit 0' TERM
    : > "$T/install-running"; while :; do sleep 0.05; done
  fi
  [ -f "$T/install-works" ] && mkdir -p "\$HOME/.config/fake" && : > "\$HOME/.config/fake/fw-ok"
  exit 0  # RPCS3's --installfw exits 0 even when it failed: success is the marker file
fi
on_term() {
  echo term >> "\$log"
  # An emulator the first SIGTERM does not end, or (deaf) none does: melonDS / Azahar with their
  # second window open.
  if [ -f "$T/deaf" ] || { [ -f "$T/two-terms" ] && [ ! -f "$T/one-term-seen" ]; }; then : > "$T/one-term-seen"; echo term-ignored >> "\$log"; return; fi
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
# RPCS3's DwarFS runtime prints the mount point BEFORE the filesystem is up (HW 2026-10-07).
[ -f "$T/print-early" ] && { echo "$T/mnt.\$\$"; sleep 0.4; }
mnt="$T/mnt.\$\$"; mkdir -p "\$mnt/usr/bin"; cp "$T/fake-emu" "\$mnt/usr/bin/duckstation-qt"
ln -s usr/bin/duckstation-qt "\$mnt/AppRun"
if [ -f "$T/sharun-hook" ]; then mkdir -p "\$mnt/bin" "\$mnt/share"; cp "$T/sharun-hook" "\$mnt/bin/\$(cat "$T/sharun-hook-name" 2>/dev/null || echo 01-path-mapping-hardcoded.hook)"; fi
echo "0.1-test.AppImage \$mnt fuse.0.1-test.AppImage ro,nosuid,nodev 0 0" >> "$T/mounts"
echo "runtime=\$\$" >> "$T/appimage.log"
grep SigIgn /proc/\$\$/status >> "$T/appimage.log"
trap 'echo hup >> "$T/appimage.log"; rm -rf "\$mnt"; exit 0' HUP
[ -f "$T/slow-mount" ] && { echo slow-mounting >> "$T/appimage.log"; while [ -f "$T/slow-mount" ]; do sleep 0.05; done; }
echo "\$mnt"
while :; do sleep 0.05; done
EOF
chmod +x "$T/bin/fusermount3" "$T/fake-emu" "$T/emus/duckstation/0.1-test.AppImage"
ln -s 0.1-test.AppImage "$T/emus/duckstation/current"
: > "$T/mounts"

ROM="$T/roms/psx/Crash Team Racing (USA).chd"
: > "$ROM"

export PATH="$T/bin:$PATH"
export QFORGE_LAUNCH_CONF="$LAUNCH_CONF" QFORGE_EMU_DATA_DIR="$SEED_DIR"
export QFORGE_EMU_DIR="$T/emus" QFORGE_MOUNTS="$T/mounts"
# The launcher seeds first-run settings into $HOME: never let a test run reach the real one.
export HOME="$T/home"
unset XDG_CONFIG_HOME  # the player conf must be found under $HOME/.config
export QFORGE_LAUNCH_STATUS="$T/launch.status.default"
mkdir -p "$HOME"

reset_logs() { rm -f "$T"/{emu,appimage,fusermount}.log "$T/stop-emu" "$T/one-term-seen"; }
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
[ "$(jget "$DS_DEF" format)" = '"appimage"' ] && [ "$(jget "$DS_DEF" binary)" = '"usr/bin/duckstation-qt"' ] \
  && ok "duckstation: an AppImage, its real binary (not AppRun)" || bad "duckstation emulator.json format/binary: $(jget "$DS_DEF" format) $(jget "$DS_DEF" binary)"
[ "$(jget "$DS_DEF" args)" = '["-batch", "-fullscreen", "--", "{rom}"]' ] \
  && ok "duckstation args: -batch (back to OGUI on close), -- before the ROM" || bad "duckstation args: $(jget "$DS_DEF" args)"

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
# A scripts-format emulator's games (PortMaster's ports) keep their data in their own folders:
# only roms/<system> for those.
for sys in $(sed -n 's/^\([a-z0-9_]*\)=.*/\1/p' "$LAUNCH_CONF"); do
  missing="" tops="roms bios saves states"
  emu="$(sed -n "s/^$sys=//p" "$LAUNCH_CONF" | tail -1)"
  [ "$(jget "$SEED_DIR/$emu/emulator.json" format 2>/dev/null)" = '"scripts"' ] && tops="roms"
  for top in $tops; do layout_has "$top/$sys" || missing="$missing $top/$sys"; done
  [ -z "$missing" ] && ok "layout has ${tops// /\/} for system '$sys'" || bad "layout lacks:$missing (system '$sys' is in launch.conf)"
done
for d in bios emulators; do layout_has "$d" && ok "layout has ~/$d" || bad "layout lacks ~/$d"; done
# PortMaster and its ports find themselves through hardcoded /roms/ports paths (its generic
# default): the image links /roms to the player's roms, and roms/ports exists for them.
layout_has roms/ports && ok "layout has ~/roms/ports (PortMaster and its ports)" || bad "layout lacks ~/roms/ports"
[ "$(readlink "$ROOT/rootfs/overlay/roms" 2>/dev/null)" = /home/player/roms ] \
  && ok "the image links /roms to /home/player/roms (PortMaster's /roms/ports)" \
  || bad "rootfs/overlay/roms is not a symlink to /home/player/roms: PortMaster would look in an empty read-only /roms"
[ "$(ini BIOS SearchDirectory)" = /home/player/bios/psx ] && [ "$(ini GameList RecursivePaths)" = /home/player/roms/psx ] \
  && [ "$(ini MemoryCards Directory)" = /home/player/saves/psx ] && [ "$(ini Folders SaveStates)" = /home/player/states/psx ] \
  && ok "duckstation seed: BIOS, ROMs, memory cards and states in the shared layout" \
  || bad "duckstation seed folders do not match the layout"

# ARMSX2 (PCSX2's settings code): the keys its first runs on hardware needed (2026-10-05).
axini() { awk -v sec="[$1]" -v key="$2" '$0 == sec {in_s=1; next} /^\[/ {in_s=0}
  in_s { split($0, kv, " = "); if (kv[1] == key) { print kv[2]; exit } }' "$AX_SEED"; }
[ "$(axini UI SettingsVersion)" = 1 ] && ok "armsx2 seed: SettingsVersion 1 (otherwise ARMSX2 offers to reset it all to defaults)" \
  || bad "armsx2 seed lacks [UI] SettingsVersion = 1: ARMSX2 treats the file as broken and resets it"
[ "$(axini UI SetupWizardIncomplete)" = false ] && ok "armsx2 seed: setup wizard skipped" || bad "armsx2 seed does not skip the setup wizard"
[ "$(axini UI ConfirmShutdown)" = false ] && ok "armsx2 seed: no exit confirmation (a SIGTERM would wait on a dialog)" \
  || bad "armsx2 seed lacks ConfirmShutdown = false: OGUI's Exit could hang on 'are you sure?'"
[ "$(axini EmuCore SaveStateOnShutdown)" = true ] && ok "armsx2 seed: resume state saved on exit" || bad "armsx2 seed lacks SaveStateOnShutdown = true"
[ "$(axini AutoUpdater CheckAtStartup)" = false ] && ok "armsx2 seed: self-updater off (QForge ships the version)" || bad "armsx2 seed leaves ARMSX2's auto-updater on"
[ -z "$(axini EmuCore/GS Renderer)" ] && ok "armsx2 seed: renderer left on Automatic (forcing it shows a warning at every start)" \
  || bad "armsx2 seed forces a renderer: ARMSX2 warns 'Graphics API is not set to Automatic' at every start"
[ -z "$(axini Filenames BIOS)" ] && ok "armsx2 seed: no BIOS file named (Auto picks one from ~/bios/ps2)" || bad "armsx2 seed names a BIOS file the player may not have"
[ "$(axini InputSources SDL)" = true ] && [ "$(axini Pad1 Type)" = DualShock2 ] && [ "$(axini Pad1 Cross)" = SDL-0/FaceSouth ] \
  && [ "$(axini Pad1 Start)" = SDL-0/Start ] && ok "armsx2 seed: Port 1 is a DualShock 2 on the InputPlumber pad (SDL-0)" \
  || bad "armsx2 seed has no SDL-0 DualShock 2 mapping for Port 1"
[ "$(axini Hotkeys OpenPauseMenu)" = "SDL-0/Back & SDL-0/Start" ] && ok "armsx2 seed: Select+Start opens the pause menu" \
  || bad "armsx2 seed: no controller binding for OpenPauseMenu"
grep -q 'SDL-0/Guide' "$AX_SEED" && bad "armsx2 seed binds Guide, which OpenGamepadUI owns" || ok "armsx2 seed leaves Guide to OGUI"
[ "$(axini Folders Bios)" = /home/player/bios/ps2 ] && [ "$(axini GameList RecursivePaths)" = /home/player/roms/ps2 ] \
  && [ "$(axini Folders MemoryCards)" = /home/player/saves/ps2 ] && [ "$(axini Folders Savestates)" = /home/player/states/ps2 ] \
  && ok "armsx2 seed: BIOS, ROMs, memory cards and states in the shared layout" || bad "armsx2 seed folders do not match the layout"
AX_DEF="$SEED_DIR/armsx2/emulator.json"
[ "$(jget "$AX_DEF" format)" = '"appimage"' ] && [ "$(jget "$AX_DEF" binary)" = '"usr/bin/armsx2-qt"' ] \
  && [ "$(jget "$AX_DEF" args)" = '["-batch", "-nogui", "-fullscreen", "--", "{rom}"]' ] \
  && ok "armsx2: real binary, -batch -nogui, -- before the ROM" || bad "armsx2 emulator.json: $(jget "$AX_DEF" binary) $(jget "$AX_DEF" args)"
[ "$(jget "$AX_DEF" seed)" = '[{"file": "PCSX2.ini", "to": ".config/ARMSX2/inis/PCSX2.ini"}]' ] \
  && ok "armsx2 seeds ~/.config/ARMSX2/inis/PCSX2.ini (where ARMSX2 reads it)" || bad "armsx2 seed: $(jget "$AX_DEF" seed)"

# Dolphin (2026-10-05): INI keys "Key = Value" in /usr/share/qforge/emulators/dolphin/*.ini.
DL_DIR="$SEED_DIR/dolphin"
dlini() { awk -v sec="[$2]" -v key="$3" '$0 == sec {in_s=1; next} /^\[/ {in_s=0}
  in_s { i = index($0, " = "); if (i && substr($0, 1, i - 1) == key) { print substr($0, i + 3); exit } }' "$DL_DIR/$1"; }
[ "$(dlini Dolphin.ini Interface ConfirmStop)" = False ] && ok "dolphin seed: no stop confirmation (a SIGTERM would wait on a dialog)" \
  || bad "dolphin seed lacks ConfirmStop = False"
[ "$(dlini Dolphin.ini Core GFXBackend)" = Vulkan ] && ok "dolphin seed: Vulkan (Dolphin's Linux default is OpenGL)" || bad "dolphin seed is not on Vulkan"
[ "$(dlini Dolphin.ini Analytics PermissionAsked)" = True ] && [ "$(dlini Dolphin.ini Analytics Enabled)" = False ] \
  && ok "dolphin seed: analytics asked and off (no opt-in dialog)" || bad "dolphin seed would open the analytics dialog"
[ "$(dlini Dolphin.ini General ISOPath0)" = /home/player/roms/gc ] && [ "$(dlini Dolphin.ini General ISOPath1)" = /home/player/roms/wii ] \
  && [ "$(dlini Dolphin.ini General NANDRootPath)" = /home/player/saves/wii ] && [ "$(dlini Dolphin.ini Core GCIFolderAPath)" = /home/player/saves/gc ] \
  && ok "dolphin seed: games, Wii NAND and GameCube cards in the shared layout" || bad "dolphin seed folders do not match the layout"
dev="$(dlini GCPadNew.ini GCPad1 Device)"
[ "$dev" = "SDL/0/Xbox One Elite 2 Controller" ] && [ "$(dlini WiimoteNew.ini Wiimote1 Device)" = "$dev" ] && [ "$(dlini Hotkeys.ini Hotkeys Device)" = "$dev" ] \
  && ok "dolphin seed: pad, Wii Remote and hotkeys on the InputPlumber pad (SDL)" || bad "dolphin seed devices differ or are not the SDL pad: '$dev'"
[ "$(dlini Hotkeys.ini Hotkeys General/Stop)" = "@(Back+Start)" ] && ok "dolphin seed: Select+Start stops the game" || bad "dolphin seed has no pad Stop hotkey"
grep -qE '^[^;].*= .*Guide' "$DL_DIR"/*.ini && bad "dolphin seed binds Guide, which OpenGamepadUI owns" || ok "dolphin seed leaves Guide to OGUI"
DL_DEF="$DL_DIR/emulator.json"
[ "$(jget "$DL_DEF" format)" = '"appimage-sharun"' ] && [ "$(jget "$DL_DEF" binary)" = '"bin/dolphin-emu"' ] \
  && ok "dolphin: a pkgforge sharun AppImage, its sharun entry (not AppRun and its self-updater)" \
  || bad "dolphin emulator.json format/binary: $(jget "$DL_DEF" format) $(jget "$DL_DEF" binary)"
[ "$(jget "$DL_DEF" args)" = '["-b", "-e", "{rom}"]' ] && ok "dolphin args: -b (back to OGUI on stop) -e <game>" || bad "dolphin args: $(jget "$DL_DEF" args)"
python3 -c 'import json,os,sys; d=json.load(open(sys.argv[1])); sys.exit(any(not os.path.isfile(os.path.join(sys.argv[2], s["file"])) for s in d["seed"]))' "$DL_DEF" "$DL_DIR" \
  && ok "dolphin: every seeded file is in the image" || bad "dolphin seeds a file that is not in $DL_DIR"

# =================================================================================================
CASE="every emulator definition"
# Each emulator.json must load (a refused definition only shows when a player starts a game) and
# seed only files the image has. With no download, --gui stops at "not installed" (exit 3) AFTER
# the definition was validated; a bad one is exit 2.
for def in "$SEED_DIR"/*/emulator.json; do
  emu="$(basename "$(dirname "$def")")"
  [ "$(QFORGE_EMU_DIR="$T/none" code --gui "$emu")" = 3 ] && ok "$emu: emulator.json is accepted" \
    || bad "$emu: emulator.json refused: $(QFORGE_EMU_DIR="$T/none" "$LAUNCH" --gui "$emu" 2>&1 | tail -1)"
  python3 -c 'import json,os,sys; d=json.load(open(sys.argv[1])); sys.exit(any(not os.path.isfile(os.path.join(sys.argv[2], s["file"])) for s in d.get("seed", [])))' \
    "$def" "$(dirname "$def")" && ok "$emu: every seeded file is in the image" || bad "$emu seeds a file that is not in the image"
done
for emu in $(sed -n 's/^[a-z0-9_]*=\([a-z0-9_-]*\)$/\1/p' "$LAUNCH_CONF" | sort -u); do
  [ -f "$SEED_DIR/$emu/emulator.json" ] && ok "launch.conf's $emu has a definition" || bad "launch.conf names $emu, which has no emulator.json"
done

# =================================================================================================
CASE="controller mappings"
# The pad every emulator sees is InputPlumber's virtual Xbox Elite (uinput 045e:0b00, xpad button
# order). Raw SDL joystick indices: b0 south, b1 east, b2 west, b3 north, b4 LB, b5 RB, b6 Select,
# b7 Start, b8 GUIDE, b9 L3, b10 R3; a0/a1 left stick, a2 LT, a3/a4 right stick, a5 RT; hat 0.
# SDL gamepad API: A0 B1 X2 Y3 Back4 Guide5 Start6. Face buttons map by POSITION (the system's
# bottom button on south...), Guide stays OpenGamepadUI's, and each emulator gets a pad way out
# (Select + Start where it can bind a combination). Checked line by line against the seeds, so a
# careless edit or a bad pin bump shows here, not on a handheld.
has() { grep -qxF -- "$2" "$SEED_DIR/$1" && ok "$1: $3" || bad "$1 lacks '$2' ($3)"; }
lacks() { grep -qE -- "$2" "$SEED_DIR/$1" && bad "$1: $3" || ok "$1: no $3"; }
# mGBA: raw indices, [gba.input.SDLB]; GBA A (right) east, B south.
has mgba/config.ini keyA=1 "GBA A on the east button (b1)"
has mgba/config.ini keyB=0 "GBA B on the south button (b0)"
has mgba/config.ini keySelect=6 "Select on b6"; has mgba/config.ini keyStart=7 "Start on b7"
has mgba/config.ini keyL=4 "L on LB"; has mgba/config.ini keyR=5 "R on RB"
lacks mgba/config.ini '^key[A-Za-z]+=8$' "binding on Guide (b8)"
# No single-button quit (R3 was too easy to hit, user 2026-10-06): mGBA and Snes9x cannot bind
# Select + Start, so OpenGamepadUI's Exit (Guide) is their way out.
[ ! -e "$SEED_DIR/mgba/qt.ini" ] && ! grep -q qt.ini "$SEED_DIR/mgba/emulator.json" \
  && ok "mgba: no pad quit shortcut seeded" || bad "mgba seeds a pad shortcut file (qt.ini)"
grep -q 'saves/{system}' "$SEED_DIR/mgba/emulator.json" && grep -q 'states/{system}' "$SEED_DIR/mgba/emulator.json" \
  && ok "mgba: per-system save and state folders from the card's system" || bad "mgba: saves/states not per system"
# Snes9x: raw indices; SNES B south, A east, Y west, X north.
has snes9x/snes9x.conf 'B = Joystick 1 Button 0' "SNES B on south"
has snes9x/snes9x.conf 'A = Joystick 1 Button 1' "SNES A on east"
has snes9x/snes9x.conf 'Y = Joystick 1 Button 2' "SNES Y on west"
has snes9x/snes9x.conf 'X = Joystick 1 Button 3' "SNES X on north"
has snes9x/snes9x.conf 'Up = Joystick 1 Axis 6 + 50%' "D-pad hat = axes 6/7 after the 6 real ones"
lacks snes9x/snes9x.conf '^b_quit' "single-button quit shortcut"
lacks snes9x/snes9x.conf '^b_[a-z_]+ = ' "binding under an internal b_* name (Snes9x reads Up, A, ...; b_* stays Unset)"
has snes9x/snes9x.conf 'FullscreenOnOpen = true' "fullscreen (no flag exists)"
lacks snes9x/snes9x.conf 'Button 8$' "binding on Guide (b8)"
# Snes9x runs its whole exit inside its SIGTERM handler: the sigdefer shim moves it to the main
# loop, and sharun only passes LD_PRELOAD on when SHARUN_ALLOW_LD_PRELOAD is set.
python3 -c 'import json,sys; e=json.load(open(sys.argv[1]))["env"]
sys.exit(not (e.get("LD_PRELOAD") == "/usr/lib/qforge/libqforge-sigdefer.so" and e.get("SHARUN_ALLOW_LD_PRELOAD") == "1"))' \
  "$SEED_DIR/snes9x/emulator.json" && ok "snes9x: the sigdefer shim is preloaded, through sharun" || bad "snes9x: sigdefer shim not preloaded (LD_PRELOAD + SHARUN_ALLOW_LD_PRELOAD)"
python3 -c 'import json,sys; e=json.load(open(sys.argv[1]))["env"]
sys.exit(not (e.get("LD_PRELOAD") == "/usr/lib/qforge/libqforge-hidemenu.so" and e.get("SHARUN_ALLOW_LD_PRELOAD") == "1"))' \
  "$SEED_DIR/melonds/emulator.json" && ok "melonds: the hidemenu shim is preloaded, through sharun" || bad "melonds: hidemenu shim not preloaded (LD_PRELOAD + SHARUN_ALLOW_LD_PRELOAD)"
# Dual-screen boards: melonDS's second window and Azahar's separate windows go to the second panel
# (gamescope 0041), and both need one more SIGTERM to exit with that window open.
has melonds/melonDS-dual-screen.toml '[Instance0.Window1]' "dual-screen seed: the second window section"
has melonds/melonDS-dual-screen.toml 'Enabled = true' "dual-screen seed: the second window enabled"
has melonds/melonDS-dual-screen.toml 'ScreenSizing = 5' "dual-screen seed: bottom screen alone in the second window"
has melonds/melonDS-dual-screen.toml 'ScreenSizing = 4' "dual-screen seed: top screen alone in the first window"
has azahar/qt-config-dual-screen.ini 'layout_option=4' "dual-screen seed: separate windows"
for emu in melonds azahar; do
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1]));
sys.exit(not (d.get("exit_resend") == 2 and all("dual_screen_file" in s for s in d["seed"])))' "$SEED_DIR/$emu/emulator.json" \
    && ok "$emu: dual-screen seed and exit_resend 2" || bad "$emu: no dual-screen seed or exit_resend"
done
# ClownMDEmu (md, segacd): fixed SDL gamepad layout, nothing to bind; one user folder per system.
has clownmdemu/configuration.ini '[Miscellaneous]' "the Miscellaneous section"
has clownmdemu/configuration.ini 'rewinding = off' "rewinding off (a rewind buffer every frame otherwise)"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); a=d["args"]
sys.exit(not ("-f" in a and a[a.index("-u") + 1] == "/home/player/.config/clownmdemu/{system}"
              and {s["to"] for s in d["seed"]} == {".config/clownmdemu/md/configuration.ini", ".config/clownmdemu/segacd/configuration.ini"}))' \
  "$SEED_DIR/clownmdemu/emulator.json" && ok "clownmdemu: fullscreen, a user folder per system, each seeded" \
  || bad "clownmdemu: args need -f and -u ~/.config/clownmdemu/{system}, with a seed per system"
for sys in md segacd; do
  grep -qxF "L \"%h/.config/clownmdemu/$sys/Save Data\" - - - - %h/saves/$sys" "$LAYOUT" \
    && ok "clownmdemu: $sys saves land in ~/saves/$sys" || bad "clownmdemu: no Save Data link for $sys in the layout"
done
# PPSSPP: SDL gamepad -> keycodes (A 189, B 190, X 191, Y 188, Guide 4); device 10.
has ppsspp/controls.ini 'Cross = 10-189' "Cross on south"; has ppsspp/controls.ini 'Circle = 10-190' "Circle on east"
has ppsspp/controls.ini 'Square = 10-191' "Square on west"; has ppsspp/controls.ini 'Triangle = 10-188' "Triangle on north"
has ppsspp/controls.ini 'L = 10-193' "L on LB (PPSSPP's SDL default leaves it dead)"; has ppsspp/controls.ini 'R = 10-192' "R on RB"
has ppsspp/controls.ini 'Pause = 10-196:10-197,1-111' "Select + Start opens the pause menu"
lacks ppsspp/controls.ini '10-4(,|:|$)' "binding on Guide (keycode 4)"
grep -q -- '--pause-menu-exit' "$SEED_DIR/ppsspp/emulator.json" && ok "ppsspp: the pause menu's Exit quits PPSSPP" || bad "ppsspp: no --pause-menu-exit"
# Flycast: raw indices; Dreamcast A south, B east, X west, Y north; picked by the SDL name.
has flycast/pad.cfg 'bind0 = 0:btn_a' "DC A on south"; has flycast/pad.cfg 'bind1 = 1:btn_b' "DC B on east"
has flycast/pad.cfg 'bind2 = 2:btn_x' "DC X on west"; has flycast/pad.cfg 'bind3 = 3:btn_y' "DC Y on north"
has flycast/pad.cfg 'bind0 = 6,7:btn_menu:0' "Select + Start opens the menu"
has flycast/pad.cfg 'triggers = 2,5' "LT/RT rest at the axis minimum"
lacks flycast/pad.cfg '^bind[0-9]+ = 8:' "binding on Guide (b8)"
grep -q '"to": ".config/flycast/mappings/SDL_Xbox One Elite 2 Controller.cfg"' "$SEED_DIR/flycast/emulator.json" \
  && ok "flycast: the mapping file is named after the pad's SDL name" || bad "flycast: mapping file name does not match the pad"
# melonDS: raw indices; DS A east, B south, X north, Y west.
has melonds/melonDS.toml 'A = 1' "DS A on east"; has melonds/melonDS.toml 'B = 0' "DS B on south"
has melonds/melonDS.toml 'X = 3' "DS X on north"; has melonds/melonDS.toml 'Y = 2' "DS Y on west"
has melonds/melonDS.toml 'Up = 17891585' "Up = hat 0 up OR left stick up"
lacks melonds/melonDS.toml '^[A-Za-z_]+ = 8$' "binding on Guide (b8)"
# Azahar: SDL gamepad numbers, any pad (maptype:all, no GUID); 3DS A east, B south, X north, Y west.
has azahar/qt-config.ini 'profiles\1\button_a="engine:sdl,api:controller,maptype:all,button:1"' "3DS A on east"
has azahar/qt-config.ini 'profiles\1\button_b="engine:sdl,api:controller,maptype:all,button:0"' "3DS B on south"
has azahar/qt-config.ini 'profiles\1\button_x="engine:sdl,api:controller,maptype:all,button:3"' "3DS X on north"
has azahar/qt-config.ini 'profiles\1\button_y="engine:sdl,api:controller,maptype:all,button:2"' "3DS Y on west"
has azahar/qt-config.ini 'Shortcuts\Main%20Window\Exit%20Azahar\controller_keyseq="engine:sdl,api:controller,maptype:all,button:4||engine:sdl,api:controller,maptype:all,button:6"' "Select + Start quits Azahar"
has azahar/qt-config.ini 'confirmClose=false' "no exit confirmation"
has azahar/qt-config.ini 'layouts_to_cycle=2, 1, 3, 0' "L3 cycles large / single screen / side by side / stacked (no separate windows)"
lacks azahar/qt-config.ini 'button:5[^0-9]' "binding on Guide (gamepad button 5)"
lacks azahar/qt-config.ini 'engine:sdl,(api:controller,)?(guid|port):' "binding tied to a GUID or port"
# Cemu: SDL gamepad numbers; Wii U A east, B south, X north, Y west; the pad is found by GUID.
has cemu/controller0.xml '            <entry><mapping>1</mapping><button>1</button></entry>' "Wii U A on east"
has cemu/controller0.xml '            <entry><mapping>2</mapping><button>0</button></entry>' "Wii U B on south"
has cemu/controller0.xml '            <entry><mapping>3</mapping><button>3</button></entry>' "Wii U X on north"
has cemu/controller0.xml '            <entry><mapping>4</mapping><button>2</button></entry>' "Wii U Y on west"
has cemu/controller0.xml '        <uuid>0_030010f85e040000000b000001000000</uuid>' "the pad's SDL GUID (computed: recheck on hardware)"
lacks cemu/controller0.xml '<button>5</button>' "binding on Guide (gamepad button 5)"
has cemu/settings.xml '        <api>3</api>' "audio on Cubeb (a missing key means DirectSound: no game starts)"
has cemu/settings.xml '        <TVVolume>100</TVVolume>' "full TV volume (a missing key means 20%)"
# xemu: SDL gamepad, its own mapping for our pad without guide; Back + Start is xemu's menu.
python3 -c 'import json,sys; m=json.load(open(sys.argv[1]))["env"]["SDL_GAMECONTROLLERCONFIG"]
f=m.split(","); sys.exit(not (f[0] == "030000005e040000000b000001000000" and "a:b0" in f and "b:b1" in f and "x:b2" in f
  and "y:b3" in f and "back:b6" in f and "start:b7" in f and not any(x.startswith("guide:") for x in f)
  and not any(x.startswith("crc:") for x in f)))' "$SEED_DIR/xemu/emulator.json" \
  && ok "xemu: SDL mapping by position for 045e:0b00 v1, no guide (Guide never opens xemu's menu), no crc" \
  || bad "xemu: SDL_GAMECONTROLLERCONFIG is not our pad's guide-less mapping"
has xemu/xemu.toml 'show_welcome = false' "no first-boot window (it would hold the game)"
# RPCS3: SDL handler defaults by position; the pad by its SDL name; PS button = Select + Start.
has rpcs3/Default.yml '  Device: Xbox One Elite 2 Controller 1' "the pad by RPCS3's '<SDL name> <n>'"
has rpcs3/Default.yml '    PS Button: Back&Start' "PS button (home menu) on Select + Start, not Guide"
has rpcs3/CurrentSettings.ini 'infoBoxEnabledWelcome=false' "no welcome dialog (it shows even with --no-gui)"
has rpcs3/CurrentSettings.ini 'confirmationBoxExitGame=false' "no exit confirmation"
[ "$(jget "$SEED_DIR/rpcs3/emulator.json" env)" = '{"SDL_NO_SIGNAL_HANDLERS": "1"}' ] \
  && ok "rpcs3: SDL's signal handlers off, so OGUI's Exit (SIGTERM) ends it (its SDL3 swallowed it)" \
  || bad "rpcs3 env: $(jget "$SEED_DIR/rpcs3/emulator.json" env)"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); i=d["install"]
sys.exit(not (i == [{"from": "bios/ps3/PS3UPDAT.PUP", "unless": ".config/rpcs3/dev_flash/vsh/etc/version.txt", "args": ["--headless", "--installfw", "{file}"]}]))' \
  "$SEED_DIR/rpcs3/emulator.json" && ok "rpcs3: the player's PS3UPDAT.PUP is installed headless before the first game" || bad "rpcs3: firmware install step missing or changed"

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
# A definition is data, checked before anything runs: anything off is exit 2, never a guess.
BAD="$T/data-bad"; mkdir -p "$BAD/duckstation"; cp "$DS_SEED" "$BAD/duckstation/"
bad_def() {  # bad_def <what> <python edit of d>: write it, expect exit 2 and nothing seeded
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); exec(sys.argv[2]); json.dump(d, open(sys.argv[3], "w"))' \
    "$DS_DEF" "$2" "$BAD/duckstation/emulator.json"
  rm -f "$HOME/.config/x.ini"
  [ "$(QFORGE_EMU_DATA_DIR="$BAD" code psx "$ROM")" = 2 ] && [ ! -e "$HOME/.config/x.ini" ] \
    && ok "$1 is refused (exit 2)" || bad "$1 was accepted"
}
bad_def "a seed to an absolute path" 'd["seed"] = [{"file": "settings.ini", "to": "/etc/passwd"}]'
bad_def "a seed out of \$HOME (..)" 'd["seed"] = [{"file": "settings.ini", "to": "../../escape"}]'
bad_def "a seed with no destination" 'd["seed"] = [{"file": "settings.ini", "to": ""}]'
bad_def "a seed with no file" 'd["seed"] = [{"to": ".config/x.ini"}]'
bad_def "a seed file the image lacks" 'd["seed"] = [{"file": "missing.ini", "to": ".config/x.ini"}]'
bad_def "an unknown key (behaviour belongs in a format)" 'd["pre_launch"] = "touch ~/pwned"'
bad_def "an unknown format" 'd["format"] = "flatpak"'
bad_def "args without {rom}" 'd["args"] = ["-batch", "--"]'
bad_def "args with {rom} twice" 'd["args"] = ["{rom}", "--", "{rom}"]'
bad_def "gui_args with {rom}" 'd["gui_args"] = ["{rom}"]'
bad_def "a binary outside the download (..)" 'd["binary"] = "../../usr/bin/sh"'
bad_def "an env value that is not a string" 'd["env"] = {"X": 1}'
bad_def "a format that is not a string" 'd["format"] = ["appimage"]'
bad_def "a binary that is '.'" 'd["binary"] = "."'
bad_def "a seed to a directory (trailing /)" 'd["seed"] = [{"file": "settings.ini", "to": ".config/x/"}]'
bad_def "an argument with a NUL byte" 'd["args"] = ["-batch\u0000x", "{rom}"]'
bad_def "system_args that are not an object" 'd["system_args"] = ["--system", "x"]'
bad_def "system_args with {rom}" 'd["system_args"] = {"psx": ["{rom}"]}'
bad_def "system_args for a bad system name" 'd["system_args"] = {"../x": ["a"]}'
bad_def "system_args that are not strings" 'd["system_args"] = {"psx": [1]}'
bad_def "a root on an AppImage format (only a folder of scripts has one)" 'd["root"] = "roms/ports/x"'
bad_def "a scripts format with no root" 'd["format"] = "scripts"'
bad_def "a scripts root outside \$HOME (..)" 'd["format"] = "scripts"; d["root"] = "../../usr"'
bad_def "a scripts root that is absolute" 'd["format"] = "scripts"; d["root"] = "/usr"'
bad_def "a dual-screen seed out of the image (..)" 'd["seed"] = [{"file": "settings.ini", "to": ".config/x.ini", "dual_screen_file": "../../etc/passwd"}]'
bad_def "a dual-screen file on a sync entry (seeds only)" 'd["sync"] = [{"file": "settings.ini", "to": ".config/x.ini", "dual_screen_file": "settings.ini"}]'
bad_def "an exit_resend of 0" 'd["exit_resend"] = 0'
bad_def "an exit_resend that is not a number" 'd["exit_resend"] = "2"'
bad_def "an exit_resend that is a boolean" 'd["exit_resend"] = True'
bad_def "an exit_resend over the cap" 'd["exit_resend"] = 600'
printf '{not json' > "$BAD/duckstation/emulator.json"
[ "$(QFORGE_EMU_DATA_DIR="$BAD" code psx "$ROM")" = 2 ] && ok "a definition that is not JSON is refused (exit 2)" || bad "broken JSON was accepted"

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
CASE="Exit while the AppImage is still mounting"
# OGUI's Exit can arrive before the mount is up: the launcher must not die of it (the runtime ignores
# SIGTERM, so a dead launcher would leave runtime and mount behind), and must still clean up.
reset_logs; touch "$T/slow-mount"
start_launcher
wait_for 'grep -qx slow-mounting "$T/appimage.log"' || bad "the fake runtime never started mounting"
kill -TERM "$lpid"; sleep 0.3
kill -0 "$lpid" 2>/dev/null && ok "SIGTERM during the mount does not kill the launcher" || bad "the launcher died of SIGTERM while mounting"
rm -f "$T/slow-mount"
wait_for emu_up && ok "the game still starts once the mount is up" || bad "no game after a SIGTERM during the mount"
touch "$T/stop-emu"; reap_launcher "$lpid"; rc=$?
[ "$rc" = 7 ] && wait_for 'grep -qx hup "$T/appimage.log"' \
  && ok "and the mount is released after it, as usual" || bad "after a SIGTERM during the mount: rc=$rc, released=$(grep -c hup "$T/appimage.log")"

# =================================================================================================
CASE="runtime that prints its mount point early"
# RPCS3's AppImage runtime (DwarFS) prints the mount point before mounting: the launcher must wait
# for the mount itself. It gave up 9 ms in ("did not mount") on the Pocket FIT, 2026-10-07.
touch "$T/print-early"; reset_logs
start_launcher
wait_for emu_up && ok "the game starts once the announced mount point is really mounted" \
  || bad "an early-printed mount point failed the launch: $(cat "$T/launch.err")"
touch "$T/stop-emu"; reap_launcher "$lpid" >/dev/null
rm -f "$T/print-early"

# =================================================================================================
CASE="pkgforge AppImage: hardcoded /tmp paths"
# Dolphin's pkgforge AppImage only finds its Sys folder through /tmp/<name> -> <mount>/share, a link
# its AppRun hook makes; qforge-launch skips AppRun, so it makes the links itself (HW 2026-10-05).
export QFORGE_TMP_LINK_DIR="$T/tmplinks"; mkdir -p "$QFORGE_TMP_LINK_DIR" "$QFORGE_TMP_LINK_DIR/Taken"
SHARUN="$T/data-sharun"; mkdir -p "$SHARUN/duckstation"; cp "$DS_SEED" "$SHARUN/duckstation/"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["format"] = "appimage-sharun"; json.dump(d, open(sys.argv[2], "w"))' \
  "$DS_DEF" "$SHARUN/duckstation/emulator.json"
printf '%s\n' '#!/bin/sh' '_tmp_bin=""' '_tmp_lib=Taken' '_tmp_share=Gxbwc' '_tmp_share=../evil' \
  'ln -sfn "$APPDIR"/share /tmp/hostile' > "$T/sharun-hook"
reset_logs
QFORGE_EMU_DATA_DIR="$SHARUN" start_launcher
wait_for emu_up || bad "the emulator never started: $(cat "$T/launch.err")"
self="$(field self)"; mnt="${self%/usr/bin/duckstation-qt}"
[ "$(field vk)" = /usr/share/vulkan/icd.d/freedreno_icd.aarch64.json ] && [ "$(field sharun_sys)" = 1 ] \
  && ok "appimage-sharun runs on the image's Turnip (system ICD allowed and chosen)" \
  || bad "sharun Vulkan env: VK_DRIVER_FILES='$(field vk)' SHARUN_ALLOW_SYS_VKICD='$(field sharun_sys)'"
[ "$(field no_updates)" = 1 ] && ok "appimage-sharun turns pkgforge's self-updater off (DISABLE_AUTO_UPDATES=1): versions are pinned" \
  || bad "the sharun format does not set DISABLE_AUTO_UPDATES=1"
[ "$(readlink "$QFORGE_TMP_LINK_DIR/Gxbwc")" = "$mnt/share" ] \
  && ok "/tmp/<name> from the hook links to <mount>/share before the emulator starts" \
  || bad "no link to the mounted share: $(ls -l "$QFORGE_TMP_LINK_DIR" 2>&1 | tr '\n' ' ')"
[ -d "$QFORGE_TMP_LINK_DIR/Taken" ] && [ ! -L "$QFORGE_TMP_LINK_DIR/Taken" ] && grep -q "Taken exists and is not a link of ours" "$T/launch.err" \
  && ok "an existing non-link /tmp/<name> is left alone, with a warning" || bad "an existing directory was replaced or not reported"
[ "$(ls "$QFORGE_TMP_LINK_DIR" | sort | tr '\n' ' ')" = "Gxbwc Taken " ] \
  && ok "the hook is read as data: empty, '../' names and its commands make nothing" \
  || bad "unexpected entries: $(ls "$QFORGE_TMP_LINK_DIR" | tr '\n' ' ')"
touch "$T/stop-emu"; reap_launcher "$lpid" >/dev/null
[ ! -e "$QFORGE_TMP_LINK_DIR/Gxbwc" ] && [ ! -L "$QFORGE_TMP_LINK_DIR/Gxbwc" ] \
  && ok "the links go away with the mount (no dangling /tmp entries)" || bad "the /tmp link outlived the game"
echo 01-path-mapping-hardcoded.src.hook > "$T/sharun-hook-name"; reset_logs
QFORGE_EMU_DATA_DIR="$SHARUN" start_launcher; wait_for emu_up
self="$(field self)"; mnt="${self%/usr/bin/duckstation-qt}"
[ "$(readlink "$QFORGE_TMP_LINK_DIR/Gxbwc")" = "$mnt/share" ] \
  && ok "the hook is also read under its .src.hook name (PPSSPP's own anylinux build)" \
  || bad "no link from bin/01-path-mapping-hardcoded.src.hook: $(ls -l "$QFORGE_TMP_LINK_DIR" 2>&1 | tr '\n' ' ')"
touch "$T/stop-emu"; reap_launcher "$lpid" >/dev/null
rm -f "$T/sharun-hook-name" "$QFORGE_TMP_LINK_DIR/Gxbwc"; reset_logs
start_launcher; wait_for emu_up
[ ! -e "$QFORGE_TMP_LINK_DIR/Gxbwc" ] && [ -z "$(field vk)" ] \
  && ok "a plain appimage gets neither: links and Vulkan env belong to the sharun format" \
  || bad "the plain appimage format made sharun links or set VK_DRIVER_FILES"
touch "$T/stop-emu"; reap_launcher "$lpid" >/dev/null
rm -f "$T/sharun-hook"; unset QFORGE_TMP_LINK_DIR

# =================================================================================================
CASE="one-time install (emulator.json install)"
# RPCS3 needs the player's PS3 firmware imported before any game: emulator.json "install" runs the
# emulator's own binary once, from the mount, when its marker file is missing.
INST="$T/data-install"; mkdir -p "$INST/duckstation"; cp "$DS_SEED" "$INST/duckstation/"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["install"] = [{"from": "bios/psx/fw.bin",
  "unless": ".config/fake/fw-ok", "args": ["--fake-install", "{file}"]}]; json.dump(d, open(sys.argv[2], "w"))' \
  "$DS_DEF" "$INST/duckstation/emulator.json"
ST="$T/launch.status"; reset_logs
rc=$(QFORGE_EMU_DATA_DIR="$INST" QFORGE_LAUNCH_STATUS="$ST" code psx "$ROM")
[ "$rc" = 3 ] && [ "$(cat "$ST" 2>/dev/null)" = "missing-file duckstation bios/psx/fw.bin" ] && [ ! -e "$T/emu.log" ] \
  && ok "the player's file is missing: exit 3, status 'missing-file <emu> <path>', no game started" \
  || bad "missing install file: rc=$rc status='$(cat "$ST" 2>/dev/null)' emu ran=$([ -e "$T/emu.log" ] && echo yes || echo no)"
QFORGE_EMU_DATA_DIR="$INST" "$LAUNCH" --gui duckstation 2>"$T/launch.err" & lpid=$!; echo "$lpid" >> "$T/pids"
wait_for emu_up && [ ! -e "$T/install.log" ] && ok "--gui opens without it (and installs nothing)" || bad "--gui did not start without the install file"
touch "$T/stop-emu"; reap_launcher "$lpid" >/dev/null; reset_logs
mkdir -p "$HOME/bios/psx"; : > "$HOME/bios/psx/fw.bin"
rc=$(QFORGE_EMU_DATA_DIR="$INST" QFORGE_LAUNCH_STATUS="$ST" code psx "$ROM")
[ "$rc" = 3 ] && [ "$(cat "$ST" 2>/dev/null)" = "install-failed duckstation" ] && ! emu_up \
  && grep -q "^install --fake-install $HOME/bios/psx/fw.bin$" "$T/install.log" \
  && ok "the install ran (binary from the mount, {file} = ~/<from>) but left no marker: install-failed, no game" \
  || bad "failed install: rc=$rc status='$(cat "$ST" 2>/dev/null)' log='$(cat "$T/install.log" 2>/dev/null)'"
[ ! -s "$T/mounts" ] && ok "and the mount is released" || bad "a failed install left the mount: $(cat "$T/mounts")"
touch "$T/install-works"; : > "$T/install.log"; reset_logs
QFORGE_EMU_DATA_DIR="$INST" start_launcher
wait_for emu_up && [ -f "$HOME/.config/fake/fw-ok" ] && [ "$(grep -c '^install' "$T/install.log")" = 1 ] \
  && ok "a working install runs once before the game, which then starts" || bad "install then game: $(cat "$T/launch.err")"
touch "$T/stop-emu"; reap_launcher "$lpid" >/dev/null; reset_logs
QFORGE_EMU_DATA_DIR="$INST" start_launcher; wait_for emu_up
[ "$(grep -c '^install' "$T/install.log")" = 1 ] && ok "with the marker present it never runs again" || bad "the install ran again"
touch "$T/stop-emu"; reap_launcher "$lpid" >/dev/null; reset_logs
# RPCS3's installer installs the firmware, then aborts (SIGABRT) on its way out: the marker is
# what counts, so the game starts; and installs never leave a core file (HW 2026-10-07).
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["install"] = [{"from": "bios/psx/fw.bin",
  "unless": ".config/fake/fw-ok", "args": ["--fake-install", "{file}"]}]; json.dump(d, open(sys.argv[2], "w"))' \
  "$DS_DEF" "$INST/duckstation/emulator.json"
rm -rf "$HOME/.config/fake"; : > "$T/install.log"; touch "$T/install-crash"; reset_logs
( ulimit -c unlimited; QFORGE_EMU_DATA_DIR="$INST" exec "$LAUNCH" psx "$ROM" 2>"$T/launch.err" ) & lpid=$!; echo "$lpid" >> "$T/pids"
wait_for emu_up && [ -f "$HOME/.config/fake/fw-ok" ] && grep -q "but ~/.config/fake/fw-ok is there: installed" "$T/launch.err" \
  && ok "an installer that crashes after a good install: the marker is there, the game starts" \
  || bad "crashing installer: $(cat "$T/launch.err")"
grep -qx "core-limit=0" "$T/install.log" && ok "install steps run with no core file" || bad "install core limit: $(grep core-limit "$T/install.log")"
touch "$T/stop-emu"; reap_launcher "$lpid" >/dev/null; reset_logs; rm -f "$T/install-crash"

python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["args"] = ["-C", "saves=/home/player/saves/{system}", "{rom}"]
d["install"] = []; json.dump(d, open(sys.argv[2], "w"))' "$DS_DEF" "$INST/duckstation/emulator.json"
reset_logs; QFORGE_EMU_DATA_DIR="$INST" start_launcher; wait_for emu_up
[ "$(sed -n 's/^arg=//p' "$T/emu.log" | tr '\n' '|')" = "-C|saves=/home/player/saves/psx|$ROM|" ] \
  && ok "{system} in args becomes the card's system (mGBA: one emulator, per-system folders)" \
  || bad "{system} not substituted: $(sed -n 's/^arg=//p' "$T/emu.log" | tr '\n' '|')"
touch "$T/stop-emu"; reap_launcher "$lpid" >/dev/null; reset_logs
# system_args: one emulator, several systems it must be told about (e.g. --system "Mega Drive").
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["args"] = ["-f", "{rom}"]; d["install"] = []
d["system_args"] = {"psx": ["--system", "Play Station", "--saves={system}"], "md": ["--system", "Mega Drive"]}
json.dump(d, open(sys.argv[2], "w"))' "$DS_DEF" "$INST/duckstation/emulator.json"
reset_logs; QFORGE_EMU_DATA_DIR="$INST" start_launcher; wait_for emu_up
[ "$(sed -n 's/^arg=//p' "$T/emu.log" | tr '\n' '|')" = "--system|Play Station|--saves=psx|-f|$ROM|" ] \
  && ok "system_args: the card's system's own arguments come first, {system} substituted, other systems' not used" \
  || bad "system_args: $(sed -n 's/^arg=//p' "$T/emu.log" | tr '\n' '|')"
touch "$T/stop-emu"; reap_launcher "$lpid" >/dev/null; reset_logs
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["args"] = ["-f", "{rom}"]; d["install"] = []
d["system_args"] = {"md": ["--system", "Mega Drive"]}; json.dump(d, open(sys.argv[2], "w"))' "$DS_DEF" "$INST/duckstation/emulator.json"
reset_logs; QFORGE_EMU_DATA_DIR="$INST" start_launcher; wait_for emu_up
[ "$(sed -n 's/^arg=//p' "$T/emu.log" | tr '\n' '|')" = "-f|$ROM|" ] \
  && ok "system_args: a system without an entry gets none" || bad "system_args (none): $(sed -n 's/^arg=//p' "$T/emu.log" | tr '\n' '|')"
touch "$T/stop-emu"; reap_launcher "$lpid" >/dev/null; reset_logs
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["gui_args"] = ["{system}"]; json.dump(d, open(sys.argv[2], "w"))' \
  "$DS_DEF" "$INST/duckstation/emulator.json"
[ "$(QFORGE_EMU_DATA_DIR="$INST" code --gui duckstation)" = 2 ] && ok "{system} in gui_args is refused (exit 2): Open has no system" || bad "gui_args with {system} accepted"
# OGUI's Exit during the install: no game afterwards, no status (the player chose to leave).
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["args"] = ["{rom}"]; d["install"] = [{"from": "bios/psx/fw.bin",
  "unless": ".config/fake/slow-ok", "args": ["--fake-install", "{file}"]}]; json.dump(d, open(sys.argv[2], "w"))' \
  "$DS_DEF" "$INST/duckstation/emulator.json"
touch "$T/install-slow"; rm -f "$ST" "$T/install-running"; reset_logs
# Under a stand-in reaper, as in "OGUI Exit" below: reap() signals the launcher too.
QFORGE_EMU_DATA_DIR="$INST" QFORGE_LAUNCH_STATUS="$ST" setsid bash -c 'echo $$ >> "$2/pids"; "$0" psx "$1"; echo "$?" > "$2/install-rc"' \
  "$LAUNCH" "$ROM" "$T" 2>"$T/launch.err" &
reaper=$!; echo "$reaper" >> "$T/pids"
wait_for '[ -f "$T/install-running" ]' || bad "the slow install never started"
ogui_reap "$reaper"
wait_for '[ -f "$T/install-rc" ]' || bad "the launcher did not exit after reap"
rc="$(cat "$T/install-rc" 2>/dev/null)"; rm -f "$T/install-rc"
[ "$rc" -ge 128 ] && ! emu_up && [ ! -e "$ST" ] \
  && ok "Exit during the install (it still finishes cleanly): the launcher stops, no game, no popup status" \
  || bad "Exit during install: rc=$rc game=$(emu_up && echo started || echo no) status='$(cat "$ST" 2>/dev/null)'"
rm -f "$T/install-slow" "$T/install-running"
wait_for '[ ! -s "$T/mounts" ]' && ok "and the mount is released" || bad "an interrupted install left the mount: $(cat "$T/mounts")"
# core_dumps false (for an emulator that crashes on every Exit): RLIMIT_CORE 0; default unchanged.
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["install"] = []; d["core_dumps"] = False; json.dump(d, open(sys.argv[2], "w"))' \
  "$DS_DEF" "$INST/duckstation/emulator.json"
reset_logs; ( ulimit -c unlimited; QFORGE_EMU_DATA_DIR="$INST" exec "$LAUNCH" psx "$ROM" 2>"$T/launch.err" ) & lpid=$!; echo "$lpid" >> "$T/pids"
wait_for emu_up; [ "$(field core)" = 0 ] && ok "core_dumps false: the emulator runs with no core file (RLIMIT_CORE 0)" || bad "core_dumps false: ulimit -c is '$(field core)'"
touch "$T/stop-emu"; reap_launcher "$lpid" >/dev/null; reset_logs
( ulimit -c unlimited; exec "$LAUNCH" psx "$ROM" 2>"$T/launch.err" ) & lpid=$!; echo "$lpid" >> "$T/pids"
wait_for emu_up; [ "$(field core)" = unlimited ] && ok "by default the emulator keeps the session's core limit" || bad "default core limit changed: '$(field core)'"
touch "$T/stop-emu"; reap_launcher "$lpid" >/dev/null; reset_logs
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["core_dumps"] = "no"; json.dump(d, open(sys.argv[2], "w"))' \
  "$DS_DEF" "$INST/duckstation/emulator.json"
[ "$(QFORGE_EMU_DATA_DIR="$INST" code psx "$ROM")" = 2 ] && ok "core_dumps must be a boolean (exit 2)" || bad "core_dumps \"no\" accepted"
for broken in '[{"from": "a", "unless": "b", "args": ["x"]}]' '[{"from": "../a", "unless": "b", "args": ["{file}"]}]' \
              '[{"from": "bios/a b.pup", "unless": "b", "args": ["{file}"]}]' '[{"from": "a", "unless": "b", "args": ["{file}", "{system}"]}]' \
              '[{"from": "a", "args": ["{file}"]}]' '[{"from": "a", "unless": "b", "args": ["{file}", "{rom}"]}]'; do
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["install"] = json.loads(sys.argv[3]); json.dump(d, open(sys.argv[2], "w"))' \
    "$DS_DEF" "$INST/duckstation/emulator.json" "$broken"
  [ "$(QFORGE_EMU_DATA_DIR="$INST" code psx "$ROM")" = 2 ] && ok "install refused (exit 2): $broken" || bad "install accepted: $broken"
done

# =================================================================================================
CASE="first-run settings on a dual-screen board"
# A dual-screen board (device-env declares a second panel) gets the seed's dual_screen_file instead.
DUAL="$T/data-dual"; mkdir -p "$DUAL/duckstation"; cp "$DS_SEED" "$DUAL/duckstation/"
echo "dual-screen settings" > "$DUAL/duckstation/settings-dual.ini"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1]));
d["seed"] = [dict(s, dual_screen_file="settings-dual.ini") for s in d["seed"]]; json.dump(d, open(sys.argv[2], "w"))' \
  "$DS_DEF" "$DUAL/duckstation/emulator.json"
fake_device_env() { printf '#!/bin/sh\necho "QFORGE_SECONDARY_CONNECTOR=%s"\n' "$1" > "$T/device-env"; chmod +x "$T/device-env"; }
for board in dual single; do
  [ "$board" = dual ] && fake_device_env "'DSI-2'" || fake_device_env "''"
  rm -rf "$HOME"; mkdir -p "$HOME"; reset_logs
  QFORGE_EMU_DATA_DIR="$DUAL" QFORGE_DEVICE_ENV="$T/device-env" start_launcher
  wait_for emu_up || bad "the emulator never started: $(cat "$T/launch.err")"
  touch "$T/stop-emu"; reap_launcher "$lpid"
  want="$DS_SEED"; [ "$board" = dual ] && want="$DUAL/duckstation/settings-dual.ini"
  cmp -s "$want" "$seeded" && ok "a $board-screen board is seeded with $(basename "$want")" \
    || bad "a $board-screen board did not get $(basename "$want")"
done

# =================================================================================================
CASE="exit_resend (a second window keeps the emulator up)"
RESEND="$T/data-resend"; mkdir -p "$RESEND/duckstation"; cp "$DS_SEED" "$RESEND/duckstation/"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["exit_resend"] = 0.5; json.dump(d, open(sys.argv[2], "w"))' \
  "$DS_DEF" "$RESEND/duckstation/emulator.json"
: > "$T/two-terms"
reset_logs
QFORGE_EMU_DATA_DIR="$RESEND" start_launcher
wait_for emu_up || bad "the emulator never started: $(cat "$T/launch.err")"
epid="$(field pid)"
kill -TERM "$epid"; kill -TERM "$lpid"  # OGUI's Exit: the emulator and the launcher both get SIGTERM
sleep 0.2
grep -qx term-ignored "$T/emu.log" && kill -0 "$epid" 2>/dev/null \
  && ok "the first SIGTERM leaves the emulator running (its second window)" || bad "the fake emulator did not ignore its first SIGTERM"
reap_launcher "$lpid"
[ "$(grep -cx term "$T/emu.log")" = 2 ] && grep -qx mount-alive "$T/emu.log" \
  && ok "exit_resend: one more SIGTERM after 0.5 s ended it, the mount still up" \
  || bad "exit_resend: emulator got $(grep -cx term "$T/emu.log") SIGTERMs (want 2)"
grep -q "one more SIGTERM (exit_resend)" "$T/launch.err" && ok "the resend is logged" || bad "the resend is not logged"
# Without exit_resend the launcher never adds a SIGTERM of its own (DuckStation's force-quit).
reset_logs
start_launcher
wait_for emu_up || bad "the emulator never started"
epid="$(field pid)"
kill -TERM "$epid"; kill -TERM "$lpid"; sleep 1
[ "$(grep -cx term "$T/emu.log")" = 1 ] && kill -0 "$epid" 2>/dev/null \
  && ok "without exit_resend, no second SIGTERM comes from the launcher" || bad "a SIGTERM was resent without exit_resend"
kill -TERM "$epid"; reap_launcher "$lpid"
rm -f "$T/two-terms" "$T/one-term-seen"
# One that never exits on SIGTERM (melonDS with two windows): SIGKILL for the emulator alone, after
# the resend, and the launcher is still there to release the mount.
: > "$T/deaf"
reset_logs
QFORGE_EMU_DATA_DIR="$RESEND" start_launcher
wait_for emu_up || bad "the emulator never started: $(cat "$T/launch.err")"
epid="$(field pid)"
kill -TERM "$epid"; kill -TERM "$lpid"
reap_launcher "$lpid"
kill -0 "$epid" 2>/dev/null && bad "exit_resend: the deaf emulator is still running" \
  || ok "exit_resend: an emulator deaf to SIGTERM is SIGKILLed after the resend"
grep -q "SIGKILL (exit_resend)" "$T/launch.err" && ok "the SIGKILL is logged" || bad "the SIGKILL is not logged"
wait_for 'grep -qx hup "$T/appimage.log"' && ok "the launcher still released the mount (SIGHUP)" \
  || bad "the mount was not released after the SIGKILL"
rm -f "$T/deaf" "$T/one-term-seen"

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
grep -qs 'CPUS\|taskset' "$SEED_DIR"/*/emulator.json && bad "an emulator definition in the image pins CPUs: pinning must stay the player's choice" \
  || ok "no emulator definition in the image pins anything"

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
# Same mount / setsid / exit handling as a ROM; the definition's gui_args instead of args.
[ "$(code --gui)" = 2 ] && ok "--gui with no emulator: exit 2" || bad "accepted a bare --gui"
[ "$(code --gui 'duck;rm')" = 2 ] && ok "--gui with shell characters in the name: exit 2" || bad "accepted --gui 'duck;rm'"
[ "$(code --gui ../duckstation)" = 2 ] && ok "--gui with a path in the name: exit 2" || bad "accepted --gui ../duckstation"
[ "$(code --gui nosuchemu)" = 2 ] && ok "--gui with no conf for the emulator: exit 2" || bad "accepted an unknown emulator"
[ "$(code --gui duckstation "$ROM")" = 2 ] && ok "--gui with a ROM too: exit 2" || bad "accepted --gui duckstation <rom>"
[ "$(QFORGE_EMU_DIR="$T/none" code --gui duckstation)" = 3 ] \
  && ok "--gui of an emulator that is not installed: exit 3" || bad "--gui of a missing emulator did not exit 3"
[ "$(jget "$DS_DEF" gui_args)" = '["-bigpicture", "-fullscreen"]' ] \
  && ok "duckstation gui_args: Big Picture (pad-driven), no -batch (it would quit with no game)" || bad "duckstation gui_args: $(jget "$DS_DEF" gui_args)"
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
[ "${args[*]}" = "-bigpicture -fullscreen" ] \
  && ok "--gui arguments are exactly the definition's gui_args (no ROM, no -batch)" \
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
CASE="folder of scripts (PortMaster)"
# PortMaster is no AppImage: qforge-emu unpacks it into ~/roms/ports/PortMaster. --gui runs its own
# PortMaster.sh from there; a ports card's "ROM" is the port's own launch script, run with bash
# (PortMaster installs ports as <Name>.sh beside its folder; their mode is not ours to trust).
SD="$T/defs-scripts"; mkdir -p "$SD/fakepm"
cat > "$SD/fakepm/emulator.json" <<'EOF'
{"format": "scripts", "root": "roms/ports/FakePM", "binary": "FakePM.sh", "args": ["{rom}"], "gui_args": ["--gui-arg"]}
EOF
echo "ports=fakepm" > "$T/launch-ports.conf"
sl() { QFORGE_EMU_DATA_DIR="$SD" QFORGE_LAUNCH_CONF="$T/launch-ports.conf" "$LAUNCH" "$@"; }
rm -rf "$HOME"; mkdir -p "$HOME/roms/ports"
PORT="$HOME/roms/ports/A Port.sh"; cp "$T/fake-emu" "$PORT"; chmod 644 "$PORT"
st="$T/launch.status.scripts"; rm -f "$st"
QFORGE_LAUNCH_STATUS="$st" sl --gui fakepm >/dev/null 2>&1; rc=$?
[ "$rc" = 3 ] && [ "$(cat "$st" 2>/dev/null)" = "not-installed fakepm" ] \
  && ok "not unpacked yet: exit 3, status 'not-installed fakepm'" || bad "rc=$rc status=$(cat "$st" 2>/dev/null)"
QFORGE_LAUNCH_STATUS="$st" sl ports "$PORT" >/dev/null 2>&1; rc=$?
[ "$rc" = 3 ] && [ "$(cat "$st" 2>/dev/null)" = "not-installed fakepm" ] \
  && ok "a port card without PortMaster: exit 3, not-installed (ports need its control files)" || bad "port without PortMaster: rc=$rc"
mkdir -p "$HOME/roms/ports/FakePM"; cp "$T/fake-emu" "$HOME/roms/ports/FakePM/FakePM.sh"; chmod 755 "$HOME/roms/ports/FakePM/FakePM.sh"
reset_logs
sl --gui fakepm 2>"$T/launch.err" & lpid=$!; echo "$lpid" >> "$T/pids"
wait_for emu_up || bad "PortMaster never started: $(cat "$T/launch.err")"
[ "$(field self)" = "$HOME/roms/ports/FakePM/FakePM.sh" ] && ok "--gui runs ~/<root>/<binary> in place (no mount)" || bad "--gui ran '$(field self)'"
[ "$(sed -n 's/^arg=//p' "$T/emu.log")" = "--gui-arg" ] && ok "--gui passes gui_args" || bad "--gui args: $(sed -n 's/^arg=//p' "$T/emu.log" | tr '\n' ' ')"
[ "$(field pid)" = "$(field sid)" ] && ok "--gui: it leads its own session (OGUI's Exit reaches its whole tree)" || bad "--gui: not a session leader"
touch "$T/stop-emu"; reap_launcher "$lpid"; rc=$?
[ "$rc" = 7 ] && ok "--gui: exits with PortMaster's status" || bad "--gui: launcher exited $rc"
[ ! -s "$T/fusermount.log" ] && ok "nothing to mount or unmount" || bad "fusermount ran for a folder"
reset_logs
sl ports "$PORT" 2>"$T/launch.err" & lpid=$!; echo "$lpid" >> "$T/pids"
wait_for emu_up || bad "the port never started: $(cat "$T/launch.err")"
[ "$(field self)" = "$PORT" ] && ok "a port card runs the port's own script (with bash: its mode is 644)" || bad "the port ran '$(field self)'"
[ -z "$(sed -n 's/^arg=//p' "$T/emu.log")" ] && ok "... with no arguments" || bad "port args: $(sed -n 's/^arg=//p' "$T/emu.log" | tr '\n' ' ')"
[ "$(field pid)" = "$(field sid)" ] && ok "the port leads its own session" || bad "the port is not a session leader"
ogui_reap "$lpid"; reap_launcher "$lpid"
grep -qx term "$T/emu.log" && ok "OGUI's Exit reaches the port" || bad "the port never got SIGTERM"

CASE="folder of scripts: QForge's hook files (sync)"
# mod_QForge.txt / libgl_QForge.txt live in the image and are copied into PortMaster's folder at
# every launch: an image update must reach an existing install, unlike a seed, which never
# overwrites. A file already identical is left alone.
printf 'hook v1\n' > "$SD/fakepm/mod_Test.txt"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["sync"]=[{"file":"mod_Test.txt","to":"roms/ports/FakePM/mod_Test.txt"}]; json.dump(d,open(sys.argv[1],"w"))' "$SD/fakepm/emulator.json"
HOOK="$HOME/roms/ports/FakePM/mod_Test.txt"
sync_run() { reset_logs; sl --gui fakepm 2>"$T/launch.err" & lpid=$!; echo "$lpid" >> "$T/pids"; wait_for emu_up || bad "PortMaster never started: $(cat "$T/launch.err")"; touch "$T/stop-emu"; reap_launcher "$lpid"; }
sync_run
[ "$(cat "$HOOK" 2>/dev/null)" = "hook v1" ] && ok "a launch copies the image's hook file into the folder" || bad "hook not synced: $(cat "$T/launch.err")"
touch -d '2001-01-01' "$HOOK"; sync_run
[ "$(stat -c %Y "$HOOK")" = "$(date -d 2001-01-01 +%s)" ] && ok "an identical hook file is left alone" || bad "an identical hook was rewritten"
printf 'player edit\n' > "$HOOK"; printf 'hook v2\n' > "$SD/fakepm/mod_Test.txt"; sync_run
[ "$(cat "$HOOK")" = "hook v2" ] && ok "a different one is replaced by the image's (an image update reaches existing installs)" || bad "hook is '$(cat "$HOOK")'"
[ -z "$(find "$HOME/roms/ports/FakePM" -name '*qforge*')" ] && ok "no temporary file left" || bad "left: $(find "$HOME/roms/ports/FakePM" -name '*qforge*')"

CASE="folder of scripts: runtimes a port left mounted"
# A port's runtime is a squashfuse mount (QForge's mount stand-in) that outlives the port when
# OGUI's Exit skips the port's own umount: the launcher releases every mount the registry lists.
REG="$T/pm-mounts"; mkdir -p "$T/rt1" "$T/rt2"
printf '%s\t%s\n' "$T/rt1" /x/godot.squashfs "$T/gone" /x/weston.squashfs > "$REG"
echo "squashfuse $T/rt1 fuse.squashfuse ro,nosuid,nodev 0 0" >> "$T/mounts"
cat > "$T/bin/fusermount" <<EOF
#!/bin/bash
echo "\$*" >> "$T/fusermount2.log"
m="\${!#}"
awk -v m="\$m" '\$2 != m' "$T/mounts" > "$T/mounts.new" && mv "$T/mounts.new" "$T/mounts"
EOF
chmod +x "$T/bin/fusermount"; rm -f "$T/fusermount2.log"
reset_logs
QFORGE_PM_MOUNTS="$REG" sl ports "$PORT" 2>"$T/launch.err" & lpid=$!; echo "$lpid" >> "$T/pids"
wait_for emu_up || bad "the port never started: $(cat "$T/launch.err")"
grep -q "rt1" "$T/fusermount2.log" 2>/dev/null && bad "released a mount while the port still ran" || ok "nothing is released while the port runs"
ogui_reap "$lpid"; reap_launcher "$lpid"
grep -qx -- "-u -z $T/rt1" "$T/fusermount2.log" 2>/dev/null && ok "after the port, its runtime mount is released (fusermount -u -z)" || bad "fusermount calls: $(cat "$T/fusermount2.log" 2>/dev/null)"
! grep -q gone "$T/fusermount2.log" 2>/dev/null && ok "a registry entry no longer mounted is skipped" || bad "unmounted something not mounted"
[ ! -s "$REG" ] && ok "the registry is emptied" || bad "registry left: $(cat "$REG")"
rm -f "$T/bin/fusermount"

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
# pkgforge-dev's runtime (Dolphin): the mount is fuse.dwarfs, named by the AppImage's full path.
reset_logs
img_real="$(readlink -f "$T/emus/duckstation/current")"
printf '%s\n' "$img_real $T/mnt.dwarfs fuse.dwarfs ro,nosuid,nodev 0 0" \
  "/elsewhere/Other.AppImage $T/mnt.otherdw fuse.dwarfs ro,nosuid,nodev 0 0" > "$T/mounts"
start_launcher; wait_for emu_up; touch "$T/stop-emu"; reap_launcher "$lpid"
grep -qx -- "-uz $T/mnt.dwarfs" "$T/fusermount.log" \
  && ok "a dead dwarfs mount of this AppImage (source = its path) is swept too" || bad "the dwarfs mount was not swept: $(cat "$T/fusermount.log" 2>/dev/null)"
grep -q "mnt.otherdw" "$T/fusermount.log" \
  && bad "another AppImage's dwarfs mount was touched" || ok "another AppImage's dwarfs mount is left alone"
: > "$T/mounts"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
