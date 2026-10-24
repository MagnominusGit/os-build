# SM6115 (MANGMI Air X) performance audit: settings and pitfalls

Measured on an Air X MQ66 (Snapdragon 662: 4x Cortex-A73 @ 2.11 GHz + 4x Cortex-A53 @ 2.02 GHz,
Adreno 610 at 320-1050 MHz, 1080x1920 portrait panel scanned out rotated), 2026-10-10. GPU time
per process is from the `drm_msm_gpu:msm_gpu_submit_retired` tracepoint; CPU loads from a 60 fps
frame-loop stand-in (`tools/perf/framesim.c`, ~6 ms of work per frame on an A73 at full clock,
two threads, 15 s per run).

## Defaults that are right (keep them)

| Setting | Why |
|---|---|
| CPU governor **ondemand** (retroforge-powerd) | 7.8 ms/frame, 1% missed, game threads on the A73s |
| Stock scheduler (EEVDF), no sched_ext | see LAVD below |
| **Animated Effects off** (OGUI, patch 0006) | the idle shell otherwise pins the GPU at 1050 MHz |
| `--composite-blit` + `--force-composition-rotation` (session.conf) | single layers and two layers (a HUD) scan out pre-rotated, UBWC, on the DPU planes; ~1.1 ms of GPU per layer per frame for the rotated copy |
| `TU_DEBUG=noconform` | turnip only offers Vulkan 1.3 on the A610 with it |
| Mesa ISA floor `armv8-a+crc` + outline atomics | ARMv8.2 code SIGILLs here |

## Pitfalls found (and what now guards them)

| Pitfall | Measured | Guard |
|---|---|---|
| Touch on the SPI touchscreen | taps unrotated: axes swapped, scrolling inverted | gamescope patch 0033 |
| OGUI home banner's animated god-rays shader | idle shell: 40 submits/s at 47 ms GPU each, GPU at 1050 MHz, ~20 fps; with it hidden: zero submits, GPU runtime-suspended at 320 MHz | OGUI patch 0006: Settings > General > Animated Effects, default off |
| **schedutil** turns on energy-aware scheduling | EAS packs game threads onto the A53s: 36 ms/frame, **95% missed** | retroforge-powerd writes `sched_energy_aware=0` after every governor change (`[cpu] energy_aware=off`). schedutil with EAS off: 7.8 ms, 1-2% missed, 15-20% lower average clocks than ondemand |
| **scx_lavd** | puts one of two game threads on the A53s: 35-48 ms, 76-86% missed, under every governor | SM6115 profiles set `RETROFORGE_CPU_SCHEDULERS=none` |
| OGUI **core count** slider | PowerStation offlined from the top: "4 cores" kept the four A53s | PowerStation patch 0003: fastest cores (cpu_capacity) kept online first |
| Screenshots (gamescope) | every screenshot crashed gamescope (no cached+coherent memory type on the A610) | gamescope patch 0032 |
| Battery state in OGUI | 50% / charging on a full battery: UPower averaged in the charger's empty companion supply; also drove the docked/undocked performance profile | kernel patch 0967 (built, not yet booted) |
| GPU load in OGUI / PowerStation | `gpu_busy_percent` "not supported" | kernel patch 0265 (built, not yet booted) |
| Steam cards at Steam's own art size (600x900, 1200x1800 for `_2x`), one texture per card | idle shell with 67 Steam games: 373 MiB of GPU memory (DRM fdinfo), RAM it shares with the game | plugin 0.1.80: 300x450 card images, one texture per art file: 309 MiB (2026-10-24) |
| Every card's art loaded when it was built, for every card of every library tab | idle shell with 1,000 games: 872 MiB of GPU memory, 843 MiB of RAM available | OGUI patch 0031: art only within a screen of what is shown, dropped 10 s after its tab hides: 310 MiB, 1,408 MiB available; switching tabs peaks at 359 MiB instead of 937 (2026-10-24) |
| Switching library tabs with 1,000 games | ~140 ms frame on every switch, the same with and without 0031 (the tab's 1,000 cards laid out again) | none yet: plan Phase 4c, library scaling |

## OpenGamepadUI's frame cost (why navigation lagged)

Profiled with Godot's own viewport GPU timer (`RenderingServer.viewport_get_measured_render_time_gpu`)
from a throwaway probe plugin, OGUI forced to redraw continuously, hiding one branch at a time:

| Change | GPU per frame | Menu navigation, frames on screen |
|---|---|---|
| stock, 1920x1080 | 19.6 ms | 27/s |
| + banner collage clipped by scissor (OGUI patch 0007) | 13.9 ms | |
| + rendered at the 1280x800 design size (`RETROFORGE_UI_VIEWPORT_RENDER=1`) | 7.9 ms | 34/s |
| + low-processor mode off for 1.5 s after input (plugin) | 7.9 ms | **61/s** |

- The home banner's collage used `clip_children` with an all-opaque mask: an offscreen canvas
  group every frame for what is a rectangle clip (~6 ms).
- The rest is overdraw: each full-screen layer costs the Adreno 610 ~2 ms at 1920x1080 (background
  panel, banner, its black base, card shelf); the empty window costs 1.1 ms.
- Godot's low-processor mode keeps the idle shell at zero cost but paces animations at ~35 fps.
- Not the cause: renderer choice (Forward+, Mobile equal; GL compatibility worse), vsync, the
  gamescope WSI layer, or the GPU clock ramp after idle (full clock within ~70 ms).
- Left alone: the cards' and icons' `clip_children` masks are real shape masks (rounded corners);
  replacing them saves ~1.3 ms but squares the cards. (Done since without squaring them, below.)

## OpenGamepadUI's frame cost, round 2 (2026-10-24)

Profiled on the Air X with a throwaway autoload (an `override.cfg` next to the engine binary, through
an overlayfs on `/usr/share/opengamepadui`; `--main-pack` is compiled out of upstream's release
binary) that hides nodes and toggles properties live, GPU time per process from
`msm_gpu_submit_retired`, OGUI redrawing continuously, Reduced UI resolution on.

The Adreno 610 is fill-bound at about 1 Mpx per ms: every full 1422x800 layer costs ~1.1 ms, a
1920x1080 one ~2 ms. Library > All Games (18 cards) under Vulkan, 14.4 ms of GPU per frame:

| Cost | GPU per frame | Fix |
|---|---|---|
| Cards' `clip_children` masks (a canvas group each) | 3.2 ms | OGUI patch 0035: the art rounds its own corners in a shader |
| Card shadows filling the card behind the art twice | 2.1 ms | 0035: the shadow draws its ring only |
| Godot's scaled copy of the 1422x800 render into the 1920x1080 window | 1.9 ms | plugin 0.1.85: Reduced UI shrinks the shell's own Xwayland; the panel plane scales it |
| Full-screen background panel | 1.2 ms | none (an opaque clear instead saves only 0.5 ms and risks the in-game overlay) |

Under OpenGL the canvas groups were the stutter: each flushes the frame, and the same page drew at
31 fps with the GPU 42% busy (59 fps after 0035). Per-frame scripts (164 Buttons with an empty
`_process`, ...) took the idle main thread to 12% of a core; OGUI patch 0036: 9.5%.

| Before -> after (fps, p99 frame interval) | Vulkan (Forward+) | OpenGL |
|---|---|---|
| Home, navigating | 59.7 fps, 28 ms -> 59.8 fps, 24 ms | 57.6 fps, 34 ms -> 58.2 fps, 33 ms |
| Library, static | 59.9 fps, 14.5 ms GPU -> 59.9 fps, 8.1 ms | 31 fps -> 58.9 fps, 8.8 ms (with gamescope's copy) |
| Library, scrolling | 57.7 fps, 29 ms -> 57.6 fps, 28 ms | -> 55.3 fps, 32 ms |

- **Renderer:** after the fixes both hold 55-60 fps, but GL still has more long frames while
  navigating (freedreno's flushes and its driver work on OGUI's main thread); GL leaves ~130 MiB more
  RAM available. The SM6115 boards start the shell on OpenGL for the RAM (board profile
  `RETROFORGE_UI_RENDERER=opengl`), and Settings > Display > Vulkan renderer switches it from the
  next start; every other board stays on Vulkan (Forward+) with no choice offered.
- Not worth changing: AA on the panel or the shadows, the top bar icons' masks, vsync, MSAA/AA (off
  already). Settings and the quick bar's `CardButton` masks cost ~1.5 ms under GL with no stall.
- CPU: no hot loop to hand-vectorise; scrolling the library spreads ~75% of a core over the GDScript
  VM and the engine (top address 1.6%). Idle, Godot 4.7's own threads poll every millisecond: the X11
  event thread (~7% of a core) and the PulseAudio thread (~3.5%); only an engine change fixes those.

## Latency: from a frame to the panel

Measured 2026-10-10 with gamescope's own trace markers (`chmod 666 /sys/kernel/tracing/trace_marker`
before the session starts, then `tracing_on=1`): a frame arrives in gamescope ("pushing wait for
commit N"), its GPU fence signals ("wait fence (end_ctx=N)"), gamescope latches it at its
vblank-timed wakeup ("flip commit"), and the flip completes at vblank ("page_flip_handler", plus
the `drm/drm_vblank_event` tracepoint). Note "commit N done" is NOT the fence: gamescope logs it
only when its main loop next wakes to paint.

| Frame -> on screen (mean / p95) | Mesa pre-rotation off | on (session default) |
|---|---|---|
| God of War, 51 fps | 28.3 / 46.1 ms | 22.0 / 29.4 ms |
| OGUI menu navigation | 36.5 / 50.2 ms | 30.2 / 32.0 ms |
| OGUI menu, Reduced UI resolution | | 15.5 / 27.1 ms |

- **Pre-rotation is a latency fix, not only a copy move.** With it off, gamescope's rotation
  copy is submitted at flip time behind the client's GPU work on the A610's single ring and
  waits for it synchronously: flips slip past vblank (one paint took 46 ms).
- **At full resolution, OGUI's frames land ~2 ms after gamescope's latch.** It starts each frame just
  after vblank (FIFO), its GPU work is ~14.5 ms (render 11.6 + blit to the swapchain 2.3 + the
  pre-rotation copy 1.0), and gamescope latches ~2.4 ms before vblank (1.65 ms redzone + its
  paint time). Every frame waits one more refresh. Reduced UI resolution (9.6 ms of GPU) makes
  the latch and halves menu latency; at full resolution the render needs ~3 ms less overdraw.
  Not the cause: swapchain image count (2 or 3), Godot frame queue size, vsync mailbox.
- **First press after the menu idles: 57-80 ms** from InputPlumber's D-Bus signal to the panel:
  OGUI's main thread wakes from its 16.7 ms low-processor sleep (avg ~8 ms), needs 11-18 ms of
  CPU for the frame, then ~20-30 ms of GPU. Pinning CPU and GPU clocks to max saves ~10 ms, GPU
  runtime-suspend (66 ms autosuspend) is not a factor; neither is worth the power.
- **ARMSX2 VsyncQueueSize = 1** (seed): one frame of EE run-ahead instead of two, same fps
  (31.3 vs 31.4 heavy scene; 0 costs 7%). Already presents MAILBOX with vsync off.
- **Input path:** InputPlumber's evdev source polls every 2.5 ms (~1.3 ms average); its targets
  are event-driven (the 8 ms target interval is only a fallback tick); it ships prebuilt.
- **The panel has one mode, 60 Hz**; a game below 60 fps waits ~half a refresh for the latch
  (8.7 ms mean in God of War).

- **Shell window hidden in games** (plugin 0.1.21): the SM6115 DPU has two source pipes (VIG
  sspp 1 with a scaler, DMA sspp 9); OGUI's empty in-game window held the DMA one. With its
  `_NET_WM_WINDOW_OPACITY` at 0 the game scans out alone on one plane (God of War 52.8 fps), the
  menu and in-game toasts bring the second plane back and it drops again after. Menu-open time
  is unchanged (Guide to menu on screen 378-397 ms hidden vs 414-487 ms visible, both including
  ~88 ms to start the injecting script). Test pitfall: in the menu OGUI is the base window, so
  opacity 0 there blanks the screen -- check `gamescopectl focus_info` shows the game first.

## Measured, no change needed

- **Godot renderer for OGUI**: Forward Mobile 17.9 ms/submit (26 fps, CPU 74%), GL compatibility
  10.8 ms/submit but CPU-bound at 20 fps (CPU 94%); Forward+ is fine once the god-rays are off.
- **TU_DEBUG sysmem / gmem / noubwc**: no effect on the shell's cost (not a tiling or bandwidth issue).
- **OGUI max_fps 30 vs 60** at idle: CPU 21% vs 27% (it no longer renders at idle anyway).
- **GPU manual clock range** (OGUI performance menu -> PowerStation -> devfreq): applies (max 600
  held at 600 under load) and returns to 320-1050 in automatic.
- **SMT toggle**: sysfs reports `notsupported`; PowerStation 0001 already keeps the core count whole.
- **Interrupts**: all device IRQs land on cpu0; worst case (Wi-Fi download) cpu0 spends ~9% of one
  A53 on irq+softirq (Wi-Fi ~2,100/s, GPU ~240/s, joypad UART ~250/s). Spreading them over
  cpu1-3 is a small, low-priority gain.
- **Fan**: the gpio fan reported 8,600 rpm at 36 C on the factory curve's 64/255 PWM floor;
  gpio-fan has few steps -- worth a listen and a curve check, not a performance issue.

## Steam on this SoC

See `docs/steam-arm64.md`. Its Big Picture sign-in screen alone holds the GPU ~80% busy.
