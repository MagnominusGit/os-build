# Per-emulator options (aspect ratio, renderer, resolution...) — plan

Status: phase 2 (framework) implemented on branch feat/emulator-options (2026-10-15), no emulator has an
options.json yet. Next: phase 3 (plugin pages). See "As built" below for where phase 2 departs from the design.
Sources: each emulator's source at the pinned version (catalog.json); file:line references were taken from
those trees (shallow clones, scratchpad of session 8826cb34, not kept).

## Goal

The player sets display/graphics options per emulator (a default) and per game (an override), from
OGUI (Settings > Emulators, and Game settings > RetroForge). A per-emulator sub-launcher turns
the resolved values into command-line arguments and/or config patches when retroforge-launch starts
the game.

## What the research says (one line per emulator)

| Emulator | Per-run override, not saved | Config rewritten by the emulator | Native per-game | Mechanism to use |
|---|---|---|---|---|
| mGBA | `-C key=value`, any key, highest priority | MRU/close: rewritten, unknown keys kept | cart HW only | **CLI** (displayDriver is in qt.ini, so patch that) |
| Flycast | `-config sec:key=v,...` (transient) | on every save, unknown keys kept | `[<IP.BIN id>]` section in emu.cfg, beats -config | **CLI** |
| Dolphin | `-C Sys.Sec.Key=V`, `-v backend` | on exit, only known keys rewritten | GameSettings/<ID6>.ini; Sys+user per-game files OUTRANK -C | **CLI** (fine for res/aspect/backend/vsync/speed; Sys files win for texture filter/EFB) |
| xemu | `-config_path <toml>` (whole file) | atexit, delta of non-defaults, unknown keys dropped | none | **per-run copy**: merged toml → -config_path |
| ARMSX2 | `-gamecfg <file.ini>` = game layer for this boot | on change only | gamesettings/<SERIAL>_<CRC>.ini (replaced by -gamecfg) | **per-run game layer**: -gamecfg (merge the player's own per-game ini in) |
| RPCS3 | `--config <yml>` REPLACES config.yml + custom config | settings dialog only | custom_configs/config_<TITLEID>.yml | **per-run copy**: deep-merge(config.yml, custom, ours) → --config |
| DuckStation | none (unknown flag = error box, quits) | on change only, safe to patch | gamesettings/<SERIAL>.ini | **patch + restore** settings.ini |
| PPSSPP | `--appendconfig` but it SAVES (unless -j first: then nothing saves) | on exit, known keys only | <DISCID>_ppsspp.ini | **patch + restore** ppsspp.ini |
| Azahar | none | at boot and exit (QSettings) | custom/<TITLEID>.ini (possible leak into global, unverified) | **patch + restore** qt-config.ini, always with `key\default=false` |
| melonDS | none | on ROM load/exit, whole TOML | none | **patch + restore** melonDS.toml (validate: a TOML error wipes the config) |
| Snes9x | some flags, but most get SAVED on exit | whole file rebuilt on exit, unknown keys DROPPED | none | **patch + restore** snes9x.conf |
| ClownMDEmu | none | whole file on exit, only known keys | none | **patch + restore** configuration.ini (strict `key = value`) |
| Cemu | none (`-f` only) | GUI actions only; SIGTERM = _Exit, nothing saved | gameProfiles/<tid>.ini (api, cpuMode) | **patch + restore** settings.xml; resolution/game aspect = graphic packs (later) |
| PortMaster | n/a | | | out of scope |

Conclusion: three mechanisms cover everything:
1. **cli**: extra arguments (mGBA, Flycast, Dolphin);
2. **run-copy**: a per-run file the emulator reads instead of, or on top of, its own (xemu, ARMSX2, RPCS3);
3. **patch+restore**: write the managed keys into the emulator's config before the start, put the previous
   values back after it exits (all the others).

**No game serials are needed for v1.** Our per-game layer is keyed by RetroForge's rom_id
(`<system>/<file>`) and applied through the three mechanisms above, never through the emulators' per-game
files. Reading disc serials (SYSTEM.CNF, PARAM.SFO, IP.BIN, NCSD, GC header, ZArchive...) is only needed
if we ever write native per-game files. That is deferred.

## Options vocabulary (common ids, each emulator exposes a subset)

| id | values (UI) | notes |
|---|---|---|
| `renderer` | vulkan / opengl / software | per-emulator list; HW-validate per SoC (Flycast Vulkan resets A610) |
| `resolution` | native, 2x, 3x, 4x (or the emulator's own steps) | biggest performance knob everywhere |
| `aspect` | auto / 4:3 / 16:9 / stretch | |
| `integer_scale` | on / off | |
| `smoothing` | sharp (nearest) / smooth (bilinear) | output filter |
| `widescreen_hack` | on / off | DuckStation, Flycast, Dolphin (hack), ARMSX2 (patch), ClownMDEmu (tiles) |
| `vsync` | on / off | |
| `frameskip` | off / auto / 1 / 2 | where it exists |
| `show_fps` | on / off | where the emulator draws it (mGBA/melonDS/Azahar: no → MangoHud) |
| `shader` | none / CRT / LCD... | later phase (bundled shader names differ per emulator) |
| system-specific | DS/3DS `screen_layout`, `screen_gap`, `swap_screens`; GB `gb_colors`; GBA `lcd_blend`; MD `region`/`pal`; Dolphin/Azahar `cpu_clock` | |

Each option at the **emulator level** has an extra value "Emulator's setting": RetroForge never touches the key
(default for every option, so nothing changes for existing players). At the **game level**: "Emulator default"
(= the emulator-level choice) or a value.

### Option matrix (v1 candidates; ✓ = exposed)

| | renderer | resolution | aspect | integer | smoothing | widescreen | vsync | frameskip | fps | extra |
|---|---|---|---|---|---|---|---|---|---|---|
| duckstation | ✓ Vulkan/OpenGL/Software | ✓ ResolutionScale | ✓ | ✓ (Scaling) | ✓ | ✓ | ✓ | – | ✓ | crop, PGXP |
| armsx2 | ✓ 14/12/13 | ✓ upscale_multiplier | ✓ | ✓ | ✓ linear_present_mode | ✓ EnableWideScreenPatches | ✓ | – | ✓ | upscaler FSR/SGSR, blending |
| rpcs3 | ✓ Vulkan (OpenGL?) | ✓ Resolution Scale % | ✓ 4:3/16:9 (+stretch) | – | ✓ Output Scaling Mode | – | ✓ | ✓ | ✓ perf overlay | frame limit |
| dolphin | ✓ -v Vulkan/OGL | ✓ InternalResolution | ✓ | – | – | ✓ wideScreenHack | ✓ | – | ✓ | shader compilation, CPU clock |
| cemu | ✓ api | (graphic pack, later) | ✓ keep/stretch only | – | ✓ Upscale/DownscaleFilter | – | ✓ | – | ✓ overlay | |
| xemu | ✓ OPENGL/VULKAN | ✓ surface_scale | ✓ | ~ fit=center | ✓ filtering | – | ✓ | – | – | |
| ppsspp | ✓ 0/3 | ✓ InternalResolution | ✓ stretch/ratio | ✓ | ✓ BufferFiltering | – | ✓ | ✓ | ✓ iShowStatusFlags | SkipBufferEffects |
| flycast | ✓ pvr.rend 0/4 (OIT 3/5) | ✓ rend.Resolution | ✓ ScreenStretching/WideScreen | ✓ | ✓ LinearInterpolation | ✓ WidescreenGameHacks | ✓ | ✓ ta.skip / AutoSkipFrame | ✓ | |
| azahar | ✓ graphics_api 0/1/2 | ✓ resolution_factor | – (Qt ignores aspect_ratio) | ✓ | ✓ filter_mode | – | ✓ | – | – | layout, swap, gap, cpu clock |
| melonds | ✓ 3D.Renderer soft/GL/compute | ✓ 3D.GL.ScaleFactor | ✓ ScreenAspectTop/Bot | ✓ | ✓ ScreenFilter | – | ✓ | – | – | layout, sizing, rotation, gap, swap |
| mgba | (qt.ini displayDriver) | – | ✓ lockAspectRatio | ✓ | ✓ resampleVideo | – | ✓ videoSync | ✓ | – | gb.colors, interframeBlending, shader |
| snes9x | ✓ HardwareAcceleration opengl/vulkan/none | – | ✓ AspectRatio 0-5 | ✓ (in AspectRatio) | ✓ BilinearFilter | – | ✓ | – | ✓ | overscan, SuperFX clock |
| clownmdemu | (SDL_RENDER_DRIVER env, unverified) | – | ✓ screen-scaling fit/fill | ✓ pixel-perfect | – | ✓ widescreen-tiles | ✓ | – | – | pal, japanese, low-pass |

Exact keys/values per emulator: Appendix A.

## Design

### Data and files

- **Option schema**: `/usr/share/retroforge/emulators/<emu>/options.json`, data only: for each option its id,
  label, description, choices (value + label), and how to apply each value (`cli` args, or a
  `{file, format, key, value}` patch). The plugin builds the pages from it; the sub-launcher applies it.
  Most emulators need no code beyond this.
- **Emulator level**: `~/.config/retroforge/emulators/<emu>.conf`, the file that already holds `CPUS=`.
  One line per option: `OPT_<id>=<value>`. A missing line means "Emulator's setting".
- **Game level**: proposed `~/.config/retroforge/games/<system>/<rom file>.conf`, same format, read by
  retroforge-launch. The alternative is OGUI settings_manager + `--opt id=value` on the card's command line, like
  `--cpus` today. Files were chosen (D2):
  - item.args does not need rebuilding when a choice changes;
  - the launcher remains the only source of truth;
  - other frontends get the same behaviour.

### Launcher

retroforge-launch resolves the values (game > emulator > untouched), then calls the emulator's adapter
before the start. The adapter returns extra args and env, plus a list of patches. After the emulator exits,
the launcher runs the restore step. It also lists options as JSON for the plugin:
`retroforge-launch --options <emu> [<system> <rom>]` prints the schema plus the current emulator-level and
game-level values, the same pattern as `retroforge-emu list`. GDScript never parses an emulator's config format.

- **Adapters**: `/usr/lib/retroforge/emulators/<emu>.py` (the "sub launcher"). It is optional, and only for
  what data cannot express:
  - RPCS3: deep-merge of the yml;
  - ARMSX2: merging the player's own gamesettings ini into the -gamecfg file;
  - xemu: merged toml;
  - Azahar: `\default=false` companions;
  - Snes9x: driver fallback;
  - Cemu: graphic packs, later.
  - Shared helpers live in one module: format-preserving ini, toml, yaml and xml key patchers, and the journal.
  - This replaces the "no code in definitions" rule for options only. The emulator.json formats stay data.
- **Emulator level is persistent; game level is temporary.**
  - An emulator-level value is written into the emulator's config at every launch, the --gui included, and
    never restored. It behaves as if the player had set it in the emulator's own UI, which RetroForge then
    keeps enforcing.
  - A game-level value is applied through cli or run-copy, or patched and then restored to its pre-launch
    value after exit.
- **Restore journal**: before patching, the launcher writes `~/.local/state/retroforge/restore/<emu>.json`
  holding the previous values. It applies the journal after the emulator exits, and also at the start of the
  next launch: a double Exit (SIGKILL) or a power cut must not leave one game's override in the global config.
  The journal is applied before any new patching.
- **Format rules from the research**, each one a crash or a silent no-op if missed:
  - Azahar: write `key\default=false` with every value.
  - ClownMDEmu: exactly `key = value`, booleans `on`/`off`.
  - Snes9x: re-write every managed key each launch (the whole file is rebuilt and unknown keys dropped;
    a failed driver falls back to `none` and is SAVED).
  - melonDS and xemu: validate the TOML we write (a syntax error wipes the melonDS config; xemu exits 1).
  - melonDS: a GL failure falls back to Software and saves it.
  - mGBA: booleans `0`/`1` only.
  - DuckStation: quote values that contain `#` or `;`.
  - PPSSPP: keep the `N (NAME)` enum style (both forms are read).
- **Precedence vs the emulator's own per-game files**: theirs win where the emulator ranks them higher:
  Dolphin Sys/user GameSettings, Flycast's per-game section, DuckStation, PPSSPP and Azahar per-game files,
  RPCS3 and ARMSX2 when merged. Documented on the page as "Settings saved inside the emulator for this game
  take priority". No extra code.

### Plugin (OGUI)

- **Settings > Emulators > <emu>**: one dropdown per option from the schema, written to `<emu>.conf`.
  The existing fast-cores toggle stays as it is.
- **Game settings > RetroForge**: the same dropdowns, for the game's emulator, with "Emulator default (X)" first.
  "Run on fast cores" stays, but saves `CPUS=` in the game .conf (D2).
- Labels come from options.json. One source, no duplicated strings in GDScript.

## As built (phase 2, 2026-10-15)

- `rootfs/overlay/usr/lib/retroforge/python/emuopts.py` (imported by retroforge-launch, found relative to the
  script so the offline tests run it from the repo); `tests/test-emuopts.sh`; options case in test-launch.sh.
- **Two mechanisms, not three.** Patch + restore works for every file-based emulator, including xemu
  (it saves at exit, then we restore), RPCS3 and ARMSX2 (their config is not rewritten on exit). So there is
  no run-copy mechanism. Add one only if an emulator turns out to need it.
- **No `retroforge-launch --options`.** The plugin reads options.json (data) and the two confs directly.
- **No per-emulator .py adapters yet.** Azahar's `key\default=false` is just a second file action in data.
  Add an adapter only when data cannot express something.
- **Conf lines**: `CPUS=big|all` plus `<option id>=<choice value>` (lowercase ids, e.g. `aspect=16:9`). Both
  levels use the same format. An unknown value is ignored with a warning.
- **Every choice of an option must write the same (file, section, key) set** (load_options refuses
  otherwise). The emulator-level choice is written at every launch, even under a game override, and the
  game's choice goes over it for the run. A setting that only one of the two choices wrote would otherwise
  stay active under the game's choice. Args and env come from the winning choice only.
- Extra arguments go before the definition's args (and system_args). options.json is refused for the
  scripts format (PortMaster).
- `--cpus` is gone from retroforge-launch. The plugin writes `CPUS=` in the game conf and cards are just
  `<system> <rom>`. Choices players had saved in OGUI's `retroforge.cpus` section are dropped (no migration).

## Phases

1. **Decisions** D1–D5: done (below).
2. **Framework** (DONE, see As built), no option exposed yet:
   - schema loader;
   - conf reading at both levels;
   - patchers for ini, toml, yaml and xml, with format-preservation tests;
   - restore journal and crash recovery;
   - `--options` JSON.
   - Tests in tests/ for every patcher and for crash recovery (journal present at start).
3. **Plugin pages**: generic dropdown pages built from the JSON. tests/test-plugin.sh covers the pure parts.
4. **Adapters, wave 1 (cli / run-copy)**: mGBA, Flycast, Dolphin, xemu, ARMSX2, RPCS3.
5. **Adapters, wave 2 (patch + restore)**: DuckStation, PPSSPP, Azahar, melonDS, Snes9x, ClownMDEmu, Cemu.
6. **HW validation** per option on SM6115 / SM8250 / SM8550:
   - every renderer choice on each SoC (e.g. Flycast Vulkan resets the A610, see memory
     flycast-a610-reset). Per D5 the schema gets no `soc` filter: problems found
     here are fixed or documented, never hidden;
   - resolution steps that hold full speed.
7. **Later**:
   - shaders (per-emulator bundled names; mGBA shaders need a stable path outside the AppImage mount);
   - Cemu graphic packs (resolution and game aspect; packs must be downloaded);
   - widescreen patches (Dolphin Gecko, RPCS3 patch.yml);
   - native per-game files keyed by serial, if "what the emulator saves for this game" ever needs to follow
     ours.

## Decisions (user, 2026-10-15)

- **D1 — v1 scope = the common set**: renderer, resolution, aspect, integer_scale, smoothing,
  widescreen_hack, vsync, show_fps. Deferred: frameskip, shaders, CPU clock, and the system-specific options
  (DS/3DS layout, GB colours, MD region...).
- **D2 — game level in .conf files**: `~/.config/retroforge/games/<system>/<rom file>.conf`, read by
  retroforge-launch.
  - **The per-game CPUS choice moves there too**: `CPUS=big|all`.
  - The plugin stops putting `--cpus` on the card's command line, so item.args is just `<system> <rom>`.
  - `--cpus` is removed from retroforge-launch outright (no transition period).
  - No migration: existing per-game choices in OGUI's `retroforge.cpus` section are dropped (players set them
    again). The plugin stops reading that section.
- **D3 — emulator level is permanent**: written into the emulator's own config at every launch (--gui
  included), never restored.
- **D4 — the player's in-run changes to an overridden key are lost** when we restore.
- **D5 — no per-SoC filtering, no tested/untested marks**: options.json lists every value the emulator
  supports; Phase 6 HW validation only fixes bugs, it does not hide values.

## Appendix A — exact keys (pinned versions)

**DuckStation** settings.ini (patch):
- `[GPU] Renderer=Automatic|Vulkan|OpenGL|Software`
- `[GPU] ResolutionScale=1..32` (0 = auto)
- `[Display] AspectRatio=Auto (Game Native)|Stretch To Fill|PAR 1:1|4:3|16:9`
- `[GPU] WidescreenHack=true` (with AspectRatio 16:9)
- `[Display] Scaling=Nearest|NearestInteger|BilinearSmooth|BilinearSharp|BilinearInteger|Lanczos`
- `[GPU] TextureFilter=Nearest|Bilinear|...`
- `[Display] CropMode=None|Overscan|Borders`
- `[Display] VSync`
- `[Main] EmulationSpeed`
- `[Display] ShowFPS`
- `[GPU] PGXPEnable`
- Notes:
  - Gamedb traits can force options off.
  - `[Main] DisableAllEnhancements` overrides everything.
  - Unknown CLI flags make DuckStation quit.

**ARMSX2** PCSX2.ini / `-gamecfg` file, section `[EmuCore/GS]`:
- `Renderer=-1|12 GL|13 SW|14 VK`
- `upscale_multiplier=1.0..`
- `AspectRatio=Stretch|Auto 4:3/3:2|4:3|16:9|...`
- `IntegerScaling`
- `linear_present_mode=0|1|2`
- `filter=0..3`
- `VsyncEnable`
- `OsdShowFPS`
- `TVShader=0..7`
- `Upscaler=0|2 FSR1|3 SGSR|4 SGSREdge`
- `accurate_blending_unit=0..5`
- Outside `[EmuCore/GS]`:
  - `[EmuCore] EnableWideScreenPatches` (stripped from per-game inis by the UI, so set it in PCSX2.ini)
  - `[Framerate] NominalScalar`
  - `[EmuCore/Speedhacks] EECycleRate`, `EECycleSkip`
- Notes:
  - In-run per-game UI edits go into our -gamecfg file.
  - `[EmuCore] WarnAboutUnsafeSettings=false`.

**RPCS3** `--config` merged yml:
- `Video: Renderer: Vulkan|OpenGL`
- `Video: Resolution Scale: 25..800`
- `Video: Aspect ratio: 4:3|16:9`
- `Video: Stretch To Display Area`
- `Video: Output Scaling Mode: Nearest|Bilinear|FidelityFX Super Resolution`
- `Video: VSync Mode: Disabled|Adaptive|Full`
- `Video: Frame limit: Off|30|50|60|Auto|...`
- `Video: Enable Frame Skip`
- `Video: Performance Overlay: Enabled`
- Note: if the player uses "save" in the home menu, RPCS3 writes the FULL g_cfg (ours included) into their
  custom config.

**Dolphin** `-C`:
- `Graphics.Settings.InternalResolution=N`
- `Graphics.Settings.AspectRatio=0 auto|1 16:9|2 4:3|3 stretch`
- `Graphics.Settings.wideScreenHack`
- `-v Vulkan|OGL`
- `Graphics.Enhancements.ForceTextureFiltering=0|1|2`
- `Graphics.Hardware.VSync`
- `Main.Core.EmulationSpeed`
- `Graphics.Settings.ShowFPS`
- `Graphics.Settings.ShaderCompilationMode=0..3`
- `Main.Core.Overclock` + `OverclockEnable`
- Notes:
  - Sys GameSettings outrank -C (texture filtering in 70 games, EFB/XFB hacks).
  - Game ID offline: `dolphin-tool header -j` (is the tool in the AppImage? unverified).

**Cemu** settings.xml `<Graphic>`:
- `api 0 GL|1 VK`
- `FullscreenScaling 0 keep|1 stretch`
- `UpscaleFilter` / `DownscaleFilter 0..3`
- `VSync 0|1|2`
- `AsyncCompile`
- `Overlay/Position 0..6`
- Notes:
  - The XML is rebuilt whole (unknown keys dropped) on GUI saves only.
  - Resolution and game aspect come from graphic packs: the `<GraphicPack><Entry filename=...><Preset>` entries.

**xemu** toml via `-config_path`:
- `[display] renderer='OPENGL'|'VULKAN'`
- `[display.quality] surface_scale=1..10`
- `[display] filtering='linear'|'nearest'`
- `[display.ui] fit='center'|'scale'|'stretch'`
- `[display.ui] aspect_ratio='native'|'auto'|'4x3'|'16x9'`
- `[display.window] vsync`
- Note: a TOML error makes xemu exit 1.

**PPSSPP** ppsspp.ini:
- `[Graphics]`:
  - `GraphicsBackend=0|3`
  - `InternalResolution=0..10`
  - `FrameSkip`, `AutoFrameSkip`
  - `VerticalSync`
  - `SkipBufferEffects`
  - `iShowStatusFlags` (2 = FPS)
- `[DisplayLayout.Landscape]`:
  - `DisplayStretch`
  - `DisplayIntegerScale`
  - `DisplayAspectRatio`
  - `BufferFiltering=1|2`
- `[PostShaderList] PostShader1=`
- Note: `--graphics=` is ineffective (overwritten by the ini load).

**Flycast** `-config config:<key>=v`:
- `pvr.rend=0|3|4|5`
- `rend.Resolution=480|720|960...`
- `rend.WideScreen`, `rend.SuperWideScreen`
- `rend.WidescreenGameHacks`
- `rend.ScreenStretching=100..250`
- `rend.IntegerScale`
- `rend.LinearInterpolation`
- `rend.vsync`
- `rend.ShowFPS`
- `ta.skip=0..6`, `pvr.AutoSkipFrame=0..2`
- `rend.ThreadedRendering`

**Azahar** qt-config.ini (`key\default=false` with each):
- `[Renderer]`:
  - `graphics_api=0|1|2`
  - `resolution_factor=0..10`
  - `use_integer_scaling`
  - `texture_filter`, `texture_sampling`
  - `use_vsync`
  - `frame_limit`
  - `async_shader_compilation`
- `[Layout]`:
  - `layout_option=0..6` (4 = separate windows, the dual-screen seed)
  - `swap_screen`
  - `screen_gap`
  - `large_screen_proportion`
  - `filter_mode`
- `[Core] cpu_clock_percentage`

**melonDS** melonDS.toml:
- Root keys:
  - `3D.Renderer=0|1|2`
  - `3D.GL.ScaleFactor=1..16`
  - `3D.Soft.Threaded`
  - `Screen.UseGL`
  - `Screen.VSync`
  - `LimitFPS`, `TargetFPS`
- `[Instance0.Window0]`:
  - `ScreenLayout=0..3`
  - `ScreenSizing=0..5`
  - `ScreenRotation`
  - `ScreenGap`
  - `ScreenSwap`
  - `ScreenAspectTop` / `ScreenAspectBot` (ids: 0 4:3, 1 16:9, 3 window)
  - `IntegerScaling`
  - `ScreenFilter`
- Note: patching layout keys must not break the dual-screen seed (Window1).

**mGBA** `-C`:
- `lockAspectRatio`
- `lockIntegerScaling`
- `resampleVideo`
- `interframeBlending`
- `shader=/abs/dir`
- `gb.colors=0..3`
- `gb.model`
- `sgb.borders`
- `videoSync`
- `frameskip`
- `fpsTarget`
- Note: the display driver is in qt.ini `[General] displayDriver=0|1|2` (patch that file).

**Snes9x** snes9x.conf:
- `[Display]`:
  - `HardwareAcceleration=none|opengl|vulkan`
  - `AspectRatio=0..5` (2 = 4:3, 3 = 4:3 integer, 4 = 8:7 PAR)
  - `ScaleToFit`
  - `MaintainAspectRatio`
  - `BilinearFilter`
  - `ShowOverscanArea`
  - `HiresEffect`
- `[OpenGL] VSync`
- `[Emulation] DisplayFrameRate`
- `[Hacks] SuperFXClockMultiplier`
- CLI: `-pal` / `-ntsc` (not saved)
- Note: never use `-frameskip` (it corrupts SpeedControlMethod).

**ClownMDEmu** `<-u dir>/configuration.ini [Miscellaneous]`:
- `screen-scaling=0 fit|1 fill|2 pixel-perfect`
- `widescreen-tiles=0..12`
- `vsync`
- `pal`
- `japanese`
- `low-pass-filter`
- `tall-interlace-mode-2`
- Booleans are `on`/`off`, written exactly as `key = value`.
