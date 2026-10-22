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
- [ ] Does the arm64 client list it? Its `compatibilitytool.vdf` says `to_oslist linux`, and the client has "Ignoring
  tool %s as it's for a different target platform".
- [x] Hades without the client through it (`~/.cache/rf-test/rf-tool-launch.py`): menu reached. Emulations peaked at
  ~1,000/s (was 3.36M/s), ~2k in total for Hades.exe, none from `ntdll.dll`; the rest is Valve's `steamclient.so`.
- [x] Experimental: rebuilt with Xalia allowed (`scan-allow.txt`), released as `armv8-experimental-11.0-20261014`.
- [ ] `PROTON_DXVK_SAREK=1` selects Sarek.
- [ ] Works with the clientless launch (`retroforge-steam-direct`).
- [ ] FEX delivery test: does Steam pick up our ARMv8.0 FEX? Try (a) our four binaries swapped into Steam's
  `steamapps/common/FEX-Emu` while its `VERSIONS.txt` matches our build, and (b) a local layer with its own
  `toolmanifest.vdf` (`compatmanager_layer_name "fex"`). Check with a native x86 Linux game and `lse-where`. Also
  check whether Steam restores Valve's files on its next tool update or verify.

### Phase 3: device import (branch `steam-armv8-proton` from `main` 99495d6; not pushed)
- [x] `steam-compat-tools`: with no `atomics` in /proc/cpuinfo it takes `proton-armv8.pin`; `.tar.zst`, `sidecar:` and
  `prereleases:` pin fields; Sarek off in every RetroForge folder. Committed as 4138332.
- [x] zram (D10): `min(ram, 8192)`. Committed as 3129ec3.
- [x] Tests: 10 new cases. In a Linux container: compat-tools 121/0, steam 99/0, steam-direct 72/0, x86-guest 110/0.
  On macOS, 12 cases fail with or without these changes (no /proc, no setsid).
- [ ] The Proton-CachyOS folder already on ARMv8.0 devices (2.2 GB) stays. Remove it? (user's call)

### Phase 4: OGUI Steam settings page (same branch, or the next one)
- [ ] A Steam page. Move "keep running", DXVK-Sarek and the clientless toggle there from Settings > General.
- [ ] Default Proton (Valve, ARMv8.0 stable or ARMv8.0 experimental; the last two only under D6).
- [ ] Per-game overrides in the game's settings (like `game_settings_page.gd`): Proton build and Sarek (D7). Turnip and FEX settings once Phase 4b answers how.
- [ ] 4b: Turnip variants in `/home` via `VK_DRIVER_FILES`. Does Steam Linux Runtime 4 load them? What about the matching x86 Turnip for FEX guests? Which `proton-fex-config.json` keys are worth exposing?
- [ ] Tests (`tests/test-plugin.sh`), docs.

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
- [ ] Stable and experimental ARMv8.0 releases are published by CI from Valve tags.
- [ ] ARMv8.0 devices download our build instead of Proton-CachyOS; other devices are unchanged.
- [ ] The Steam settings page ships with the per-game Proton and Sarek choices.
- [ ] Phase 5 is discussed and scheduled.
