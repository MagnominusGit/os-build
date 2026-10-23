# Plan: ARMv8.0 Proton, and a Steam settings page

**Complexity**: High. **Branches**: a new public build repo (name TBD) for Proton; os-build branches cut from
`main` at `99495d6` (clientless Steam launch). **Status**: planned 2026-10-22; Phase 0 next. Done in order,
in one session.

## Summary

On ARMv8.0 SoCs (SM6115: Cortex-A73/A53, no LSE atomics) Valve's Proton ARM64 runs only because kernel
patch 0025 emulates LSE. Measured on the MANGMI Air X (2026-10-22):

- An emulated atomic costs 276 ns on the A73 and 487 ns on the A53, against ~11 ns for an LL/SC loop.
- While Hades loaded, emulations peaked at 3.36M/s, about 1–1.5 cores of pure overhead.
- ~94% came from Proton's `aarch64-windows/ntdll.dll`: RtlEnter/LeaveCriticalSection, RtlAllocateHeap and
  heap_free_block_lfh.
- LSE instructions in `ntdll.dll`: Valve 11.0-2e 245, Experimental 244, Proton-CachyOS 252. CachyOS's
  DXVK-Sarek `d3d11.dll` has 6,048.
- FEX's generated code caused none. FEX's own DLL (`libarm64ecfex.dll`) caused 1.3M.

The fix is Proton built with `-march=armv8-a`, which Azkali/proton-arm64-a57 proved on the Cortex-A57. We build
it in CI from Valve's source, with DXVK-Sarek built in, on a stable and an experimental channel. Devices without
LSE download it on demand. A Steam settings page in OGUI gathers the Steam options and adds per-game
compatibility overrides.

## Decisions

| | Decision |
|---|---|
| D1 | **Valve's source is the base**, not CachyOS's or Azkali's builds. The repo is a small public build repo of our own: a patch series applied to Valve's tags, not a full Proton fork. |
| D2 | **DXVK-Sarek is built in** (ported from CachyOS: `extras/build-dxvk-sarek.mk` and the `proton` script's `dxvksarek` switch, i.e. `PROTON_DXVK_SAREK=1`). It needs an ARMv8.0 build anyway and is 39 MB. It replaces the Proton-CachyOS download on these devices. |
| D3 | **Stable** builds each Valve `proton-11.0-*` tag. **Experimental** builds each Valve `experimental-11.0-*` tag, not a branch-head nightly. |
| D4 | **Release gates:** the patches apply, the build passes, and the LSE scan finds no inline LSE/RCpc outside outline-atomics helpers. When a patch stops applying, an agent (Claude Code GitHub Action) opens a refresh PR; a human merges it. Nothing an agent changed is released unreviewed. |
| D5 | **CI** runs on GitHub's `ubuntu-24.04-arm`, modelled on CachyOS's `_job_build.yml` (free disk space, ccache, `make redist`, ~3 h). The repo is public, so runner time and release storage are free. |
| D6 | **Offered when `/proc/cpuinfo` lacks `atomics`**, not by a SoC list, so future ARMv8.0 boards are covered. Downloaded on demand. The image carries only the pins. |
| D7 | **Per-game choices are RetroForge's own** (`~/.config/retroforge/`, keyed by app id) and are applied by the clientless launcher. Launches through the Steam client keep Steam's own CompatToolMapping. Editing `config.vdf` stays off the table unless the user decides otherwise. |
| D8 | **Steam sign-in** goes through Steam's own screen only. RetroForge never collects credentials. Making it seamless is the last phase (TODO). |
| D9 | **Build repo**: `sunshineinabox/proton-armv8`, public (user, 2026-10-22). |
| D10 | **zram**: `zram-size = min(ram, 8192)`, with no toggle. zram is RAM-only and never writes to the SD card. zswap is rejected: it writes cold pages back to a disk swap device (here the SD card), and the kernel has `CONFIG_ZSWAP` off. |
| D11 | **The patch-refresh agent is open**: Claude Code Action, or GitHub's own (Copilot/GitHub Models), decided later. Until then a failing patch opens an issue. |

## Tasks

### Phase 0: FEX question (before any build work)
FEX inside Proton (`libarm64ecfex.dll` 5.0 MB, `libwow64fex.dll` 4.5 MB) is built by Proton's build, so D1's
patch covers it. FEX upstream supports ARMv8.0 hosts ("ARMv8.0-a or newer, FEAT_FP and FEAT_CRC32"), but its
`TUNE_CPU` defaults to `native`, so a binary built on an LSE machine can still be full of LSE.
- [x] Valve's FEX tool (app 3127680, installdir `FEX-Emu`, build 24136555, `FEX-2607-76-g37265b1`, 25 MB) installed
  on the Air X with no user input: an app manifest with `StateFlags 1026`, then Steam started in the background
  through `/usr/bin/steam -steamdeck` and stopped with `steam -shutdown`.
- [x] LSE scan of its arm64 binaries (inline LSE, i.e. outside runtime-checked helpers): `usr/bin/FEX` 244,
  `FEXOfflineCompiler` 139, `FEXGetConfig` 4, `FEXServer` 1. `FEXCompatTool`, `FEXServerManager`, the host thunks:
  0. So Valve builds it for ARMv8.1+, like Proton.
- [x] How Steam uses it: a compat *layer* (`toolmanifest.vdf` `compatmanager_layer_name "fex"`; `emulator.json`
  gives pressure-vessel `./usr/bin/FEX` for x86_64/i386 programs). It is not selectable per game like a Proton build.
- [x] Decision: the build repo also builds FEX at Valve's tool commit with `-march=armv8-a` (only `FEX`,
  `FEXServer`, `FEXOfflineCompiler`, `FEXGetConfig`; a CMake build of minutes). Delivery is decided in Phase 2 by
  testing: swap those four into Steam's `FEX-Emu` while its version matches ours, or a local layer, if Steam takes one.
- [ ] Optional: run-time cost via `lse-where` during a native x86 Linux game (needs one installed). FEX's
  translated code itself emits no LSE.

### Phase 1: build repo
- [x] Repo `sunshineinabox/proton-armv8`, public, created 2026-10-22 (`main` 1fddf23). Local checkout:
  `~/Documents/GitHub/proton-armv8`; patch work tree: `~/Documents/GitHub/proton-armv8-work/proton` (branch `armv8`).
- [x] `patches/0001-armv8.0.patch`: `aarch64_CFLAGS`/`arm64ec_CFLAGS` to `-march=armv8-a`, FEX `-DTUNE_CPU=generic`.
- [x] `patches/0002-dxvk-sarek.patch`: CachyOS's `extras/build-dxvk-sarek.mk`, its include after dxvk's rules, and
  in `proton`: `use_dxvk_sarek` in the prefix config string, the copy from `wine/dxvk-sarek`, `PROTON_DXVK_SAREK`,
  and Sarek's thread counts. Sarek pinned in `sarek.pin` (pythonlover02/DXVK-Sarek v1.14.1, 0c0e8f6).
- [x] `scripts/scan-lse.py` (helper vs inline; checked: Proton `ntdll.dll` 245 inline), and `scripts/build.sh`.
- [x] Both patches apply to `proton-11.0-2e` and `experimental-11.0-20261014` with `git am -C0`; experimental moved
  FEX's CMake args into `FEX_COMMON_CMAKE_ARGS`.
- [x] `.github/workflows/sync.yml`: daily, plus manual dispatch. Newest stable (no beta/rc) and experimental tag;
  build on `ubuntu-24.04-arm`; release `armv8-<tag>` (experimental = pre-release); an issue on failure. Agent: D11.
- [x] First CI runs: stable 74 min, experimental needed the Xalia exception (scan-allow.txt).
- [ ] FEX job: build `FEX`, `FEXServer`, `FEXOfflineCompiler`, `FEXGetConfig` at Valve's tool commit (37265b1) for ARMv8.0.
- [ ] LICENSE for the repo (the user's choice).

### Phase 2: hardware check (Air X)
- [x] Installed `armv8-proton-11.0-2e` with the branch's `steam-compat-tools` on the Air X (2026-10-22): 412 MB
  download, 215 s, 2.0 GB; named and Sarek on as designed.
- [x] The arm64 client takes it: compat_log.txt has `Command prefix for tool 0 "Proton ARMv8.0 (RetroForge)"`.
- [x] Hades without the client through it (`~/.cache/rf-test/rf-tool-launch.py`): menu reached. Emulations peaked at
  ~1,000/s (was 3.36M/s), ~2k in total for Hades.exe, none from `ntdll.dll`; the rest is Valve's `steamclient.so`.
- [x] Experimental: rebuilt with Xalia allowed (`scan-allow.txt`), released as `armv8-experimental-11.0-20261014`.
- [x] `PROTON_DXVK_SAREK=1` selects Sarek: Hades on DirectX 11 reached its first room through Sarek, without an OOM.
- [x] Works with the clientless launch (`retroforge-steam-direct`), which swaps in the tool Steam is set to now (437e6d5).
- [x] FEX delivery test (a), 2026-10-23: SuperTux (app 1572920, free, x86_64 Linux AppImage) on the Air X. Our
  build of Valve's commit (debian:trixie arm64, clang 19 as Valve's, `BUILD_STEAM_SUPPORT=TRUE`, LTO,
  `TUNE_CPU=none`, `TUNE_ARCH=armv8-a`; same `FEX-2607-76-g37265b1`) swapped into `FEX-Emu/usr/bin`: Steam ran it.
  Inline LSE: Valve's seven binaries 388, ours 0 (4 in `FEXGetConfig`'s `--test-fault-granularity` asm probe).
  Kernel LSE emulations at SuperTux's menu: Valve's FEX ~3,000/s from the game (7,528/s in all, the rest the
  client), ours 0/s (4,415/s in all).
  How SuperTux got there: the arm64 client maps an x86 Linux game that also has a Windows build to Proton
  (non-user mapping, priority 85), so its compat tool has to be forced to `fex` (Valve's tool, shown as "fex").
  The AppImage needs FUSE, which the image lacks: `APPIMAGE_EXTRACT_AND_RUN=1 %command%`. Its controller needs
  Steam Input off: OGUI tags windows of games started inside the client with the client's app id
  (`running_app.gd` `_ensure_app_id`), so Steam Input never routes to them (separate session).
- [x] FEX delivery (b), the user's choice, works (2026-10-23): `compatibilitytools.d/fex-armv8-retroforge` with
  `compatibilitytool.vdf` ("FEX ARMv8.0 (RetroForge)", linux to linux), Valve's tool files and our eight binaries
  (FEXCompatTool too, 0 inline LSE). After a restart Steam listed it, SuperTux's compat tool was set to it, and Steam
  ran `fex-armv8-retroforge/fex-compat-tool`; FEX, FEXServer and the game ran from it, 0 emulations from the game.
  It is a per-game choice: the x86 Steam Linux Runtimes' automatic FEX dependency stays Valve's app 3127680.
  Licences: FEX (binaries, `Source/Steam/{toolmanifest.vdf,emulator.json,ConfigTemplate.json,CompatTool.cpp}`) is
  MIT; `fex-compat-tool` and `unshare.py` are Valve's and not in FEX's repo, so the device copies those two from
  the installed `FEX-Emu` rather than our releases carrying them.
- [ ] Ship it: a FEX job in proton-armv8 building Valve's tool commit (`VERSIONS.txt` "FEX bash") for ARMv8.0,
  released with FEX's Steam files and checksummed; on ARMv8.0 devices, assemble the tool from that release plus
  Valve's two scripts once Steam has installed `FEX-Emu`. Open: whether to also swap our binaries into Valve's tool
  so x86 games that never get a per-game choice use them too.

### Phase 3: device import (branch `steam-armv8-proton` from `main` 99495d6; not pushed)
- [x] `steam-compat-tools`: with no `atomics` in /proc/cpuinfo it takes `proton-armv8.pin`; `.tar.zst`, `sidecar:` and
  `prereleases:` pin fields; Sarek off in every RetroForge folder. Committed as 4138332.
- [x] zram (D10): `min(ram, 8192)`. Committed as 3129ec3.
- [x] Tests: 10 new cases. In a Linux container: compat-tools 121/0, steam 99/0, steam-direct 72/0, x86-guest 110/0.
  On macOS, 12 cases fail with or without these changes (no /proc, no setsid).
- [ ] The Proton-CachyOS folder already on ARMv8.0 devices (2.2 GB) stays. Remove it? (user's call)

### Phase 4: OGUI Steam settings page (same branch, or the next one)
- [x] Settings > Steam (`steam_settings.gd`), after General; the three Steam toggles moved there (6ecae33). Seen on the Air X.
- [x] Proton row (`steam_proton.gd`), only on ARMv8.0 CPUs: stable or experimental. `retroforge-steam-proton` makes it
  Steam's default (`CompatToolMapping` "0" in config.vdf, written while the client is closed; 15dc8a3). The user decided
  2026-10-22: default on ARMv8.0-only devices, nothing elsewhere, other options hidden there.
- [x] Per-game overrides in Game settings > RetroForge, for games started without the client: Proton build, Sarek
  (D7), launch option with its own arguments (as Steam's dialog offers them on a Deck), and resolution (Steam's Game
  resolution, else Settings > Display; put back when the game ends). a77b560, 1f7e09b, daecd3d, 4c0d867; all seen on
  the Air X with Hades (2026-10-23). Turnip and FEX settings once Phase 4b answers how.
- [x] 4b answered on the Air X (2026-10-23):
  - Turnip: yes. SLR4's pressure-vessel (0.20261007) takes `VK_DRIVER_FILES` (also `VK_ICD_FILENAMES`,
    `VK_ADD_DRIVER_FILES`), rewrites the ICD into its overrides and leaves `library_path` in `/home`, which the
    container shares. `vulkaninfo` in the runtime used "Turnip Adreno (TM) 610" from the `/home` copy. The driver's
    own libraries come from the runtime, so a variant has to be built against what steamrt4 ships.
  - x86 Turnip: not needed for Proton games. Proton ARM64 runs x86 Windows code through FEX inside Wine
    (`libarm64ecfex`, `libwow64fex`, `xtajit64`), and winevulkan calls the arm64 Turnip. Only native x86 Linux
    games under Steam's FEX layer use the x86 Mesa guest, as now.
  - FEX: Proton writes `proton-fex-config.json` per game from `STEAM_FEX_TSOENABLED`, `STEAM_FEX_MULTIBLOCK`, or
    `STEAM_COMPAT_FEX_CONFIG` ("TSOEnabled:1,Multiblock:1", which sets both), plus its own profiles table
    (X87ReducedPrecision for The Witcher 3). Its defaults (`files/share/fex-emu/Config.json`): TSOEnabled 1,
    HalfBarrierTSOEnabled 1, VectorTSOEnabled 0, MemcpySetTSOEnabled 0, Multiblock 1, X87ReducedPrecision 1,
    MaxInst 500. The arm64 client sets `STEAM_COMPAT_FEX_CONFIG` empty at every launch (compat_log.txt) and no
    `STEAM_FEX_*`, so a clientless launch loses nothing. Appinfo has Valve's `common/steam_frame_compatibility/
    configuration/tso_enable` (Hades: 0), apparently for the Steam Frame only. Worth exposing: TSO (the big cost
    on ARMv8.0 cores, with Valve's hint as a label), maybe Multiblock.
- [x] Per-game FEX TSO row (`STEAM_FEX_TSOENABLED`, 424d7e4). Hades on the Air X, standing in the House of Hades
  hub, 30 s each (2026-10-23): TSO off 237% of one core (threads 98/48/29%, system 39% of 8 cores); TSO on 262%
  (97/51/41%, system 44%). The main thread is maxed either way, so off saves about a tenth of the CPU, mostly on
  the worker threads.
- [ ] Per-game Turnip (`VK_DRIVER_FILES`): later, by the user's call (2026-10-23); only the image's Turnip for now.
- [x] Tests (`tests/test-plugin.sh`, `test-steam-direct.sh`, `test-steam-proton.sh`), docs (`docs/steam-arm64.md`).

### Later (TODO)
- [ ] Steam page: an "Open Steam (Remote Play)" button, as Emulators > Steam Client > Open, and a read-only video decode
  line (hardware: venus on SM6115, Iris on SM8250/8550/8650; else software). Steam's own Remote Play settings keep the
  hardware-decoding switch.
- [ ] Remote Play on hardware: a stream from a PC, "V4L2 ... hardware decoding" in the client's log, no stall after
  the first frame, the stream window focused under OGUI.

### Phase 5 (TODO, last): seamless Steam login
- [ ] Discuss first. Ideas: a "Sign in to Steam" button that opens Steam's own sign-in; check QR sign-in in Big Picture on the arm64 client; keep the session on /home; a cloud sync around clientless sessions.

## Validation
- The LSE scan passes on every release. On the Air X, Hades shows about 0 kernel LSE emulations with the new tool.
- The os-build suites pass (`test-steam*`, `test-plugin`, `test-steam-compat-tools`).
- Hades plays on the Air X through the Steam page's choices.

## Risks
- **A cold CI build may not fit a hosted runner's 6 h limit or its disk.** Fallback: a self-hosted runner in an arm64 Linux VM (OrbStack on the user's Mac).
- **Valve's FEX tool may need its own build, and Steam may not accept a replacement** (Phase 0 answers both).
- **Sarek's port may conflict** with Valve changes on each new tag. The patch-refresh PRs cover this.
- **Our builds use LL/SC everywhere on the PE side.** That is why they are offered only under D6.

## Acceptance
- [x] Stable and experimental ARMv8.0 releases are published by CI from Valve tags.
- [x] ARMv8.0 devices download our build instead of Proton-CachyOS; other devices are unchanged.
- [x] The Steam settings page ships with the per-game Proton and Sarek choices (on this branch, not yet merged).
- [ ] Phase 5 is discussed and scheduled.
