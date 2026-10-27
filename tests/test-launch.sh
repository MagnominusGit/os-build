#!/usr/bin/env bash
# Offline test for retroforge-launch: how a ROM card starts an emulator AppImage, and how it stops.
#
#   tests/test-launch.sh
#
# WHY THIS EXISTS. Each rule in retroforge-launch was a crash on hardware (DuckStation, Pocket Max,
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
LAUNCH="$ROOT/rootfs/overlay/usr/bin/retroforge-launch"
LAUNCH_CONF="$ROOT/rootfs/overlay/etc/retroforge/launch.conf"
SEED_DIR="$ROOT/rootfs/overlay/usr/share/retroforge/emulators"
DS_DEF="$SEED_DIR/duckstation/emulator.json"
DS_SEED="$SEED_DIR/duckstation/settings.ini"
AX_SEED="$SEED_DIR/armsx2/PCSX2.ini"
LAYOUT="$ROOT/rootfs/overlay/usr/share/user-tmpfiles.d/retroforge-home.conf"

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
  echo "lowprio=\${RETROFORGE_GAME_LOWPRIO-}"; echo "tu_autotune=\${TU_AUTOTUNE_FLAGS-}"
  echo "vram_on=\${ENABLE_MESA_VRAM_REPORT_LIMIT-}"; echo "vram_mib=\${VK_VRAM_REPORT_LIMIT_HEAP_SIZE-}"
  echo "vram_id=\${VK_VRAM_REPORT_LIMIT_DEVICE_ID-}"; echo "opt_env=\${FAKE_OPT-}"
  printf 'arg=%s\n' "\$@"; } >> "\$log"
if [ "\${1-}" = --fake-setup ]; then  # a setup run (emulator.json "setup_args"), not a game
  echo "setup \$*" >> "$T/setup.log"
  [ -f "$T/setup-fails" ] && exit 9
  exit 0
fi
if [ "\${1-}" = --headless ] && [ "\${2-}" = --installpkg ]; then  # the PSN inbox (--psn-install)
  echo "psn-install \$*" >> "$T/psn.log"
  echo "RPCS3-LOG-NOISE"  # RPCS3 logs to stdout: it must never land on the result lines
  [ -f "$T/psn-fake.sh" ] && . "$T/psn-fake.sh"
  exit 0  # RPCS3's --installpkg exits 0 even when it failed: success is per file, on disk
fi
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
# inherited as ignored, so it keeps retroforge-launch's SIGTERM disposition just as the real runtime
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
export RETROFORGE_LAUNCH_CONF="$LAUNCH_CONF" RETROFORGE_EMU_DATA_DIR="$SEED_DIR"
export RETROFORGE_EMU_DIR="$T/emus" RETROFORGE_MOUNTS="$T/mounts"
# The launcher seeds first-run settings into $HOME: never let a test run reach the real one.
export HOME="$T/home"
unset XDG_CONFIG_HOME  # the player conf must be found under $HOME/.config
export RETROFORGE_LAUNCH_STATUS="$T/launch.status.default"
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
[ "$(RETROFORGE_EMU_DIR="$T/none" code psx "$ROM")" = 3 ] \
  && ok "emulator not installed (no current): exit 3" || bad "a missing emulator did not exit 3"

# =================================================================================================
CASE="launch failure status (for the plugin's popup)"
# OGUI runs games through its reaper and never sees retroforge-launch's exit code, so an exit-3 failure
# is also written to $RETROFORGE_LAUNCH_STATUS; the plugin's EXIT hook reads it and shows a popup.
ST="$T/launch.status"
echo "stale" > "$ST"
RETROFORGE_LAUNCH_STATUS="$ST" RETROFORGE_EMU_DIR="$T/none" "$LAUNCH" psx "$ROM" >/dev/null 2>&1
[ "$(cat "$ST" 2>/dev/null)" = "not-installed duckstation" ] \
  && ok "emulator not installed: status 'not-installed duckstation'" || bad "status was '$(cat "$ST" 2>/dev/null)'"
echo "stale" > "$ST"
RETROFORGE_LAUNCH_STATUS="$ST" RETROFORGE_EMU_DIR="$T/none" "$LAUNCH" --gui duckstation >/dev/null 2>&1
[ "$(cat "$ST" 2>/dev/null)" = "not-installed duckstation" ] \
  && ok "--gui of a missing emulator: same status" || bad "status was '$(cat "$ST" 2>/dev/null)'"
echo "stale" > "$ST"
RETROFORGE_LAUNCH_STATUS="$ST" "$LAUNCH" psx "$T/roms/psx/missing.chd" >/dev/null 2>&1
[ ! -e "$ST" ] && ok "a bad invocation (exit 2) clears the status and writes none" || bad "status left: '$(cat "$ST")'"

# =================================================================================================
CASE="config shipped in the image"
grep -qx 'psx=duckstation' "$LAUNCH_CONF" && ok "launch.conf maps psx to duckstation" || bad "launch.conf does not map psx=duckstation"
[ "$(jget "$DS_DEF" format)" = '"appimage"' ] && [ "$(jget "$DS_DEF" binary)" = '"usr/bin/duckstation-qt"' ] \
  && ok "duckstation: an AppImage, its real binary (not AppRun)" || bad "duckstation emulator.json format/binary: $(jget "$DS_DEF" format) $(jget "$DS_DEF" binary)"
[ "$(jget "$DS_DEF" args)" = '["-batch", "-fullscreen", "--", "{rom}"]' ] \
  && ok "duckstation args: -batch (back to OGUI on close), -- before the ROM" || bad "duckstation args: $(jget "$DS_DEF" args)"
RMG_DEF="$SEED_DIR/rmg/emulator.json"
RMG_SEED="$SEED_DIR/rmg/mupen64plus.cfg"
grep -qx 'n64=rmg' "$LAUNCH_CONF" && ok "launch.conf maps n64 to rmg" || bad "launch.conf does not map n64=rmg"
[ "$(jget "$RMG_DEF" format)" = '"appimage-sharun"' ] && [ "$(jget "$RMG_DEF" binary)" = '"bin/RMG"' ] \
  && ok "rmg: a sharun AppImage, its real binary (not AppRun)" || bad "rmg emulator.json format/binary: $(jget "$RMG_DEF" format) $(jget "$RMG_DEF" binary)"
[ "$(jget "$RMG_DEF" args)" = '["-f", "-n", "-q", "{rom}"]' ] \
  && ok "rmg args: fullscreen, no GUI chrome, quit when emulation ends" || bad "rmg args: $(jget "$RMG_DEF" args)"
python3 -c 'import json,sys; sys.exit(json.load(open(sys.argv[1]))["env"].get("SDL_NO_SIGNAL_HANDLERS") != "1")' "$RMG_DEF" \
  && ok "rmg: SDL_NO_SIGNAL_HANDLERS=1 (RMG-Input's SDL would swallow OGUI Exit's SIGTERM)" || bad "rmg env lacks SDL_NO_SIGNAL_HANDLERS=1"
rmgini() { awk -v sec="[$1]" -v key="$2" '$0 == sec {in_s=1; next} /^\[/ {in_s=0}
  in_s { split($0, kv, " = "); if (kv[1] == key) { print kv[2]; exit } }' "$RMG_SEED"; }
[ "$(rmgini "Rosalie's Mupen GUI" ConfirmExitWhileInGame)" = False ] \
  && ok "rmg seed: no exit confirmation (OGUI's Exit would hang on 'are you sure?')" \
  || bad "rmg seed lacks ConfirmExitWhileInGame = False"
[ "$(rmgini "Rosalie's Mupen GUI" CheckForUpdates)" = False ] && ok "rmg seed: self-updater off (RetroForge ships the version)" \
  || bad "rmg seed leaves RMG's update check on"
[ "$(rmgini "Rosalie's Mupen GUI Core" GFX_Plugin)" = '"mupen64plus-video-GLideN64.so"' ] \
  && ok "rmg seed: GLideN64 video pinned (paraLLEl-RDP does not run on A610)" \
  || bad "rmg seed video plugin: $(rmgini "Rosalie's Mupen GUI Core" GFX_Plugin)"
[ "$(rmgini Core SaveSRAMPath)" = '"/home/player/saves/n64"' ] && [ "$(rmgini Core SaveStatePath)" = '"/home/player/states/n64"' ] \
  && ok "rmg seed: saves and states in the shared layout" || bad "rmg seed save paths do not match the layout"
[ "$(rmgini "Rosalie's Mupen GUI - Input Plugin Profile 0" PluggedIn)" = True ] \
  && [ "$(rmgini "Rosalie's Mupen GUI - Input Plugin Profile 0" DeviceType)" = 2 ] \
  && ok "rmg seed: player 1 plugged in on the Automatic device (no profile = no pad at all)" \
  || bad "rmg seed: no Automatic player-1 input profile"
[ "$(rmgini "Rosalie's Mupen GUI - Input Plugin Profile 0" Hotkey_Shutdown_Data)" = '"4;6"' ] \
  && ok "rmg seed: Select+Start stops emulation (with -q, back to OGUI)" \
  || bad "rmg seed: no Select+Start shutdown combo"

# DuckStation reads INI values as "key = value"; check the keys the hardware test needed.
ini() { awk -v sec="[$1]" -v key="$2" '$0 == sec {in_s=1; next} /^\[/ {in_s=0}
  in_s { split($0, kv, " = "); if (kv[1] == key) { print kv[2]; exit } }' "$DS_SEED"; }
[ "$(ini Main SetupWizardIncomplete)" = false ] && ok "duckstation seed: setup wizard skipped" || bad "duckstation seed does not skip the setup wizard"
[ "$(ini Main ConfirmPowerOff)" = false ] && ok "duckstation seed: no exit confirmation (a SIGTERM would wait on a dialog)" \
  || bad "duckstation seed lacks ConfirmPowerOff = false: OGUI's Exit and a session stop hang on 'are you sure?'"
[ "$(ini Main SaveStateOnExit)" = true ] && ok "duckstation seed: resume state saved on exit (off by default)" \
  || bad "duckstation seed lacks SaveStateOnExit = true: closing a game keeps no save state"
[ "$(ini AutoUpdater CheckAtStartup)" = false ] && ok "duckstation seed: self-updater off (RetroForge ships the version)" || bad "duckstation seed leaves DuckStation's auto-updater on"
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
  missing="" tops="roms saves states"
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
[ "$(ini BIOS SearchDirectory)" = /home/player/bios ] && [ "$(ini GameList RecursivePaths)" = /home/player/roms/psx ] \
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
[ "$(axini AutoUpdater CheckAtStartup)" = false ] && ok "armsx2 seed: self-updater off (RetroForge ships the version)" || bad "armsx2 seed leaves ARMSX2's auto-updater on"
[ -z "$(axini EmuCore/GS Renderer)" ] && ok "armsx2 seed: renderer left on Automatic (forcing it shows a warning at every start)" \
  || bad "armsx2 seed forces a renderer: ARMSX2 warns 'Graphics API is not set to Automatic' at every start"
[ -z "$(axini Filenames BIOS)" ] && ok "armsx2 seed: no BIOS file named (Auto picks one from ~/bios)" || bad "armsx2 seed names a BIOS file the player may not have"
[ "$(axini InputSources SDL)" = true ] && [ "$(axini Pad1 Type)" = DualShock2 ] && [ "$(axini Pad1 Cross)" = SDL-0/FaceSouth ] \
  && [ "$(axini Pad1 Start)" = SDL-0/Start ] && ok "armsx2 seed: Port 1 is a DualShock 2 on the InputPlumber pad (SDL-0)" \
  || bad "armsx2 seed has no SDL-0 DualShock 2 mapping for Port 1"
[ "$(axini Hotkeys OpenPauseMenu)" = "SDL-0/Back & SDL-0/Start" ] && ok "armsx2 seed: Select+Start opens the pause menu" \
  || bad "armsx2 seed: no controller binding for OpenPauseMenu"
grep -q 'SDL-0/Guide' "$AX_SEED" && bad "armsx2 seed binds Guide, which OpenGamepadUI owns" || ok "armsx2 seed leaves Guide to OGUI"
[ "$(axini Folders Bios)" = /home/player/bios ] && [ "$(axini GameList RecursivePaths)" = /home/player/roms/ps2 ] \
  && [ "$(axini Folders MemoryCards)" = /home/player/saves/ps2 ] && [ "$(axini Folders Savestates)" = /home/player/states/ps2 ] \
  && ok "armsx2 seed: BIOS, ROMs, memory cards and states in the shared layout" || bad "armsx2 seed folders do not match the layout"
AX_DEF="$SEED_DIR/armsx2/emulator.json"
[ "$(jget "$AX_DEF" format)" = '"appimage"' ] && [ "$(jget "$AX_DEF" binary)" = '"usr/bin/armsx2-qt"' ] \
  && [ "$(jget "$AX_DEF" args)" = '["-batch", "-nogui", "-fullscreen", "--", "{rom}"]' ] \
  && ok "armsx2: real binary, -batch -nogui, -- before the ROM" || bad "armsx2 emulator.json: $(jget "$AX_DEF" binary) $(jget "$AX_DEF" args)"
[ "$(jget "$AX_DEF" seed)" = '[{"file": "PCSX2.ini", "to": ".config/ARMSX2/inis/PCSX2.ini"}]' ] \
  && ok "armsx2 seeds ~/.config/ARMSX2/inis/PCSX2.ini (where ARMSX2 reads it)" || bad "armsx2 seed: $(jget "$AX_DEF" seed)"

# Dolphin (2026-10-05): INI keys "Key = Value" in /usr/share/retroforge/emulators/dolphin/*.ini.
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
[ "$(dlini Hotkeys.ini Hotkeys General/Stop)" = '@(Back+Start) | `XInput2/0/Virtual core pointer:F4`' ] \
  && ok "dolphin seed: Select+Start and Guide+Start (F4) stop the game" || bad "dolphin seed has no pad Stop hotkey"
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
# A gamepad_profile replaces what OGUI's intercept did for Guide (OGUI patch 0024 adds the same to
# its own JSON profiles): Guide holds a layer AND sends dbus ui_guide (InputPlumber 0002 taps it on
# release when the layer went unused), and that layer maps South -> ui_quick (quick bar) and
# North -> ui_osk (keyboard). CPAN::Meta::YAML (core perl) reads our block-style profiles.
guide_layer_ok() {
  perl -MCPAN::Meta::YAML -e '
    my $p = CPAN::Meta::YAML->read($ARGV[0]) or exit 1; $p = $p->[0];
    my ($layer, $tap);
    for my $m (@{ $p->{mapping} || [] }) {
      next unless ((($m->{source_event} || {})->{gamepad} || {})->{button} // "") eq "Guide";
      for my $t (@{ $m->{target_events} || [] }) {
        $layer = $t->{layer}{name} if ref $t->{layer};
        $tap = 1 if ($t->{dbus} // "") eq "ui_guide";
      }
    }
    exit 1 unless defined $layer && $tap;
    my %row;
    for my $l (@{ $p->{layers} || [] }) {
      next unless $l->{name} eq $layer;
      for my $m (@{ $l->{mapping} || [] }) {
        my $b = (($m->{source_event} || {})->{gamepad} || {})->{button} // next;
        $row{$b} = join ",", map { $_->{dbus} // "-" } @{ $m->{target_events} || [] };
      }
    }
    exit !(($row{South} // "") eq "ui_quick" && ($row{North} // "") eq "ui_osk");
  ' "$1"
}

# Each emulator.json must load (a refused definition only shows when a player starts a game) and
# seed only files the image has. With no download, --gui stops at "not installed" (exit 3) AFTER
# the definition was validated; a bad one is exit 2.
for def in "$SEED_DIR"/*/emulator.json; do
  emu="$(basename "$(dirname "$def")")"
  [ "$(RETROFORGE_EMU_DIR="$T/none" code --gui "$emu")" = 3 ] && ok "$emu: emulator.json is accepted" \
    || bad "$emu: emulator.json refused: $(RETROFORGE_EMU_DIR="$T/none" "$LAUNCH" --gui "$emu" 2>&1 | tail -1)"
  python3 -c 'import json,os,sys; d=json.load(open(sys.argv[1])); sys.exit(any(not os.path.isfile(os.path.join(sys.argv[2], s["file"])) for s in d.get("seed", [])))' \
    "$def" "$(dirname "$def")" && ok "$emu: every seeded file is in the image" || bad "$emu seeds a file that is not in the image"
  python3 -c 'import json,os,sys; d=json.load(open(sys.argv[1])); p=d.get("gamepad_profile"); sys.exit(0 if p is None else 0 if os.path.isfile(os.path.join(sys.argv[2], p)) else 1)' \
    "$def" "$(dirname "$def")" && ok "$emu: the gamepad profile, if named, is in the image" \
    || bad "$emu names a gamepad_profile that is not in the image"
  profile="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("gamepad_profile") or "")' "$def")"
  [ -z "$profile" ] || { guide_layer_ok "$(dirname "$def")/$profile" \
    && ok "$emu: its gamepad profile carries OGUI's Guide (layer + ui_guide tap, Guide+A/X)" \
    || bad "$emu: $profile lacks Guide -> [layer, dbus ui_guide] or the layer's South -> ui_quick / North -> ui_osk"; }
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
# armGBA (gb, gbc, gba): SDL game-controller API, so the pad maps itself; its Nintendo layout (A east,
# B south) is the default and is not seeded. Its Hotkey must be Select (4 = SDL_CONTROLLER_BUTTON_BACK):
# on Auto it takes Home (Guide), which OpenGamepadUI owns. Select + Start pressed twice quits (a
# combination: no single-button quit, user 2026-10-06), so the seed must not rebind the Quit action.
has armgba/frontend.cfg 'hotkeypad = 4' "Hotkey on Select, not Guide"
lacks armgba/frontend.cfg '^hotkeypad = 5$' "Hotkey on Guide (5), which OGUI owns"
lacks armgba/frontend.cfg '^hotkeypad_12 =' "Quit rebound (the default Hotkey + Start, pressed twice, stays)"
lacks armgba/frontend.cfg '^pad_[0-9]+ =' "pad buttons seeded by raw number (SDL maps the pad; Nintendo layout is the default)"
has armgba/frontend.cfg 'bios_folder = "/home/player/bios"' "BIOS files in the flat ~/bios"
has armgba/frontend.cfg 'save_folder = "/home/player/saves/gba"' "Open's saves in ~/saves/gba"
has armgba/frontend.cfg 'state_folder = "/home/player/states/gba"' "Open's states in ~/states/gba"
has armgba/frontend.cfg 'fullscreen = true' "fullscreen for Open too"
AG_DEF="$SEED_DIR/armgba/emulator.json"
[ "$(jget "$AG_DEF" format)" = '"appimage"' ] && [ "$(jget "$AG_DEF" binary)" = '"usr/bin/armgba"' ] \
  && [ "$(jget "$AG_DEF" args)" = '["--fullscreen", "{rom}"]' ] && [ "$(jget "$AG_DEF" gui_args)" = '["--fullscreen"]' ] \
  && ok "armgba: upstream's plain AppImage, its real binary, --fullscreen for a game and for Open" \
  || bad "armgba emulator.json: $(jget "$AG_DEF" format) $(jget "$AG_DEF" binary) $(jget "$AG_DEF" args)"
# armGBA has ONE save and ONE state folder, set only in frontend.cfg: the launcher writes the card's
# system into both before every game (system_settings), so saves stay in ~/saves/<system>.
python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["system_settings"]
keys={(a["key"], a["value"]) for s in d for a in s["set"] if s["file"] == ".config/armgba/frontend.cfg" and s["format"] == "ini"}
sys.exit(not keys >= {("save_folder", "\"/home/player/saves/{system}\""), ("state_folder", "\"/home/player/states/{system}\"")})' "$AG_DEF" \
  && ok "armgba: save_folder and state_folder follow the card's system (system_settings on frontend.cfg)" \
  || bad "armgba: per-system save/state folders are not written by system_settings"
[ -z "$(jget "$AG_DEF" env | grep -o SDL_NO_SIGNAL_HANDLERS)" ] \
  && ok "armgba: SDL's SIGTERM handler kept (its quit event writes the save; HW rule for mGBA's SIGTERM no longer applies)" \
  || bad "armgba sets SDL_NO_SIGNAL_HANDLERS: a SIGTERM would end it without writing the save"
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
sys.exit(not (e.get("LD_PRELOAD") == "/usr/lib/retroforge/libretroforge-sigdefer.so" and e.get("SHARUN_ALLOW_LD_PRELOAD") == "1"))' \
  "$SEED_DIR/snes9x/emulator.json" && ok "snes9x: the sigdefer shim is preloaded, through sharun" || bad "snes9x: sigdefer shim not preloaded (LD_PRELOAD + SHARUN_ALLOW_LD_PRELOAD)"
python3 -c 'import json,sys; e=json.load(open(sys.argv[1]))["env"]
sys.exit(not (e.get("LD_PRELOAD") == "/usr/lib/retroforge/libretroforge-hidemenu.so" and e.get("SHARUN_ALLOW_LD_PRELOAD") == "1"))' \
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
sys.exit(not (d["env"].get("SDL_NO_SIGNAL_HANDLERS") == "1" and all("dual_screen_file" in s for s in d["seed"])))' "$SEED_DIR/$emu/emulator.json" \
    && ok "$emu: dual-screen seed, SIGTERM not caught by SDL" || bad "$emu: no dual-screen seed or SDL_NO_SIGNAL_HANDLERS"
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
sys.exit(not (i == [{"from": "bios/PS3UPDAT.PUP", "unless": ".config/rpcs3/dev_flash/vsh/etc/version.txt", "args": ["--headless", "--installfw", "{file}"]}]))' \
  "$SEED_DIR/rpcs3/emulator.json" && ok "rpcs3: the player's PS3UPDAT.PUP is installed headless before the first game" || bad "rpcs3: firmware install step missing or changed"


# =================================================================================================
CASE="Guide hotkeys"
# Each gamepad_profile's guide layer turns Guide+L1/R1/R2/Start into keys the seed binds: load
# state, save state, fast-forward, quit (keyboard F1-F4 where the emulator lets us bind them; its
# fixed shortcuts where it does not). A seed that loses one of these rows leaves that Guide chord
# dead with no error anywhere, so every row is pinned here. The why of each is in the seed.
has duckstation/settings.ini 'LoadSelectedSaveState = Keyboard/F1' "Guide+L1 quick load"
has duckstation/settings.ini 'SaveSelectedSaveState = Keyboard/F2' "Guide+R1 quick save"
has duckstation/settings.ini 'FastForward = Keyboard/F3' "Guide+R2 fast-forward (hold)"
has duckstation/settings.ini 'PowerOff = Keyboard/F4' "Guide+Start quits (-batch ends the process)"
has duckstation/settings.ini 'ConfirmPowerOff = false' "PowerOff hotkey must not stop on a dialog"
has armsx2/PCSX2.ini 'LoadStateFromSlot1 = Keyboard/F1' "Guide+L1 load slot 1"
has armsx2/PCSX2.ini 'SaveStateToSlot1 = Keyboard/F2' "Guide+R1 save slot 1"
has armsx2/PCSX2.ini 'HoldTurbo = Keyboard/F3' "Guide+R2 fast-forward (hold)"
has armsx2/PCSX2.ini 'ShutdownVM = Keyboard/F4' "Guide+Start quits (-batch ends the process)"
has armsx2/PCSX2.ini 'ConfirmShutdown = false' "ShutdownVM hotkey must not stop on a dialog"
has ppsspp/controls.ini 'Load State = 1-131' "Guide+L1 load state (keyboard F1)"
has ppsspp/controls.ini 'Save State = 1-132' "Guide+R1 save state (keyboard F2)"
has ppsspp/controls.ini 'Fast-forward = 1-133' "Guide+R2 fast-forward (keyboard F3)"
has ppsspp/controls.ini 'Exit App = 1-134' "Guide+Start quits (keyboard F4)"
has ppsspp/ppsspp.ini 'AskForExitConfirmationAfterSeconds = 0' "Exit App must not stop on a dialog"
has dolphin/Hotkeys.ini 'Load State/Load State Slot 1 = `XInput2/0/Virtual core pointer:F1`' "Guide+L1 loads slot 1"
has dolphin/Hotkeys.ini 'Save State/Save State Slot 1 = `XInput2/0/Virtual core pointer:F2`' "Guide+R1 saves slot 1"
has dolphin/Hotkeys.ini 'Emulation Speed/Disable Emulation Speed Limit = `XInput2/0/Virtual core pointer:F3`' "Guide+R2 fast-forward while held"
for f in qt-config.ini qt-config-dual-screen.ini; do
  has azahar/$f 'Shortcuts\Main%20Window\Quick%20Load\KeySeq=F1' "Guide+L1 quick load"
  has azahar/$f 'Shortcuts\Main%20Window\Quick%20Save\KeySeq=F2' "Guide+R1 quick save"
  has azahar/$f 'Shortcuts\Main%20Window\Toggle%20Turbo%20Mode\KeySeq=F3' "Guide+R2 turbo toggle"
  has azahar/$f 'Shortcuts\Main%20Window\Exit%20Azahar\KeySeq=F4' "Guide+Start quits"
  has azahar/$f 'Shortcuts\Main%20Window\Load%20Amiibo\KeySeq=' "default F2 (Load Amiibo) cleared"
  has azahar/$f 'Shortcuts\Main%20Window\Remove%20Amiibo\KeySeq=' "default F3 (Remove Amiibo) cleared"
  has azahar/$f 'Shortcuts\Main%20Window\Continue\Pause%20Emulation\KeySeq=' "default F4 (pause) cleared"
  has azahar/$f 'Shortcuts\Main%20Window\Swap%20Screens\KeySeq=F9' "Guide+L2 swaps the screens"
  lacks azahar/$f 'controller_keyseq=.*button:(7|8)"' "screen shortcut on L3/R3 alone (too easy to click)"
done
# One screen per panel on a dual-screen board: only the swap there, the layout never changes.
has azahar/qt-config.ini 'Shortcuts\Main%20Window\Toggle%20Screen%20Layout\KeySeq=F10' "Guide+Y cycles the layouts"
has azahar/qt-config-dual-screen.ini 'Shortcuts\Main%20Window\Toggle%20Screen%20Layout\KeySeq=' "dual screen: no layout change (default F10 emptied)"
for row in '<ToggleFastForward>342 -1</ToggleFastForward>:Guide+R2 toggles fast-forward (WXK_F3)' \
           '<ExitApplication>343 -1</ExitApplication>:Guide+Start quits Cemu (WXK_F4)'; do
  grep -qE "^[[:space:]]*${row%%:*}\$" "$SEED_DIR/cemu/settings.xml" && ok "cemu/settings.xml: ${row#*:}" \
    || bad "cemu/settings.xml lacks ${row%%:*} (${row#*:})"
done
for f in melonDS.toml melonDS-dual-screen.toml; do
  has melonds/$f '[Instance0.Keyboard]' "keyboard hotkeys section (Guide layer)"
  has melonds/$f 'HK_FastForward = 16777273' "F10 (Qt::Key_F10) fast-forwards: Guide+R2"
  has melonds/$f 'HK_SwapScreens = 16777274' "F11 (Qt::Key_F11) swaps the screens: Guide+L2"
  has melonds/$f 'HK_Mic = 16777233' "End (Qt::Key_End) is the mic, held: Guide+R3"
  lacks melonds/$f '^HK_(Mic|SwapScreens) = (9|10)$' "mic or swap on L3/R3 alone (too easy to click)"
done
has melonds/melonDS.toml 'HK_SwapScreenEmphasis = 16777232' "Home (Qt::Key_Home) swaps the emphasis: Guide+Y"
has melonds/melonDS.toml 'ScreenSizing = 1' "top screen emphasized: the emphasis swap has nothing to swap at equal sizes"
lacks melonds/melonDS-dual-screen.toml '^HK_SwapScreenEmphasis' "dual screen: an emphasis hotkey (one screen per panel)"
has flycast/kbd.cfg 'version = 4' "current mapping format (bind lines)"
has flycast/kbd.cfg 'bind0 = 58:btn_jump_state' "F1 loads the state: Guide+L1"
has flycast/kbd.cfg 'bind1 = 59:btn_quick_save' "F2 saves the state: Guide+R1"
has flycast/kbd.cfg 'bind2 = 60:btn_fforward' "F3 toggles fast-forward: Guide+R2"
has flycast/kbd.cfg 'bind3 = 61:btn_escape' "F4 quits (dc_exit): Guide+Start"
grep -qF '"to": ".config/flycast/mappings/SDL_Keyboard.cfg"' "$SEED_DIR/flycast/emulator.json" \
  && ok "flycast: kbd.cfg seeds SDL_Keyboard.cfg (the keyboard device's mapping file)" || bad "flycast: kbd.cfg is not seeded as mappings/SDL_Keyboard.cfg"
has clownmdemu/configuration.ini '[Keyboard Bindings]' "keyboard bindings section (Guide layer)"
has clownmdemu/configuration.ini '58 = INPUT_BINDING_QUICK_LOAD_STATE' "F1 quick load: Guide+L1"
has clownmdemu/configuration.ini '59 = INPUT_BINDING_QUICK_SAVE_STATE' "F2 quick save: Guide+R1"
has clownmdemu/configuration.ini '60 = INPUT_BINDING_FAST_FORWARD' "F3 fast-forward (held): Guide+R2"
has armgba/frontend.cfg 'hotkey_5 = 58' "F1 loads a state: Guide+L1"
has armgba/frontend.cfg 'hotkey_4 = 59' "F2 saves a state: Guide+R1"
has armgba/frontend.cfg 'hotkey_1 = 60' "F3 fast-forwards (held): Guide+R2"
has armgba/frontend.cfg 'hotkey_12 = 61' "F4 quits (twice within 3 s): Guide+Start"
has armgba/frontend.cfg 'hotkey_11 = 0' "Restart off F2"
has armgba/frontend.cfg 'hotkey_13 = 0' "Frame Rate off F3"
has rmg/mupen64plus.cfg 'LoadState = "F1"' "Guide+L1 loads state"
has rmg/mupen64plus.cfg 'SaveState = "F2"' "Guide+R1 saves state"
has rmg/mupen64plus.cfg 'LimitFPS = "F3"' "Guide+R2 toggles the speed limiter"
has rmg/mupen64plus.cfg 'Shutdown = "F4"' "Guide+Start stops emulation; -q quits RMG"
has rmg/mupen64plus.cfg 'SoftReset = ""' "F1 no longer soft-resets"
has rmg/mupen64plus.cfg 'Resume = ""' "F2 no longer pauses"
has rmg/mupen64plus.cfg 'Screenshot = ""' "F3 no longer takes a screenshot"
has rpcs3/CurrentSettings.ini 'game_window_savestate_1=F1' "Guide+L1 reboots from the newest savestate"
has rpcs3/CurrentSettings.ini 'game_window_savestate=F2' "Guide+R1 creates a savestate"
has rpcs3/CurrentSettings.ini 'game_window_frame_limit=F3' "Guide+R2 toggles the frame limit"
has rpcs3/CurrentSettings.ini 'game_window_stop=F4' "Guide+Start stops the game; --no-gui quits RPCS3"
has xemu/xemu.toml "f5 = 'quick'" "Guide+L1/R1 (F5 / Shift+F5) load/save the 'quick' snapshot"
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
  [ "$(RETROFORGE_EMU_DATA_DIR="$BAD" code psx "$ROM")" = 2 ] && [ ! -e "$HOME/.config/x.ini" ] \
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
bad_def "system_settings that are not a list" 'd["system_settings"] = {"file": ".config/x.ini"}'
bad_def "a system_settings file that is absolute" 'd["system_settings"] = [{"file": "/etc/x.ini", "format": "ini", "set": [{"section": "", "key": "a", "value": "b"}]}]'
bad_def "a system_settings file out of \$HOME (..)" 'd["system_settings"] = [{"file": "../x.ini", "format": "ini", "set": [{"section": "", "key": "a", "value": "b"}]}]'
bad_def "a system_settings format emuopts has no patcher for" 'd["system_settings"] = [{"file": ".config/x.conf", "format": "conf", "set": [{"section": "", "key": "a", "value": "b"}]}]'
bad_def "a system_settings separator that is not '='" 'd["system_settings"] = [{"file": ".config/x.ini", "format": "ini", "separator": ": ", "set": [{"section": "", "key": "a", "value": "b"}]}]'
bad_def "a system_settings separator on yaml" 'd["system_settings"] = [{"file": ".config/x.yml", "format": "yaml", "separator": "=", "set": [{"section": "", "key": "a", "value": "b"}]}]'
bad_def "system_settings with no settings" 'd["system_settings"] = [{"file": ".config/x.ini", "format": "ini", "set": []}]'
bad_def "a system_settings value with {rom}" 'd["system_settings"] = [{"file": ".config/x.ini", "format": "ini", "set": [{"section": "", "key": "game", "value": "{rom}"}]}]'
bad_def "a system_settings value over two lines" 'd["system_settings"] = [{"file": ".config/x.ini", "format": "ini", "set": [{"section": "", "key": "a", "value": "b\nc=d"}]}]'
bad_def "a system_settings setting with an empty key" 'd["system_settings"] = [{"file": ".config/x.ini", "format": "ini", "set": [{"section": "", "key": " ", "value": "b"}]}]'
bad_def "a system_settings setting with an extra field" 'd["system_settings"] = [{"file": ".config/x.ini", "format": "ini", "set": [{"section": "", "key": "a", "value": "b", "args": ["x"]}]}]'
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
bad_def "a gamepad_profile that is absolute" 'd["gamepad_profile"] = "/etc/passwd"'
bad_def "a gamepad_profile out of the image (..)" 'd["gamepad_profile"] = "../../../etc/passwd"'
printf '{not json' > "$BAD/duckstation/emulator.json"
[ "$(RETROFORGE_EMU_DATA_DIR="$BAD" code psx "$ROM")" = 2 ] && ok "a definition that is not JSON is refused (exit 2)" || bad "broken JSON was accepted"

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
[ ! -e "$RETROFORGE_LAUNCH_STATUS" ] && ok "a launch that ran leaves no failure status" || bad "status after a normal run: $(cat "$RETROFORGE_LAUNCH_STATUS")"
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
# its AppRun hook makes; retroforge-launch skips AppRun, so it makes the links itself (HW 2026-10-05).
export RETROFORGE_TMP_LINK_DIR="$T/tmplinks"; mkdir -p "$RETROFORGE_TMP_LINK_DIR" "$RETROFORGE_TMP_LINK_DIR/Taken"
SHARUN="$T/data-sharun"; mkdir -p "$SHARUN/duckstation"; cp "$DS_SEED" "$SHARUN/duckstation/"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["format"] = "appimage-sharun"; json.dump(d, open(sys.argv[2], "w"))' \
  "$DS_DEF" "$SHARUN/duckstation/emulator.json"
printf '%s\n' '#!/bin/sh' '_tmp_bin=""' '_tmp_lib=Taken' '_tmp_share=Gxbwc' '_tmp_share=../evil' \
  'ln -sfn "$APPDIR"/share /tmp/hostile' > "$T/sharun-hook"
reset_logs
RETROFORGE_EMU_DATA_DIR="$SHARUN" start_launcher
wait_for emu_up || bad "the emulator never started: $(cat "$T/launch.err")"
self="$(field self)"; mnt="${self%/usr/bin/duckstation-qt}"
[ "$(field vk)" = /usr/share/vulkan/icd.d/freedreno_icd.aarch64.json ] && [ "$(field sharun_sys)" = 1 ] \
  && ok "appimage-sharun runs on the image's Turnip (system ICD allowed and chosen)" \
  || bad "sharun Vulkan env: VK_DRIVER_FILES='$(field vk)' SHARUN_ALLOW_SYS_VKICD='$(field sharun_sys)'"
[ "$(field no_updates)" = 1 ] && ok "appimage-sharun turns pkgforge's self-updater off (DISABLE_AUTO_UPDATES=1): versions are pinned" \
  || bad "the sharun format does not set DISABLE_AUTO_UPDATES=1"
[ "$(readlink "$RETROFORGE_TMP_LINK_DIR/Gxbwc")" = "$mnt/share" ] \
  && ok "/tmp/<name> from the hook links to <mount>/share before the emulator starts" \
  || bad "no link to the mounted share: $(ls -l "$RETROFORGE_TMP_LINK_DIR" 2>&1 | tr '\n' ' ')"
[ -d "$RETROFORGE_TMP_LINK_DIR/Taken" ] && [ ! -L "$RETROFORGE_TMP_LINK_DIR/Taken" ] && grep -q "Taken exists and is not a link of ours" "$T/launch.err" \
  && ok "an existing non-link /tmp/<name> is left alone, with a warning" || bad "an existing directory was replaced or not reported"
[ "$(ls "$RETROFORGE_TMP_LINK_DIR" | sort | tr '\n' ' ')" = "Gxbwc Taken " ] \
  && ok "the hook is read as data: empty, '../' names and its commands make nothing" \
  || bad "unexpected entries: $(ls "$RETROFORGE_TMP_LINK_DIR" | tr '\n' ' ')"
touch "$T/stop-emu"; reap_launcher "$lpid" >/dev/null
[ ! -e "$RETROFORGE_TMP_LINK_DIR/Gxbwc" ] && [ ! -L "$RETROFORGE_TMP_LINK_DIR/Gxbwc" ] \
  && ok "the links go away with the mount (no dangling /tmp entries)" || bad "the /tmp link outlived the game"
echo 01-path-mapping-hardcoded.src.hook > "$T/sharun-hook-name"; reset_logs
RETROFORGE_EMU_DATA_DIR="$SHARUN" start_launcher; wait_for emu_up
self="$(field self)"; mnt="${self%/usr/bin/duckstation-qt}"
[ "$(readlink "$RETROFORGE_TMP_LINK_DIR/Gxbwc")" = "$mnt/share" ] \
  && ok "the hook is also read under its .src.hook name (PPSSPP's own anylinux build)" \
  || bad "no link from bin/01-path-mapping-hardcoded.src.hook: $(ls -l "$RETROFORGE_TMP_LINK_DIR" 2>&1 | tr '\n' ' ')"
touch "$T/stop-emu"; reap_launcher "$lpid" >/dev/null
rm -f "$T/sharun-hook-name" "$RETROFORGE_TMP_LINK_DIR/Gxbwc"; reset_logs
start_launcher; wait_for emu_up
[ ! -e "$RETROFORGE_TMP_LINK_DIR/Gxbwc" ] && [ -z "$(field vk)" ] \
  && ok "a plain appimage gets neither: links and Vulkan env belong to the sharun format" \
  || bad "the plain appimage format made sharun links or set VK_DRIVER_FILES"
touch "$T/stop-emu"; reap_launcher "$lpid" >/dev/null
rm -f "$T/sharun-hook"; unset RETROFORGE_TMP_LINK_DIR

# =================================================================================================
CASE="one-time install (emulator.json install)"
# RPCS3 needs the player's PS3 firmware imported before any game: emulator.json "install" runs the
# emulator's own binary once, from the mount, when its marker file is missing.
INST="$T/data-install"; mkdir -p "$INST/duckstation"; cp "$DS_SEED" "$INST/duckstation/"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["install"] = [{"from": "bios/fw.bin",
  "unless": ".config/fake/fw-ok", "args": ["--fake-install", "{file}"]}]; json.dump(d, open(sys.argv[2], "w"))' \
  "$DS_DEF" "$INST/duckstation/emulator.json"
ST="$T/launch.status"; reset_logs
rc=$(RETROFORGE_EMU_DATA_DIR="$INST" RETROFORGE_LAUNCH_STATUS="$ST" code psx "$ROM")
[ "$rc" = 3 ] && [ "$(cat "$ST" 2>/dev/null)" = "missing-file duckstation bios/fw.bin" ] && [ ! -e "$T/emu.log" ] \
  && ok "the player's file is missing: exit 3, status 'missing-file <emu> <path>', no game started" \
  || bad "missing install file: rc=$rc status='$(cat "$ST" 2>/dev/null)' emu ran=$([ -e "$T/emu.log" ] && echo yes || echo no)"
RETROFORGE_EMU_DATA_DIR="$INST" "$LAUNCH" --gui duckstation 2>"$T/launch.err" & lpid=$!; echo "$lpid" >> "$T/pids"
wait_for emu_up && [ ! -e "$T/install.log" ] && ok "--gui opens without it (and installs nothing)" || bad "--gui did not start without the install file"
touch "$T/stop-emu"; reap_launcher "$lpid" >/dev/null; reset_logs
mkdir -p "$HOME/bios"; : > "$HOME/bios/fw.bin"
rc=$(RETROFORGE_EMU_DATA_DIR="$INST" RETROFORGE_LAUNCH_STATUS="$ST" code psx "$ROM")
[ "$rc" = 3 ] && [ "$(cat "$ST" 2>/dev/null)" = "install-failed duckstation" ] && ! emu_up \
  && grep -q "^install --fake-install $HOME/bios/fw.bin$" "$T/install.log" \
  && ok "the install ran (binary from the mount, {file} = ~/<from>) but left no marker: install-failed, no game" \
  || bad "failed install: rc=$rc status='$(cat "$ST" 2>/dev/null)' log='$(cat "$T/install.log" 2>/dev/null)'"
[ ! -s "$T/mounts" ] && ok "and the mount is released" || bad "a failed install left the mount: $(cat "$T/mounts")"
touch "$T/install-works"; : > "$T/install.log"; reset_logs
RETROFORGE_EMU_DATA_DIR="$INST" start_launcher
wait_for emu_up && [ -f "$HOME/.config/fake/fw-ok" ] && [ "$(grep -c '^install' "$T/install.log")" = 1 ] \
  && ok "a working install runs once before the game, which then starts" || bad "install then game: $(cat "$T/launch.err")"
touch "$T/stop-emu"; reap_launcher "$lpid" >/dev/null; reset_logs
RETROFORGE_EMU_DATA_DIR="$INST" start_launcher; wait_for emu_up
[ "$(grep -c '^install' "$T/install.log")" = 1 ] && ok "with the marker present it never runs again" || bad "the install ran again"
touch "$T/stop-emu"; reap_launcher "$lpid" >/dev/null; reset_logs
# RPCS3's installer installs the firmware, then aborts (SIGABRT) on its way out: the marker is
# what counts, so the game starts; and installs never leave a core file (HW 2026-10-07).
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["install"] = [{"from": "bios/fw.bin",
  "unless": ".config/fake/fw-ok", "args": ["--fake-install", "{file}"]}]; json.dump(d, open(sys.argv[2], "w"))' \
  "$DS_DEF" "$INST/duckstation/emulator.json"
rm -rf "$HOME/.config/fake"; : > "$T/install.log"; touch "$T/install-crash"; reset_logs
( ulimit -c unlimited; RETROFORGE_EMU_DATA_DIR="$INST" exec "$LAUNCH" psx "$ROM" 2>"$T/launch.err" ) & lpid=$!; echo "$lpid" >> "$T/pids"
wait_for emu_up && [ -f "$HOME/.config/fake/fw-ok" ] && grep -q "but ~/.config/fake/fw-ok is there: installed" "$T/launch.err" \
  && ok "an installer that crashes after a good install: the marker is there, the game starts" \
  || bad "crashing installer: $(cat "$T/launch.err")"
grep -qx "core-limit=0" "$T/install.log" && ok "install steps run with no core file" || bad "install core limit: $(grep core-limit "$T/install.log")"
touch "$T/stop-emu"; reap_launcher "$lpid" >/dev/null; reset_logs; rm -f "$T/install-crash"

python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["args"] = ["-C", "saves=/home/player/saves/{system}", "{rom}"]
d["install"] = []; json.dump(d, open(sys.argv[2], "w"))' "$DS_DEF" "$INST/duckstation/emulator.json"
reset_logs; RETROFORGE_EMU_DATA_DIR="$INST" start_launcher; wait_for emu_up
[ "$(sed -n 's/^arg=//p' "$T/emu.log" | tr '\n' '|')" = "-C|saves=/home/player/saves/psx|$ROM|" ] \
  && ok "{system} in args becomes the card's system (one emulator, per-system folders on its command line)" \
  || bad "{system} not substituted: $(sed -n 's/^arg=//p' "$T/emu.log" | tr '\n' '|')"
touch "$T/stop-emu"; reap_launcher "$lpid" >/dev/null; reset_logs
# system_settings: the same for an emulator whose folders live only in its settings file (armGBA):
# written before every game with {system} in the path and the values, a missing file created, the
# player's other lines kept, and never for --gui (no system).
SS_CFG="$HOME/.config/fake/frontend.cfg"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["args"] = ["{rom}"]; d["install"] = []
d["system_settings"] = [{"file": ".config/fake/frontend.cfg", "format": "ini", "separator": " = ",
  "set": [{"section": "", "key": "save_folder", "value": "\"/home/player/saves/{system}\""},
          {"section": "", "key": "state_folder", "value": "\"/home/player/states/{system}\""}]},
  {"file": ".config/fake/{system}.ini", "format": "ini", "set": [{"section": "Paths", "key": "system", "value": "{system}"}]}]
json.dump(d, open(sys.argv[2], "w"))' "$DS_DEF" "$INST/duckstation/emulator.json"
rm -rf "$HOME/.config/fake"; reset_logs; RETROFORGE_EMU_DATA_DIR="$INST" start_launcher; wait_for emu_up
[ "$(cat "$SS_CFG" 2>/dev/null)" = "$(printf 'save_folder = "/home/player/saves/psx"\nstate_folder = "/home/player/states/psx"')" ] \
  && ok "system_settings: written into a file that was not there, {system} = the card's system, the entry's separator" \
  || bad "system_settings on a new file: $(cat "$SS_CFG" 2>/dev/null | tr '\n' '|')"
[ "$(cat "$HOME/.config/fake/psx.ini" 2>/dev/null)" = "$(printf '[Paths]\nsystem=psx')" ] \
  && ok "system_settings: {system} in the file name too, a section made, '=' by default" \
  || bad "system_settings with {system} in the path: $(cat "$HOME/.config/fake/psx.ini" 2>/dev/null | tr '\n' '|')"
touch "$T/stop-emu"; reap_launcher "$lpid" >/dev/null; reset_logs
printf '# armgba rewrites me\nscale = 3\nsave_folder = "/home/player/saves/md"\nstate_folder = "/home/player/states/gb"\nvolume = 80\n' > "$SS_CFG"
RETROFORGE_EMU_DATA_DIR="$INST" start_launcher; wait_for emu_up
[ "$(cat "$SS_CFG")" = "$(printf '# armgba rewrites me\nscale = 3\nsave_folder = "/home/player/saves/psx"\nstate_folder = "/home/player/states/psx"\nvolume = 80')" ] \
  && ok "system_settings: a value the player (or the last game) left is replaced in place, every other line kept" \
  || bad "system_settings over an existing file: $(cat "$SS_CFG" | tr '\n' '|')"
touch "$T/stop-emu"; reap_launcher "$lpid" >/dev/null; reset_logs
printf 'save_folder = "/home/player/saves/gb"\n' > "$SS_CFG"
RETROFORGE_EMU_DATA_DIR="$INST" "$LAUNCH" --gui duckstation 2>"$T/launch.err" & lpid=$!; echo "$lpid" >> "$T/pids"
wait_for emu_up
[ "$(cat "$SS_CFG")" = 'save_folder = "/home/player/saves/gb"' ] && ok "system_settings: --gui (no system) leaves the file alone" \
  || bad "--gui rewrote the per-system settings: $(cat "$SS_CFG" | tr '\n' '|')"
touch "$T/stop-emu"; reap_launcher "$lpid" >/dev/null; reset_logs
# A file that cannot be written is a warning: the game still starts (as with sync).
mkdir -p "$HOME/.config/fake/frontend.cfg.d"; rm -f "$SS_CFG"; ln -s frontend.cfg.d "$SS_CFG"
RETROFORGE_EMU_DATA_DIR="$INST" start_launcher
wait_for emu_up && grep -q "warning: duckstation: could not write psx's settings" "$T/launch.err" \
  && ok "system_settings: an unwritable file is a warning and the game starts" \
  || bad "system_settings on an unwritable file: emu up=$(emu_up && echo yes || echo no) err='$(cat "$T/launch.err")'"
touch "$T/stop-emu"; reap_launcher "$lpid" >/dev/null; reset_logs; rm -rf "$HOME/.config/fake"
# system_args: one emulator, several systems it must be told about (e.g. --system "Mega Drive").
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["args"] = ["-f", "{rom}"]; d["install"] = []
d["system_args"] = {"psx": ["--system", "Play Station", "--saves={system}"], "md": ["--system", "Mega Drive"]}
json.dump(d, open(sys.argv[2], "w"))' "$DS_DEF" "$INST/duckstation/emulator.json"
reset_logs; RETROFORGE_EMU_DATA_DIR="$INST" start_launcher; wait_for emu_up
[ "$(sed -n 's/^arg=//p' "$T/emu.log" | tr '\n' '|')" = "--system|Play Station|--saves=psx|-f|$ROM|" ] \
  && ok "system_args: the card's system's own arguments come first, {system} substituted, other systems' not used" \
  || bad "system_args: $(sed -n 's/^arg=//p' "$T/emu.log" | tr '\n' '|')"
touch "$T/stop-emu"; reap_launcher "$lpid" >/dev/null; reset_logs
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["args"] = ["-f", "{rom}"]; d["install"] = []
d["system_args"] = {"md": ["--system", "Mega Drive"]}; json.dump(d, open(sys.argv[2], "w"))' "$DS_DEF" "$INST/duckstation/emulator.json"
reset_logs; RETROFORGE_EMU_DATA_DIR="$INST" start_launcher; wait_for emu_up
[ "$(sed -n 's/^arg=//p' "$T/emu.log" | tr '\n' '|')" = "-f|$ROM|" ] \
  && ok "system_args: a system without an entry gets none" || bad "system_args (none): $(sed -n 's/^arg=//p' "$T/emu.log" | tr '\n' '|')"
touch "$T/stop-emu"; reap_launcher "$lpid" >/dev/null; reset_logs
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["gui_args"] = ["{system}"]; json.dump(d, open(sys.argv[2], "w"))' \
  "$DS_DEF" "$INST/duckstation/emulator.json"
[ "$(RETROFORGE_EMU_DATA_DIR="$INST" code --gui duckstation)" = 2 ] && ok "{system} in gui_args is refused (exit 2): Open has no system" || bad "gui_args with {system} accepted"
# OGUI's Exit during the install: no game afterwards, no status (the player chose to leave).
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["args"] = ["{rom}"]; d["install"] = [{"from": "bios/fw.bin",
  "unless": ".config/fake/slow-ok", "args": ["--fake-install", "{file}"]}]; json.dump(d, open(sys.argv[2], "w"))' \
  "$DS_DEF" "$INST/duckstation/emulator.json"
touch "$T/install-slow"; rm -f "$ST" "$T/install-running"; reset_logs
# Under a stand-in reaper, as in "OGUI Exit" below: reap() signals the launcher too.
RETROFORGE_EMU_DATA_DIR="$INST" RETROFORGE_LAUNCH_STATUS="$ST" setsid bash -c 'echo $$ >> "$2/pids"; "$0" psx "$1"; echo "$?" > "$2/install-rc"' \
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
reset_logs; ( ulimit -c unlimited; RETROFORGE_EMU_DATA_DIR="$INST" exec "$LAUNCH" psx "$ROM" 2>"$T/launch.err" ) & lpid=$!; echo "$lpid" >> "$T/pids"
wait_for emu_up; [ "$(field core)" = 0 ] && ok "core_dumps false: the emulator runs with no core file (RLIMIT_CORE 0)" || bad "core_dumps false: ulimit -c is '$(field core)'"
touch "$T/stop-emu"; reap_launcher "$lpid" >/dev/null; reset_logs
( ulimit -c unlimited; exec "$LAUNCH" psx "$ROM" 2>"$T/launch.err" ) & lpid=$!; echo "$lpid" >> "$T/pids"
wait_for emu_up; [ "$(field core)" = unlimited ] && ok "by default the emulator keeps the session's core limit" || bad "default core limit changed: '$(field core)'"
touch "$T/stop-emu"; reap_launcher "$lpid" >/dev/null; reset_logs
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["core_dumps"] = "no"; json.dump(d, open(sys.argv[2], "w"))' \
  "$DS_DEF" "$INST/duckstation/emulator.json"
[ "$(RETROFORGE_EMU_DATA_DIR="$INST" code psx "$ROM")" = 2 ] && ok "core_dumps must be a boolean (exit 2)" || bad "core_dumps \"no\" accepted"
for broken in '[{"from": "a", "unless": "b", "args": ["x"]}]' '[{"from": "../a", "unless": "b", "args": ["{file}"]}]' \
              '[{"from": "bios/a b.pup", "unless": "b", "args": ["{file}"]}]' '[{"from": "a", "unless": "b", "args": ["{file}", "{system}"]}]' \
              '[{"from": "a", "args": ["{file}"]}]' '[{"from": "a", "unless": "b", "args": ["{file}", "{rom}"]}]'; do
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["install"] = json.loads(sys.argv[3]); json.dump(d, open(sys.argv[2], "w"))' \
    "$DS_DEF" "$INST/duckstation/emulator.json" "$broken"
  [ "$(RETROFORGE_EMU_DATA_DIR="$INST" code psx "$ROM")" = 2 ] && ok "install refused (exit 2): $broken" || bad "install accepted: $broken"
done

# =================================================================================================
CASE="first-run settings on a dual-screen board"
# A dual-screen board (device-env declares a second panel) gets the seed's dual_screen_file instead.
DUAL="$T/data-dual"; mkdir -p "$DUAL/duckstation"; cp "$DS_SEED" "$DUAL/duckstation/"
echo "dual-screen settings" > "$DUAL/duckstation/settings-dual.ini"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1]));
d["seed"] = [dict(s, dual_screen_file="settings-dual.ini") for s in d["seed"]]; json.dump(d, open(sys.argv[2], "w"))' \
  "$DS_DEF" "$DUAL/duckstation/emulator.json"
fake_device_env() { printf '#!/bin/sh\necho "RETROFORGE_SECONDARY_CONNECTOR=%s"\n' "$1" > "$T/device-env"; chmod +x "$T/device-env"; }
for board in dual single; do
  [ "$board" = dual ] && fake_device_env "'DSI-2'" || fake_device_env "''"
  rm -rf "$HOME"; mkdir -p "$HOME"; reset_logs
  RETROFORGE_EMU_DATA_DIR="$DUAL" RETROFORGE_DEVICE_ENV="$T/device-env" start_launcher
  wait_for emu_up || bad "the emulator never started: $(cat "$T/launch.err")"
  touch "$T/stop-emu"; reap_launcher "$lpid"
  want="$DS_SEED"; [ "$board" = dual ] && want="$DUAL/duckstation/settings-dual.ini"
  cmp -s "$want" "$seeded" && ok "a $board-screen board is seeded with $(basename "$want")" \
    || bad "a $board-screen board did not get $(basename "$want")"
done

# =================================================================================================
CASE="a card moved to a board with the other panel count"
# /home is on the card: a home seeded on one kind of board boots on the other. Only the settings the
# two variants disagree on follow the board; the player's other changes stay.
MOVE="$T/data-move"; mkdir -p "$MOVE/duckstation"
printf '[Main]\nVolume = 50\n\n[Window0]\nSizing = 0\n' > "$MOVE/duckstation/settings.ini"
printf '[Main]\nVolume = 50\n\n[Window0]\nSizing = 4\n\n[Window1]\nEnabled = true\nSizing = 5\n' > "$MOVE/duckstation/settings-dual.ini"
cp "$DUAL/duckstation/emulator.json" "$MOVE/duckstation/"
marker="$HOME/.config/retroforge/seed-board/duckstation"
launch_on() {  # launch_on dual|single: one run of the launcher on that kind of board
  [ "$1" = dual ] && fake_device_env "'DSI-2'" || fake_device_env "''"
  reset_logs; RETROFORGE_EMU_DATA_DIR="$MOVE" RETROFORGE_DEVICE_ENV="$T/device-env" start_launcher
  wait_for emu_up || bad "the emulator never started: $(cat "$T/launch.err")"
  touch "$T/stop-emu"; reap_launcher "$lpid"
}
val() { awk -v sec="[$1]" -v key="$2" '/^\[/ { in_s = ($0 == sec); next }
  in_s { split($0, kv, " = "); if (kv[1] == key) { print kv[2]; exit } }' "$seeded"; }
rm -rf "$HOME"; mkdir -p "$HOME"
launch_on single
[ "$(cat "$marker" 2>/dev/null)" = single ] && ok "the seeded variant is recorded (single)" || bad "seed-board marker: '$(cat "$marker" 2>/dev/null)'"
sed -i 's/^Volume = 50$/Volume = 80/' "$seeded"  # the player's own change
launch_on dual
[ "$(val Window0 Sizing)" = 4 ] && [ "$(val Window1 Enabled)" = true ] && [ "$(val Window1 Sizing)" = 5 ] \
  && ok "single -> dual board: the dual-screen layout (changed, and a new section added)" || bad "single -> dual: $(tr '\n' '|' < "$seeded")"
[ "$(val Main Volume)" = 80 ] && ok "and the player's other settings are kept" || bad "the player's Volume was lost: $(tr '\n' '|' < "$seeded")"
[ "$(cat "$marker")" = dual ] && ok "the marker follows the board" || bad "marker after the move: '$(cat "$marker")'"
grep -q "was set up on a single-screen board" "$T/launch.err" && ok "the switch is logged" || bad "the switch is not logged"
launch_on single
[ "$(val Window0 Sizing)" = 0 ] && [ -z "$(val Window1 Enabled)" ] && [ -z "$(val Window1 Sizing)" ] && [ "$(val Main Volume)" = 80 ] \
  && ok "dual -> single board: back to one window, the second window's settings gone" || bad "dual -> single: $(tr '\n' '|' < "$seeded")"
sed -i 's/^Sizing = 0$/Sizing = 2/' "$seeded"; before="$(cat "$seeded")"
launch_on single
[ "$(cat "$seeded")" = "$before" ] && ok "same board: the player's own layout is left alone" || bad "same board rewrote the file"
# A home seeded before the marker existed: judged by its layout settings.
cp "$MOVE/duckstation/settings-dual.ini" "$seeded"; sed -i 's/^Volume = 50$/Volume = 80/' "$seeded"; rm -f "$marker"
launch_on single
[ "$(val Window0 Sizing)" = 0 ] && [ -z "$(val Window1 Enabled)" ] && [ "$(val Main Volume)" = 80 ] && [ "$(cat "$marker")" = single ] \
  && ok "no marker, dual-screen layout on a single-screen board: switched, marker written" || bad "legacy dual home: $(tr '\n' '|' < "$seeded")"
sed -i 's/^Sizing = 0$/Sizing = 2/' "$seeded"; rm -f "$marker"; before="$(cat "$seeded")"
launch_on dual
[ "$(cat "$seeded")" = "$before" ] && [ "$(cat "$marker")" = dual ] \
  && ok "no marker, a layout of the player's own: left alone, marker written" || bad "legacy custom home rewritten: $(tr '\n' '|' < "$seeded")"
# A file that cannot be rewritten is a warning: the game still starts.
rm -f "$marker"; cp "$MOVE/duckstation/settings-dual.ini" "$seeded"; chmod a-w "$(dirname "$seeded")"
launch_on single
chmod u+w "$(dirname "$seeded")"
grep -q "warning: duckstation: could not switch" "$T/launch.err" && ok "a layout switch that fails is a warning, the game still runs" \
  || bad "no warning for a failed switch: $(cat "$T/launch.err")"

# =================================================================================================
CASE="GPU priority (the game-priority Vulkan layer)"
# Only the A7xx boards (SM8550, SM8650: preemptible rings) get RETROFORGE_GAME_LOWPRIO=1 and Turnip's
# preempt_optimize; the single-ring boards and an unknown one get neither, so the layer stays out of
# the process. The SoC class comes from device-env.
soc_device_env() { printf '#!/bin/sh\necho "RETROFORGE_SOC_CLASS=%s"\n' "$1" > "$T/device-env"; chmod +x "$T/device-env"; }
for soc in SM8550 SM8650 SM8250 SM6115 ""; do
  soc_device_env "'$soc'"; reset_logs
  RETROFORGE_DEVICE_ENV="$T/device-env" start_launcher
  wait_for emu_up || bad "the emulator never started: $(cat "$T/launch.err")"
  touch "$T/stop-emu"; reap_launcher "$lpid"
  lp=""; want=""; case "$soc" in SM8550|SM8650) lp=1; want=preempt_optimize ;; esac
  [ "$(field lowprio)" = "$lp" ] && [ "$(field tu_autotune)" = "$want" ] \
    && ok "${soc:-unknown board}: RETROFORGE_GAME_LOWPRIO='$lp', TU_AUTOTUNE_FLAGS='$want'" \
    || bad "${soc:-unknown board}: lowprio='$(field lowprio)' tu_autotune='$(field tu_autotune)'"
done
# A definition's env wins: an emulator that misbehaves at LOW opts out in its emulator.json.
PRIO="$T/data-prio"; mkdir -p "$PRIO/duckstation"; cp "$DS_SEED" "$PRIO/duckstation/"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["env"] = dict(d.get("env", {}), RETROFORGE_GAME_LOWPRIO="0", TU_AUTOTUNE_FLAGS="");
json.dump(d, open(sys.argv[2], "w"))' "$DS_DEF" "$PRIO/duckstation/emulator.json"
soc_device_env "'SM8650'"; reset_logs
RETROFORGE_EMU_DATA_DIR="$PRIO" RETROFORGE_DEVICE_ENV="$T/device-env" start_launcher
wait_for emu_up || bad "the emulator never started: $(cat "$T/launch.err")"
touch "$T/stop-emu"; reap_launcher "$lpid"
[ "$(field lowprio)" = 0 ] && [ -z "$(field tu_autotune)" ] && ok "a definition's env overrides both" \
  || bad "definition env lost: lowprio='$(field lowprio)' tu_autotune='$(field tu_autotune)'"

# =================================================================================================
CASE="VRAM report limit (mesa's vram-report-limit layer)"
# Every emulator gets the layer at 4096 MiB, keyed on device-env's RETROFORGE_GPU_CHIP_ID (the id
# Turnip reports; device-env derives it, tests/test-device-env.sh). No chip id, no limit. Nor below
# 15/16 of RAM = 4096 MiB, where the layer would report MORE than Turnip's real heap.
chip_device_env() { printf '#!/bin/sh\necho "RETROFORGE_GPU_CHIP_ID=%s"\n' "$1" > "$T/device-env"; chmod +x "$T/device-env"; }
meminfo() { printf 'MemTotal:       %s kB\nMemFree:          123456 kB\n' "$1" > "$T/meminfo"; }
meminfo 15820000   # a 16 GB board
export RETROFORGE_MEMINFO="$T/meminfo"
for chip in 0x5143:0x43051401 0x5143:0x06050002 0x5143:0x06010000 ""; do
  chip_device_env "$chip"; reset_logs
  RETROFORGE_DEVICE_ENV="$T/device-env" start_launcher
  wait_for emu_up || bad "the emulator never started: $(cat "$T/launch.err")"
  touch "$T/stop-emu"; reap_launcher "$lpid"
  if [ -z "$chip" ]; then
    [ -z "$(field vram_on)$(field vram_mib)$(field vram_id)" ] && ok "no GPU chip id: no limit" \
      || bad "no chip id: vram_on='$(field vram_on)' vram_id='$(field vram_id)'"
  else
    [ "$(field vram_on)" = 1 ] && [ "$(field vram_mib)" = 4096 ] && [ "$(field vram_id)" = "$chip" ] \
      && ok "chip $chip: 4096 MiB" \
      || bad "chip $chip: vram_on='$(field vram_on)' mib='$(field vram_mib)' id='$(field vram_id)'"
  fi
done
# A definition's env wins, as for GPU priority.
VRAM="$T/data-vram"; mkdir -p "$VRAM/duckstation"; cp "$DS_SEED" "$VRAM/duckstation/"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["env"] = dict(d.get("env", {}), ENABLE_MESA_VRAM_REPORT_LIMIT="0");
json.dump(d, open(sys.argv[2], "w"))' "$DS_DEF" "$VRAM/duckstation/emulator.json"
chip_device_env 0x5143:0x43051401; reset_logs
RETROFORGE_EMU_DATA_DIR="$VRAM" RETROFORGE_DEVICE_ENV="$T/device-env" start_launcher
wait_for emu_up || bad "the emulator never started: $(cat "$T/launch.err")"
touch "$T/stop-emu"; reap_launcher "$lpid"
[ "$(field vram_on)" = 0 ] && ok "a definition's env turns the limit off" || bad "definition env lost: vram_on='$(field vram_on)'"
# The RAM gate: 4 GB and 3 GB boards (Turnip heap ~3.4 / ~2.6 GiB) get no limit; 4369 MiB of RAM is
# exactly 4096 MiB of heap (not above: off); 6 GB is on; an unreadable meminfo is off.
chip_device_env 0x5143:0x06010000
for pair in "3770000 -" "2860000 -" "4473856 -" "5700000 1" "missing -"; do
  read -r kb want <<<"$pair"
  if [ "$kb" = missing ]; then rm -f "$T/meminfo"; else meminfo "$kb"; fi
  reset_logs; RETROFORGE_DEVICE_ENV="$T/device-env" start_launcher
  wait_for emu_up || bad "the emulator never started: $(cat "$T/launch.err")"
  touch "$T/stop-emu"; reap_launcher "$lpid"
  [ "$want" = - ] && want=""
  [ "$(field vram_on)" = "$want" ] && ok "MemTotal $kb kB: limit '${want:-off}'" \
    || bad "MemTotal $kb kB: vram_on='$(field vram_on)', want '${want:-off}'"
done
# The shell runs with its OWN, smaller report (retroforge-session) and starts us: an emulator must
# never inherit it. Below the gate nothing is set; above it the emulator's 4096 replaces the shell's.
for pair in "3386492 -" "15820000 4096"; do
  read -r kb want <<<"$pair"; meminfo "$kb"; reset_logs
  ENABLE_MESA_VRAM_REPORT_LIMIT=1 VK_VRAM_REPORT_LIMIT_HEAP_SIZE=512 VK_VRAM_REPORT_LIMIT_DEVICE_ID=0x5143:0x06010000 \
    RETROFORGE_DEVICE_ENV="$T/device-env" start_launcher
  wait_for emu_up || bad "the emulator never started: $(cat "$T/launch.err")"
  touch "$T/stop-emu"; reap_launcher "$lpid"
  [ "$want" = - ] && want=""
  [ "$(field vram_mib)" = "$want" ] && ok "MemTotal $kb kB under the shell's 512 MiB report: emulator gets '${want:-none}'" \
    || bad "MemTotal $kb kB: emulator inherited mib='$(field vram_mib)' on='$(field vram_on)', want '${want:-none}'"
done
unset RETROFORGE_MEMINFO

# =================================================================================================
CASE="exit_resend (a second window keeps the emulator up)"
RESEND="$T/data-resend"; mkdir -p "$RESEND/duckstation"; cp "$DS_SEED" "$RESEND/duckstation/"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["exit_resend"] = 0.5; json.dump(d, open(sys.argv[2], "w"))' \
  "$DS_DEF" "$RESEND/duckstation/emulator.json"
: > "$T/two-terms"
reset_logs
RETROFORGE_EMU_DATA_DIR="$RESEND" start_launcher
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
RETROFORGE_EMU_DATA_DIR="$RESEND" start_launcher
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
CASE="CPU pinning (CPUS=big)"
# The game's own conf (Game settings > RetroForge) holds the per-game choice.
GCONF="$HOME/.config/retroforge/games/psx/$(basename "$ROM").conf"
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
pinned_run() {  # one launch with the game's CPUS=big and the fake topology; prints the taskset list or "none"
  rm -f "$T/taskset.log"; reset_logs
  mkdir -p "$(dirname "$GCONF")"; echo "CPUS=big" > "$GCONF"
  RETROFORGE_CPU_ROOT="$T/cpu" "$LAUNCH" psx "$ROM" 2>"$T/launch.err" & lpid=$!; echo "$lpid" >> "$T/pids"
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
# Without a CPUS line (and nothing in the image can write one) nothing is pinned.
mkcpus 0-7 0:284 1:284 2:284 3:284 4:871 5:871 6:871 7:1024
rm -f "$T/taskset.log" "$GCONF"; reset_logs
RETROFORGE_CPU_ROOT="$T/cpu" start_launcher; wait_for emu_up; touch "$T/stop-emu"; reap_launcher "$lpid"
[ ! -e "$T/taskset.log" ] && ok "no CPUS line: no taskset (pinning is never the default)" || bad "pinned without a CPUS line"
[ "$(code --cpus big psx "$ROM")" = 2 ] && ok "--cpus is no longer an option (the confs hold the choice): exit 2" || bad "accepted --cpus"
grep -qs 'CPUS\|taskset' "$SEED_DIR"/*/emulator.json && bad "an emulator definition in the image pins CPUs: pinning must stay the player's choice" \
  || ok "no emulator definition in the image pins anything"

# =================================================================================================
CASE="player's emulator default (CPUS=)"
# Main menu > Emulators writes ~/.config/retroforge/emulators/<emu>.conf; the game's conf overrides it
# (Game settings > RetroForge: emulator default = no line / on = CPUS=big / off = CPUS=all).
PCONF="$HOME/.config/retroforge/emulators/duckstation.conf"
cpus_run() {  # one launch with the given arguments and the fake topology; prints the taskset list or "none"
  rm -f "$T/taskset.log"; reset_logs
  RETROFORGE_CPU_ROOT="$T/cpu" "$LAUNCH" "$@" 2>"$T/launch.err" & lpid=$!; echo "$lpid" >> "$T/pids"
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
printf '# set by Main menu > Emulators\nCPUS=big\n' > "$PCONF"
[ "$(cpus_run psx "$ROM")" = "4,5,6,7" ] && ok "CPUS=big: a game with no override is pinned" || bad "CPUS=big did not pin a ROM launch"
[ "$(cpus_run --gui duckstation)" = "4,5,6,7" ] && ok "CPUS=big: Open (--gui) is pinned too" || bad "CPUS=big did not pin --gui"
echo "CPUS=all" > "$GCONF"
[ "$(cpus_run psx "$ROM")" = none ] && ok "the game's CPUS=all beats the emulator's CPUS=big" || bad "the game's CPUS=all did not override CPUS=big"
[ "$(cpus_run --gui duckstation)" = "4,5,6,7" ] && ok "a game's conf never applies to Open (--gui)" || bad "a game's CPUS reached --gui"
echo "CPUS=all" > "$PCONF"; echo "CPUS=big" > "$GCONF"
[ "$(cpus_run psx "$ROM")" = "4,5,6,7" ] && ok "the game's CPUS=big beats the emulator's CPUS=all" || bad "the game's CPUS=big did not override CPUS=all"
rm -f "$GCONF"
printf 'CPUS=fast\n' > "$PCONF"
[ "$(cpus_run psx "$ROM")" = none ] && grep -q "ignoring" "$T/launch.err" \
  && ok "an unknown CPUS value is ignored (not pinned) and reported" || bad "a bad CPUS value was not ignored with a warning"
echo "CPUS=big" > "$PCONF"; echo "CPUS=fast" > "$GCONF"
[ "$(cpus_run psx "$ROM")" = "4,5,6,7" ] && grep -q "ignoring" "$T/launch.err" \
  && ok "an unknown game CPUS value falls back to the emulator's, reported" || bad "a bad game CPUS value did not fall back"
rm -f "$GCONF"
printf 'CPUS=big\n$(touch %s/pwned)\n' "$T" > "$PCONF"
cpus_run psx "$ROM" >/dev/null
[ ! -e "$T/pwned" ] && ok "the player conf is read, never run as shell" || bad "the player conf was executed"
rm -f "$PCONF"

# =================================================================================================
CASE="per-emulator options (options.json)"
# Main menu > Emulators and Game settings > RetroForge write option lines into the same confs as CPUS;
# options.json says what each value does. The emulator's choice is written into its settings and stays;
# the game's is put back when the emulator exits, and by the next launch after a double Exit.
OPTD="$T/data-options"; mkdir -p "$OPTD/duckstation"; cp "$DS_DEF" "$DS_SEED" "$OPTD/duckstation/"
cat > "$OPTD/duckstation/options.json" <<'JSON'
{"files": {"main": {"path": ".local/share/duckstation/settings.ini", "format": "ini", "separator": " = "}},
 "options": [{"id": "aspect", "label": "Aspect ratio", "choices": [
   {"value": "4:3", "label": "4:3", "set": [{"file": "main", "section": "Display", "key": "AspectRatio", "value": "4:3"}]},
   {"value": "16:9", "label": "16:9", "set": [{"file": "main", "section": "Display", "key": "AspectRatio", "value": "16:9"},
                                            {"args": ["-fakewide"]}, {"env": {"FAKE_OPT": "wide"}}]}]}]}
JSON
DSINI="$HOME/.local/share/duckstation/settings.ini"
OPCONF="$HOME/.config/retroforge/emulators/duckstation.conf"
OGCONF="$HOME/.config/retroforge/games/psx/$(basename "$ROM").conf"
JOURNAL="$HOME/.local/state/retroforge/restore/duckstation.json"
aspect() { sed -n 's/^AspectRatio *= *//p' "$DSINI"; }
mkdir -p "$(dirname "$OPCONF")" "$(dirname "$OGCONF")"
echo "aspect=4:3" > "$OPCONF"; echo "aspect=16:9" > "$OGCONF"
reset_logs; RETROFORGE_EMU_DATA_DIR="$OPTD" start_launcher
wait_for emu_up || bad "the emulator never started: $(cat "$T/launch.err")"
mapfile -t args < <(sed -n 's/^arg=//p' "$T/emu.log")
[ "${args[0]}" = -fakewide ] && [ "${args[*]:1}" = "-batch -fullscreen -- $ROM" ] \
  && ok "a game choice's arguments come first, the definition's after" || bad "arguments were: $(printf '[%s] ' "${args[@]}")"
[ "$(field opt_env)" = wide ] && ok "a game choice's env reaches the emulator" || bad "opt env: '$(field opt_env)'"
[ "$(aspect)" = 16:9 ] && [ -f "$JOURNAL" ] && ok "during the run the game's value is in the emulator's settings (journalled)" \
  || bad "during the run AspectRatio='$(aspect)', journal $( [ -f "$JOURNAL" ] && echo present || echo missing)"
touch "$T/stop-emu"; reap_launcher "$lpid" >/dev/null
[ "$(aspect)" = 4:3 ] && [ ! -e "$JOURNAL" ] && ok "after the run the emulator's own choice is back, no journal left" \
  || bad "after the run AspectRatio='$(aspect)'"
reset_logs; RETROFORGE_EMU_DATA_DIR="$OPTD" "$LAUNCH" --gui duckstation 2>"$T/launch.err" & lpid=$!; echo "$lpid" >> "$T/pids"
wait_for emu_up || bad "the emulator never started: $(cat "$T/launch.err")"
[ "$(aspect)" = 4:3 ] && ! grep -qx arg=-fakewide "$T/emu.log" && ok "Open (--gui) gets the emulator's choice, never a game's" \
  || bad "--gui: AspectRatio='$(aspect)'"
touch "$T/stop-emu"; reap_launcher "$lpid" >/dev/null
# A double Exit SIGKILLed the last run mid-game: its journal is still there, the game's value in the file.
rm -f "$OGCONF"; sed -i 's/^AspectRatio = .*/AspectRatio = 16:9/' "$DSINI"
mkdir -p "$(dirname "$JOURNAL")"
printf '{"version": 1, "restore": [{"path": "%s", "format": "ini", "separator": " = ", "section": "Display", "key": "AspectRatio", "value": "Auto (Game Native)"}]}' "$DSINI" > "$JOURNAL"
rm -f "$OPCONF"
reset_logs; RETROFORGE_EMU_DATA_DIR="$OPTD" start_launcher
wait_for emu_up || bad "the emulator never started: $(cat "$T/launch.err")"
[ "$(aspect)" = "Auto (Game Native)" ] && [ ! -e "$JOURNAL" ] \
  && ok "a journal a killed run left is restored before the next start" || bad "after a killed run AspectRatio='$(aspect)'"
touch "$T/stop-emu"; reap_launcher "$lpid" >/dev/null
echo "aspect=21:9" > "$OGCONF"
reset_logs; RETROFORGE_EMU_DATA_DIR="$OPTD" start_launcher
wait_for emu_up || bad "the emulator never started: $(cat "$T/launch.err")"
grep -q "aspect=21:9 is not one of" "$T/launch.err" && [ "$(aspect)" = "Auto (Game Native)" ] \
  && ok "a value options.json does not have is ignored with a warning" || bad "unknown value: AspectRatio='$(aspect)'"
touch "$T/stop-emu"; reap_launcher "$lpid" >/dev/null
rm -f "$OGCONF"
echo '{"options": [{"id": "x"}]}' > "$OPTD/duckstation/options.json"
[ "$(RETROFORGE_EMU_DATA_DIR="$OPTD" code psx "$ROM")" = 2 ] && ok "an invalid options.json is refused (exit 2)" || bad "an invalid options.json was accepted"

# =================================================================================================
CASE="emulator GUI (--gui)"
# The plugin store's Open: the emulator's own UI with no ROM, for the settings OGUI does not expose.
# Same mount / setsid / exit handling as a ROM; the definition's gui_args instead of args.
[ "$(code --gui)" = 2 ] && ok "--gui with no emulator: exit 2" || bad "accepted a bare --gui"
[ "$(code --gui 'duck;rm')" = 2 ] && ok "--gui with shell characters in the name: exit 2" || bad "accepted --gui 'duck;rm'"
[ "$(code --gui ../duckstation)" = 2 ] && ok "--gui with a path in the name: exit 2" || bad "accepted --gui ../duckstation"
[ "$(code --gui nosuchemu)" = 2 ] && ok "--gui with no conf for the emulator: exit 2" || bad "accepted an unknown emulator"
[ "$(code --gui duckstation "$ROM")" = 2 ] && ok "--gui with a ROM too: exit 2" || bad "accepted --gui duckstation <rom>"
[ "$(RETROFORGE_EMU_DIR="$T/none" code --gui duckstation)" = 3 ] \
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

# =================================================================================================
CASE="folder of scripts (PortMaster)"
# PortMaster is no AppImage: retroforge-emu unpacks it into ~/roms/ports/PortMaster. --gui runs its own
# PortMaster.sh from there; a ports card's "ROM" is the port's own launch script, run with bash
# (PortMaster installs ports as <Name>.sh beside its folder; their mode is not ours to trust).
SD="$T/defs-scripts"; mkdir -p "$SD/fakepm"
cat > "$SD/fakepm/emulator.json" <<'EOF'
{"format": "scripts", "root": "roms/ports/FakePM", "binary": "FakePM.sh", "args": ["{rom}"], "gui_args": ["--gui-arg"]}
EOF
echo "ports=fakepm" > "$T/launch-ports.conf"
sl() { RETROFORGE_EMU_DATA_DIR="$SD" RETROFORGE_LAUNCH_CONF="$T/launch-ports.conf" "$LAUNCH" "$@"; }
rm -rf "$HOME"; mkdir -p "$HOME/roms/ports"
PORT="$HOME/roms/ports/A Port.sh"; cp "$T/fake-emu" "$PORT"; chmod 644 "$PORT"
st="$T/launch.status.scripts"; rm -f "$st"
RETROFORGE_LAUNCH_STATUS="$st" sl --gui fakepm >/dev/null 2>&1; rc=$?
[ "$rc" = 3 ] && [ "$(cat "$st" 2>/dev/null)" = "not-installed fakepm" ] \
  && ok "not unpacked yet: exit 3, status 'not-installed fakepm'" || bad "rc=$rc status=$(cat "$st" 2>/dev/null)"
RETROFORGE_LAUNCH_STATUS="$st" sl ports "$PORT" >/dev/null 2>&1; rc=$?
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

CASE="folder of scripts: RetroForge's hook files (sync)"
# mod_RetroForge.txt / libgl_RetroForge.txt live in the image and are copied into PortMaster's folder at
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
[ -z "$(find "$HOME/roms/ports/FakePM" -name '*retroforge*')" ] && ok "no temporary file left" || bad "left: $(find "$HOME/roms/ports/FakePM" -name '*retroforge*')"

CASE="folder of scripts: runtimes a port left mounted"
# A port's runtime is a squashfuse mount (RetroForge's mount stand-in) that outlives the port when
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
RETROFORGE_PM_MOUNTS="$REG" sl ports "$PORT" 2>"$T/launch.err" & lpid=$!; echo "$lpid" >> "$T/pids"
wait_for emu_up || bad "the port never started: $(cat "$T/launch.err")"
grep -q "rt1" "$T/fusermount2.log" 2>/dev/null && bad "released a mount while the port still ran" || ok "nothing is released while the port runs"
ogui_reap "$lpid"; reap_launcher "$lpid"
grep -qx -- "-u -z $T/rt1" "$T/fusermount2.log" 2>/dev/null && ok "after the port, its runtime mount is released (fusermount -u -z)" || bad "fusermount calls: $(cat "$T/fusermount2.log" 2>/dev/null)"
! grep -q gone "$T/fusermount2.log" 2>/dev/null && ok "a registry entry no longer mounted is skipped" || bad "unmounted something not mounted"
[ ! -s "$REG" ] && ok "the registry is emptied" || bad "registry left: $(cat "$REG")"
rm -f "$T/bin/fusermount"

# =================================================================================================
CASE="plain binary format"
# A release asset that is ONE plain executable, no AppImage (gopher64 shipped this way until RMG
# replaced it; the format stays for the next such emulator): retroforge-emu still saves it as
# <tag>.AppImage and points `current` at it; the binary format runs `current` in place, no mount.
BD="$T/defs-binary"; mkdir -p "$BD/fakebin"
cat > "$BD/fakebin/emulator.json" <<'EOF'
{"format": "binary", "binary": "current", "args": ["--fullscreen", "{rom}"], "gui_args": []}
EOF
echo "n64=fakebin" > "$T/launch-binary.conf"
bl() { RETROFORGE_EMU_DATA_DIR="$BD" RETROFORGE_LAUNCH_CONF="$T/launch-binary.conf" "$LAUNCH" "$@"; }
mkdir -p "$T/roms/n64"; NROM="$T/roms/n64/A Game (USA).z64"; : > "$NROM"
st="$T/launch.status.binary"; rm -f "$st"
RETROFORGE_LAUNCH_STATUS="$st" bl n64 "$NROM" >/dev/null 2>&1; rc=$?
[ "$rc" = 3 ] && [ "$(cat "$st" 2>/dev/null)" = "not-installed fakebin" ] \
  && ok "not installed: exit 3, status 'not-installed fakebin'" || bad "rc=$rc status=$(cat "$st" 2>/dev/null)"
mkdir -p "$T/emus/fakebin"; cp "$T/fake-emu" "$T/emus/fakebin/v1.0.0.AppImage"
ln -s v1.0.0.AppImage "$T/emus/fakebin/current"
reset_logs
bl n64 "$NROM" 2>"$T/launch.err" & lpid=$!; echo "$lpid" >> "$T/pids"
wait_for emu_up || bad "the emulator never started: $(cat "$T/launch.err")"
[ "$(field self)" = "$T/emus/fakebin/current" ] \
  && ok "runs current in place (the download itself)" || bad "ran '$(field self)'"
mapfile -t args < <(sed -n 's/^arg=//p' "$T/emu.log")
[ "${args[*]}" = "--fullscreen $NROM" ] \
  && ok "arguments are the definition's args with the ROM" || bad "args were: $(printf '[%s] ' "${args[@]}")"
[ "$(field pid)" = "$(field sid)" ] && ok "it leads its own session" || bad "not a session leader"
touch "$T/stop-emu"; reap_launcher "$lpid"; rc=$?
[ "$rc" = 7 ] && ok "the launcher exits with the emulator's status" || bad "launcher exited $rc, the emulator 7"
[ ! -s "$T/fusermount.log" ] && [ ! -s "$T/appimage.log" ] \
  && ok "nothing mounted, nothing unmounted" || bad "mount activity for a plain binary"
reset_logs
bl n64 "$NROM" 2>"$T/launch.err" & lpid=$!; echo "$lpid" >> "$T/pids"
wait_for emu_up || bad "the emulator never started: $(cat "$T/launch.err")"
ogui_reap "$lpid"; reap_launcher "$lpid"
grep -qx term "$T/emu.log" && ok "OGUI's Exit reaches the emulator" || bad "the emulator never got SIGTERM"
reset_logs
bl --gui fakebin 2>"$T/launch.err" & lpid=$!; echo "$lpid" >> "$T/pids"
wait_for emu_up || bad "--gui never started: $(cat "$T/launch.err")"
[ "$(field self)" = "$T/emus/fakebin/current" ] && [ -z "$(sed -n 's/^arg=//p' "$T/emu.log")" ] \
  && ok "--gui runs current with the definition's (empty) gui_args" \
  || bad "--gui ran '$(field self)' with: $(sed -n 's/^arg=//p' "$T/emu.log" | tr '\n' ' ')"
touch "$T/stop-emu"; reap_launcher "$lpid"
mkdir -p "$BD/badbin"
cat > "$BD/badbin/emulator.json" <<'EOF'
{"format": "binary", "root": "roms/n64", "binary": "current", "args": ["{rom}"]}
EOF
echo "n64=badbin" > "$T/launch-badbin.conf"
RETROFORGE_EMU_DATA_DIR="$BD" RETROFORGE_LAUNCH_CONF="$T/launch-badbin.conf" "$LAUNCH" n64 "$NROM" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "a binary definition with root is refused (root is the scripts format's)" || bad "root on binary: exit $rc"
cat > "$BD/badbin/emulator.json" <<'EOF'
{"format": "binary", "binary": "fakebin", "args": ["{rom}"]}
EOF
RETROFORGE_EMU_DATA_DIR="$BD" RETROFORGE_LAUNCH_CONF="$T/launch-badbin.conf" "$LAUNCH" n64 "$NROM" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] \
  && ok "a binary definition whose binary is not current is refused (the download IS the program)" \
  || bad "binary != current: exit $rc"

# =================================================================================================
CASE="setup runs (setup_args)"
# Some emulators only read state their own binary wrote for this boot (gopher64 stored the pad's
# /dev/input/eventN path, which no board or boot guarantees): setup_args runs the emulator's binary
# before EVERY start (game and --gui) so the emulator itself rewrites it. A failed setup is a
# warning, never a blocked game.
mkdir -p "$BD/fakeset"
cat > "$BD/fakeset/emulator.json" <<'EOF'
{"format": "binary", "binary": "current", "args": ["{rom}"], "gui_args": [],
 "setup_args": ["--fake-setup"]}
EOF
echo "n64=fakeset" > "$T/launch-setup.conf"
stl() { RETROFORGE_EMU_DATA_DIR="$BD" RETROFORGE_LAUNCH_CONF="$T/launch-setup.conf" "$LAUNCH" "$@"; }
mkdir -p "$T/emus/fakeset"; cp "$T/fake-emu" "$T/emus/fakeset/v1.0.0.AppImage"
ln -s v1.0.0.AppImage "$T/emus/fakeset/current"
reset_logs; rm -f "$T/setup.log" "$T/setup-fails"
stl n64 "$NROM" 2>"$T/launch.err" & lpid=$!; echo "$lpid" >> "$T/pids"
wait_for emu_up || bad "the game never started: $(cat "$T/launch.err")"
grep -qx "setup --fake-setup" "$T/setup.log" 2>/dev/null \
  && ok "the setup ran with the definition's setup_args before the game" || bad "no setup run: $(cat "$T/setup.log" 2>/dev/null)"
touch "$T/stop-emu"; reap_launcher "$lpid"
reset_logs; rm -f "$T/setup.log"
stl --gui fakeset 2>"$T/launch.err" & lpid=$!; echo "$lpid" >> "$T/pids"
wait_for emu_up || bad "--gui never started: $(cat "$T/launch.err")"
[ -s "$T/setup.log" ] && ok "--gui runs the setup too" || bad "--gui skipped the setup"
touch "$T/stop-emu"; reap_launcher "$lpid"
reset_logs; rm -f "$T/setup.log"; : > "$T/setup-fails"
stl n64 "$NROM" 2>"$T/launch.err" & lpid=$!; echo "$lpid" >> "$T/pids"
wait_for emu_up && grep -q "setup run ended with 9" "$T/launch.err" \
  && ok "a failed setup is a warning and the game still starts" \
  || bad "setup exit 9: game up=$(emu_up && echo yes || echo no), err: $(tail -1 "$T/launch.err" 2>/dev/null)"
touch "$T/stop-emu"; reap_launcher "$lpid"; rm -f "$T/setup-fails"
cat > "$BD/fakeset/emulator.json" <<'EOF'
{"format": "binary", "binary": "current", "args": ["{rom}"], "setup_args": ["--load", "{rom}"]}
EOF
[ "$(RETROFORGE_EMU_DATA_DIR="$BD" RETROFORGE_LAUNCH_CONF="$T/launch-setup.conf" code n64 "$NROM")" = 2 ] \
  && ok 'setup_args holding "{rom}" is refused (a setup run has no game)' || bad 'accepted {rom} in setup_args'

# =================================================================================================
CASE="gamepad profile (emulator.json gamepad_profile -> OpenGamepadUI declaration)"
# The definition's InputPlumber profile (the Guide hotkey layer) is declared to OpenGamepadUI, which
# loads it while the game has focus: the profile's path and the launcher's pid, written before the
# game starts and removed when it exits. Best-effort: a declaration that fails still means a game.
mkdir -p "$BD/fakepad"
cat > "$BD/fakepad/emulator.json" <<'EOF'
{"format": "binary", "binary": "current", "args": ["{rom}"], "gamepad_profile": "guide.yaml"}
EOF
printf 'version: 1\n' > "$BD/fakepad/guide.yaml"
echo "n64=fakepad" > "$T/launch-pad.conf"
mkdir -p "$T/emus/fakepad"; cp "$T/fake-emu" "$T/emus/fakepad/v1.0.0.AppImage"
ln -s v1.0.0.AppImage "$T/emus/fakepad/current"
DECL="$T/ogui/game_profile"
pl() { RETROFORGE_EMU_DATA_DIR="$BD" RETROFORGE_LAUNCH_CONF="$T/launch-pad.conf" \
         RETROFORGE_GAME_PROFILE="$DECL" "$LAUNCH" "$@"; }

rm -rf "$T/ogui"; reset_logs
pl n64 "$NROM" 2>"$T/launch.err" & lpid=$!; echo "$lpid" >> "$T/pids"
wait_for emu_up || bad "the emulator never started: $(cat "$T/launch.err")"
[ "$(sed -n 1p "$DECL" 2>/dev/null)" = "$BD/fakepad/guide.yaml" ] \
  && ok "the profile is declared (its directory created) before the game starts" \
  || bad "declaration: $(cat "$DECL" 2>&1)"
owner="$(sed -n 2p "$DECL" 2>/dev/null)"
grep -q retroforge-launch "/proc/${owner:-0}/cmdline" 2>/dev/null && ok "the declaration names the launcher's pid" \
  || bad "declared pid ${owner:-none} is not a running launcher"
touch "$T/stop-emu"; reap_launcher "$lpid" >/dev/null
[ ! -e "$DECL" ] && ok "the declaration is withdrawn when the game exits" || bad "declaration left: $(cat "$DECL")"

# Another launcher's declaration (a newer game) is not ours to withdraw.
reset_logs
pl n64 "$NROM" 2>"$T/launch.err" & lpid=$!; echo "$lpid" >> "$T/pids"
wait_for emu_up || bad "the emulator never started: $(cat "$T/launch.err")"
printf '/elsewhere.yaml\n1\n' > "$DECL"
touch "$T/stop-emu"; reap_launcher "$lpid" >/dev/null
[ "$(sed -n 1p "$DECL" 2>/dev/null)" = /elsewhere.yaml ] && ok "a declaration that is not ours stays" \
  || bad "withdrew another launcher's declaration"
rm -f "$DECL"

# Cannot write the declaration (its directory is a file): the game starts as before, one log line.
rm -rf "$T/ogui"; : > "$T/ogui"; reset_logs
pl n64 "$NROM" 2>"$T/launch.err" & lpid=$!; echo "$lpid" >> "$T/pids"
wait_for emu_up && grep -q "could not declare" "$T/launch.err" && ok "an undeclarable profile: the game still starts" \
  || bad "a failed declaration stopped the launch: $(cat "$T/launch.err")"
touch "$T/stop-emu"; reap_launcher "$lpid"; rc=$?
[ "$rc" = 7 ] && ok "and the exit path is untouched" || bad "exit was $rc, the emulator 7"
rm -f "$T/ogui"

# A profile the image lacks: hotkeys off, game on, nothing declared.
cat > "$BD/fakepad/emulator.json" <<'EOF'
{"format": "binary", "binary": "current", "args": ["{rom}"], "gamepad_profile": "missing.yaml"}
EOF
reset_logs
pl n64 "$NROM" 2>"$T/launch.err" & lpid=$!; echo "$lpid" >> "$T/pids"
wait_for emu_up && grep -q "gamepad profile" "$T/launch.err" && [ ! -e "$DECL" ] \
  && ok "a profile the image lacks: a log line, no declaration, the game starts" \
  || bad "missing profile: up=$(emu_up && echo yes || echo no), decl=$(cat "$DECL" 2>/dev/null), err=$(tail -1 "$T/launch.err" 2>/dev/null)"
touch "$T/stop-emu"; reap_launcher "$lpid" >/dev/null

# =================================================================================================
CASE="stub ROMs (PSN .psn -> %RPCS3_GAMEID%:<id>)"
# A .psn card is a stub the PSN installer wrote: its first line is the title id, and the
# definition's "stub" maps the extension to what the emulator boots in its place. Only the command
# line gets the target; the stub path stays the game's identity (card name, per-game conf).
mkdir -p "$BD/fakestub"
cat > "$BD/fakestub/emulator.json" <<'EOF'
{"format": "binary", "binary": "current", "args": ["--no-gui", "{rom}"], "gui_args": [],
 "stub": {"psn": "%RPCS3_GAMEID%:{text}"}}
EOF
echo "ps3=fakestub" > "$T/launch-stub.conf"
sbl() { RETROFORGE_EMU_DATA_DIR="$BD" RETROFORGE_LAUNCH_CONF="$T/launch-stub.conf" "$LAUNCH" "$@"; }
mkdir -p "$T/emus/fakestub"; cp "$T/fake-emu" "$T/emus/fakestub/v1.0.0.AppImage"
ln -s v1.0.0.AppImage "$T/emus/fakestub/current"
mkdir -p "$T/roms/ps3"; SROM="$T/roms/ps3/A PSN Game.psn"
printf 'NPUB30024\n' > "$SROM"
reset_logs
sbl ps3 "$SROM" 2>"$T/launch.err" & lpid=$!; echo "$lpid" >> "$T/pids"
wait_for emu_up || bad "the game never started: $(cat "$T/launch.err")"
mapfile -t args < <(sed -n 's/^arg=//p' "$T/emu.log")
[ "${args[*]}" = "--no-gui %RPCS3_GAMEID%:NPUB30024" ] \
  && ok "the stub's first line replaces {text}, the result replaces {rom}" || bad "args were: $(printf '[%s] ' "${args[@]}")"
touch "$T/stop-emu"; reap_launcher "$lpid"
printf 'NPUB30024\nsecond line ignored\n' > "$SROM"; reset_logs
sbl ps3 "$SROM" 2>"$T/launch.err" & lpid=$!; echo "$lpid" >> "$T/pids"
wait_for emu_up || bad "the game never started: $(cat "$T/launch.err")"
[ "$(sed -n 's/^arg=//p' "$T/emu.log" | tail -1)" = "%RPCS3_GAMEID%:NPUB30024" ] \
  && ok "only the first line is the id" || bad "args were: $(sed -n 's/^arg=//p' "$T/emu.log" | tr '\n' ' ')"
touch "$T/stop-emu"; reap_launcher "$lpid"
st="$T/launch.status.stub"
# The id is strictly [A-Za-z0-9_]{1,64}: a path (../), an option (-x), control characters, a BOM
# or whitespace must never reach the emulator's command line (the id feeds RPCS3's VFS lookup).
for broken in "" " " "NPUB 30024" "../NPUB30024" "-flag" "$(printf 'NPUB\x1b30024')" \
              "$(printf '\xef\xbb\xbfNPUB30024')" "$(printf 'N%.0s' $(seq 65))"; do
  printf '%s\n' "$broken" > "$SROM"; reset_logs; rm -f "$st"
  RETROFORGE_LAUNCH_STATUS="$st" sbl ps3 "$SROM" >/dev/null 2>&1; rc=$?
  [ "$rc" = 3 ] && [ "$(cat "$st" 2>/dev/null)" = "bad-stub fakestub" ] && [ ! -e "$T/emu.log" ] \
    && ok "a stub with first line '${broken:0:20}': exit 3, status 'bad-stub fakestub', no game" \
    || bad "stub '${broken:0:20}': rc=$rc status='$(cat "$st" 2>/dev/null)' emu ran=$([ -e "$T/emu.log" ] && echo yes || echo no)"
done
head -c 512 /dev/urandom > "$SROM"; printf '\x00\xff\xfe' >> "$SROM"; reset_logs; rm -f "$st"
RETROFORGE_LAUNCH_STATUS="$st" sbl ps3 "$SROM" >/dev/null 2>&1; rc=$?
[ "$rc" = 3 ] && [ "$(cat "$st" 2>/dev/null)" = "bad-stub fakestub" ] && [ ! -e "$T/emu.log" ] \
  && ok "a binary file named .psn: bad-stub, never mojibake on the command line" \
  || bad "binary stub: rc=$rc status='$(cat "$st" 2>/dev/null)' emu ran=$([ -e "$T/emu.log" ] && echo yes || echo no)"
# A symlinked stub works (the share may present links); a DIRECTORY named .psn is no stub and
# falls through as an ordinary ROM path (a disc-dump folder may carry any name).
printf 'NPUB30024\n' > "$SROM"; ln -sf "$SROM" "$T/roms/ps3/Link Game.psn"; reset_logs
sbl ps3 "$T/roms/ps3/Link Game.psn" 2>"$T/launch.err" & lpid=$!; echo "$lpid" >> "$T/pids"
wait_for emu_up || bad "the game never started: $(cat "$T/launch.err")"
[ "$(sed -n 's/^arg=//p' "$T/emu.log" | tail -1)" = "%RPCS3_GAMEID%:NPUB30024" ] \
  && ok "a symlinked stub resolves" || bad "args were: $(sed -n 's/^arg=//p' "$T/emu.log" | tr '\n' ' ')"
touch "$T/stop-emu"; reap_launcher "$lpid"
mkdir -p "$T/roms/ps3/Dir Game.psn"; reset_logs
sbl ps3 "$T/roms/ps3/Dir Game.psn" 2>"$T/launch.err" & lpid=$!; echo "$lpid" >> "$T/pids"
wait_for emu_up || bad "the game never started: $(cat "$T/launch.err")"
[ "$(sed -n 's/^arg=//p' "$T/emu.log" | tail -1)" = "$T/roms/ps3/Dir Game.psn" ] \
  && ok "a directory named .psn passes through as an ordinary ROM" || bad "args were: $(sed -n 's/^arg=//p' "$T/emu.log" | tr '\n' ' ')"
touch "$T/stop-emu"; reap_launcher "$lpid"
printf 'NPUB30024\n' > "$SROM"; rm -f "$st"
RETROFORGE_LAUNCH_STATUS="$st" RETROFORGE_EMU_DIR="$T/none" sbl ps3 "$SROM" >/dev/null 2>&1
[ "$(cat "$st" 2>/dev/null)" = "not-installed fakestub" ] \
  && ok "a missing emulator wins over the stub (checked first)" || bad "status was '$(cat "$st" 2>/dev/null)'"
# An extension the definition does not map is an ordinary ROM: the path itself is the target.
DROM="$T/roms/ps3/Disc Game.iso"; : > "$DROM"; reset_logs
sbl ps3 "$DROM" 2>"$T/launch.err" & lpid=$!; echo "$lpid" >> "$T/pids"
wait_for emu_up || bad "the game never started: $(cat "$T/launch.err")"
[ "$(sed -n 's/^arg=//p' "$T/emu.log" | tail -1)" = "$DROM" ] \
  && ok "a non-stub extension passes the ROM path through" || bad "args were: $(sed -n 's/^arg=//p' "$T/emu.log" | tr '\n' ' ')"
touch "$T/stop-emu"; reap_launcher "$lpid"
# A definition without "stub" treats a .psn file as a plain ROM path.
reset_logs
bl n64 "$SROM" 2>"$T/launch.err" & lpid=$!; echo "$lpid" >> "$T/pids"
wait_for emu_up || bad "the game never started: $(cat "$T/launch.err")"
[ "$(sed -n 's/^arg=//p' "$T/emu.log" | tail -1)" = "$SROM" ] \
  && ok "a definition without stub passes a .psn path through" || bad "args were: $(sed -n 's/^arg=//p' "$T/emu.log" | tr '\n' ' ')"
touch "$T/stop-emu"; reap_launcher "$lpid"
for broken in \
  '{"stub": {"psn": "%RPCS3_GAMEID%:"}}' \
  '{"stub": {"psn": "{text} and {text}"}}' \
  '{"stub": {"psn": "{text} with {rom}"}}' \
  '{"stub": {"PSN": "{text}"}}' \
  '{"stub": {".psn": "{text}"}}' \
  '{"stub": ["psn"]}'; do
  python3 -c 'import json,sys; d={"format": "binary", "binary": "current", "args": ["{rom}"]};
d.update(json.loads(sys.argv[1])); json.dump(d, open(sys.argv[2], "w"))' "$broken" "$BD/fakestub/emulator.json"
  [ "$(RETROFORGE_EMU_DATA_DIR="$BD" RETROFORGE_LAUNCH_CONF="$T/launch-stub.conf" code ps3 "$SROM")" = 2 ] \
    && ok "stub refused (exit 2): $broken" || bad "stub accepted: $broken"
done
cat > "$BD/fakestub/emulator.json" <<'EOF'
{"format": "scripts", "root": "roms/fakestub", "binary": "run.sh", "args": ["{rom}"],
 "stub": {"psn": "{text}"}}
EOF
[ "$(RETROFORGE_EMU_DATA_DIR="$BD" RETROFORGE_LAUNCH_CONF="$T/launch-stub.conf" code ps3 "$SROM")" = 2 ] \
  && ok "stub on the scripts format is refused (a scripts ROM is run, not passed)" || bad "stub on scripts accepted"
# The image's RPCS3 definition boots a .psn stub by game id, VFS-resolved.
RPCS3_DEF="$SEED_DIR/rpcs3/emulator.json"
[ "$(jget "$RPCS3_DEF" stub)" = '{"psn": "%RPCS3_GAMEID%:{text}"}' ] \
  && ok "rpcs3: .psn stubs boot as %RPCS3_GAMEID%:<id>" || bad "rpcs3 stub: $(jget "$RPCS3_DEF" stub)"

# =================================================================================================
CASE="PSN inbox (--psn-install)"
# The player drops .pkg and .rap files into ~/roms/ps3/psn/; the verb runs the emulator once,
# headless, on the whole folder, verifies each file on disk (RPCS3 exits 0 even on failure),
# writes a .psn stub per base game and CONSUMES what succeeded. One tab-separated result line per
# file on stdout for the plugin.
mkdir -p "$BD/fakepsn"
INBOX="$HOME/roms/ps3/psn"; HDD0="$HOME/saves/ps3/dev_hdd0"; EXDATA="$HDD0/home/00000001/exdata"
cat > "$BD/fakepsn/emulator.json" <<'EOF'
{"format": "binary", "binary": "current", "args": ["--no-gui", "{rom}"], "gui_args": [],
 "seed": [{"file": "vfs.yml", "to": ".config/rpcs3/vfs.yml"}]}
EOF
printf '/games/: %s/roms/ps3/\n/dev_hdd0/: %s/\n' "$HOME" "$HDD0" > "$BD/fakepsn/vfs.yml"
echo "ps3=fakepsn" > "$T/launch-psn.conf"
mkdir -p "$T/emus/fakepsn"; cp "$T/fake-emu" "$T/emus/fakepsn/v1.0.0.AppImage"
ln -s v1.0.0.AppImage "$T/emus/fakepsn/current"
pl() { RETROFORGE_EMU_DATA_DIR="$BD" RETROFORGE_LAUNCH_CONF="$T/launch-psn.conf" \
       RETROFORGE_PSN_LOCK="$T/psn.lock" "$LAUNCH" --psn-install; }
# A minimal retail .pkg header: the magic, the content id at 0x30 (title id = its chars 7..15).
make_pkg() { python3 -c '
import sys
h = bytearray(0x60); h[0:4] = b"\x7fPKG"
cid = sys.argv[2].encode(); h[0x30:0x30 + len(cid)] = cid
open(sys.argv[1], "wb").write(bytes(h))' "$1" "$2"; }
# A minimal PARAM.SFO holding CATEGORY and TITLE (format 0x0204 = UTF-8 string).
make_sfo() { python3 -c '
import struct, sys
entries = [("CATEGORY", sys.argv[3]), ("TITLE", sys.argv[2])]
keys = data = index = b""
for k, v in entries:
    raw = v.encode() + b"\0"
    index += struct.pack("<HHIII", len(keys), 0x0204, len(raw), len(raw), len(data))
    keys += k.encode() + b"\0"; data += raw
key_start = 20 + 16 * len(entries)
header = b"\0PSF" + struct.pack("<I", 0x101) + struct.pack("<III", key_start, key_start + len(keys), len(entries))
open(sys.argv[1], "wb").write(header + index + keys + data)' "$1" "$2" "$3"; }
# A minimal ICON0.PNG the box seed accepts: PNG signature + an IHDR with sane dimensions.
make_icon() { python3 -c '
import struct, sys
ihdr = struct.pack(">II", 320, 176) + b"\x08\x02\x00\x00\x00"
open(sys.argv[1], "wb").write(b"\x89PNG\r\n\x1a\n" + struct.pack(">I", len(ihdr)) + b"IHDR" + ihdr + b"\0\0\0\0")' "$1"; }
rm -rf "$INBOX" "$HDD0" "$HOME/.config/rpcs3"; mkdir -p "$INBOX"
out="$(pl 2>"$T/launch.err")"; rc=$?
[ "$rc" = 0 ] && [ "$out" = "nothing-to-do" ] && [ ! -e "$T/psn.log" ] \
  && ok "an empty inbox: 'nothing-to-do', exit 0, the emulator never runs" || bad "empty inbox: rc=$rc out='$out'"
echo "drop your .pkg files here" > "$INBOX/README.txt"
out="$(pl 2>"$T/launch.err")"; rc=$?
[ "$rc" = 0 ] && [ "$out" = "nothing-to-do" ] \
  && ok "an inbox with only the README: 'nothing-to-do'" || bad "README-only inbox: rc=$rc out='$out'"
# The happy path: a base game (HG) with its licence. The fake "installs" by copying a staged
# game dir into dev_hdd0 and the inbox's raps into exdata, as RPCS3's one dir-install call does.
make_pkg "$INBOX/A Game.pkg" "UP0001-NPUB30024_00-AGAME00000000000"
echo "fake licence" > "$INBOX/UP0001-NPUB30024_00-AGAME00000000000.rap"
STAGE="$T/psn-stage"; rm -rf "$STAGE"; mkdir -p "$STAGE/NPUB30024/USRDIR"
make_sfo "$STAGE/NPUB30024/PARAM.SFO" "Mario's Adventure: Go/Stop" HG
: > "$STAGE/NPUB30024/USRDIR/EBOOT.BIN"
make_icon "$STAGE/NPUB30024/ICON0.PNG"
cat > "$T/psn-fake.sh" <<EOF
mkdir -p "$HDD0/game" "$EXDATA"
cp -r "$STAGE/." "$HDD0/game/"
for f in "\$3"/*.rap; do [ -f "\$f" ] && cp "\$f" "$EXDATA/"; done
EOF
out="$(pl 2>"$T/launch.err")"; rc=$?
STUB="$HOME/roms/ps3/Mario's Adventure: Go Stop.psn"
[ "$rc" = 0 ] && ok "a base game and its rap: exit 0" || bad "happy path: rc=$rc out='$out' err: $(tail -2 "$T/launch.err")"
grep -q "^psn-install --headless --installpkg $INBOX\$" "$T/psn.log" \
  && ok "one headless --installpkg run on the whole inbox" || bad "psn.log: $(cat "$T/psn.log" 2>/dev/null)"
[ -f "$HOME/.config/rpcs3/vfs.yml" ] \
  && ok "the emulator's seed ran first (vfs.yml places dev_hdd0 before the first install)" || bad "vfs.yml was not seeded"
printf '%s\n' "$out" | grep -qP "^ok\tA Game\.pkg\tNPUB30024\tMario's Adventure: Go Stop\.psn$" \
  && ok "pkg result line: ok, title id, stub named from PARAM.SFO's TITLE (sanitized)" || bad "out was: $out"
printf '%s\n' "$out" | grep -qP "^ok\tUP0001-NPUB30024_00-AGAME00000000000\.rap\t-\t-$" \
  && ok "rap result line: ok" || bad "out was: $out"
[ "$(cat "$STUB" 2>/dev/null)" = "NPUB30024" ] && ok "the stub holds the title id" || bad "stub: '$(cat "$STUB" 2>/dev/null)'"
[ ! -e "$INBOX/A Game.pkg" ] && [ ! -e "$INBOX/UP0001-NPUB30024_00-AGAME00000000000.rap" ] \
  && ok "the inbox is consumed (pkg and rap deleted)" || bad "inbox still holds: $(ls "$INBOX")"
[ -f "$INBOX/README.txt" ] && ok "the README survives, with no result line" || bad "the README was deleted"
printf '%s\n' "$out" | grep -q README && bad "the README got a result line" || true
# A new card's box art: the game's own ICON0.PNG, seeded into the scraper's media folder (a
# digital-only title often has no box scan on ScreenScraper, which left the card blank).
BOX="$HOME/.local/share/retroforge/media/ps3/Mario's Adventure: Go Stop.psn-box.png"
cmp -s "$BOX" "$STAGE/NPUB30024/ICON0.PNG" \
  && ok "the stub's box art is seeded from the game's ICON0.PNG" || bad "box seed missing or differs"
# An update for the same game: installed and consumed, the existing stub kept (never a second
# card), and an existing box (a real ScreenScraper one, say) is never clobbered by the seed.
make_pkg "$INBOX/A Game Update.pkg" "UP0001-NPUB30024_00-AGAMEPATCH000000"
echo "a real box from ScreenScraper" > "$BOX"
out="$(pl 2>"$T/launch.err")"; rc=$?
[ "$rc" = 0 ] && printf '%s\n' "$out" | grep -qP "^ok\tA Game Update\.pkg\tNPUB30024\tMario's Adventure: Go Stop\.psn$" \
  && [ "$(ls "$HOME/roms/ps3/"*.psn | wc -l)" = 1 ] \
  && ok "an update pkg reuses the existing stub (one card)" || bad "update: rc=$rc out='$out'"
[ "$(cat "$BOX" 2>/dev/null)" = "a real box from ScreenScraper" ] \
  && ok "an existing box survives the seed (real art wins)" || bad "box clobbered: '$(cat "$BOX" 2>/dev/null)'"
# A mixed batch: a DLC-style pkg with no EBOOT.BIN (GD: no card), a pkg the install never
# produced (failed, stays), a garbage .pkg (failed, stays), a rap the install did not copy
# (failed, stays). Exit 3: something failed.
make_pkg "$INBOX/Game Data.pkg" "UP0001-NPUB77777_00-SOMEGAMEDATA0000"
mkdir -p "$STAGE/NPUB77777"; make_sfo "$STAGE/NPUB77777/PARAM.SFO" "Some Game Data" GD
make_pkg "$INBOX/Broken.pkg" "UP0001-NPUB11111_00-NEVERINSTALLS000"
echo "not a package" > "$INBOX/Garbage.pkg"
echo "fake licence" > "$INBOX/Orphan.rap"
cat > "$T/psn-fake.sh" <<EOF
mkdir -p "$HDD0/game" "$EXDATA"
cp -r "$STAGE/NPUB77777" "$HDD0/game/"
EOF
out="$(pl 2>"$T/launch.err")"; rc=$?
[ "$rc" = 3 ] && ok "a batch with failures: exit 3" || bad "mixed batch: rc=$rc out='$out'"
printf '%s\n' "$out" | grep -qP "^ok\tGame Data\.pkg\tNPUB77777\t-$" && [ ! -e "$INBOX/Game Data.pkg" ] \
  && ok "a GD pkg (update/DLC data): installed, consumed, no stub" || bad "GD pkg: $out"
printf '%s\n' "$out" | grep -qP "^failed\tBroken\.pkg\tNPUB11111\t-$" && [ -f "$INBOX/Broken.pkg" ] \
  && ok "a pkg the install did not produce: failed, stays in the inbox" || bad "broken pkg: $out"
printf '%s\n' "$out" | grep -qP "^failed\tGarbage\.pkg\t-\t-$" && [ -f "$INBOX/Garbage.pkg" ] \
  && ok "a file that is no package: failed, stays" || bad "garbage pkg: $out"
printf '%s\n' "$out" | grep -qP "^failed\tOrphan\.rap\t-\t-$" && [ -f "$INBOX/Orphan.rap" ] \
  && ok "a rap the install did not copy: failed, stays" || bad "orphan rap: $out"
printf '%s\n' "$out" | grep -q "RPCS3-LOG-NOISE" \
  && bad "the emulator's stdout leaked onto the result lines" || ok "the emulator's stdout stays off the result lines"
rm -f "$INBOX"/*.pkg "$INBOX/Orphan.rap"
# A re-dropped pkg whose game is ALREADY installed from an earlier run: the stale install must
# not verify it (RPCS3 exits 0 even on failure; only a dir this run touched counts).
make_pkg "$INBOX/Stale.pkg" "UP0001-NPUB77777_00-SOMEGAMEDATA0000"
: > "$T/psn-fake.sh"
out="$(pl 2>"$T/launch.err")"; rc=$?
[ "$rc" = 3 ] && printf '%s\n' "$out" | grep -qP "^failed\tStale\.pkg\tNPUB77777\t-$" && [ -f "$INBOX/Stale.pkg" ] \
  && ok "a pkg 'verified' only by a stale earlier install: failed, stays" || bad "stale re-drop: rc=$rc out='$out'"
rm -f "$INBOX/Stale.pkg"
# A name collision (another game, the same TITLE) and a missing TITLE.
make_pkg "$INBOX/Clone.pkg" "UP0001-NPUB22222_00-ACLONE0000000000"
mkdir -p "$STAGE/NPUB22222/USRDIR"; : > "$STAGE/NPUB22222/USRDIR/EBOOT.BIN"
make_sfo "$STAGE/NPUB22222/PARAM.SFO" "Mario's Adventure: Go/Stop" HG
make_pkg "$INBOX/Nameless.pkg" "UP0001-NPUB33333_00-NAMELESS00000000"
mkdir -p "$STAGE/NPUB33333/USRDIR"; : > "$STAGE/NPUB33333/USRDIR/EBOOT.BIN"
make_sfo "$STAGE/NPUB33333/PARAM.SFO" "" HG
cat > "$T/psn-fake.sh" <<EOF
mkdir -p "$HDD0/game" "$EXDATA"
cp -r "$STAGE/NPUB22222" "$STAGE/NPUB33333" "$HDD0/game/"
EOF
out="$(pl 2>"$T/launch.err")"; rc=$?
[ "$rc" = 0 ] \
  && [ "$(cat "$HOME/roms/ps3/Mario's Adventure: Go Stop (NPUB22222).psn" 2>/dev/null)" = "NPUB22222" ] \
  && ok "a taken name gets ' (<id>)' appended" || bad "collision: rc=$rc out='$out' stubs: $(ls "$HOME/roms/ps3/")"
[ "$(cat "$HOME/roms/ps3/NPUB33333.psn" 2>/dev/null)" = "NPUB33333" ] \
  && ok "a missing TITLE falls back to the title id" || bad "nameless: $(ls "$HOME/roms/ps3/")"
[ ! -e "$HOME/.local/share/retroforge/media/ps3/NPUB33333.psn-box.png" ] \
  && ok "a game without ICON0.PNG seeds no box (the scraper may still find one)" \
  || bad "a box appeared with no ICON0.PNG"
# Seeding is COSMETIC by contract: a junk ICON0 (not a PNG — a seed the scraper would mistake for
# real art), an oversized one, or an unwritable media folder each log to stderr and change nothing
# about the install itself.
MEDIA="$HOME/.local/share/retroforge/media"
make_pkg "$INBOX/Junk Icon.pkg" "UP0001-NPUB88855_00-JUNKICON00000000"
mkdir -p "$STAGE/NPUB88855/USRDIR"; : > "$STAGE/NPUB88855/USRDIR/EBOOT.BIN"
make_sfo "$STAGE/NPUB88855/PARAM.SFO" "Junk Icon Game" HG
echo "not a png" > "$STAGE/NPUB88855/ICON0.PNG"
make_pkg "$INBOX/Big Icon.pkg" "UP0001-NPUB88856_00-BIGICON000000000"
mkdir -p "$STAGE/NPUB88856/USRDIR"; : > "$STAGE/NPUB88856/USRDIR/EBOOT.BIN"
make_sfo "$STAGE/NPUB88856/PARAM.SFO" "Big Icon Game" HG
make_icon "$STAGE/NPUB88856/ICON0.PNG"; truncate -s 2M "$STAGE/NPUB88856/ICON0.PNG"
cat > "$T/psn-fake.sh" <<EOF
mkdir -p "$HDD0/game"
cp -r "$STAGE/NPUB88855" "$STAGE/NPUB88856" "$HDD0/game/"
EOF
out="$(pl 2>"$T/launch.err")"; rc=$?
[ "$rc" = 0 ] && [ ! -e "$MEDIA/ps3/Junk Icon Game.psn-box.png" ] && [ ! -e "$MEDIA/ps3/Big Icon Game.psn-box.png" ] \
  && [ "$(grep -c "could not seed card art" "$T/launch.err")" = 2 ] \
  && ok "a junk or oversized ICON0: no seed, a log each, the installs still ok" \
  || bad "junk/big icon: rc=$rc out='$out' err: $(grep seed "$T/launch.err")"
make_pkg "$INBOX/Shy Icon.pkg" "UP0001-NPUB88857_00-SHYICON000000000"
mkdir -p "$STAGE/NPUB88857/USRDIR"; : > "$STAGE/NPUB88857/USRDIR/EBOOT.BIN"
make_sfo "$STAGE/NPUB88857/PARAM.SFO" "Shy Icon Game" HG
make_icon "$STAGE/NPUB88857/ICON0.PNG"
cat > "$T/psn-fake.sh" <<EOF
mkdir -p "$HDD0/game"
cp -r "$STAGE/NPUB88857" "$HDD0/game/"
EOF
mv "$MEDIA" "$MEDIA.keep"; : > "$MEDIA"
out="$(pl 2>"$T/launch.err")"; rc=$?
rm -f "$MEDIA"; mv "$MEDIA.keep" "$MEDIA"
[ "$rc" = 0 ] && grep -q "could not seed card art" "$T/launch.err" \
  && printf '%s\n' "$out" | grep -qP "^ok\tShy Icon\.pkg\tNPUB88857\tShy Icon Game\.psn$" \
  && ok "an unwritable media folder: logged, the install and its result line stay ok" \
  || bad "unwritable media: rc=$rc out='$out'"
# A hostile TITLE (path traversal) and an oversized one (NAME_MAX is bytes, TITLE is characters).
make_pkg "$INBOX/Evil.pkg" "UP0001-NPUB66666_00-EVIL000000000000"
mkdir -p "$STAGE/NPUB66666/USRDIR"; : > "$STAGE/NPUB66666/USRDIR/EBOOT.BIN"
make_sfo "$STAGE/NPUB66666/PARAM.SFO" "../../evil" HG
make_pkg "$INBOX/Long.pkg" "UP0001-NPUB55555_00-LONG000000000000"
mkdir -p "$STAGE/NPUB55555/USRDIR"; : > "$STAGE/NPUB55555/USRDIR/EBOOT.BIN"
make_sfo "$STAGE/NPUB55555/PARAM.SFO" "$(python3 -c "print('ゲ' * 120)")" HG
cat > "$T/psn-fake.sh" <<EOF
mkdir -p "$HDD0/game" "$EXDATA"
cp -r "$STAGE/NPUB66666" "$STAGE/NPUB55555" "$HDD0/game/"
EOF
out="$(pl 2>"$T/launch.err")"; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$HOME/roms/ps3/evil.psn" 2>/dev/null)" = "NPUB66666" ] \
  && [ ! -e "$HOME/roms/evil.psn" ] && [ ! -e "$HOME/evil.psn" ] \
  && ok "a traversal TITLE is neutralised: the stub lands in ~/roms/ps3" \
  || bad "traversal: rc=$rc stubs: $(ls "$HOME/roms/ps3/" | tr '\n' ' ')"
long_stub="$(cd "$HOME/roms/ps3" && ls ゲ*.psn 2>/dev/null | head -1)"
[ -n "$long_stub" ] && [ "$(printf %s "$long_stub" | wc -c)" -le 200 ] \
  && [ "$(cat "$HOME/roms/ps3/$long_stub")" = "NPUB55555" ] \
  && ok "an oversized TITLE is truncated by bytes (the stub still writes)" \
  || bad "long title: stub '$long_stub' ($(printf %s "$long_stub" | wc -c) bytes)"
# A name the result lines cannot carry (a carriage return) is left alone.
: > "$INBOX/$(printf 'cr\rname.pkg')"
out="$(pl 2>"$T/launch.err")"; rc=$?
[ "$rc" = 0 ] && [ "$out" = "nothing-to-do" ] && [ -e "$INBOX/$(printf 'cr\rname.pkg')" ] \
  && ok "a control-character file name is skipped, never printed" || bad "cr name: rc=$rc out='$out'"
rm -f "$INBOX/$(printf 'cr\rname.pkg')"
# A second install at the same time: refused (two emulators would write one dev_hdd0). The lock
# is held by an fd holder that SIGNALS when it truly has it (a timed `flock -c sleep` races the
# test on a slow machine, and a lapsed one would run a real launch and hang the suite).
psn_hold() {
  rm -f "$T/psn.held" "$T/psn.release"
  ( exec 9>"$T/psn.lock"; flock 9; : > "$T/psn.held"
    while [ ! -e "$T/psn.release" ]; do sleep 0.05; done ) & hlpid=$!
  echo "$hlpid" >> "$T/pids"
  wait_for '[ -e "$T/psn.held" ]' || bad "the test's lock holder never took the lock"
}
psn_release() { touch "$T/psn.release"; wait "$hlpid" 2>/dev/null; }
make_pkg "$INBOX/Late.pkg" "UP0001-NPUB44444_00-LATE000000000000"
psn_hold
out="$(pl 2>"$T/launch.err")"; rc=$?
[ "$rc" = 3 ] && [ -z "$out" ] && [ -f "$INBOX/Late.pkg" ] && grep -q "already running" "$T/launch.err" \
  && ok "a concurrent install is refused (flock)" || bad "lock: rc=$rc out='$out' err: $(tail -1 "$T/launch.err")"
psn_release
# The emulator missing: exit 3 before anything is touched.
out="$(RETROFORGE_EMU_DIR="$T/none" pl 2>"$T/launch.err")"; rc=$?
[ "$rc" = 3 ] && [ -z "$out" ] && [ -f "$INBOX/Late.pkg" ] \
  && ok "ps3's emulator not installed: exit 3, nothing consumed" || bad "not installed: rc=$rc out='$out'"
rm -f "$INBOX/Late.pkg" "$T/psn-fake.sh" "$T/psn.log"
# Launch vs install: a ps3 GAME takes the installer's lock too (one RPCS3 at a time — shared
# dev_hdd0, and two do not fit in a handheld's RAM). Other systems are untouched.
printf 'ps3=fakepsn\npsx=fakepsn\n' > "$T/launch-psn.conf"
plg() { RETROFORGE_EMU_DATA_DIR="$BD" RETROFORGE_LAUNCH_CONF="$T/launch-psn.conf" \
        RETROFORGE_PSN_LOCK="$T/psn.lock" "$LAUNCH" "$@"; }
DISC="$HOME/roms/ps3/Disc Game.iso"; : > "$DISC"
st="$T/launch.status.psn"
psn_hold
reset_logs; rm -f "$st"
RETROFORGE_LAUNCH_STATUS="$st" plg ps3 "$DISC" >/dev/null 2>"$T/launch.err"; rc=$?
[ "$rc" = 3 ] && [ "$(cat "$st" 2>/dev/null)" = "psn-installing fakepsn" ] && [ ! -e "$T/emu.log" ] \
  && ok "a ps3 launch while the installer holds the lock: exit 3, 'psn-installing', no game" \
  || bad "launch vs install: rc=$rc status='$(cat "$st" 2>/dev/null)' emu ran=$([ -e "$T/emu.log" ] && echo yes || echo no)"
reset_logs
plg psx "$DISC" 2>"$T/launch.err" & lpid=$!; echo "$lpid" >> "$T/pids"
wait_for emu_up || bad "the psx game never started: $(cat "$T/launch.err")"
ok "the lock guards only ps3: a psx launch starts while it is held"
touch "$T/stop-emu"; reap_launcher "$lpid"
psn_release
# The other direction: a RUNNING ps3 game holds the lock, so --psn-install is refused while it
# plays (the lock is taken before the inventory, so even an empty inbox answers 'already
# running') and works again once the game exits.
reset_logs
plg ps3 "$DISC" 2>"$T/launch.err" & lpid=$!; echo "$lpid" >> "$T/pids"
wait_for emu_up || bad "the ps3 game never started: $(cat "$T/launch.err")"
out="$(pl 2>"$T/launch.err")"; rc=$?
[ "$rc" = 3 ] && [ -z "$out" ] && grep -q "already running" "$T/launch.err" \
  && ok "--psn-install while a ps3 game runs: refused on the game's lock" \
  || bad "install vs game: rc=$rc out='$out' err: $(tail -1 "$T/launch.err")"
touch "$T/stop-emu"; reap_launcher "$lpid"
out="$(pl 2>"$T/launch.err")"; rc=$?
[ "$rc" = 0 ] && [ "$out" = "nothing-to-do" ] \
  && ok "the game's exit releases the lock: the next install runs" || bad "lock not released: rc=$rc out='$out'"
# A broken lock PATH is a system problem, not contention: the installer refuses with the real
# error (never "already running"), a game launch logs it and runs UNGUARDED (the guard must not
# brick every ps3 launch).
badlock() { RETROFORGE_EMU_DATA_DIR="$BD" RETROFORGE_LAUNCH_CONF="$T/launch-psn.conf" \
            RETROFORGE_PSN_LOCK="$T/no-such-dir/psn.lock" "$LAUNCH" "$@"; }
out="$(badlock --psn-install 2>"$T/launch.err")"; rc=$?
[ "$rc" = 3 ] && grep -q "cannot take the PSN install lock" "$T/launch.err" \
  && ! grep -q "already running" "$T/launch.err" \
  && ok "an unwritable lock path: the installer refuses with the real error" \
  || bad "bad lock path (install): rc=$rc err: $(tail -1 "$T/launch.err")"
reset_logs
badlock ps3 "$DISC" 2>"$T/launch.err" & lpid=$!
echo "$lpid" >> "$T/pids"
wait_for emu_up || bad "the game never started on a bad lock path: $(cat "$T/launch.err")"
grep -q "launching unguarded" "$T/launch.err" \
  && ok "an unwritable lock path: a ps3 launch logs it and still starts" \
  || bad "bad lock path (launch): no 'launching unguarded' in: $(tail -1 "$T/launch.err")"
touch "$T/stop-emu"; reap_launcher "$lpid"
rm -f "$DISC"
# The image ships the inbox and its README: the folder from the first session (before any rpcs3
# launch, so tmpfiles, not the launcher's sync), the README following image updates (C+, not C).
layout_has roms/ps3/psn && ok "layout has ~/roms/ps3/psn (the PSN inbox)" || bad "layout lacks ~/roms/ps3/psn"
grep -Eq '^C\+[[:space:]]+%h/roms/ps3/psn/README\.txt[[:space:]].*rpcs3/psn-readme\.txt$' "$LAYOUT" \
  && ok "layout keeps the inbox README current (C+)" || bad "layout lacks the README C+ row"
[ -s "$SEED_DIR/rpcs3/psn-readme.txt" ] && grep -q "DELETED" "$SEED_DIR/rpcs3/psn-readme.txt" \
  && ok "the README ships beside the rpcs3 seeds and states the consumed-on-install contract" \
  || bad "psn-readme.txt is missing or silent about deletion"

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
