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
| Root slots | 4G each (was 7G with the x86 payloads) |
| Firmware | Still fetched from Nova-Deck/qcom-firmwares (pinned); move to a QForge repo later |
| OTA signing | New QForge CA; private keys in `~/qforge-pki`, never in the repo |
| Emulators | Native PKGBUILDs (not Flatpak) so they use our patched Mesa/Turnip |

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
| Build `make sdcard`, check `du --apparent-size out/images/rootfs.img` | Confirm the 4G slot has ≥1G headroom; `make-sdcard.sh`'s `fits` check is the backstop |
| Boot on one SM8250, one SM8550, one SM8650 board | Gate: gamescope + vkcube on the panel, A/B confirm via qforge-boot-good |
| Back up `~/qforge-pki/ca.key.pem` off this machine | Losing it means no device can ever accept another update |

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
- **Perf UI = PowerStation shim (if kept).** OGUI's performance menu speaks only
  `org.shadowblip.PowerStation` (no PPD/UPower profiles); a minimal CPU/GPU/Card/TDP tree in
  qforge-powerd mapped onto eco/balanced/performance + GPU clock would light it up.

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

Remaining OS-side (found in OGUI source):
- OGUI power menu / idle suspend run `systemctl suspend|poweroff|reboot` as `player` — confirm
  logind/polkit allows it from the gamescope session (and that suspend routes to qforge-suspend).
- PowerStation shim (above) — or accept a dead performance menu for now.
- Clean remaining Steam wording in `automount.sh`, `qforge-suspend`, `qforge-scheduler`,
  `power-ops.sh`, `qforge-session`.
- `kernel/kernel.config` comment still names qforge_perf as CONFIG_PROC_CHILDREN's consumer; fix
  with the next real kernel change (any edit there forces a ~25 min kernel rebuild).
- qforge-pairingd stays always-on (no shell switch).

### Phase 3 — Emulators (High)

- Native PKGBUILDs under `packages/`: RetroArch + curated cores, PPSSPP, Dolphin, melonDS, Flycast,
  Azahar, mupen64plus.
- Per-device defaults from the device profiles; InputPlumber hotkeys (exit to shell, save states).
- Layout `/home/player/{roms/<system>,bios,saves,states}`; ROMs also from SD via automount.
- Licence allowlist in `verify-lock`; never ship BIOS; no DuckStation (CC BY-NC-ND) or
  non-commercial cores if distribution model requires it.

### Phase 4 — ROM library in OGUI (Medium)

- Library plugin scanning ROM dirs, mapping systems → emulator launch commands.
- Artwork scraping later (ScreenScraper needs credentials).

### Phase 5 — Release infrastructure (Medium)

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
