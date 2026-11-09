# RetroArch + RetroAchievements for the pre-PS1 systems (and N64) — plan

Status: decisions D1-D7 AGREED 2026-11-09 (branch plan/retroarch). Phase 0 on the Air X 2026-11-09: steps 1-5 OK,
6-7 open (RetroAchievements sign-in + unlock, menu walk), 8 moved to Phase 5 unless a disc + BIOS show up.

## Why

Players want RetroAchievements. None of today's emulators for the older systems has it:

| Systems | Today (`launch.conf`) | Achievements today |
|---|---|---|
| gb, gbc, gba | armGBA 1.0 standalone (catalog `Jacob-Matthew-Cook/armGBA`, now redirects to `MagnominusGit/armGBA`) | no (1.5 has them, needs libcurl) |
| snes | Snes9x 1.63 GTK + `retroforge-sigdefer` shim | no |
| md, segacd | ClownMDEmu 1.6.12 | no |
| n64 | RMG + GLideN64 | no (upstream feature request still open) |

RetroArch has rcheevos built in. This plan moves all four rows to one RetroArch with one core per
system, and one RetroAchievements sign-in.

## Decisions (agreed 2026-11-09)

| System(s) | Core | Source | Achievements |
|---|---|---|---|
| gb, gbc, gba | **armGBA** (`armgba_libretro.so` + `.info`) | `MagnominusGit/armGBA` release zip `armGBA-<v>-aarch64.zip`, GitHub sha256 digest | yes (memory described as mGBA's / gambatte-libretro's) |
| snes | Snes9x (`snes9x_libretro`) | libretro buildbot nightly linux/aarch64 | yes |
| md, segacd | Genesis Plus GX (`genesis_plus_gx_libretro`) | buildbot | yes |
| n64 (Phase 6) | Mupen64Plus-Next (`mupen64plus_next_libretro`), GLideN64 | buildbot | yes |

RetroArch itself: `pkgforge-dev/RetroArch-AppImage-Enhanced`, `RetroArch-<v>-anylinux-aarch64.AppImage`
(1.22.2, 35 MB, sharun, GitHub digests), format `appimage-sharun`.

- **D1 Buildbot cores, managed by `retroforge-emu`, Cemu-nightly style.** libretro's core repos tag no
  releases (Genesis Plus GX: none; mupen64plus-libretro-nx: one stale tag; libretro/snes9x: 1.52/1.53),
  and `buildbot.libretro.com/nightly/linux/aarch64/latest/` keeps no history, so a pin would point to a
  file gone the next night. So: no tested pin (`--tested` refused for them, the page shows "Nightly
  <date>"); the build id is the date + CRC32 from `latest/.index-extended`; downloads are https only and
  CRC-checked; the previous `.so` stays on the device for `rollback`. No CI repo of our own: it would
  only add a re-installable tested build and a sha256 known in advance, for three cores that change
  rarely. Revisit if Phase 0 finds a core that will not load, or if a bad nightly ever bites.
  armGBA and RetroArch keep the normal catalog model (latest by default, pin = tested, Revert).
- **D1b RetroArch's Online Updater stays OFF** (user 2026-11-09: players must not install cores for
  other systems). The seed hides it, the core updater and Load Core; the cores folder is ours. A `.so`
  copied in by hand over SMB/SSH can still be loaded from RetroArch's content browser: not offered by
  the UI, not blocked.
- **D2 Mega CD on RetroArch, BIOS required.** Genesis Plus GX needs `bios_CD_U.bin` / `bios_CD_E.bin` /
  `bios_CD_J.bin` in the flat `~/bios` (ClownMDEmu needed none: a regression, accepted). A segacd game
  without the BIOS gets a clear "BIOS missing" message, not a black screen.
- **D3 Hardcore off by default**, a toggle in the plugin. Hardcore blocks state loading, rewind, slow
  motion and cheats, so Guide+L1 would stop working.
- **D4 No 32X now.** PicoDrive would bring it back, with achievements: a follow-up.
- **D5 No new systems now** (NES, SMS, GG, PCE, ...): each is a core + ROM folder + `launch.conf` line
  once this plan is done.
- **D6 armGBA as a core inside RetroArch**, not the standalone app: one frontend, one sign-in, same
  hotkeys and options; armGBA's speed (the reason it replaced mGBA) is kept. armGBA is not on the
  buildbot, so it is a catalog asset.
- **D7 N64 moves too, in its own phase (Phase 6)**, after the pre-PS1 systems are HW-OK. Same mupen64plus
  core and GLideN64 as RMG, so the A610 should cope. If Phase 0/6 measures it slower than RMG on the
  A610, N64 stays on RMG without achievements.

## What we know (2026-11-09)

- Stable buildbot has no linux/aarch64 (`/stable/1.22.2/linux/` = x86, x86_64); nightly has
  `RetroArch.7z` and every core we need in `latest/`.
- The sharun AppImage path is already handled: `launch_formats.py:146` `SharunAppImage` links the
  hardcoded paths, forces the image's Turnip (`SHARUN_ALLOW_SYS_VKICD=1`, `VK_DRIVER_FILES`) and keeps
  the self-updater off (`DISABLE_AUTO_UPDATES=1`).
- armGBA core needs glibc >= 2.34; whatever glibc sharun bundles is what the `dlopen` sees.
- RetroArch 1.22.2 sorts saves by core or content dir, not by our system folder: we rewrite
  `savefile_directory` / `savestate_directory` per game, as armGBA's `system_settings` does today.

## Patterns to mirror

| Category | Source | Pattern |
|---|---|---|
| Launch definition | `rootfs/overlay/usr/share/retroforge/emulators/armgba/emulator.json` | notes[], format, binary, args, gui_args, seed, `system_settings` rewriting folders per game |
| Per-system args | `rootfs/overlay/usr/lib/retroforge/python/launch_def.py:19` | `system_args` = per-system `-L <core>` |
| Sharun AppImage | `rootfs/overlay/usr/lib/retroforge/python/launch_formats.py:146` | no AppRun, hook links, system Vulkan ICD |
| Rolling builds | `rootfs/overlay/usr/bin/retroforge-emu` header (ROLLING TAGS / NO TESTED BUILD) | `<tag>-<id>` naming, `--tested` refused, previous kept for rollback |
| Errors | `retroforge-emu` | exit 0/2/3/4/5/6, progress + JSON on stdout only, the rest on stderr |
| Catalog | `rootfs/overlay/usr/share/retroforge/catalog.json` | github, tag, tag_pattern, asset, sha256, size, licence |
| Account sign-in | `apps/ogui-retroforge-plugin/plugin/scraper_settings.gd:81` | user + secret password rows, password handed to a tool, never kept by the plugin |
| Hotkeys | `emulators/*/guide-hotkeys.yaml` | Guide + L1/R1/R2/Start -> F1-F4, bound in the seeded config |
| Options | `emulators/*/options.json`, `emuopts.py` | common set, per-game .conf |
| Source compliance | `.github/emu-sources.json` | upstream repo + tag -> ref |
| Tests | `tests/test-emu.sh`, `tests/test-launch.sh`, `tests/test-catalog.sh`, `tests/test-emuopts.sh`, `tests/test-key-drift.sh` | shell tests, offline by default, `RETROFORGE_NET_TEST=1` for live |

## Phase 0 — HW spike (no commits but notes here)

On the weakest board (A610/SM6115, Air X) and one SM8250 (Pocket Max), RetroArch AppImage pushed by
hand to `~/emulators/retroarch`, cores by hand:

1. RetroArch runs mounted through `SharunAppImage` on our Turnip under gamescope: pick `vulkan` vs
   `glcore` (and `gl`/GLES for GLideN64), and the audio driver (pipewire vs pulse).
2. All four cores `dlopen` inside the sharun process (buildbot glibc, armGBA's >= 2.34).
3. SIGTERM (OGUI's Exit) = normal exit with SRAM written; no dialog; no `SDL_NO_SIGNAL_HANDLERS`
   needed.
4. The InputPlumber Elite pad is auto-configured (autoconfig, assets, core-info present in the
   AppImage, or what to seed).
5. armGBA core vs armGBA standalone speed on the A610; Mupen64Plus-Next vs RMG on the A610, same games.
6. Sign in, unlock one achievement in softcore and one in hardcore.
7. Walk RetroArch 1.22's menus with D1b settings: list every path that installs a core (Core Manager,
   Restore Backup, ...) and the key that hides it.
8. Genesis Plus GX Mega CD with and without the BIOS: what the player sees.

GATE: 1, 2 or 3 failing stops the plan. 5 failing for N64 drops Phase 6 (D7).

### Phase 0 notes (2026-11-09, Air X MQ66 = A610, dev card 78354ddb, kernel 7.3.3, 192.168.1.100)

Set-up (gone at reboot): bind mounts over `/usr/share/retroforge/emulators` (+ `retroarch/` spike
definition), `/usr/share/retroforge/catalog.json` (+ `retroarch` entry) and `/etc/retroforge/launch.conf`
(gb/gbc/gba/snes/md/segacd/n64 = retroarch); AppImage as `~/emulators/retroarch/<tag>.AppImage`, cores
by hand in `cores/`. `retroforge-emu list` sees it installed = tested.

- Downloads: AppImage and armGBA zip match GitHub's sha256 digests. Buildbot `.index-extended` CRC32 is
  the CRC of the `.so` INSIDE the zip (= the zip member's CRC), not of the zip: Phase 1 checks the
  unpacked core.
- AppImage (DwarFS, uruntime): bundles glibc **2.43**, Mesa 26.2.6 (Arch) for GL/EGL/gbm, SDL2/3,
  PipeWire, Pulse, ALSA. `share/retroarch` holds only `filters`: NO assets (ozone/xmb unusable ->
  `menu_driver = rgui`), NO autoconfig, NO core info, NO database. RetroAchievements compiled in
  (`cheevos_*`, `dorequest.php`). Build's `core_updater_buildbot_cores_url` is empty: its Online
  Updater cannot fetch cores anyway (D1b holds even before hiding it).
- Cores (readelf): armGBA glibc 2.34 (libz, libstdc++); Snes9x 2.33; Genesis Plus GX 2.33;
  Mupen64Plus-Next 2.34 and **libGL.so.1** (desktop GL; no GLES build on the aarch64 buildbot) ->
  N64 needs RetroArch's `gl`/`glcore` driver, on the bundled Mesa GL as RMG does today. Step 2 OK on
  paper (2.43 >= 2.34); real `dlopen` per core still to see with a game.
- Step 1 OK (menu): `video_driver = vulkan` -> "Turnip Adreno (TM) 610" through the launcher's
  `SHARUN_ALLOW_SYS_VKICD`, X11 (Xwayland) fullscreen 1920x1080, 3 swapchain images; `audio_driver =
  pipewire` -> Speaker sink. Harmless noise: GameMode, xdg-screensaver, MIDI /dev/snd/seq.
- Step 4 pad: seeded `autoconfig/sdl2/RetroForge pad.cfg` matched by vid/pid 1118/2816 ("Xbox One
  Elite 2 Controller configured in port 1"). Buttons not yet checked on screen.
- Step 3 OK (menu): ONE SIGTERM to RetroArch (what OGUI's Exit sends; the launcher never forwards) ->
  normal exit in ~800 ms, config + playlists written, launcher returned, mount released.
  `quit_press_twice` does not apply to signals. No `SDL_NO_SIGNAL_HANDLERS` / `exit_resend` needed.
- RetroArch rewrites the cfg on exit (3377 lines) and keeps our keys; it writes paths back as `~/...`.
- Games from OGUI cards (user: "everything seems to work"; history playlist confirms the core per
  system): gba TMNT (armGBA core, .7z), snes Super Mario All-Stars (Snes9x), md Kunio (Genesis Plus
  GX), n64 Super Mario 64 (Mupen64Plus-Next; RetroArch switched to a GL context for it by itself
  with `video_driver = vulkan`). All four cores `dlopen` fine: step 2 OK. SRAM written (gba, snes);
  Guide hotkey save states written (snes, md).
- FOUND: `sort_savefiles_enable` / `sort_savestates_enable` default to true -> saves landed in
  `~/saves/<system>/<core name>/` (`armGBA/`, `Snes9x/`, `Genesis Plus GX/`). Must be "false" in the
  seed AND in `system_settings` (RetroArch writes its in-memory value back on exit). Spike fixed,
  test files moved up.
- Mupen64Plus-Next writes `Mupen64plus/mupen64plus.ini` + `shaders/` into `system_directory`
  (= the flat `~/bios`): ACCEPTED (user 2026-11-09).
- Step 5 OK (user 2026-11-09): N64 speed on the A610 is fine -> D7 holds, Phase 6 stays. More
  emulator-default and per-ROM options later, if needed.
- Save states: no migration, old states may break (user 2026-11-09). SRAM migration stays (Phase 4).
- Still open: step 6 (RetroAchievements: not signed in yet), step 7 (menu walk), step 8 + segacd (no
  disc, no BIOS on the Air X; can move to the Phase 5 card), gb/gbc.

## Phase 1 — catalog and `retroforge-emu`

- `catalog.json`: new `retroarch` entry (pkgforge AppImage, tag_pattern `^[0-9][0-9.]*@...$` as
  Azahar's) with:
  - `cores`: `{"armgba": {github MagnominusGit/armGBA, tag, tag_pattern, asset ^armGBA-[0-9.]+-aarch64\.zip$,
    sha256, size, files: [armgba_libretro.so, armgba_libretro.info]}, "snes9x": {"buildbot":
    "snes9x_libretro.so.zip"}, "genesis_plus_gx": {...}}` (mupen64plus_next added in Phase 6).
  - Only the cores `launch.conf` maps to `retroarch` are listed (D1b).
- `retroforge-emu`:
  - `install retroarch` installs the AppImage, then every core into `~/emulators/retroarch/cores/<core>/<id>/`,
    `current` symlink per core, previous kept (same `activate()` logic).
  - buildbot core: fetch `latest/.index-extended`, take the row, download over https, unzip ONE member
    (`<core>_libretro.so`, `safe_relative`), check CRC32, id = `nightly-<date>-<crc>`.
  - GitHub core: the existing tested/latest path, unzip the named files only.
  - `check` / `list` report each core; `rollback retroarch [--core <c>]`; `remove` removes cores too.
  - Entries no longer in the catalog (armgba, snes9x, clownmdemu, later rmg) are reported as orphaned
    and removable (Phase 4).
- `.github/emu-sources.json`: retroarch (libretro/RetroArch, tag -> v<ver>), armgba core
  (MagnominusGit/armGBA); buildbot cores point at their libretro repos (master).
- Validate: `tests/test-emu.sh` new cases (core install, CRC mismatch -> exit 4 and nothing changed,
  missing index row -> exit 3, per-core rollback, zip with extra/evil members refused),
  `tests/test-catalog.sh` (schema + live with `RETROFORGE_NET_TEST=1`).

## Phase 2 — launch definition and seeds

- `rootfs/overlay/usr/share/retroforge/emulators/retroarch/`:
  - `emulator.json`: format `appimage-sharun`, binary from Phase 0, args
    `-f --config /home/player/.config/retroarch/retroarch.cfg {rom}`; `system_args` per system =
    `-L /home/player/emulators/retroarch/cores/<core>/current/<core>_libretro.so`;
    `system_settings` rewriting `savefile_directory` / `savestate_directory` to `~/saves/{system}` /
    `~/states/{system}`; gui_args = RetroArch's menu.
  - `retroarch.cfg` seed (comments in the notes, RetroArch rewrites the file): drivers from Phase 0;
    `system_directory = ~/bios`; `libretro_directory` / `libretro_info_path` = our cores folder;
    `menu_show_online_updater = false`, `menu_show_core_updater = false`, `menu_show_load_core = false`
    + whatever Phase 0 step 7 found; `cheevos_enable = true`, `cheevos_hardcore_mode_enable = false`;
    `config_save_on_exit` kept on (menu changes stick; our keys are rewritten per game anyway).
  - Hotkeys: `input_load_state = f1`, `input_save_state = f2`, `input_hold_fast_forward = f3`,
    `input_exit_emulator = f4`, `quit_press_twice = true`; `guide-hotkeys.yaml` as the other emulators'.
  - Core options seed (`retroarch-core-options.cfg` or per-core): armGBA's BIOS / boot ROM choices
    carried over from `armgba/frontend.cfg`.
  - `options.json`: the common set mapped to cfg / core-option keys (emulator-options plan).
- Missing BIOS (D2) and missing core: the launcher checks before starting and shows a message.
- `launch.conf`: gb, gbc, gba, snes, md, segacd -> `retroarch`.
- Validate: `tests/test-launch.sh` (core per system, folder rewrite, missing-core/BIOS message),
  `tests/test-emuopts.sh`, `tests/test-key-drift.sh`.

## Phase 3 — RetroAchievements sign-in

- New `/usr/bin/retroforge-cheevos login|logout|status`: password on stdin only; POST
  `https://retroachievements.org/dorequest.php` `r=login2` (https only, `RetroForge/<version>`
  User-Agent, curl like `retroforge-emu`); writes ONLY `cheevos_username` + `cheevos_token` into
  `retroarch.cfg` (0600, atomic replace), never the password; `hardcore on|off`. Exit codes in the
  `retroforge-emu` style; no secret in logs or errors.
- Plugin: Settings > Library > RetroAchievements (user, password, signed-in state, Sign out, Hardcore
  toggle), mirroring `scraper_settings.gd`; plugin version bump.
- Validate: new `tests/test-cheevos.sh` with a local fake server (good login, bad login, token written,
  password never on disk, cfg perms); plugin Godot suite (see the plugin-godot-tests memory).
- Security review of the helper and the plugin rows before commit.

## Phase 4 — removal and migration

- Delete `emulators/{armgba,snes9x,clownmdemu}`, their catalog and emu-sources rows, the ClownMDEmu
  `Save Data` rows in `user-tmpfiles.d/retroforge-home.conf`, `apps/retroforge-sigdefer`,
  `rootfs/lib-assemble-sigdefer.sh`, `tests/test-sigdefer.sh` (re-check nothing else preloads it) and
  their rows in `Makefile`, `rootfs/assemble-rootfs.sh`, `.gitignore`; named cases in
  `launch_def.py`, `launch_formats.py`, `emuopts.py`, `retroforge-launch`, tests,
  `packages/inputplumber/PKGBUILD` (testbed reference).
- Existing devices: orphaned `~/emulators/<old>` removed (plugin row or first RetroArch install).
  armGBA `.srm` saves keep their names; check Snes9x and ClownMDEmu SRAM naming and rename to
  `<rom>.srm` where the bytes match. Save states: no migration, old ones may break (user 2026-11-09).
- Seed + `system_settings`: `sort_savefiles_enable = "false"`, `sort_savestates_enable = "false"`
  (Phase 0: per-core subfolders otherwise).
- Docs: README row 3, `retroforge.plan.md` notes, RUNBOOK.

## Phase 5 — HW validation, merge, push

Dev card (`source dev.env`), A610 + SM8250: a game per system boots; saves land in `~/saves/<system>`;
Guide hotkeys; clean Exit; per-core and RetroArch Revert; sign-in + one achievement; Mega CD with and
without BIOS; no menu path installs a core. Then merge (ff) and push.

## Phase 6 — N64 (D7)

- Catalog: add `mupen64plus_next` (buildbot). Per-core override
  `~/.config/retroarch/config/Mupen64Plus-Next/Mupen64Plus-Next.cfg` with the GL driver from Phase 0
  (unless every core runs on it); core options: GLideN64, never paraLLEl-RDP (A610), RMG's dynarec and
  1x resolution.
- Pad: RetroArch autoconfig + core layout (C buttons on the right stick) replace RMG's seeded Profile 0.
  R2 becomes a real hold fast-forward.
- Saves: RMG's separate `.eep/.sra/.fla/.mpk` (good-name) -> the core's single `<rom>.srm`; convert a
  copy, keep originals in `~/saves/n64/rmg-backup`; if conversion is unreliable, say saves start
  fresh. States do not carry over.
- Remove `emulators/rmg` + catalog/emu-sources rows + named tests.
- `launch.conf`: n64 -> retroarch.
- HW: the Air X games that run on RMG at the same speed, one SM8250/SM8550 game, one achievement,
  clean Exit.

## Risks

| Risk | Level | Mitigation |
|---|---|---|
| Buildbot core will not load in the sharun RetroArch (glibc) | HIGH | Phase 0 step 2; fall back to a CI repo of our own (D1 revisit) |
| Bad buildbot nightly reaches players (no tested pin) | MED | Update is on demand only; per-core rollback keeps the previous `.so` |
| AppImage lacks assets / autoconfig / core-info | MED | Phase 0 step 4; seed or catalog `data` |
| Mega CD now needs a BIOS | MED | D2 message; docs |
| Players lose save states; N64 save conversion | MED | Documented; N64 converts a copy, originals kept |
| A menu path still installs cores (D1b) | LOW | Phase 0 step 7 + Phase 5 check |
| RetroArch writes its cfg on exit, undoing our keys | LOW | Rewritten before every game (armGBA pattern) |
| RetroAchievements token leak / password on disk | MED | Token only, 0600, stdin password, security review |
| Mupen64Plus-Next slower than RMG on A610 | MED | Measured; N64 stays on RMG (D7) |

## Acceptance

- [ ] Phase 0 notes recorded here, gate passed
- [ ] gb/gbc/gba/snes/md/segacd run on RetroArch, HW-OK on A610 + SM8250
- [ ] One achievement unlocked on HW; hardcore toggle works
- [ ] armgba/snes9x/clownmdemu/sigdefer gone; old installs cleaned; saves migrated
- [ ] Offline tests green (`tests/test-emu.sh`, `test-launch.sh`, `test-catalog.sh`, `test-emuopts.sh`,
      `test-key-drift.sh`, `test-cheevos.sh`, plugin suite)
- [ ] Phase 6 done or dropped by the D7 rule
