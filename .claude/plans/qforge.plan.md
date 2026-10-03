# Plan: QForge

**Complexity**: Large
**Status**: Phase 0 done. Phase 1 built, HW validation pending. Phase 2 in progress.

## Summary

QForge is a standalone retro-emulation Linux distribution for Qualcomm Snapdragon handhelds
(SM8250 / SM8550 / SM8650). It is derived from the upstream project credited in README.md (GPL-2.0-or-later): it reuses
that project's Holo aarch64 base, unified kernel/DTS, steamcl + GRUB boot chain, RAUC A/B updates
and installer, without the Steam client, x86 emulation or the Android container. The shell is
[OpenGamepadUI](https://github.com/ShadowBlip/OpenGamepadUI) inside gamescope, launching RetroArch
and standalone emulators.

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
- **Not yet done on hardware**: no card has been built or booted from this tree.

### Phase 0 follow-ups (before the first real build)

| Task | Why |
|---|---|
| Build `make sdcard`, check `du --apparent-size out/images/rootfs.img` | Confirm the 2G slot has ≥1G headroom; `make-sdcard.sh`'s `fits` check is the backstop |
| Boot on one SM8250, one SM8550, one SM8650 board | Gate: gamescope + vkcube on the panel, A/B confirm via qforge-boot-good |
| ✅ Back up `~/qforge-pki/ca.key.pem` off this machine (done 2026-10-03) | Losing it means no device can ever accept another update |

### Phase 1 — OpenGamepadUI as the shell (built, HW validation pending)

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
- **Hardware**: boot to OGUI on each SoC; check navigation with the pad (InputPlumber), quick menu
  overlay over a game, mangoapp, focus switching OGUI ↔ game, rotation/scale per panel.
- Check OGUI's in-app update setting cannot still download a user-local build.
- PowerStation deferred to Phase 2 (no Qualcomm backend; would contend with qforge-powerd).

### Phase 2 — Handheld features in OGUI (High) — in progress

Decisions (2026-10-02, from reading OGUI v0.46.1 source in `_ref/OpenGamepadUI`):
- **No OGUI plugin for now.** Only OGUI's built-in screens; QForge-only controls (fan curve,
  scheduler, update channel) stay CLI/SSH (`qforge-scheduler`, `qforge-update`, powerd D-Bus).
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
- Send upstream: PowerStation 0001/0002 (ShadowBlip/PowerStation), OGUI 0003 + the #542/#540
  fixes (ShadowBlip/OpenGamepadUI). Branches: `_ref/PowerStation` qforge-arm,
  `_ref/OpenGamepadUI` qforge-perf-menu.
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

### Phase 3 — Emulators (High)

- Emulators to ship (decided 2026-10-03): Dolphin, ARMSX2, DuckStation, Azahar, rpcs3, Cemu.
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
  - Per-emulator setting with a per-device default; rpcs3 and Cemu are the likely beneficiaries.
  - Check against sched_ext: scx_lavd does its own big.LITTLE placement when it is selected.
- PowerStation follow-up for upstream: order SetCoresEnabled by `cpu_capacity` instead of CPU
  number (Qualcomm numbers cores slowest-first; other SoCs do not).
- Per-device defaults from the device profiles; InputPlumber hotkeys (exit to shell, save states).
- Layout `/home/player/{roms/<system>,bios,saves,states}`; ROMs also from SD via automount.
- Licence check: never ship BIOS. DuckStation is CC BY-NC-ND (no commercial use, no modified
  versions) -- confirm shipping its unmodified AppImage fits how QForge is distributed.

### Phase 4 — QForge OGUI plugin: ROM library + emulator manager (High)

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

**Plugin parts**
1. Systems table (in the plugin): `psx -> {name "PlayStation", exts [chd, cue, pbp, m3u, iso],
   emulator duckstation}`, `ps2 -> armsx2`, `gc/wii -> dolphin`, `3ds -> azahar`, `ps3 -> rpcs3`,
   `wiiu -> cemu`. ROM dirs `/home/player/roms/<system>/` (one level deep; m3u wins over its
   member cue/chd so a multi-disc game is one card).
2. Library provider `qforge-roms`: one item per ROM, `name` from the file name (strip region /
   tags later), `tags [<system>]`, `metadata {system, rom, emulator}`, `installed true`.
   `command` = `qforge-launch` (below), `args [<system>, <rom path>]`. Rescan on OGUI start and
   via a refresh action; inotify later.
3. Tabs: one tab per system that has at least one ROM, populated from the provider's items.
   Check first whether OGUI's library grid can be reused for a tab or the plugin builds its own.
4. Emulator manager: QForge-published manifest (JSON over HTTPS on the QForge update server)
   `emulator -> {version, url (our mirror), sha256, arch, default args}`. Install = download to
   `/home/player/emulators/<emu>/<version>.AppImage`, verify sha256, chmod +x, flip a `current`
   symlink (rollback = previous AppImage kept until the new one has launched once).
   PRE_LAUNCH hook installs it when missing (progress shown). Updates: NOT via OGUI's
   `has_update` -- in v0.46.1 no UI calls it, and it is per library item, so one DuckStation
   update would flag every PSX card. Proposed: a plugin "Emulators" page (installed vs published
   version, Update / Roll back buttons) + an OGUI notification when the manifest has a newer
   version. Never auto-update at launch.
5. Per-emulator first-run config: write the emulator's own config before its first start
   (DuckStation: settings.ini with wizard off, BIOS/ROM dirs, Vulkan, `[Pad1]` SDL-0 mapping,
   auto-updater off). Never overwrite a user-changed config after that.

**Launcher `qforge-launch <system> <rom>`** (in the image, `/usr/bin`, shell, unit-tested)
- Resolves the emulator from the system, execs
  `/home/player/emulators/<emu>/current <per-emu args> <rom>` (DuckStation:
  `-batch -fullscreen -- <rom>`; `-batch` returns to OGUI when the game closes).
- The one place for per-game CPU pinning (Phase 3) and per-device defaults.
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
- Same server can host the emulator manifest (part 4), so one QForge endpoint serves plugin and
  emulator updates. Trust (decided 2026-10-03): HTTPS to the QForge host is enough; the index
  and manifest carry sha256 per archive, no separate signature. Downloads must refuse plain
  http and invalid certificates.

**Delivery of the plugin itself**
- Built in-repo (`apps/ogui-qforge-plugin/` -> zip), shipped in the image at a read-only path and
  copied into `~player/.local/share/opengamepadui/plugins/` by the session when missing or older
  than the image's copy (compare `plugin.version`), so a fresh card works offline. Later
  versions come from the QForge store; the session never downgrades a store-updated copy.

**Decided 2026-10-03**
- Download source: the QForge server MIRRORS pinned upstream AppImages (we pick the version,
  sha256 in the manifest); no direct upstream GitHub downloads.
- FUSE: add `fuse3` to the image (fusermount3 setuid) and run AppImages directly, no extraction.
  Re-check DuckStation then: launched as the AppImage, Qt's applicationDirPath is inside the
  mount, so the `AppRun` symlink problem from the extracted test should not apply. Install
  becomes download + verify + chmod + `current` symlink.
- ROM cards show in All Games as well as in their system tab.

**Open questions for review**
- Licences: we mirror unmodified AppImages, which redistributes them. DuckStation is
  CC BY-NC-ND (unmodified + non-commercial: mirroring fits if QForge stays non-commercial and
  credits it). Check each emulator's licence before adding it to the manifest.
- BIOS: the plugin can tell the user which BIOS a system needs and where to drop it; never ships it.
- Artwork scraping later (ScreenScraper needs credentials).

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

- Update server via `ota/setup-server.sh`; replace the `updates.qforge.invalid` placeholder in
  `qforge-update`, `installer/release-info`, `installer/netcfg`.
- CI release secrets `RAUC_CERT_PEM` / `RAUC_KEY_PEM` from `~/qforge-pki`.
- Card / bundle / installer release workflows, runbook.
- Optionally move firmware to a QForge-owned repo.

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
