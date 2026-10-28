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
- [x] Ship it, both ways on ARMv8.0 devices only (the user's choice, 2026-10-23):
  - proton-armv8 `e47fa65` (local, not pushed): `fex.pin` (Valve's commit and version, bumped by hand: the
    tool's depots are owners-only, anonymous steamcmd gets "Missing configuration"), `scripts/build-fex.sh`
    (everything in a Debian 13 arm64 container; FEX's own install lays the tool out as Valve ships it),
    `scan-allow-fex.txt`, `.github/workflows/fex.yml` (release `fex-armv8-<describe>`, not "latest"). Built
    here: 1.4 MB, scan 0.
  - os-build `3b9783e`: steam-compat-tools pins get `entry:` (the file a tool is checked by; own lock and
    waiting folder, no Sarek); `fex-armv8.pin`; `retroforge-steam-fex` apply/install/status, run by
    `/usr/bin/steam`; tests (fex 19, compat-tools 128).
- [x] On the Air X from the real release (2026-10-23): proton-armv8 pushed, the FEX workflow released
  `fex-armv8-FEX-2607-76-g37265b1` in ~5 min (1.4 MB, not "latest"). The branch's `install`: downloaded and
  checked it, installed it in 3 s, took Valve's two scripts in, and swapped 6 binaries into Valve's tool
  (`FEXBash` and `FEXpidof` were already byte-identical: Valve builds with the same Debian clang 19.1.7);
  `status` went valve -> ours. SuperTux ran from it, 0 emulations from the game (4,451/s in all, the client).
  Steam's game properties show "Warning: FEX ARMv8.0 (RetroForge) is incompatible with this application"
  (`is_incompatible`, the client's own rule; the tool declares linux to linux like Valve's SLR 3.0), and the game
  runs regardless.

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

### Detour: compression speed (2026-10-23)
- [x] zlib-ng as the system zlib (0f63372): `zlib-ng-compat 2.3.3-1` from the pinned holo snapshot replaces
  `core/zlib 1.3.2` (relock diff: that line, plus OGUI's new hash for patch 0025, a539c17). Valve's build on the
  Air X, 32 MB of libraries: inflate 1.4-1.5x, deflate 2x, crc32 6-10x, adler32 2-6x; no LSE; level-1 output
  ~25% bigger. Helps what uses the system libz (our Python tools, OGUI, PortMaster ports), not emulators or
  Steam's runtime (their own zlib). Native-mode zlib-ng (`libz-ng.so.2`): nothing in the image uses it.
- [x] zram (a142e98): lz4 for what is swapped out, zstd level 1 for what then sits idle
  (`compression-algorithm = lz4 zstd(level=1)`, CONFIG_ZRAM_BACKEND_LZ4 + CONFIG_ZRAM_MULTI_COMP, asserted by
  kernel/build.sh; `retroforge-zram-recompress.timer` every 10 min at idle priority). Measured with real swapped
  pages: zstd level 1 = level 3's ratio (1.78 vs 1.79) at +26% compression speed; lz4 compresses 3.3x and
  decompresses 4.5-5x faster than zstd at a 1.59 ratio.
- [x] On the Air X with dev build 31 (20261023T070207Z): `comp_algorithm` [lz4], `recomp_algorithm` #1 [zstd],
  the timer every 10 min; `libz.so.1` -> `libz.so.1.3.1.zlib-ng`.
  In kernel, 256 MB of real swapped pages (Steam + SuperTux), warm cores: lz4 271/174 MB/s compress and
  928/533 decompress (A73/A53) at 1.87; zstd 1 84/49 and 313/179 at 2.22 (lz4 3-3.5x faster, 19% more
  memory). A scratch device, lz4 then everything idle recompressed to zstd 1: 3.1 s for 256 MB (87 MB/s),
  ratio 1.90 -> 2.26. Live zram0, the timer's second run (07:33, Steam and SuperTux in memory): compressed
  629 -> 531 MB, memory used 640 -> 587 MB, ratio 2.21 -> 2.61, 19 s of CPU at idle priority.
- [x] Hades on build 31: the kernel OOM-killed it 74 s in (07:42, anon 146 MB, 1.28 GB swapped). Loading swaps
  out in one burst with nothing idle yet, so lz4's ~19% more RAM ran out before recompression could help;
  earlyoom never fired (its swap-free condition: zram looked half empty). With an /etc override to
  `zstd(level=1)` alone, the same load got through (07:46-07:50, quit from OGUI): available memory touched 0 MB
  at +92 s, zram 1.72 GB in 955 MB afterwards. Fixed in d9439a0: zstd level 1 alone, the timer and script
  removed, lz4 and MULTI_COMP left in the kernel unused. The Air X keeps the override
  (`/etc/systemd/zram-generator.conf`) until an image with d9439a0 is installed; remove it then.

### Later (TODO)
- [ ] Steam page: an "Open Steam (Remote Play)" button, as Emulators > Steam Client > Open, and a read-only video decode
  line (hardware: venus on SM6115, Iris on SM8250/8550/8650; else software). Steam's own Remote Play settings keep the
  hardware-decoding switch.
- [ ] Remote Play on hardware: a stream from a PC, "V4L2 ... hardware decoding" in the client's log, no stall after
  the first frame, the stream window focused under OGUI.

### Phase 5 (TODO, last): seamless Steam login
- [ ] Discuss first. Ideas: a "Sign in to Steam" button that opens Steam's own sign-in; keep the session on /home; a cloud sync around clientless sessions.
- [x] QR sign-in on the arm64 client (Air X, 2026-10-24): Steam's own sign-in screen shows a QR code
  (BeginAuthSessionViaQR in steamui/sp.js). Signed out in Steam, scanned with the Steam Mobile App,
  logged on 'OK' with RememberPassword 1. The saved session already lasts: Steam logged on with no
  prompt after an OTA update and reboots, on the same /etc/machine-id since first boot.
- Direction (discussed 2026-10-24): RetroForge only opens Steam's sign-in and reads loginusers.vdf for
  the state ("Signed in as ..."); it never reads or copies Steam's session files, and takes no password.

### Phase 6: Steam Cloud and achievements on low-RAM boards (2026-10-24)
Keep Cloud saves and achievements on the 3.5 GB boards (Air X) without losing what the clientless launch
saves. Test tools: `~player/.cache/rf-lite/rf-lite.sh` on the Air X (one command per step).
- [x] Hades uses Auto-Cloud (`root="WinMyDocuments" path="Saved Games/Hades" pattern="Profile*.sav"`). The
  client syncs it around its own launches only: `Starting sync (AC Launch,down,)` before the game,
  `(up,AC Exit,)` after it (cloud_log.txt). Valve's docs say both mechanisms sync "before and after every
  session" and say nothing about games started outside the client.
- [x] SteamCMD (arm64, 1792617903) has no cloud command: `find cloud` lists only convars. Its
  `app_run`/`app_launch` take Steam's launch path. Its first sign-in takes a password and Steam Guard, later
  ones the cached credentials (`+@NoPromptForPassword 1`: "FAILED (No cached credentials ...)", exit 5;
  `logout`/`logoff` revoke them). A game cannot use it as its client: with SteamCMD signed in, a
  Steamworks connection (`CreateSteamPipe`) finds none. Its data folder is whatever `~/.steam/steam` names
  (on a device, the client's): it wrote `config/config.vdf`, `logs/` and `appcache/` there, and keeps its
  binaries in its own folder. 66-67 MiB RSS signed in.
- [x] Earlier run (06:59, the client launching Hades with `-nofriendsui`, web helpers SIGSTOPped and paged
  out 15 s after Hades.exe started): the helpers went from 917 to 31 MiB of RAM, but kept 892 MiB in zram
  and 252 MiB of GPU buffers, and earlyoom killed Hades 40 s in (available 112 MiB, swap free 535). Capping
  or reclaiming the helpers is not enough: their GPU memory cannot be swapped.
- [x] E0, the client idle in the background (`-steamdeck -silent -nofriendsui`, user unit
  `retroforge-steam`), RAM+swap in use (MiB): no client 2040; signed in after 20 s; idle 3180-3308. Core:
  135-170 PSS + 21-24 swap + 28 GPU. Web helpers (8 processes): 710-1100 PSS + up to 300 swap + 12-32 GPU.
  Without `-gamepadui` the helpers are as big, with less GPU.
- [x] Killing the web helpers does not stick: the client starts them again at once (14 times in 120 s, no
  limit seen) and stays signed in.
- [x] Freezing them does: kill the helper, then SIGSTOP the one the client starts 0.3 s later (7 MB RSS;
  0.2 s of CPU to catch it). The client waited 6 min without starting another or logging anything, and
  stayed signed in. RAM+swap in use 2265-2307: the client then costs ~240 MiB (core 176-192 RSS, 23 swap,
  28 GPU). SIGCONT brings its UI back (8 processes).
- [x] A process the client did not start can use it (2026-10-25, the frozen-helper client): a Steamworks
  probe as app 480 (ctypes on `linuxarm64/steamclient.so`, SDK 1.65 layouts) connected, signed in, cloud on
  (4 KB quota), stats received. `SetAchievement` + `StoreStats` came back stored (EResult 1); cleared after.
  The client logged `Game process added : AppID 480 ""`, tracked it, and on its exit ran
  `Starting sync (up,AC Exit,)`: the file written with `ISteamRemoteStorage::FileWrite` was uploaded
  (`Upload OK`). On connect it ran only an `init` sync, no `AC Launch,down`.
- [x] E1, Hades started clientless (`retroforge-steam-direct`) beside the frozen-helper client: Hades.log
  `Steam Input initialized`, `Steam initialized`. gameprocess_log: `PID ... was launched outside Steam,
  using container PID ... as root`. controller_ui: `OnFocusWindowChanged to game window type: AppID
  1145360`. Playtime +3 min. On exit Auto-Cloud logged `No launch record found. Skipping looking for files
  added/removed while the game was running`, then still uploaded the new and changed saves (Profile4,
  change number 1 -> 2). No sync down before the game.
- [x] E2, the same client launching Hades itself (`-gamepadui ... -nofriendsui`, the kept-client path), its
  helper frozen 15 s after Hades.exe started: launch option dialog, install script evaluator (9 s),
  `AC Launch,down`, stats, shader prompt, then the game 14 s after the URI. Steam initialized, Steam Input
  focus, playtime +4 min, the save uploaded on exit (change number 3). The helpers peaked at 1970 MiB
  (1425 RSS, 356 swap, 189 GPU) during Steam's launch steps.
- [x] Memory, Hades's first room then quit from its menu, same launch option, MemTotal 3621 MiB, no OOM in
  any of them (peak RAM+swap in use / least swap free / least available, MiB):
  | mode | peak | swap free | available | Steam features |
  |---|---|---|---|---|
  | clientless (baseline, same day) | 5735 | 1428 | 24 | none |
  | E1: frozen-helper client beside a clientless launch | 5810 | 1311 | 47 | all but the sync down before play |
  | E2: frozen-helper client launches the game | 6274 | 833 | 48 | all |
  The swap the launch-time helpers push out stays out for the whole game, hence E2's cost.
- [x] SteamCMD as the default download path, if it could use the client's sign-in: no. Run on the Air X
  with the client's folder as its data folder (through an overlay, its writes thrown away), as uid 0 and as
  uid 1000: "Cached credentials not found" (exit 5, no prompt). It would need a first sign-in of its own with
  a password and Steam Guard, which RetroForge does not take (D8). Not a download path then. The
  frozen-helper client can download instead (an app manifest with StateFlags 1026, as in Phase 0).
- [x] The user's choice (2026-10-25): a minimal client for all background running, the full client
  whenever Steam's UI is needed, "client off" still an option, and the background minimal client the
  default on every device. So "Keep Steam running" (KEEP_RUNNING) is on by default, renamed "Steam: keep
  running in the background", and the kept client is minimal while nothing holds its UI. Refined the same
  day: games start without the client by default on every device too (DIRECT_LAUNCH, was SM6115 and
  4 GB boards only), so the full client comes up only when the player opens Steam, and for what only it
  can start (a game's first launch on the device, x86 games, installs). With the toggle off, no Steam in
  the background. The minimal client is ~240 MB idle, ~75 MB at Hades's peak (pushed to zram).
- [x] Implemented: `retroforge-steam-keep full [PID]` / `minimal [PID]` (kill the web helper, freeze
  the restarted one and what it started; holds per launch in `$XDG_RUNTIME_DIR/retroforge-steam-full`).
  `/usr/bin/steam`: Steam's UI holds the client full until OGUI closes it; a game the client starts
  holds it until it has run 15 s; a game started without the client gets the kept client beside it
  (started with the launch's arguments minus the URI, signed in first, ~20 s once per boot, 45 s at
  most; only with a remembered sign-in). `retroforge-steam-direct check` lets a game start without the
  client while the kept one (cgroup `retroforge-steam.service`) runs. Plugin texts, docs, tests
  (steam 117, steam-direct 103).
- [x] On the Air X (2026-10-25, the three scripts bind-mounted over build b447b50): the first launch
  started the client, which signed in and froze 18 s after the press, then Hades clientless (Steam
  initialized, Steam Input, peak 5930 MiB, 1209 free). Three bugs, fixed: (1) the kept client logs a game
  it did not start as `Game process added : AppID 1145360 ""`, and the helper took that for Steam's newest
  launch, so the second launch went through Steam; such lines are skipped now. (2) A game Steam launched,
  frozen 15 s after its process appeared but before its window, never got Steam Input (no controls); it
  is frozen once `OnFocusWindowChanged to game window type` is logged. (3) Steam's UI from a minimal
  client: `steam://open/bigpicture` sent while the UI was starting again was lost (window unmapped, OGUI's
  loading screen); it is sent once the UI has made its first calls (~14 s in all). After the fixes:
  second launch clientless in 3 s, controls fine, Cloud upload on exit; Steam's UI came up.
- [x] The restarted helper frozen after Steam's UI has run is born bigger (~110 MB private, ~60 MB anon,
  files cached), against 4 MB on the client's first start; the catch is not late (frozen within 0.6 s).
  It goes to zram when a game needs the memory. The client's own idle CPU is ~6% of a core, frozen or not.
- [ ] Steam Input beside a frozen client is not consistent: it switched to the clientless Hades on the
  first launch (the player felt lag) and not on the retest (felt better). Open: whether the lag was Steam
  Input through a swapped-out client or the client's first-start work; MemoryLow on the unit if the former.

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
