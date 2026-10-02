# rootfs/overlay — the unified rootfs overlay payload

Every SoC-agnostic file that qforge lays over the base rootfs lives here, in **one tree that
mirrors the target filesystem exactly**. `rootfs/assemble-rootfs.sh` injects it with a single
`cp -a rootfs/overlay/. "$stage/"` (the `overlay-payload` stage). The tree carries final paths, executable
bits (tracked in git), and the systemd presets + `*.target.wants` symlinks that enable each
service — so the assembler generates and `chmod`s nothing. Ownership is normalized to `root:root`
afterwards (the `overlay-ownership` stage).

Every file lands at a unique target path; the layers below are a way of reading the tree, not
separate trees.

## Layers (what each backing does, and why)

**Input — `etc/inputplumber/`** (part of every build)
InputPlumber's device/profile config: the union of every supported board's config. InputPlumber
matches by hardware, so non-matching configs are inert. It overrides the package's
`/usr/share/inputplumber` defaults ONLY via the `.d` dirs it scans under `/etc` — composite
configs in `devices.d/` and capability maps in `capability_maps.d/`. Do **not** rename them to the
un-suffixed `devices`/`capability_maps` (those apply only under `/usr/share`) or the configs load
from nowhere and no composite device is built. Enabled by a shipped
`usr/lib/systemd/system-preset/60-qforge.preset` (60 < the stock 99 "disable *") plus a
`multi-user.target.wants/inputplumber.service` symlink.

**Session — gamescope-session plumbing**
The boot-to-compositor path: launcher `/usr/bin/qforge-session` + its `/etc/qforge/session.conf`,
SDDM autologin wiring, PAM drop-ins, and `default.target -> graphical.target`. The device boots
through SDDM autologin, giving a REAL active `seat0` logind session (so stock polkit authorizes
Wi-Fi/timezone). `seatd.service` stays enabled as an unused fallback; gamescope takes the seat
through logind. The shell gamescope hosts is `QFORGE_SESSION_CMD` in `session.conf` (a `vkcube`
liveness placeholder until OpenGamepadUI lands), plus `QFORGE_GAMESCOPE_SHELL_ARGS` for the
gamescope flags that shell needs.

**HW-support — Qualcomm backings for handheld affordances**
`qforge-rest` (userspace "rest mode"/fake-suspend), the suspend engine (a `systemd-suspend.service`
drop-in redirects logind `Suspend()` into `qforge-suspend`; `qforge-powerbuttond` runs a
configurable short/long-press action, suspend and power-off by default), the power-policy daemon
`qforge-powerd`, the key-pairing agent `qforge-pairingd`, Bluetooth, and `systemd-timesyncd`.
All enabled via shipped presets + `*.target.wants` symlinks. No Wi-Fi resume hook ships (NM
re-associates unaided).

**Update and storage entry points**
`usr/bin/qforge-update` is the OS update client (RAUC), including its channel picker
(`channels` / `set-channel`); `usr/bin/qforge-format-sdcard` / `qforge-format-device` pkexec into
`usr/lib/qforge/storage/format-device.sh`. `50-qforge-timezone.rules` is the one polkit grant
stock polkit still prompts for.

**Audio — ALSA UCM2 machine profiles**
`usr/share/alsa/ucm2/Qualcomm/sm8{250,550,650}/<CARD>/` profiles, card-name-matched via relative
symlinks under `conf.d/sm8{250,550,650}/` (preserved by `cp -a`). They `Include` codec snippets that
the base `alsa-ucm-conf` package must provide (SM8550 uses wcd938x, SM8650 wcd939x, SM8250 wcd938x
plus wsa881x or AW88166 for speakers). One snippet is NOT in that package and ships here instead:
`ucm2/codecs/wsa881x/init.conf`, without which the two wsa881x amps expose no stereo `Speakers
Volume` control for the SM8250 profiles to bind to. The SM8250 boards also route through the legacy
q6asm/ADM path rather than AudioReach, and the AYN Thor Lite additionally needs
`usr/share/wireplumber/wireplumber.conf.d/51-ayn-thor-lite.conf` to pin its PCMs to S16LE — the ADM
COPP is a bit-exact passthrough and UCM has no key for the sample format.

DisplayPort audio on SM8250 is its own UCM verb, `ucm2/Qualcomm/sm8250/DisplayPort.conf`, never a
device in HiFi: with no display attached the ADSP refuses the DP port, and one PCM that cannot open
makes PipeWire reject the whole verb it sits in. The Retroid profile enables it; the Pocket Max
profile has it commented out, because probing it undocked delays sound by ~16 s at every boot. The
Pocket Max's `52-pocket-max-dp.conf` (S16LE, fixed periods, no mmap on `hw:PocketMax,3`) is dormant
until that verb returns.

**System hygiene — identity, memory, and the `/var` shape**
Four files that are not a subsystem but are load-bearing for the immutable A/B model, because on
this image `/etc/passwd` and `/var` are *build products* rather than device state:

- `usr/lib/sysusers.d/01-qforge-enforce-ids.conf` — pins every system UID/GID that
  `systemd-sysusers` would otherwise allocate by counting down from 999. Adding one package with a
  sysusers entry shifts every id below it, and the RAUC post-install hook copies `/var` wholesale
  across an update, so drifting ids reassign the ownership of persisted state. **This file is also
  read by `rootfs/customize-base.sh`**, which stages it into the target root *before* the pacman
  transaction — the pin only works if it is there when the sysusers hook runs. Its sha is in the
  base reuse key, and `rootfs/guard-rootfs.sh` assertion 8 checks the built tree against it. There
  is no end-of-line comment syntax in sysusers.d; a trailing `#` silently rejects the line.
- `usr/lib/tmpfiles.d/qforge-var.conf` — declares the `/var` hierarchy in the ROOT. A fresh flash
  gets `/var` from the build; an *updated* slot gets the previous version's `/var`, so a directory a
  new version needs has to be asserted at boot or it will not exist. New `/var` paths go here.
- `usr/lib/systemd/system/earlyoom.service.d/qforge.conf` — OOM policy: absolute thresholds
  (RAM spans 8–16 GB across supported SKUs, so percentages mean different headroom per unit),
  reports off (the default is one journal line per second, onto an SD card), and the session spine
  protected. Enabled by `60-qforge-earlyoom.preset` + a `multi-user.target.wants` symlink.
- `usr/lib/systemd/zram-generator.conf` — the image's only swap device, `ram/2` compressed in RAM.
  **Coupled to the kernel:** it needs `CONFIG_ZRAM` + the zstd backend, which `kernel/build.sh`
  asserts, because without them there is no `zram0`, no swap, and no error.
