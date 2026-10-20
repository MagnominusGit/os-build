# N64 via gopher64 — plan

Status: AGREED 2026-10-20 (user: "confirm, start phase 1"). Phase 1 DONE 2026-10-20 (not
committed): retroforge-launch `binary` format (Binary class, FORMATS, header doc) + test-launch.sh
"plain binary (gopher64)" case (suite 381/0; test-catalog/emuopts/plugin/session green).
python-reviewer: approved; its MEDIUM (a binary definition naming a file other than `current`
would pass the not-installed check and then fail to start) fixed — load_definition now requires
binary == "current" for the format, with a negative test.
Phase 2 DONE 2026-10-20 (not committed): catalog gopher64 entry (v1.1.42 pin, GPL-3.0, digest
verified live), launch.conf n64=gopher64, emulators/gopher64/emulator.json (binary format,
--fullscreen {rom}, SDL_NO_SIGNAL_HANDLERS=1) + options.json (Widescreen on-only — --widescreen is
a flag, unset is the off; Overclock on/off via --overclock true/false), tmpfiles n64 rows +
~/.local/share/gopher64/{saves,states} links. Suites: launch 385, catalog 204, emuopts 596, emu
142, plugin 77, scrape 113, shares 29, session 75 — all 0 failed.
Phase 3 DONE 2026-10-20 (not committed): library_roms.gd SYSTEMS "n64" (Nintendo 64, z64/n64/v64/
zip/7z, after snes), scraper systems.json n64 ss [14] (verified live against systemesListe.php
2026-10-20; 64DD is its own system, 122, not shipped), plugin 0.1.60. Suites: plugin 77,
scrape 113, plugin-install 14, ui 301, launch 385, catalog 204 — all 0 failed.
Phase 4 checked 2026-10-20: NO-OP — no doc lists systems or per-system emulators (README's phase
table is the generic roadmap; the data files and emulator.json notes are the documentation).
Phase 5 HW on the Pocket ACE 2026-10-20: game boots (aarch64 dynarec + wgpu-on-Turnip OK), but NO
CONTROLS on a fresh config — gopher64 never auto-binds a pad (controller_assignment defaults to
None; init() only opens an assigned one; hotplug only rebinds a known GUID) and the assignment it
stores is the pad's /dev/input/eventN path, which no board or boot guarantees. Fix: new generic
launcher key `setup_args` (the emulator's own binary, run and waited for before EVERY start, game
and --gui; failure = warning, 20 s cap, {rom}/{file}/{system} refused) — gopher64 runs
`--assign-controller 1 --port 1`, rewriting the assignment to this boot's path of the one SDL
joystick a session shows (InputPlumber's virtual pad). HW-OK on the ACE from a wiped config via
bind-mounted launcher+definition. test-launch 393/0. Remaining: SM6115 board check (A610 + wgpu),
tested there = pin stays; and the melonDS-style dual-screen question never applies (one screen).

## Why

RetroForge ships no N64 emulator since ares was dropped (63cc4ff). Research (2026-10-19/20, memory
n64-gopher64-plan): no aarch64 N64 AppImage exists anywhere (RMG x86_64-only, simple64
Windows-only, pkgforge-dev has no N64 repo). **gopher64** is the candidate: GitHub
`gopher64/gopher64`, release asset `gopher64-linux-aarch64` — a dynamically linked PIE needing only
libc/libm/libgcc_s/libstdc++/libfontconfig (all in the Arch rootfs); SDL3 + wgpu compiled in,
Vulkan through the loader (our Turnip); has an aarch64 dynarec (ships Android builds).

## Facts checked against v1.1.42 source (2026-10-20)

- CLI (clap): `gopher64 [GAME]`, `-f/--fullscreen`, `--widescreen`, `--overclock <bool>`,
  `--disable-expansion-pak <bool>`, `--load-state <0-9>`; no args = its own GUI window.
- ROMs: `n64, v64, z64, bin` (either case), plus `zip`/`7z` holding one of those.
- Dirs (XDG, no flags to move them): config `~/.config/gopher64`, data
  `~/.local/share/gopher64/{saves,states}`, cache `~/.cache/gopher64`. Portable mode exists
  (`portable.txt` beside the exe) — not used: the exe lives in `/home/player/emulators/gopher64/`,
  which retroforge-emu owns.
- Config file is **JSON** (`~/.config/gopher64/config.json`) — emuopts has no JSON patcher
  (ini/toml/yaml/xml only), so file-based options are out of reach for now (D3).
- Tested pin: tag `v1.1.42` (published 2026-10-15), asset `gopher64-linux-aarch64`,
  size 60297392, sha256 `1232b3a20bb8b742547c355970e815dd5123d05df3ead3db95fbea45000ff502`
  (GitHub's per-asset digest). Tags are `v<major>.<minor>.<patch>`, one release per version, no
  rolling tags: `tag_pattern` `^v[0-9]+\.[0-9]+\.[0-9]+$` follows latest per the emulator-latest
  plan.

## Decisions

- **D1 — new launcher format `binary`**: retroforge-emu already saves any matched asset as
  `<tag>.AppImage`, chmod +x (file name only; nothing checks it is an AppImage). retroforge-launch
  needs a format that runs the download in place, no mount: class `Binary` (prepare -> the
  emulator's folder, i.e. dirname of `current`; env {}; release no-op; runs_rom False).
  emulator.json: `{"format": "binary", "binary": "current", ...}`. A definition that needs code is
  a format, never shell — this is one small format class.
- **D2 — saves/states in the shared layout** via user-tmpfiles (the ClownMDEmu/PPSSPP pattern):
  `d %h/.local/share/gopher64` then `L` links `saves -> %h/saves/n64`, `states -> %h/states/n64`.
  gopher64's `create_dir_all(data_dir/saves)` follows an existing symlink, and tmpfiles runs at
  login, before any first run. No BIOS: the N64 needs none (the bios/n64 row still ships, the
  layout is per system).
- **D3 — options.json, args-only to start**: Widescreen (off/on -> `--widescreen`) and CPU
  overclock (off/on -> `--overclock true/false`). Upscaling/CRT shader live in config.json: either
  teach emuopts JSON later or leave them to gopher64's own GUI (Open). Not in this plan's scope.
- **D4 — library systems entry**: `"n64": {"name": "Nintendo 64", "exts": ["z64", "n64", "v64",
  "zip", "7z"]}` (skip `bin`: too generic for a library listing; gopher64 would still run one by
  hand). Tab order: by maker then age -> between "3ds" and "gc"? No — N64 (1996) sits after SNES,
  before NDS: insert after "snes". Scraper systems.json gains `n64` (ScreenScraper systemeid 14,
  verify against systemesListe.php as the file's header demands), same exts; test-scrape.sh
  compares the two.
- **D5 — SDL3 signal handling**: like melonDS/Azahar, set `SDL_NO_SIGNAL_HANDLERS=1` in the
  definition's env so OGUI's Exit (SIGTERM) ends it instead of SDL swallowing it. Verify on HW; add
  `exit_resend` only if HW says SIGTERM still does not end it.
- **D6 — no seed**: defaults are fine (fullscreen comes from args, pad mapping is gopher64's own
  Xbox-style default against InputPlumber's virtual pad). A seed appears only if HW shows a needed
  first-run setting.

## Phases

1. **Launcher format** — retroforge-launch: `Binary` class + `FORMATS["binary"]`; header doc
   block gains the format. tests/test-launch.sh: definition-validation and launch cases for the
   new format (no mount expected, binary = `current`, not-installed path).
2. **Integration data** —
   - catalog.json: `gopher64` entry (github `gopher64/gopher64`, tag `v1.1.42` + sha256 + size
     above, `tag_pattern` `^v[0-9]+\.[0-9]+\.[0-9]+$`, asset `^gopher64-linux-aarch64$`, systems
     `["n64"]`, homepage https://github.com/gopher64/gopher64, licence GPL-3.0).
   - launch.conf: `n64=gopher64`.
   - emulators/gopher64/emulator.json: format binary, binary `current`, args
     `["--fullscreen", "{rom}"]`, gui_args `[]`, env `{"SDL_NO_SIGNAL_HANDLERS": "1"}`, notes.
   - emulators/gopher64/options.json: D3's two options.
   - user-tmpfiles retroforge-home.conf: roms/bios/saves/states n64 rows + D2 links.
   - tests: test-catalog.sh and test-launch.sh cross-checks pass as data (they derive from the
     files); test-emuopts/test-ui if they enumerate emulators.
3. **Plugin** — library_roms.gd SYSTEMS n64 (D4), scraper/systems.json n64 (ss 14); plugin version
   bump; test-scrape.sh parity, test-plugin.sh.
4. **Docs** — README/RUNBOOK emulator tables if they list systems (check at implementation).
5. **HW gate** (the real risk, untestable offline): on ACE (SM8550) and one small board (SM6115):
   boot a game (dynarec), wgpu-on-Turnip stability, performance, Exit via OGUI (D5), pad mapping,
   saves landing in ~/saves/n64, `--gui` Open, Widescreen/Overclock options, install/update/
   rollback through Main menu > Emulators.

## Risks

- wgpu (not a hand-written Vulkan backend) on Turnip: untested combination on our boards; the HW
  gate decides. If it fails, there is no fallback N64 emulator — the catalog entry simply does not
  ship (revert phases 2-3; phase 1's format is generic and stays).
- gopher64's parallel-RSP/JIT on big.LITTLE: CPUS=big default pinning applies as to every emulator.
- GitHub digest present on the pinned asset: verified 2026-10-20 (retroforge-emu requires it for
  newest-build installs).
