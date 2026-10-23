# mesa patches

retroforge patches applied on top of the upstream mesa release source (currently `26.2.5`), in
the order listed by `patches:` in [`../source.pin`](../source.pin). Each is applied with
`patch -p1` from the mesa source root (the `mesa-<version>/` tree inside makepkg's `$srcdir`)
by [`packages/build-overlay.sh`](../../build-overlay.sh), inserted right after the first `cd`
in the PKGBUILD's `prepare()`.

## Present

```
0001-add-a830-chip-id.patch                                          # SM8750 / a830 enablement
```

- **0001** (a830-specific) — register the Adreno 830 (a8xx) `chip_id`s in
  `src/freedreno/common/freedreno_devices.py` so freedreno/Turnip recognise the SM8750 GPU (adds
  the msm `0xffff4405…` and KGSL `0x4405…` variants).

## Dropped

- **0002-freedreno-ir3-vulkan-disable-bindless-ubo-const-lowering.patch** — dropped 2026-08-19
  (this file's history has the full write-up). It was a ROCKNIX-origin workaround (added there
  2026-05-12, never upstreamed) that made ir3's UBO-range analysis treat a bindless UBO load as a
  constant range only when the offset was also constant. ROCKNIX removed it on 2026-08-11 as "no
  longer needed" (`ROCKNIX/distribution#3167`), the UBO-range analysis it patched was reworked
  between mesa 26.0.0 and 26.2.0, and this file already marked it a removal candidate.

  **HW retest still owed:** being wrong costs miscompiled shaders — a hang or corruption in a
  Vulkan title, found by a player, not by a build. On the next flashed card, play the Vulkan test
  titles (Super Meat Boy, Garage Circuit Rally, plus at least one Proton title) and watch for
  corruption. If anything reproduces, restore the patch from git history AND record what
  reproduced — the note that was always missing from it.

Patches apply `-p1` against the upstream mesa tree, in the order listed in
[`../source.pin`](../source.pin)'s `patches:` line. If a declared patch is missing or fails to
apply, `build-overlay.sh` / `makepkg` fails fast before the package is built.

## Pre-rotated presents (0002-0013), added 2026-10-09

The twelve commits sunshineinabox carries on top of upstream Mesa in ROCKNIX
(`projects/ROCKNIX/packages/graphics/mesa/patches/0001`-`0012` on `next`, which pins the same
26.2.4 tarball we do; also the fork at gitlab.freedesktop.org/sunshineinabox/mesa, `89ba0269`).
In order: `tu` implements `VK_QCOM_rotated_copy_commands`; the Wayland WSI sorts surface
formats, gets `vkCmdBlitImage2` in its dispatch table, supports a rotated `preTransform`, and
gains OPTIONAL pre-rotated presents (`vk_wsi_wayland_prerotate` driconf / env, 90/180/270: the
swapchain image is blitted, rotated, into a panel-oriented buffer at present time and committed
with the matching `wl_surface.set_buffer_transform`, re-sent on every present); it keeps the
modifier across feedback changes while doing so. Gallium's blit info learns a rotation, the util
blitter and freedreno implement it, DRI passes it through `dri2_blit_image`, and EGL's Wayland
platform gets the same optional pre-rotation (`egl_wayland_prerotate`).

What it is for: a board whose display plane cannot rotate (SM6115) otherwise pays a GPU composite
per frame in the compositor. With these the CLIENT rotates once at present, cheaply (a transfer
blit, `VK_QCOM_rotated_copy_commands` on Adreno), and a compositor that honours buffer transforms
(KWin, sway) scans the buffer out directly. ROCKNIX sets the two variables per board from
`prerotate_env` in its `001-functions`. Under gamescope the client side is NOT used: gamescope
rotates layers itself, and its own rotated-blit patches (`packages/gamescope`) use the same
`VK_QCOM_rotated_copy_commands` from `0002` here. Off unless the variable is set, so every
other board is unaffected. Applied cleanly on 26.2.4 (checked 2026-10-09).

## A610 registers from the stock blob (0014), added 2026-10-23

Mesa shares one register table (`a6xx_gen1_low`) between the A605 and the A610. 0014 gives the
A610 its own entry, using what the stock Android 14 driver (`Adreno610v1`) writes when it sets up
a context on the Air X. The values come from libwrap captures of a draw, a copy and a compute
dispatch, diffed against Turnip on drm-shim. In the table, TPL1_DBG_ECO_CNTL becomes 0x8000,
SP_CHICKEN_BITS 0x400 and UCHE_UNKNOWN_0E12 0x10000001. It adds the blob's writes of
UCHE_UNKNOWN_0E11, VFD_DBG_ECO_CNTL, RB_UNKNOWN_8E09 (0x4, the same value the A710 uses with one
CCU), SP_UNKNOWN_0CE2-0CE7 and RB_UNKNOWN_8A00-8A30. Two props change: `prim_alloc_threshold`
(3, the blob's value) and `highest_bank_bit` (14). The bank bit is only a fallback, since Turnip
asks the kernel, and every A610 SoC (SM6115, SM4250, SM6125) reports 14 there and in KGSL.

Left out on purpose: UCHE_CLIENT_PF, because the msm kernel sets it to 0x81 for its fault
handler and the blob's 0x4 would clear that. Also left out: values Turnip hardcodes for every A6XX
(TPL1_UNKNOWN_B605, GRAS_MODE_CNTL, TPL1_MODE_CNTL rounding), which would need code changes.
None of the new registers fall in the A610's CP protect list (`a630_protect`, kernel 7.2.11).
With 0014, Turnip's A610 init stream matches the blob for every register above.

**HW test still owed:** this was checked on drm-shim only. On the Air X, run a Vulkan title and a
GL one and watch for hangs or corruption.
