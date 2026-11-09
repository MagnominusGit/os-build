# Xbox via hakuX (replaces xemu) — plan

Status: AGREED 2026-11-07 (user: "lets add hakux as another app for this emulator", "ideally we
would replace xemu", "no retroarch", "Revive on hakuX-lr"; xemu removed entirely). Phases 1-3 DONE
2026-11-07, not committed. Phase 4 (publish) DONE 2026-11-08; phase 5 is the HW gate.

## Why

hakuX (rfandango/hakuX) is an HLE original-Xbox emulator: the title's x86 code on a FEX fork's JIT
under a reimplemented Xbox kernel, NV2A push buffers decoded into Vulkan, the MCPX APU from xemu.
No BIOS, MCPX ROM or HDD image from the player, and tuned for Adreno. Upstream ships Android APKs
only. portare-ch/hakuX-lr is its Linux fork (PortareOS, SM8550): upstream merged to the v1.3.0
point, +375 commits (NV2A accuracy, CHD, a DSP56300 JIT, x86-64 KVM), released as a libretro core.
Its linux-v0.1.0-v0.3.x releases also had a standalone `hakux`, removed in 0.4.0 as untested.

## Decisions

- **D1 — no RetroArch**: the standalone front end comes back on hakuX-lr master (branch
  `retroforge-standalone` in ~/Documents/GitHub/hakuX-lr): `native/app/linux_main.c` (v0.3.0's,
  on today's API), `native/dev/apu/out_sdl.c` (+ `apu_out_close`), `native/cmake/linux-app.cmake`,
  `HAKUX_BUILD_APP` on Linux; linux-build.sh builds it, linux-package.sh ships it as
  `hakux-<version>-standalone-<arch>` beside the libretro tarball. Porting upstream's Android app
  ourselves was scoped and rejected (it redoes hakuX-lr's platform work and loses its 375 commits).
- **D2 — one ARMv8.0 build for every board**: HAKUX_ARCH empty (FEX `-march=armv8-a+crc`, outline
  atomics in the static code). FEX's JIT picks LSE/LL-SC, FlagM and RCPC per CPU from the ID
  registers; kernel 0025 leaves HWCAP_ATOMICS clear on the SM6115, so JIT code never traps.
- **D3 — hosting**: the fork sunshineinabox/hakux (of portare-ch/hakuX-lr; branch
  `retroforge-standalone`, pushed 2026-11-08 at f90b59d), tag
  `linux-v<lr version>-rf.<n>`; the catalog pins the standalone asset (GitHub digest required).
- **D4 — layout**: data folder ~/.local/share/hakux: hdd/ (only Partition1, the E: drive with the game
  saves, linked to ~/saves/xbox by retroforge-home.conf; C:, X/Y/Z caches and .overwrite stay), cache/
  (shaders), hakux.log (the core's ~17 lines/s, kept out of the journal); quick state
  ~/states/xbox/<disc>/quick.hxs.
- **D5 — keys**: F5 load, Shift+F5 save, Ctrl+Q leave (xemu's keys, so the Guide profile moved over).
  SIGTERM stops the core and syncs the hard disk; relaunch and state loads execv in place.
- **D6 — options**: arguments only (render scale, console video mode, aspect, upscaling, FXAA, shader
  compilation): no settings file, so no emu-sources.json entry for the key-drift check.

## Verified offline (2026-11-07)

- hakuX-lr's 20 ctest suites pass with hakux added (linux-build.sh, pinned image).
- Under `qemu-aarch64 -cpu cortex-a53` (checked first: an LSE binary dies with SIGILL there):
  linux-smoke, check.py (99 PASS, incl. the ARMv8.0 unaligned-atomic handler), kernel_io, kernel_mm
  all pass; FEX logs "Host CPU doesn't support atomics".
- The v1.3.0 APK core and lr's linux-v0.20.0 core both keep every LSE op in guarded outline helpers.
- hakux offscreen on lavapipe: options before operands, Vulkan device + swapchain, SDL audio, a guest
  HLT, SIGTERM (core stopped, hdd/ made), the missing dashboard, a bad option; 2026-11-08 SIGTERM and
  exitafter on a spinning guest, native and under qemu cortex-a53 (exit 0, core stopped).
- Release file hakux-0.22.0-rf.1-standalone-aarch64: 11256960 bytes, sha256 f5d1695a...e1af0aba2f,
  the catalog pin: the fork's CI build (linux.yml on the tag, GitHub's arm64 runner, Ubuntu 22.04
  sysroot). The file uploaded from here (9560c192..., then 6b930e4d for 0.20.0-rf.1) was replaced
  by that build minutes later (the release job's `--clobber`): releases come from CI only, the pin
  is what CI uploads. Base: hakuX-lr master b7b240f, after 0.22.0. Needs libSDL3.so.0, libz,
  libstdc++ (rootfs: SDL3 3.4.8, glibc 2.43, gcc-libs 16).
- The fork's retroforge-standalone (its default branch) is rebased onto each new upstream linux-v
  release by .github/workflows/upstream-sync.yml (every 6 h); it was on linux-v0.25.2 at 5eb73c95b2
  on 2026-11-09 (54b0f897a7). CHANGELOG.md conflicts are settled by the script; any other conflict
  opens an upstream-sync issue with its hunks (alert only: GitHub Models, the first choice, was
  retired 2026-07-30). No release or pin change is automatic.
- os-build suites: launch 605/0 (with perl's CPAN::Meta::YAML, missing from rf-trixie-py), catalog
  204/0, emu 151/0, emuopts 654/0, key-drift 45/0, plugin 130/0, plugin-install 14/0, portmaster
  39/0, scrape 112/1 (the image has no git: the hygiene check), shares 30/0.

## Found on the RG 55G1 (2026-11-07)

- GTA San Andreas: 30 fps steady, the in-game save written through hdd/Partition1 to ~/saves/xbox.
- The pinned build (b2866e75) crashes (SIGSEGV) at every exit after frames were shown: the front
  end's core thread didn't call `nc_hle_cpu_leave()` / `nc_cpu_thread_done()`, so the stall
  monitor's PC sampler sent SIGPROF to the joined vCPU thread during `nc_core_halt`. Fixed with the
  exit line's run-average fps in 6b930e4d (2026-11-08, 20/20 ctest), the new pin.
- Same card in the Air X (SM6115, no LSE), 2026-11-08: GTA SA runs on the ARMv8.0 path; the exit
  crash is the same (libc's `__aarch64_cas4_acq` LL/SC path instead of `casa`). Exit took 32.4 s:
  31.6 s of it systemd-coredump reading the 768M-capped core (740 MB peak on a 3.5 GB board), the
  process held until the dump ends. The fix removes the dump, so the exit is the halt alone.
  A/B on the Air X (GTA offscreen on Turnip, SIGTERM): b2866e75 exit 139 (SIGSEGV), 6b930e4d exit 0
  in 127 and 107 ms.
- hakuX-lr's tracker: per-game core bugs, plus #144/#149 (`nc_core_halt` hangs on x86-64): if hakux
  ever outlives Exit the same way, the definition's `exit_resend` is the fallback.

## Phases

1. DONE — hakuX-lr branch: front end, audio sink, build and package scripts, CI artifact paths,
   README.linux.md section, CHANGELOG `linux-v0.22.0-rf.1` (was 0.20.0-rf.1 before the rebase).
2. DONE — os-build: catalog hakux (xemu's slot), launch.conf xbox=hakux, emulators/hakux
   (emulator.json, options.json, guide-hotkeys.yaml moved from xemu), xemu files and its
   emu-sources row removed, retroforge-home.conf link, library/scraper xbox `chd`, plugin 0.1.107,
   tests.
3. DONE — the offline checks above.
4. DONE 2026-11-08 — forked to sunshineinabox/hakux, `retroforge-standalone` pushed (f90b59d), releases
   `linux-v0.20.0-rf.1`, then `linux-v0.22.0-rf.1` (rebased onto b7b240f, branch at a1b1bf5) with the pinned file; retroforge-emu's tested_build() on the Air X resolves it
   and the download hashes to the pin.
5. PENDING — HW: an SM6115 board (A610: Vulkan through noconform, FEX without LSE, 3.5 GB) and an
   A7xx board: a real game boots and draws, sound, pad, Guide keys, Exit (hard disk synced), a
   title's relaunch, the quick state, install/update/rollback from Main menu > Emulators.

## Risks

- A610: hakuX targets Vulkan 1.3 (1.2 path slower); our A610 gets 1.3 only via TU_DEBUG=noconform,
  which Mesa 26.3 drops. Guest RAM is copied on Linux (no AHardwareBuffer import), slower than
  Android's zero-copy.
- FEX without LSE: correct under qemu, performance unknown ("Expect bad performance" is FEX's own
  warning for LL/SC atomics; Xbox titles use LOCK-prefixed ops sparingly on one CPU).
- The fork tracks a fast upstream (hakuX-lr releases daily): the branch is additive files plus a few
  lines, so a rebase per update is cheap; tag_pattern only follows `-rf.<n>` tags we publish.
