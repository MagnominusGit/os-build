# Plan: QForge

**Complexity**: Large
**Status**: Phase 0 done (`b318711`). Next: Phase 1.

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

### Phase 1 — OpenGamepadUI as the shell (High)

- `packages/opengamepadui/`: aarch64 build — Godot 4 linux-arm64 export template + OGUI's Rust
  GDExtension. Upstream ships x86_64 only: **prove this on one device first**.
- `packages/powerstation/`: aarch64 build.
- OGUI session profile: `QFORGE_SESSION_CMD` + `QFORGE_GAMESCOPE_SHELL_ARGS` matching OGUI's upstream
  gamescope session; check QAM overlay, mangoapp, focus switching OGUI ↔ game.
- Review gamescope patches that assume Steam focus (`0005-steamcontrolled-steam-focus-fallback`,
  `0023-xdg-titles-are-reported-to-steam`); keep display/colour/rotation patches.
- Tests: session profile selection; no Steam flags under the OGUI profile.

### Phase 2 — Handheld features in OGUI (High)

- Power/perf: adapter OGUI → `org.qforge.Power` (qforge-powerd) first; a Qualcomm PowerStation
  backend upstream later.
- **qforge-update login gate**: it still requires Steam's `loginusers.vdf`, so it always reports
  "no update". Replace with a first-boot-setup-done marker written by the shell.
- OS updates screen in OGUI driving `qforge-update` (RAUC); decide whether `qforge-select-branch`
  stays (nothing calls it now).
- Per-game performance: `qforge_perf.py` detects games via the Steam process tree — re-key on the
  shell's launched process.
- Brightness/volume, suspend, power menu (can replace the powerbuttond defaults), battery (UPower),
  fan curve UI, first-boot Wi-Fi.
- Remote-access switch in the shell; then make qforge-pairingd switch-driven again.
- Clean remaining Steam wording in `qforge-update`, `qforge-powerd`, `automount.sh`,
  `qforge-suspend`, `qforge-scheduler`.

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
