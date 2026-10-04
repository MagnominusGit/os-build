# Plan: QForge

**Complexity**: Large
**Status** (2026-10-03): Phases 0-2 done -- HW-validated on SM8550 (AYANEO Pocket ACE) and SM8250
(MANGMI Pocket Max); SM8650 not booted since the OGUI crash fix. Phase 3 done (emulator platform,
DuckStation end to end). Phase 4 designed (QForge OGUI plugin), next. Phase 4b (more emulators)
after it. Phase 5 not started.

## Summary

QForge is a standalone retro-emulation Linux distribution for Qualcomm Snapdragon handhelds
(SM8250 / SM8550 / SM8650). It is derived from the upstream project credited in README.md (GPL-2.0-or-later): it reuses
that project's Holo aarch64 base, unified kernel/DTS, steamcl + GRUB boot chain, RAUC A/B updates
and installer, without the Steam client, x86 emulation or the Android container. The shell is
[OpenGamepadUI](https://github.com/ShadowBlip/OpenGamepadUI) inside gamescope. Emulators are upstream
AppImages that the QForge OGUI plugin downloads from their own releases (not in the image), started
per ROM by `qforge-launch`.

## Decisions

| Decision | Choice |
|---|---|
| Relationship to upstream | Own project, not a fork. No upstream remote. Attribution kept (README, DTS copyrights, patch authors) |
| Base | Holo aarch64 packages, pinned snapshot, sealed read-only Btrfs root |
| Targets | SM8250, SM8550, SM8650 — same kernel/DTS/boot chain as upstream; ROCKNIX ABL prerequisite |
| Shell | OpenGamepadUI under gamescope |
| Removed | Steam client + seed, Decky, FEX, Proton, lsfg-vk, Android container (Lepton, Play, podman, adb), gtk2, vpower, steamos-* entry points |
| Kept | qforge-pairingd (always on until the shell has a switch), userspace fake-suspend (qforge-suspend / qforge-rest) |
| Names | Display QForge, os-release ID `qforge`, D-Bus `org.qforge`, session user `player` (uid 1000) |
| Root slots | 2G each (was 4G until 2026-10-03 trim, 7G with the x86 payloads) |
| Firmware | Still fetched from Nova-Deck/qcom-firmwares (pinned); move to a QForge repo later |
| OTA signing | New QForge CA; private keys in `~/qforge-pki`, never in the repo |
| Emulators | Upstream AppImages, downloaded on demand by an OGUI plugin (not in the image); must use our patched Mesa/Turnip, not a bundled one |

## Phases

### Phase 0 — Base system ✅ done

- Imported the reference tree, removed Steam / x86 / Android stacks, their tests, CI jobs and kernel
  options (binder, Android netfilter set, NTSYNC, EROFS).
- Session launcher shell-agnostic: `QFORGE_SESSION_CMD` (placeholder `vkcube --wsi xcb`) +
  `QFORGE_GAMESCOPE_SHELL_ARGS`.
- Power button: configurable short/long actions (suspend / power off).
- Upstream names renamed to qforge; `deck` → `player`; root slots 4G.
- SD format helpers kept as `qforge-format-{sdcard,device}`.
- `guard-rootfs.sh` fails a release build if a removed stack comes back;
  `tests/test-upstream-name.sh` fails on leftover upstream names.
- New OTA signing CA + release cert.
- `make relock` run: `rootfs/manifest.lock` re-resolved without the removed stacks' dependencies.
  `installer/manifest.lock` needs no relock (same package set and snapshot); relock it after the
  first `make kernel` if its package list changes.
- Since built and booted many times (2026-10-02/03): root image ~1.0G apparent in its 2G slot.

### Phase 0 follow-ups (before the first real build)

| Task | Why |
|---|---|
| ✅ Build `make sdcard`, check `du --apparent-size out/images/rootfs.img` (~1.0G in the 2G slot) | Confirm the 2G slot has ≥1G headroom; `make-sdcard.sh`'s `fits` check is the backstop |
| Boot on one SM8250 ✅, one SM8550 ✅, one SM8650 (open: not booted since the OGUI fix) | Gate: gamescope + vkcube on the panel, A/B confirm via qforge-boot-good |
| ✅ Back up `~/qforge-pki/ca.key.pem` off this machine (done 2026-10-03) | Losing it means no device can ever accept another update |

### Phase 1 — OpenGamepadUI as the shell — done (SM8650 still to boot)

Done:
- `packages/opengamepadui/prebuilt.pin`: upstream's **aarch64 release tarball** (v0.46.1) — no
  Godot/GDExtension build needed. strip 2 into `/usr`; `deps: libxinerama` (Godot's X11 backend).
- Session profile in `session.conf`: `QFORGE_SESSION_CMD=opengamepadui`,
  `QFORGE_GAMESCOPE_SHELL_ARGS="--steam --xwayland-count 2"` (OGUI drives gamescope through the
  Steam-mode X atoms, so X11/Xwayland is required), plus `QT_QPA_PLATFORM=xcb`,
  `SDL_VIDEO_MINIMIZE_ON_FOCUS_LOSS=0`, `vk_xwayland_wait_ready=false`. Driven by `qforge-session`;
  `gamescope-session-plus` is NOT used.
- OGUI's self-updater trimmed from the release root (incl. the `make_nice` setcap helper that any
  user could pkexec). The OS slot carries the OGUI version.
- gamescope `0023` (Android/xdg titles) retired; `0005` kept (it covers OGUI's window too).
- Guard 9b (shell present, updater absent); `tests/test-session.sh`.
- Relocked: + opengamepadui, + libxinerama, gamescope rehashed. Root 1.8G apparent / 945M allocated.

Remaining:
- ✅ **Hardware** (SM8550 Pocket ACE, SM8250 Pocket Max, 2026-10-02/03): boots to OGUI; pad
  navigation (InputPlumber), quick-menu overlay over a running game, mangoapp, focus switching
  OGUI <-> game (DuckStation), panel rotation. Open: SM8650.
- Check OGUI's in-app update setting cannot still download a user-local build.
- ✅ PowerStation: done in Phase 2 (patched upstream PowerStation, qforge-powerd stripped down).

### Phase 2 — Handheld features in OGUI (High) — done

Decisions (2026-10-02, from reading OGUI v0.46.1 source in `_ref/OpenGamepadUI`):
- **No OGUI plugin for now** (superseded 2026-10-03: the Phase 4 QForge plugin). Only OGUI's built-in screens; QForge-only controls (fan curve,
  scheduler, update channel) stay CLI/SSH (`qforge-scheduler`, `qforge-update`, powerd D-Bus).
  Update channel / OS updates: superseded 2026-10-04 by a QForge OSPlatform in OGUI (Phase 5).
- **No per-game (per-ROM) layer.** The upstream tweaks layer (game-tweaks.json, qforge_perf, the
  per-game `scheduler` override) existed for x86 titles under FEX/Proton; emulators carry their own
  per-game settings (Phase 3). Profile, GPU clock, CPU scheduler, fan curve stay system-wide.
- **Update gate = OGUI's own OOBE marker**: `settings.cfg [general] first_boot=false`.
- **Perf UI = upstream PowerStation, patched (2026-10-03).** OGUI's performance menu speaks only
  `org.shadowblip.PowerStation`. We build upstream PowerStation (`packages/powerstation`, main @
  b161e80) with two patches meant for upstream: non-SMT CPUs keep all cores (it halved them and
  grouped big.LITTLE cores by per-cluster core_id), and a devfreq backend for non-PCI GPUs
  (Adreno under msm: clock limits, min/max range, manual switch). OGUI patch 0003 hides the TDP /
  thermal / power-profile controls an SoC GPU does not have. qforge-powerd's power profiles, PPD
  interface and GPU clock control were removed; it keeps the fan (one curve, `power.conf`), the
  boot CPU governor (ondemand; the kernel default is performance), sched_ext and the suspend clamp.
  scx_lavd no longer runs with --autopower.

Done (uncommitted):
- qforge-update gates on the OGUI first-boot marker (was Steam's loginusers.vdf); Steam wording
  gone; `channels` / `set-channel <name>` added. `qforge-select-branch` + its test removed.
- Per-game layer removed: `qforge_perf.py`, `tests/test-perf.sh`, powerd's perf tick and
  scheduler override (powerd keeps a 3s scheduler-reconcile tick).
- Phase 1 card kept as `out/images/sdcard.p1.img`.
- `brightnessctl` 0.5.1 (overlay PKGBUILD — not in the holo snapshot; logind backend, not setuid)
  so OGUI's brightness slider exists. Relocked (+1 row). HW: check the slider moves the panel.
- Session runs `opengamepadui --skip-update-pack`: OGUI's self-updater fetches the x86_64
  `update.zip`; applying it at start would black the panel and override the image's shell version.

- **OGUI v0.46.1 crash-loops on DT boards** (HW, Pocket FIT 2026-10-02: black panel after the
  splash). HardwareManager reads DMI `product_name`; no SMBIOS on ABL UEFI → null FileAccess →
  SIGSEGV ~10s into every start (upstream #542). Also #540: Godot 4.7 native
  `custom_maximum_size` breaks the game launch menu. v0.45.1 crashes the same way.
  Fix: `packages/opengamepadui` is now a local PKGBUILD — upstream's aarch64 engine/core/reaper
  from the release tarball, `opengamepad-ui.pck` re-exported from the v0.46.1 tag + 2 patches
  (null guard + devicetree-model fallback; rename to `scroll_maximum_size`) with the arm64
  Godot 4.7.1 editor and the real core loaded (an x86 export without the core drops data from 14
  scenes). Pck verified file-by-file against upstream. HW: boot to OGUI, open a game's launch menu.
  Drop the patches when upstream releases fixes; consider sending them upstream.
- `which` added to PKGS: OGUI probes helpers with `which <cmd>` (brightnessctl, wpctl, mangoapp,
  bwrap); without it the brightness slider was absent.
- HW 2026-10-02, AYANEO Pocket ACE (SM8550), build 20261002T165505Z: boots to OGUI, no crashes,
  0 script errors, brightness slider works, volume works. Remaining log noise is harmless:
  "Could not identify active GPU" (platform DRM device has no PCI ids; glxinfo would not help —
  decided to skip it), a one-time burst of 68 "Unexpected NUL" (upstream /proc scan), plugin store
  request failing on first boot. Still to check: power menu, a game's launch menu, SM8250/SM8650.

Remaining OS-side (found in OGUI source):
- ✅ OGUI power menu suspend / reboot / poweroff work from the session (HW, Pocket Max 2026-10-03).
- ✅ PowerStation (above) HW-tested 2026-10-03 on the Pocket Max (SM8250, dev build
  20261003T114234Z): Adreno 650 found via devfreq, menu populated without TDP controls, GPU max
  405 -> 400 MHz OPP lands in devfreq, core count 4 offlines cpu4-7, all 8 cores kept after OGUI's
  default apply, ondemand on every policy; GPU cap and core count survive suspend/resume.
- Send upstream: PowerStation 0001/0002 (ShadowBlip/PowerStation), branch `_ref/PowerStation`
  qforge-arm. OGUI sent 2026-10-03: #559 (0001, fixes #542), #560 (0002, fixes #540), #561 (0003),
  from loki666/OpenGamepadUI branches fix/no-dmi-devicetree, fix/custom-maximum-size,
  fix/perf-menu-soc-gpu. Drop each patch once it lands in a release.
- HW 2026-10-03, MANGMI Pocket Max (SM8250), dev build 20261003T094820Z (`29a24b7`): first
  SM8250 boot. qforge-session.service (no sddm) gives an Active wayland session on seat0/VT1,
  boot-good confirmed slot A, polkit grants NM / timezone / power / udisks to the session with no
  prompt, OGUI up without crashes (only the known glxinfo / GPU-id errors), backlight controllable.
  Also verified: session restarts after gamescope is killed (Restart=always, new seat0 session);
  OGUI power menu suspend / reboot / poweroff, and power-key short press -> qforge-suspend (both
  suspend cycles resume with radios, CPUs, backlight and the session intact). gamescope does
  direct multi-plane scanout here (OGUI + mangoapp on 2 KMS planes, UBWC, DPU 90-degree rotation),
  compositing only occasionally. A game's launch menu / game scanout moves to Phase 3.
- ✅ Steam wording cleaned (2026-10-03) across the overlay; what remains names a measurement
  taken under the Steam client or the boot chain (steamcl, steamos-bootconf), on purpose.
- ✅ `kernel/kernel.config` CONFIG_PROC_CHILDREN comment fixed (2026-10-03; next card build
  rebuilds the kernel).
- qforge-pairingd stays always-on (no shell switch).

### Phase 3 — Emulator platform (High) — done (closed 2026-10-03)

Closed with DuckStation running end to end on the SM8250 Pocket Max: upstream AppImage on our
Mesa/Turnip (fuse3), `qforge-launch` with clean exits on every path, first-run settings from the
image, per-game CPU pinning (`--cpus big`), the player folder layout, guest SMB shares (with the
ksmbd backport), and the qforge-session stop fixes (fast restart, games stopped first). What was
left moved: the other five emulators and the DuckStation hotkeys to Phase 4b (they reach players
through the plugin catalog); DuckStation's pinned-tag re-test to Phase 4 (first catalog); the
upstream reports to the Backlog; the SM8650 boot stays a Phase 0/1 item.


- Emulators to ship (decided 2026-10-03): Dolphin, ARMSX2, DuckStation, Azahar, rpcs3, Cemu.
  DuckStation done here; the other five moved to Phase 4b.
  Packaging: probably AppImages (they bundle their own Qt / ffmpeg, which is why the root dropped
  both). Check per AppImage whether it uses the system's patched Mesa/Turnip or a bundled one --
  that decides GPU support on these SoCs. (Earlier plan: native PKGBUILDs, RetroArch + cores.)
- **Distribution (decided 2026-10-03, design in Phase 4): not in the image.** An OGUI plugin downloads an
  emulator's AppImage the first time a ROM needs it, and offers updates when QForge publishes a
  new one. This reverses the Phase 2 "no OGUI plugin" decision for this purpose. Until it exists,
  AppImages are pushed to `/home/player/emulators` by hand for testing.
- **DuckStation first** (2026-10-03). Upstream `latest` DuckStation-arm64.AppImage (86 MB,
  218 MB unpacked): bundles Qt6 / SDL3 / GTK3 but NO Mesa, libvulkan, libGL/EGL, gbm or drm, so
  it uses our Mesa/Turnip. Needs glibc >= 2.35 (root has 2.43) and host libX11/xcb/wayland/
  fontconfig, all present; only unused Qt plugins (eglfs, wl-shell) miss libs. Static type-2
  runtime: root has no `fusermount`, so either ship fuse3 or extract on download
  (`--appimage-extract`, what the test does). Launched from OGUI via a `Categories=Game` .desktop
  in `~/.local/share/applications` with `-bigpicture -fullscreen`.
  HW ✅ 2026-10-03, MANGMI Pocket Max (SM8250): Crash Team Racing (CHD, SCPH-550x BIOS set) runs
  full speed on Vulkan/Turnip through the gamescope WSI layer (60 Hz swapchain, Adreno idling at
  305 MHz); sound, picture and orientation OK; OGUI overlay works over it; OGUI's Exit (reaper
  SIGTERM to the process group) quits it cleanly. With cpu4-7 offline it ran on the little
  cluster alone, CPU thread ~44% of one 1.8 GHz core: PS1 needs no pinning. Lessons for the
  plugin / launcher:
  - Exec the real binary (`usr/bin/duckstation-qt`), never the extracted `AppRun` symlink: Qt
    takes applicationDirPath from the symlink, misses `qt.conf`, finds no platform plugin, aborts.
  - Seeding settings.ini to skip the setup wizard also skips its controller auto-map: write
    `[InputSources] SDL = true` + a `[Pad1]` SDL-0 mapping. InputPlumber exposes a single
    virtual Xbox Elite 2 pad (real joypad is root-only), so `SDL-0` is stable. Leave Guide
    unbound (OGUI owns it).
  - No xdg-desktop-portal: harmless Qt warning, it falls back to its own theme.
  - Exit is OGUI Guide -> running-game card -> Exit; an emulator hotkey can come later.
- **Per-game CPU pinning at launch** (decided 2026-10-03). The performance menu's core-count
  slider stays a POWER control: PowerStation offlines the fastest cores first, so "4 cores" on
  SM8250/SM8550/SM8650 is the little cluster only. Keeping a game's threads on the fast cores
  (no migration across clusters) is done per game instead: the launcher sets the emulator's CPU
  affinity to the big cores, so background work (audio, input, Wi-Fi) keeps the little ones.
  - Pick the big cores from `/sys/devices/system/cpu/cpuN/cpu_capacity`, not by CPU number.
  - Per game, the player's choice through the plugin (decided 2026-10-03; done, see above).
  - sched_ext: scx_lavd honours the affinity mask (HW-checked).
- PowerStation follow-up for upstream: moved to the Backlog.
- InputPlumber hotkeys: exit to shell works through OGUI's Guide menu; emulator save/load-state
  hotkeys moved to Phase 4b.
- Per-device defaults: DROPPED as a standalone item (2026-10-03). Nothing needs one today (DuckStation's
  seed is the same on every device; per-device pinning went with the per-game player choice). Add a
  device-specific value from `/usr/lib/qforge/devices/<device>.conf` only when an emulator needs it --
  likely first: Azahar's screen layout on the dual-screen Pocket DS, or resolution scaling once a heavy
  emulator shows a real gap between SoCs.
- ✅ **Player folder layout** (2026-10-03): `~/{roms/<system>,bios,saves/<system>,states/<system>,
  emulators}` from `/usr/share/user-tmpfiles.d/qforge-home.conf`, created by player's own user
  manager at every login (system tmpfiles is not ordered after /home, which is `nofail`), so OTA'd
  devices, which keep /home, gain new folders too. The user `systemd-tmpfiles-setup.service` must be
  linked into `/etc/systemd/user/basic.target.wants` -- user presets are only applied at package
  install, which an image build never runs (HW: the folders were missing until that link). Every
  launch.conf system needs its rows (test). DuckStation's seed puts memory cards in `~/saves/psx`
  and states in `~/states/psx`. ROMs from a second SD card stay with Phase 5's automount decision.
- ✅ **Network shares** (decided + built 2026-10-03): ksmbd (in-kernel SMB3, `CONFIG_SMB_SERVER=m`)
  + ksmbd-tools 3.5.7 (overlay PKGBUILD, not in the snapshot; Samba was ~110 MiB+ with deps),
  `/etc/ksmbd/ksmbd.conf`: shares roms, bios, saves, states only; GUEST read-write mapped to
  `player`; ON by default (preset + .wants), avahi-daemon enabled for `qforge.local` and an
  `_smb._tcp` record. `[ipc$] guest ok = yes` is needed: ksmbd-tools adds [ipc$] without it, so a
  guest could not list shares. HW (Pocket Max, 20261003T175813Z): direct share URLs work as guest
  (anonymous or any name) from Linux; Windows 10/11 refuse SMB guest logins by default.
  - ✅ Listing the shares at the server root (`smb://qforge.local/`) failed for every user, guest
    or authenticated, with stock or our [ipc$]: kernel 7.2's `smb2_ioctl()` looks the RPC pipe id up
    as an open file and returns -ENOENT before `fsctl_pipe_transceive()` runs. Upstream regression
    from "ksmbd: add SMB3 request replay support"; backported Gael Blivet's fix (applied to
    ksmbd-for-next-next) as kernel/patches/1000. HW (20261003T183508Z): guest `smbclient -L` and
    the desktop file manager list roms/bios/saves/states.
  - HW end to end (same card): folders created at login with no manual step; BIOS + CTR copied in
    over the guest shares (~58 MB/s, owned by player, with a POSIX ACL from ksmbd); DuckStation
    seeded from the image; the CTR memory card landed in ~/saves/psx and is visible on the `saves`
    share; with SaveStateOnExit (now in the seed) OGUI's Exit wrote ~/states/psx/
    SCUS-94426_resume.sav. Not yet checked: what DuckStation does with that resume state on the next
    launch; two short runs right after enabling it wrote no state (likely exited during boot).
- ✅ Licence check: never ship BIOS. DuckStation checked 2026-10-03 (see Phase 4, Licences);
  emulators come from upstream, so QForge redistributes none.

### Phase 4 — QForge OGUI plugin: ROM library + emulator manager (High)

First steps, host-testable before any GDScript: `qforge-launch --gui <emulator>` (no-ROM mode
for the store's Open; done 2026-10-04, `GUI_ARGS` in the emulator conf, DuckStation
`-bigpicture -fullscreen`; HW ✅ 2026-10-04 on the Pocket ACE: Big Picture opens with no ROM, its
own Exit returns to OGUI, mount released), and a first
`catalog.json` with DuckStation pinned to a
numbered release (v0.1-11894 or newer), re-tested on HW (launch, pad, every exit path, memory card,
resume state). Catalog done 2026-10-04: `/usr/share/qforge/catalog.json` in the image (schema 1: name,
systems, github owner/repo, tag, anchored asset regex, sha256, size, homepage, licence; launch
details stay in the image's emulator conf), DuckStation pinned to v0.1-11894 (sha256 = GitHub's
digest), checked by `tests/test-catalog.sh` (`QFORGE_NET_TEST=1` also re-checks every pin against
GitHub). The image's copy is the offline fallback; the plugin keeps the hosted one in
`~/.cache/qforge/catalog.json`, which wins.
Part 2 started 2026-10-04: `/usr/bin/qforge-emu list | install <emu> | remove <emu>` (Python,
`tests/test-emu.sh`), the download half the plugin drives (stdout = `N%` lines / JSON; exit 2 usage,
3 network, 4 verification, 5 local). Install: GitHub API for the pinned tag, refuse unless the
asset's digest + size equal the catalog's and the URL is https; curl `--proto =https
--proto-redir =https` into a .part; sha256 + size again; rename to `<tag>.AppImage`, flip
`current` atomically, keep the previous AppImage, delete older ones. Real install from GitHub
verified on the host (DuckStation, 86 MB, 9 s).
Plugin side done 2026-10-04 (HW ✅ Pocket ACE):
- No pre-launch check (decided): a ROM card always launches; when qforge-launch exits 3 it leaves
  `not-installed|mount-failed <emu>` in `$XDG_RUNTIME_DIR/qforge-launch.status`, and the plugin's
  EXIT hook shows OGUI's shared dialog ("DuckStation is not installed. Download it from the QForge
  store first."). Needed OGUI patch 0004 (#562): an app that exits before any window was never
  seen as stopped (loading screen hung); now stopped on the first failed check, ~0.6 s.
- Store = Settings > Emulators (decided: not OGUI's dormant Store button, which is meant for game
  stores): the plugin injects a button after Library + a page into OGUI's settings menu at runtime
  (`emulators_page.gd`, built like library_settings_menu.tscn: own State, StateUpdater REPLACE,
  TabSetter, TextSetter). Per emulator: Download / Update / Open (`qforge-launch --gui` via
  LaunchManager) and Delete (confirm dialog); progress from the .part size; rows rebuilt after
  each action with the focus handed back.
- qforge-emu retries every transient curl error (`--retry-all-errors`): a curl 55 (Wi-Fi drop)
  failed the first in-UI download on the ACE.
Still open in part 2/3: an OGUI notification when the hosted catalog offers an update (needs the
hosted catalog, Phase 5); the plugin fetching that catalog into `~/.cache/qforge/`.
HW 2026-10-04, Pocket ACE, v0.1-11894 from a card: first-run seed, launch, OGUI Exit
(double SIGTERM, clean, mount released); DuckStation keeps every seeded value when it rewrites
settings.ini (drops our comments, adds [UI] geometry). Memory card and resume state not checked
(game left during the intro).
Tab prototype done 2026-10-04 (`apps/ogui-qforge-plugin/`, `build.sh` -> `out/plugins/qforge.zip`,
`tests/test-plugin.sh`): YES, a plugin can add a per-system tab. HW ✅ Pocket ACE: a "PlayStation"
tab next to Installed / All Games with OGUI's own cards, CTR also in All Games, its card opens OGUI's
launch menu and runs `qforge-launch psx <rom>` (path with spaces as one argument). What it took:
- OGUI's library menu only fills Installed and All Games; a tab added via `library_tabs_state`
  is placed in the TabContainer but the plugin fills its grid (cards from `card.tscn`, button_up ->
  `game_launcher` state, as `library_menu.gd` does). Node layout must match AllGamesTab
  (ScrollerJoystick, then MarginContainer > HFlowContainer): the menu focuses `get_child(1).get_child(0)`.
- Plugins initialise BEFORE the library menu is ready (PluginManager first in card_ui.tscn), so
  tabs are added from `library_manager.library_loaded`, never in the plugin's `_ready`.
- Never override `_init()` in a plugin script: it replaces the base constructor, and
  `Library._init` is what registers the library on ready (first try loaded, never registered).
Done 2026-10-04 (plugin 0.1.2; HW ✅ Pocket ACE: 4 colliding ROMs = 4 cards, Refresh Library after deleting two dropped the stale cards and renamed the rest): library items are keyed by NAME across
all providers, so two same-named ROMs merged into one item (the second was lost). `rom_names.gd`
now names a colliding ROM "Tetris (PlayStation)" (other system) or "Tetris (CUE)" (same system),
compared without case; and each scan first removes our launch items whose ROM is gone or whose
name now means another file (`load_library` only adds). Tested in a stock headless Godot
(`QFORGE_GODOT=<godot 4.7 x86_64>`, skipped without). Per-game fast cores done 2026-10-04 (plugin 0.1.3): Game settings > QForge (the gear on a ROM's
launch menu; button + page injected at runtime like Settings > Emulators, shown for QForge ROMs
only) holds "Run on fast cores". Saved in OGUI's settings.cfg `[qforge.fast_cores]`, key
`<system>/<file>` (not the card name, which can change), absent = off; flipping it rewrites the
launch item's args (`--cpus big` first), which OGUI reads at each launch. HW ✅ Pocket FIT
(SM8650): on -> `qforge-launch --cpus big`, DuckStation affinity 2-7; off -> 0-7, key erased;
on survives a session restart (toggle shown on, pinned 2-7).
Still to handle: OGUI's search only covers Installed / All Games;
the tab refreshes twice at start (two library loads); upstream `remove_tab` resets `current_tab`
on the wrong condition (`size > current_tab`).
OGUI only reloads its library at start and from Settings > Library > Refresh Library: no D-Bus
service, signal or file watch. The plugin runs in-process, so it calls
`library_manager.reload_library()` itself after a rescan or a download. Then the tab prototype: can a plugin add a PSX tab that reuses OGUI's game grid.

Decided 2026-10-03: one OGUI card per ROM, grouped in one library tab per system (PSX, PS2, ...),
and emulators fetched on demand. Both live in ONE plugin (`qforge`), since the ROM card is what
needs the emulator. Design from OGUI v0.46.1 source (`_ref/OpenGamepadUI`); to review before code.

**What OGUI gives us (verified in source)**
- Plugins: `user://plugins/<id>.zip` = `~player/.local/share/opengamepadui/plugins/`, loaded with
  `ProjectSettings.load_resource_pack`; the zip holds `plugins/<id>/plugin.json` + `plugin.gd`
  (GDScript source, no export needed). Enabled by default (`settings.cfg [plugins.enabled]`).
  Only the user dir is scanned, so the image can not ship it read-only: seed the zip into /home
  (see Delivery).
- `Library` subclass = a library provider: `get_library_launch_items()` returns
  `LibraryLaunchItem`s (`name, command, args[], env{}, cwd, tags[], categories[], installed,
  metadata{}`); args are an array, so ROM paths with spaces need no quoting (unlike `.desktop`
  Exec, which OGUI splits on spaces).
- `get_app_lifecycle_hooks()` -> `AppLifecycleHook` PRE_LAUNCH / LAUNCH / EXIT;
  `LaunchManager` AWAITS pre-launch hooks before starting the app, and a hook can emit
  `progressed(percent)` / `notified(text)`. That is the "download on first launch" point.
- `Library.install/update/has_update/uninstall` + `install_progressed`: OGUI's install flow.
  The launch menu only shows Install / Launch / Uninstall; nothing in the UI calls `has_update`
  or `InstallManager.update`, so there is no built-in update badge.
- Library tabs: `res://core/ui/card_ui/library/library_tabs_state.tres` (`TabContainerState`)
  has `add_tab(text, ScrollContainer)` / `remove_tab`; the menu itself only builds Installed and
  All Games. A plugin adds the per-system tabs and fills their grids.
- `BoxArtProvider` (GRID_PORTRAIT / GRID_LANDSCAPE / BANNER / LOGO): artwork per item, later.

**Plugin parts** (overall shape, 2026-10-03: like armada's Decky store -- a store for the emulators
plus the ROM library that launches them)
1. Systems table (in the plugin): `psx -> {name "PlayStation", exts [chd, cue, pbp, m3u, iso],
   emulator duckstation}`, `ps2 -> armsx2`, `gc/wii -> dolphin`, `3ds -> azahar`, `ps3 -> rpcs3`,
   `wiiu -> cemu`. ROM dirs `/home/player/roms/<system>/` (one level deep; m3u wins over its
   member cue/chd so a multi-disc game is one card).
2. Library provider `qforge-roms`: one item per ROM, `name` from the file name (strip region /
   tags later), `tags [<system>]`, `metadata {system, rom, emulator}`, `installed true`.
   `command` = `qforge-launch` (below), `args [<system>, <rom path>]`, prefixed with
   `--cpus big` when the player turned "fast cores" on for that game (per-game setting the plugin
   stores and offers; off by default). Rescan on OGUI start and via a refresh action; inotify later.
   **Resume (decided 2026-10-03): the plugin asks.** When a game has a resume state, its card offers
   Resume / Start fresh before launching. Emulators cannot ask themselves: DuckStation's "Resume
   Game -- load this state, or start from a fresh boot?" dialog only exists in its own game list
   (`FullscreenUI::HandleGameListActivate`), which a ROM card on the command line bypasses. Needs a
   `qforge-launch --resume` mapped per emulator (DuckStation: `-resume`, from the emulator conf) and
   a per-emulator way to tell whether a resume state exists (DuckStation names it
   `~/states/psx/<serial>_resume.sav`, so the plugin needs the game's serial). Until then games boot
   fresh; the state is still loadable from the emulator's pause menu.
3. Tabs: one tab per system that has at least one ROM, populated from the provider's items.
   Check first whether OGUI's library grid can be reused for a tab or the plugin builds its own.
4. Emulator manager, modelled on armada's Decky store (armada-os/armada, `decky/armada-store`;
   decided 2026-10-03): NO mirror -- AppImages come straight from each emulator's own releases.
   A catalog (`catalog.json`) lists per emulator: the releases API URL (GitHub / GitLab), the
   PINNED release tag, an asset regex (e.g. `^DuckStation-arm64\.AppImage$`), the binary inside the
   AppImage and default args. Decided 2026-10-03: QForge HOSTS the catalog (fetched over HTTPS from
   the QForge server; the copy bundled in the plugin is only the offline fallback) and pins one
   tested tag per emulator, so QForge alone decides when an update is offered: bumping a tag in the
   hosted catalog after testing is what makes the plugin offer it. No "newest" mode (armada follows
   upstream's newest; an upstream change could break a seed or the launch args unnoticed). Rolling
   tags are never pinned: DuckStation's `latest` (the 0.1-12070 build tested so far) replaces its
   asset in place, so its pin must be a numbered release (v0.1-11894 or newer), re-tested on HW.
   Install: fetch that tag's release, download over HTTPS only (refuse a
   redirect to http), verify the asset's sha256 against the API's `digest` field (GitHub publishes
   one per asset; matched our tested DuckStation AppImage) -- armada does not verify, we do --
   then stage and rename atomically to `/home/player/emulators/<emu>/<tag>.AppImage`, chmod +x,
   flip `current` (previous AppImage kept until the new one has launched once). Update check =
   installed tag vs the hosted catalog's tag (armada's 1 h cache, and a failed fetch never counts
   as "no update").
   **Store screen** (decided 2026-10-03, armada-store style): the plugin's own page lists the
   catalog's emulators with installed vs catalog tag, and per emulator: Download, Update (when the
   hosted catalog's pinned tag is newer), Delete, and **Open** -- start the emulator's own GUI for
   the settings OGUI does not expose (graphics, per-game options, controller tweaks). Open needs a
   no-ROM mode in the launcher (`qforge-launch --gui <emulator>`: same AppImage mount / setsid /
   exit handling, GUI args from the emulator conf instead of the ROM args, e.g. DuckStation without
   `-batch`). An OGUI notification points at the store when the catalog offers an update. Updates
   are never applied at launch. Not via OGUI's `has_update`: in v0.46.1 no UI calls it, and it is
   per library item, so one DuckStation update would flag every PSX card.
   **ROM whose emulator is not installed**: the PRE_LAUNCH hook does NOT download silently -- it
   shows a popup offering to download the emulator (name, size from the release asset), with
   progress, then launches the ROM; declining cancels the launch.
5. Per-emulator first-run config -- MOVED to the image (decided 2026-10-03, done): defaults in
   `/usr/share/qforge/emulators/<emu>/`, named by `SEED=(<file>:<path under $HOME>)` in
   `/etc/qforge/emulators/<emu>.conf`; qforge-launch copies them before the first start, never
   over an existing file. One set per emulator for every device: InputPlumber presents each
   handheld's joypad as one virtual Xbox Elite pad (SDL-0). Per-device overrides via
   `/usr/lib/qforge/devices/<device>.conf` only if a device ever needs one. The plugin only
   downloads; a "reset to QForge defaults" action on its Emulators page if needed later.
   HW ✅ (Pocket Max, settings.ini removed first): seeded, no wizard, pad + Select+Start + Exit OK.
   Contents (DuckStation: settings.ini with wizard off, BIOS/ROM dirs, Vulkan, `[Pad1]` SDL-0 mapping,
   ConfirmPowerOff off (SIGTERM path), auto-updater off, `[Hotkeys] OpenPauseMenu = SDL-0/Back & SDL-0/Start` -- by default only
   keyboard Escape opens its menu, so a controller can never reach Exit; HW-verified). Never overwrite a user-changed config after that.

**Launcher `qforge-launch <system> <rom>`** (in the image, `/usr/bin`, shell, unit-tested)
- Resolves the emulator from the system, mounts `/home/player/emulators/<emu>/current` and runs
  `<mount>/<binary> <per-emu args> <rom>` under the AppImage rules above (DuckStation:
  `-batch -fullscreen -- <rom>`; `-batch` returns to OGUI when the game closes).
- The one place for per-game CPU pinning (Phase 3), and for any device-specific value later.
- Keeps the plugin free of emulator details beyond the manifest; testable over SSH without OGUI.

**Plugin store: QForge's own, upstream's masked** (decided 2026-10-03)
- OGUI hard-codes `PLUGIN_STORE_URL` = ShadowBlip/OpenGamepadUI-plugins `plugins.json`
  (`core/global/plugin_loader.gd:20`). Its 7 entries (steam, flathub, steamgriddb, recapture,
  lutris, sunshine, ayaneo-modules) are Steam/x86/desktop oriented, and the request is the
  "plugin store request failing" noise seen on first boot. Mask it.
- OGUI patch 0004: read the store URL from a ProjectSettings key next to the existing
  `OpenGamepadUI/plugin/directory` (upstreamable; default stays upstream's), and set it to the
  QForge store in our build. Placeholder host until Phase 5 replaces `updates.qforge.invalid`.
- QForge store = a `plugins.json` in the same format (`plugin.id/name/version/min-api-version`,
  `archive.url`, `archive.sha256`, `versions[]`) on the QForge update server, listing `qforge`
  (and anything else we publish). OGUI then gives us, unchanged: periodic store check
  (`on_update_timeout`), "update available" when `plugin.version` is greater and the API is
  compatible, install with sha256 verification into `user://plugins/<id>.zip`.
- The QForge server hosts the plugin store (`plugins.json` + plugin zips) and the emulator
  catalog (`catalog.json`, pinned tags); the emulators themselves come from upstream (part 4). Trust (decided 2026-10-03): HTTPS to the QForge host is enough; the plugin
  index carries a sha256 per archive (emulators: GitHub's per-asset digest), no separate signature. Downloads must refuse plain
  http and invalid certificates.

**Delivery of the plugin itself**
- Built in-repo (`apps/ogui-qforge-plugin/` -> zip), shipped in the image at a read-only path and
  copied into `~player/.local/share/opengamepadui/plugins/` by the session when missing or older
  than the image's copy (compare `plugin.version`), so a fresh card works offline. Later
  versions come from the QForge store; the session never downgrades a store-updated copy.

**Decided 2026-10-03**
- Download source: ~~QForge mirror~~ REVERSED 2026-10-03 -- straight from upstream releases,
  armada-store style (see part 4). We redistribute nothing, so no LGPL source hosting for the
  libraries the AppImages bundle.
- FUSE: `fuse3` in the image (fusermount3 setuid, already on the guard permit list), AppImages
  stay packed. Install = download + verify + chmod + `current` symlink.
  HW ✅ 2026-10-03 (Pocket Max, dev build 20261003T135813Z): AppImage mounts as player; CTR runs,
  controller OK; OGUI Exit graceful in ~70 ms, no core dump, no leftover process or mount -- but
  only through a launcher wrapper (prototype `/home/player/emulators/appimage-run`, to become
  the AppImage path of `qforge-launch`). Rules it encodes, each found on HW:
  - Never exec the AppImage (or AppRun): the runtime starts `AppRun`, a symlink; Qt takes
    applicationDirPath from it, misses `usr/bin/qt.conf`, finds no platform plugin and aborts.
    Same in DuckStation v0.1-11580 / 11894; desktops hide it with a system Qt. Mount with
    `--appimage-mount` and exec `<mount>/<binary>` (manifest field `binary`, e.g.
    `usr/bin/duckstation-qt`). Report upstream.
  - OGUI `Reaper.reap()` (`core/systems/launcher/reaper.gd:65`) signals every PID in the tree,
    leaves inward, as `kill -TERM -- -PID` then `kill -TERM PID`, separate commands. Run the
    emulator under `setsid` so it leads its own group: its two signals arrive back to back and
    coalesce, as when OGUI launches it directly. Inside the wrapper's group it got a second,
    later SIGTERM, which DuckStation takes as "force quit" -> abort(), core dump, 14 s exit.
    No OGUI patch needed.
  - The mount runtime is in the tree too: start it with SIGTERM ignored, or OGUI tears the files
    away under a shutting-down emulator. The runtime also ignores INT (bash background) -- release
    it after the emulator exits with SIGHUP to the runtime, then `fusermount3 -u` (the parent
    holds the mount busy until it exits).
  - Exit pressed twice = SIGKILL leaves a dead mount: sweep `fuse.<appimage>` mounts on start
    (`fusermount3 -uz`).
  - The wrapper traps TERM and waits; it never forwards the signal (that would be the second
    Ctrl+C).
- **`qforge-launch <system> <rom>` done** (2026-10-03): `/usr/bin/qforge-launch` with
  `/etc/qforge/launch.conf` (system -> emulator) and `/etc/qforge/emulators/<emu>.conf` (BINARY
  inside the AppImage, ARGS); runs `/home/player/emulators/<emu>/current`. Offline suite
  `tests/test-launch.sh` (fake AppImage / emulator / fusermount3, OGUI reap replayed; in
  `make test`). HW ✅ on the Pocket Max, dev build 20261003T153817Z: an OGUI card running
  `qforge-launch psx .../ctr.chd` boots CTR directly; OGUI Exit graceful (~190 ms), and quitting
  from DuckStation's own pause menu returns to OGUI (`-batch`); no core dump, process or mount left.
  The FUSE type is named after the file `current` points to (`fuse.0.1-12070.AppImage`), as the
  stale sweep assumes; only the mount dir takes the link's name.
- ✅ **Per-game CPU pinning** (2026-10-03): `qforge-launch --cpus big <system> <rom>` starts the
  emulator under `taskset -c <fast cores>`: every ONLINE CPU whose cpu_capacity is above the
  smallest online one (SM8250 cpu4-7, SM8550 cpu3-7, SM8650 cpu2-7), never by number, never the
  prime core alone; nothing pinned when no fast core is online (PowerStation core-count limit) or
  the SoC is homogeneous. Decided: it is the PLAYER's choice, per game -- the plugin offers it and
  puts `--cpus big` on that game's command line; no emulator conf in the image pins anything (a
  test enforces it). HW (Pocket Max, DuckStation): affinity 4-7, every working thread stays there;
  Mesa's 4 idle shader-disk-cache threads reset themselves to all CPUs (Mesa util_queue,
  harmless); scx_lavd honours the mask (320 samples, 0 on cpu0-3). CoreThread ~10% of a big core
  at 825 MHz -- PS1 gains nothing; it matters for rpcs3 / Cemu / ARMSX2.
- ✅ **`systemctl restart qforge-session` took 90 s** (fixed 2026-10-03). PAMName= moves the
  session into the logind session scope, so the service cgroup is empty and systemd's stop only
  signals the main PID, qforge-session (sh). It ran OGUI in the FOREGROUND, and sh holds a trapped
  SIGTERM until the foreground command returns: nothing ever told OGUI to quit, so every stop sat
  out TimeoutStopSec and ended in SIGKILL. Not new (every restart was 90 s), just unmeasured. Now
  the client runs in the background and the script `wait`s, forwards SIGTERM to it, then stops
  gamescope; `<&0` keeps tty1 as its stdin; `SuccessExitStatus=143` so a requested stop is not
  logged as a failure. HW (bind-mounted script + runtime drop-in): restart 0.9-2.3 s (stop
  ~0.1 s + RestartSec), OGUI stdin still /dev/tty1. tests/test-session.sh runs the real script
  with a fake gamescope and client; it fails on the old script.
- ✅ **Games running when the session stops** (fixed 2026-10-03). OGUI quits without stopping
  them: its reaper goes to PID 1, the game runs on until gamescope dies, then loses its display
  and aborts (core dump, ~15 s orphan holding the GPU into the next session). qforge-session now
  stops games FIRST, gamescope still up, exactly as OGUI's Exit does (Reaper.reap pattern),
  finding OGUI's reapers by executable (so a game outliving a crashed OGUI is covered too), waits
  up to 10 s (QFORGE_GAME_STOP_TIMEOUT), then SIGKILLs leftovers. HW: CTR shut down gracefully,
  game gone ~330 ms after the stop, mount released, restart 3.5 s, no core dump; the stale mount
  a killed run left was swept by the next launch.
  Found on the way: DuckStation's `ConfirmPowerOff` IS needed. Its menu Exit never asks, but a
  SIGTERM does, and the dialog waited out the 10 s timeout (game killed, stale mount). Restored
  in the seed, with a test.
- Not pursued (decided 2026-10-03): a one-off gamescope SIGABRT core dump when a game was
  SIGKILLed during the session stop (timeout/kill path only; never seen on a clean stop).
- ROM cards show in All Games as well as in their system tab.

**Open questions for review**
- Licences: the plugin downloads from upstream, so QForge redistributes no emulator; still check
  each emulator's licence AND its author's stated terms (configuration, packaging) before adding it
  to the catalog.
  DuckStation (checked 2026-10-03): CC BY-NC-ND 4.0. The README allows redistributing
  "unmodified releases", prefers a link to duckstation.org, and states "pre-configured settings and
  packages are considered modifications" -- so the author would count our seed settings.ini and the
  plugin's packaging as modifications. Decided 2026-10-03: proceed anyway (seed; the mirror is
  gone, see Download source), the risk is accepted. Still owed whatever we do: attribution (name, link, licence) in the plugin, and
  QForge staying non-commercial.
- BIOS: the plugin can tell the user which BIOS a system needs and where to drop it; never ships it.
- Artwork scraping later (ScreenScraper needs credentials).

### Phase 4b — Grow the emulator catalog (after Phase 4)

- The other five: ARMSX2 (PS2), Azahar (3DS), Dolphin (GC/Wii), rpcs3 (PS3, needs firmware),
  Cemu (Wii U). Recipe from DuckStation, per emulator: an aarch64 AppImage that uses our
  Mesa/Turnip (armada's catalog has working asset patterns for all five); `.conf` + minimal seed;
  `launch.conf` system + folder-layout rows; every exit path (SIGTERM vs menu: ConfirmPowerOff-style
  dialogs, save state on exit); licence and author's stated terms; pinned tag in the hosted catalog.
- Emulator save/load-state hotkeys (DuckStation first: seed bindings that avoid in-game combos).
- Device-specific values only when needed (Azahar's dual-screen layout on the Pocket DS is the
  likely first).

### Phase 4c — Library scaling polish (later, decided 2026-10-04)

Measured 2026-10-04 on the Pocket ACE (plugin timing logs, 2,000 empty `.chd` in `~/roms/psx`):
the ROM scan takes 9 ms, so a scan cache would not help. The cost is OGUI's card UI: its library
menu queues a full refresh per added item (2,001 refreshes, ~24 s of rebuilding after start, each
up to 27 ms), every ROM gets three cards (our tab, All Games, Installed: ~6,000), and OGUI's RSS
goes from 0.4 GB to 1.8 GB (+~240 KB per card, ACE has 7.5 GB). Our tab (0.8 s for 2,000 cards)
is only built after that churn (28 s) and three times. Options, to pick when polishing:
- A. Keep ROMs out of OGUI's lists: register the library (hooks, launch menu) but hand OGUI no
  items; the plugin keeps its own ROM list and builds cards only in its tabs. Loses All Games and
  OGUI search for ROMs (own search needed); reverses "ROM cards show in All Games too".
- B. Lazy cards in our tabs (only what is on screen / page by page).
- C. OGUI patch, upstreamable: coalesce library refreshes (one per batch of adds).
A metadata cache (titles, serials, resume) keyed by path + size + mtime comes with the per-ROM
work that needs it, not before.

### Phase 5 — Release infrastructure (Medium)

- **OGUI's storage screen is dead** (deferred 2026-10-03: only matters once QForge runs from
  internal UFS and the SD slot is free for storage; booted from the only SD slot it has nothing to
  manage): its removable-media manager calls
  `/usr/bin/steamos-polkit-helpers/steamos-{format-sdcard,retrigger-automounts,trim-devices}`,
  which Phase 0 removed (guard-forbidden). Decide: ship those three paths as thin wrappers over
  qforge-format-sdcard / block-event, or accept no Format button.
- **SD automount is ext4-only** (deferred 2026-10-03 with the storage screen: a second card only
  exists to mount once QForge runs from internal UFS), inherited from the Steam library requirement that no longer
  applies; ROM cards are usually exfat. Decide whether to automount exfat/vfat too.

- **OS update UI = a QForge OSPlatform in OGUI** (noted 2026-10-04, to design with the update
  server). OGUI picks an OS platform from `/etc/os-release` `ID` (hard-coded list in
  `core/global/platform.gd`: steamos, chimeraos, manjaro, nixos, bazzite); its `ready(root)` may
  change the scene tree. The NixOS one (`core/platform/os/nixos.gd`) is the model: it removes OGUI's
  own updater (which on QForge only knows the x86 `update.zip`, hence `--skip-update-pack`) and,
  when its `os-updater` script exists, adds an update section to Settings > General: check, apply
  (progress), auto-update toggle and a branch dropdown, all via `Command` on that script.
  For QForge: OGUI patch adding `core/platform/os/qforge.{gd,tres}` + `ID=qforge` detection,
  driving `qforge-update` (`check` / apply with `N%` / `channels` / `set-channel`; its contract is
  already OGUI-shaped). Upstreamable like the other distro platforms, and the natural home for
  other QForge defaults (theme, startup actions). Replaces "update channel stays CLI/SSH" (Phase 2).
- Update server via `ota/setup-server.sh`; replace the `updates.qforge.invalid` placeholder in
  `qforge-update`, `installer/release-info`, `installer/netcfg`.
- CI release secrets `RAUC_CERT_PEM` / `RAUC_KEY_PEM` from `~/qforge-pki`.
- Card / bundle / installer release workflows, runbook.
- Optionally move firmware to a QForge-owned repo.

## Backlog (outward-facing: send only when decided)

- PowerStation: order SetCoresEnabled by `cpu_capacity` instead of CPU number (Qualcomm numbers
  cores slowest-first; other SoCs do not); plus our patches 0001/0002 (`_ref/PowerStation` qforge-arm).
- OpenGamepadUI: SENT 2026-10-03 as #559 / #560 / #561; #562 (our patch 0004, apps that exit
  before creating a window) sent 2026-10-04.
- OpenGamepadUI: the library menu queues one full refresh per library_item_added (2,000 items =
  2,001 refreshes, ~24 s); coalesce them (Phase 4c option C).
- DuckStation: AppRun is a symlink, so on a system without Qt, Qt's applicationDirPath misses
  `usr/bin/qt.conf` and no platform plugin loads.

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| OGUI / Godot / GDExtension do not build or run on aarch64 | Medium | Phase 1 proof of concept before anything depends on it |
| PowerStation has no Qualcomm backend | High | Adapter to `org.qforge.Power` first |
| Steam-shaped contracts silently broken (update gate, per-game perf, OOBE Wi-Fi) | High | Listed above as Phase 2 tasks |
| Emulator licensing / aarch64 availability | Medium | Licence allowlist; prefer emulators with arm64 JITs |
| No upstream merges for hardware fixes | Medium | Accepted — QForge is standalone |
| SM8250 has no sensor DSP firmware (no auto-rotate) | Certain | Documented |

## Validation

```bash
make test                                   # all offline suites
make test-signing PKIDIR=~/qforge-pki       # signing chain, in container
make test-disk                              # installer disk suites, in container
make sdcard && make verify-card             # first real build
```
