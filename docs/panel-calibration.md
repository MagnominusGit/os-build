# Panel frame-length calibration

Some of our panels self-time their refresh from a DDIC frame-length word whose stock constants
land measurably off nominal — an Odin 3 measured **118.35 Hz** on its "120 Hz" mode. gamescope's
fps limiter divides the refresh by the target with integer floor, so a panel running *under*
nominal makes every cap land one divisor high: ask 30, get ~39.5 (real/3); ask 20, get ~23.7
(real/5). HW-diagnosed 2026-10-20 on an Odin 3 (Darksiders 2, fps limiter "not working").

The fix is ROCKNIX's: trim the panel until it scans **at or just above** nominal (never below —
below is the floor-division failure itself), per rate, per unit.

## Pieces

| piece | where | role |
|---|---|---|
| kernel knobs | `frame_len_<rate>` sysfs on the mipi-dsi device (patch `0533` for the Odin 3's ICNA3520) | live trim of the DDIC frame length, replayed by the driver on every panel init incl. resume |
| `retroforge_panel.py` + `panel-calibration` CLI | `/usr/lib/retroforge/` | measure the real rate (DRM vblank timestamps, no DRM master needed), run the trim loop, persist |
| `retroforge-panel-calibration.service` | preset-enabled oneshot | boot-time re-apply of persisted values; Condition-gated, a no-op on boards without knobs |
| `retroforge-paneld` | `org.retroforge.Panel1` on the system bus, D-Bus activated | the root side of the quick bar: `Status(b measure)` and `Calibrate()`, each the module's JSON; exits when idle |
| Quick bar > Hardware | plugin `hardware_card.gd` + `panel_client.gd` | the measured rate under Backlight on every board; calibration state and a Calibrate button where the knobs exist |

## Rules of the design

- **No calibration at boot.** Measuring and stepping the DDIC is operator-triggered: the quick
  bar's Calibrate button (Hardware card), or `/usr/lib/retroforge/panel-calibration calibrate` as
  root over SSH. Boot only re-applies.
- **Root over D-Bus, not sudo.** The knobs and the state file are root's; the shell is player.
  `retroforge-paneld` does the work, and its bus policy lets `wheel` (player) call it, like
  `org.retroforge.Power`. A measurement or calibration while another one runs is refused
  (`Error.Busy`), never queued: an extra vblank waiter would jitter the running calibration.
- **Stamped to the unit.** `/var/lib/retroforge/panel-calibration.json` is keyed by the SoC
  serial; two boards of the same model hold separate entries, and a card moved to a unit that
  never calibrated applies nothing there.
- **Calibrates the rate the panel is scanning now.** gamescope owns mode choice; to calibrate
  the other rate, switch the refresh rate and run `calibrate` again.

## Adding a board

Ship the kernel-side knob in that board's panel driver (hoist the frame-length words out of the
init sequence into per-mode fields with `frame_len_*` sysfs, defaults = the old constants — see
patch 0533, or ROCKNIX's RP6/Thor equivalents). Everything above keys on the attributes
existing, so no userspace change is needed.

Offline coverage: `tests/test-panel-calibration.sh` (convergence policy, serial stamping,
failure restore, and `retroforge-paneld` live on a private bus: replies, Busy, failures, idle
exit) and the `panel client` case of `tests/test-plugin.sh` (the card's busctl against that
daemon), in `make test`.
