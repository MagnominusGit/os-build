# Kernel config and cmdline tuning for the SM6115 (MANGMI Air X) — report

Status: review done 2026-10-24 on branch `claude/kernel-tuning-7b4d5c`. Three low-risk changes are
committed (below); nothing is built, flashed or changed on the device. The rest needs a decision or a
hardware A/B.

Device: Air X MQ66, kernel 7.2.11 (`/proc/config.gz`, built 2026-10-24 01:24 UTC), up ~7 h with an OGUI
session plus Steam/Proton games (Hades, GRIP) run by other sessions. Cmdline read from `/proc/cmdline`.
All measurements are read-only: `/sys`, `/proc`, the journal, and short ftrace runs in private trace
instances (`instances/kt-*`, removed afterwards). The one load generated was a direct read of the SD
card (no page cache) and a 40 MB transfer to `/dev/null` over SSH. Function-graph timings include the
tracer's own overhead, so per-call numbers are upper bounds; ratios between them hold.

Comparison: ROCKNIX `projects/ROCKNIX/devices/SM6115/linux/linux.aarch64.conf` (local
`~/Documents/GitHub/distribution`) and postmarketOS `linux-postmarketos-qcom-sm6115` (6.10).

## Committed (low risk)

| Commit | Change | Scope |
|---|---|---|
| be0fc47 | `CONFIG_PREEMPT=y` pinned, `CONFIG_PREEMPT_DYNAMIC=y` | all boards; no behaviour change by default |
| bad7a19 | `audit=0` in `BOOT_CMDLINE` (both generators) | all boards |
| 6abd0e2 | `iommu.strict=0 swiotlb=4096` on the four SM6115 rows of `boot/boards.map` | Air X MQ65/MQ66/MQ66B, Air Y |

`tests/test-stage2-grub.sh` (413 ok) and `tests/test-mkimage.sh` (64 ok) pass. None of it is built: the
kernel config change needs a rebuild on the buildbox; the cmdline changes ride in the next image/OTA.

## Knob by knob

### IOMMU (arm-smmu, Qualcomm MMU-500)
- **Current:** `CONFIG_IOMMU_DEFAULT_DMA_STRICT=y`; dmesg `DMA domain TLB invalidation policy: strict mode`.
- **Who it affects (iommu_groups):** DMA-API devices only: sdhc_1 eMMC (4744000), sdhc_2 SD (4784000),
  USB (4e00000), Wi-Fi WCN3950 (c800000), venus (5a00000), QUP (4ac0000), GPI DMA + crypto, the ADSP/CDSP
  fastrpc banks. **The GPU (5900000) and the display (5e00000) are `identity` groups**:
  `qcom_smmu_def_domain_type()` bypasses `qcom,adreno` and `qcom,sm6115-mdss`, and drm/msm runs its own
  page tables and invalidations. So strict vs lazy changes nothing for rendering or scanout.
- **Evidence:** strict unmap = page-table clear + TLBI + `qcom_smmu_tlb_sync`.
  SD, 8,704 direct reads: 9,336 unmaps, median 7.3 us (sync 1.8 us), ~4% of cpu0 at 4K IOPS.
  Wi-Fi receive of 40 MB: 27,653 packets, 89,004 unmaps (3.2 per packet), 865 ms of unmap in 27 s, of
  which 233 ms TLB sync — ~3% of a core at only ~12 Mbit/s, so a fast Steam download pays several times
  that. arm-smmu advertises `IOMMU_CAP_DEFERRED_FLUSH`, so lazy gives these groups a DMA-FQ domain.
- **Recommendation:** lazy on SM6115 — **committed** as `iommu.strict=0` on the SM6115 rows (ROCKNIX's
  SM6115 config has `IOMMU_DEFAULT_DMA_LAZY=y`; its SM8xxx configs and pmOS stay strict).
  Expected: fewer CPU cycles in SD and Wi-Fi completion paths (mostly cpu0); no FPS change except while
  streaming assets or downloading.
- **Risk:** low. For up to the flush-queue timeout, a device can still reach a buffer it just unmapped
  (the WCN3950 firmware, the SD/USB controllers). External-facing PCI devices stay strict regardless.
  ~1 MB for the per-CPU flush queues. Verify after boot: `grep . /sys/kernel/iommu_groups/*/type` shows
  `DMA-FQ` for the groups above.

### swiotlb (memory)
- **Current:** default 64 MB pool (`software IO TLB: mapped ... (64MB)`), reserved at boot.
- **Evidence:** `/sys/kernel/debug/swiotlb/io_tlb_used_hiwater` = **2 slabs (4 KB)** after 7 h of SD, USB,
  Wi-Fi and games. Every DMA master sits in an IOMMU group (the GPU and display in identity ones). What
  still bounces is small unaligned kmalloc buffers for non-coherent devices
  (`DMA_BOUNCE_UNALIGNED_KMALLOC`).
- **Recommendation:** `swiotlb=4096` (8 MB, 8 areas of 512 slabs) — **committed** on the SM6115 rows.
  Returns 56 MB to the page allocator on a 3.5 GB device that hits the kernel OOM killer (below).
- **Risk:** low. If a future driver ever bounces more than 8 MB at once, mappings fail with
  `swiotlb buffer is full`. Watch `io_tlb_used_hiwater`.

### Audit
- **Current:** `CONFIG_AUDIT=y`, initialised with `audit_enabled=0`. systemd 260's journald defaults to
  `Audit=yes` and switches it on; auditd is installed but disabled.
- **Evidence:** ~2,970 `audit:` records in this boot's kernel log, `SYSCALL` records included. Each task
  forked after journald gets an audit context, so every syscall takes the audited entry/exit path. kmsg
  was so full that `dmesg` began at uptime 24,422 s: the boot log only survives in the journal.
- **Recommendation:** `audit=0` — **committed** for all boards. The subsystem never initialises, so
  journald has nothing to switch on. ROCKNIX does not set it; it is free to drop.
- **Risk:** low. Loses kernel audit records, which nothing on the image consumes. loginuid/PAM still work.

### Preemption model
- **Current:** `CONFIG_PREEMPT=y` (full), inherited from the arm64 defconfig; no `PREEMPT_DYNAMIC`.
- **Evidence:** in 7.2 the choice defaults to `PREEMPT_LAZY` when unset (`kernel/Kconfig.preempt`), and
  `PREEMPT_VOLUNTARY` no longer exists on arm64. Lazy leaves a waking SCHED_OTHER thread behind the running
  task until the next tick or return to user — up to 4 ms at HZ=250. ROCKNIX SM6115 has
  `PREEMPT_DYNAMIC=y`; pmOS is full without it.
- **Recommendation:** keep full; pin it and add `PREEMPT_DYNAMIC` — **committed**. `preempt=lazy` then
  becomes a cmdline A/B with no rebuild (`/sys/kernel/debug/sched/preempt` shows the mode).
- **Risk:** low. arm64 switches with static keys.

### HZ
- **Current:** `CONFIG_HZ=250` (ROCKNIX and pmOS too).
- **Evidence:** ondemand cannot sample faster than two ticks (`CPUFREQ_DBS_MIN_SAMPLING_INTERVAL`,
  `cpufreq_governor.c:22`). Both policies sit at `sampling_rate=8000`, and lower writes are rejected. A
  load step therefore waits 8–16 ms for a frequency change: up to a whole 60 fps frame. EEVDF's 2.8 ms
  base slice is only enforced at tick granularity (`NO_HRTICK`), i.e. 4 ms.
- **Recommendation:** **not committed.** Test `HZ=1000` only if ondemand stays the governor. If schedutil
  wins the A/B below, HZ matters much less (it updates from scheduler events, not a 2-tick timer).
- **Risk:** medium. All boards; ~1000 timer interrupts/s per busy CPU (a few tenths of a percent on an
  A53), with some battery cost.

### cpufreq governor, EAS, sched_ext
- **Current:** powerd sets `ondemand` (up_threshold 95, sampling 8 ms) with `sched_energy_aware` off;
  sched_ext off (`RETROFORGE_CPU_SCHEDULERS=none`: scx_lavd put a game thread on the A53s, 76-86% missed
  deadlines). EAS with schedutil measured 95% missed frames on the Air X (power.conf).
- **New evidence — every ondemand frequency change blocks ~1 ms on the RPM.** `qcom_cpufreq_hw_target_index()`
  writes the perf state, then `qcom_cpufreq_set_bw()` → `dev_pm_opp_set_opp()` → `icc_set_bw()` → a
  **synchronous SMD-RPM write** for the CPU-DDR vote. Traced at idle UI over 3 s:
  | voter | rate | median | p90 | max |
  |---|---|---|---|---|
  | little policy (cpu0) | 83/s | 995 us | 1.5 ms | 4.4 ms |
  | big policy (cpu4) | 27/s | 1.1 ms | 2.3 ms | 7.9 ms |
  | CPU bwmon IRQ thread | 21/s | 739 us | 1.3 ms | 1.5 ms |
  | GPU devfreq | 14/s | 414 us | 739 us | 1.7 ms |

  They share one SMD channel, so GPU and SD votes queue behind the CPU ones. glink-rpm interrupts:
  ~456/s at idle, all on cpu0. **schedutil's fast-switch path (`qcom_cpufreq_hw_fast_switch`) writes the
  register and makes no bandwidth vote**: no kworker, no RPM round trip. DDR bandwidth is then left to
  the bwmon and the GPU's own votes.
- **Recommendation:** A/B on the Air X: schedutil with EAS off vs ondemand, frame-time capture on two
  titles (Hades + one native), and glink-rpm/s logged. Pick by frame time. If ondemand wins, try HZ=1000
  with it. Keep sched_ext off on this SoC until a scheduler with big.LITTLE-aware placement measures
  better. This is a powerd setting, not a kernel change.
- **Risk:** low to test (runtime governor switch), but it changes the device's state for other sessions,
  so it needs your OK. Medium to ship: it reverses an earlier measured choice.

### Spectre/Meltdown mitigations
- **Current:** `ssbd=force-off kpti=off` (ROCKNIX parity); Meltdown not affected. `spectre_v2: Mitigation:
  Branch predictor hardening, but not BHB` — on the Kryo-260 Gold (A73) cores that is a firmware SMC on
  every mm switch (`arch/arm64/mm/context.c:263`) and on some EL0 aborts.
- **Recommendation:** optional `nospectre_v2` on the SM6115 rows. **Not committed:** it is a security
  policy call, and the gain is unmeasured (estimated well under 1% of a big core).
- **Risk:** medium (security: cross-process branch-target injection becomes possible).

### MGLRU, `min_ttl_ms`, and the kernel OOM killer — **the largest problem found**
- **Current:** MGLRU on. `lru_gen/enabled=0x0001`: ARMv8.0 has no hardware access flag, so the MMU walk
  is not used here. `LRU_GEN_WALKS_MMU` is inert on this SoC. `min_ttl_ms=1000` comes from
  `/usr/lib/tmpfiles.d/retroforge-mm.conf` (f9e40e9, "as ChromeOS sets it").
- **Evidence:** 16 kernel OOM-killer runs this boot, every one `kswapd0 invoked oom-killer:
  gfp_mask=0xcc0(GFP_KERNEL), order=0` — MGLRU's thrashing guard calling `out_of_memory()` from kswapd.
  Free swap was 1.8–2.5 GB at each, so zram was not full. RAM was ~1.3–1.7 GB unevictable (GPU GEM
  buffers) plus compressed zram. The guard fires long before earlyoom's thresholds, which is why
  earlyoom never acts. At 24,393 s it killed wireplumber, pipewire-pulse, pipewire, tailscaled, at-spi,
  dbus-broker; retroforge-session failed and restarted. The game, `Grip-Win64-Ship` (265 MB rss + 1.1 GB
  swap), survived. It ran at **oom_score_adj 0**, while the session's user services run at **200**. +200
  is worth ~365k pages of badness against the game's ~356k. Hand-over with details:
  `side-session-notes/.../airx-kernel-oom-victims.md`.
- **Recommendation (your decision, not committed):** either
  1. keep `min_ttl_ms=1000` and fix victim choice: every launch path sets the game to 900 (this one did
     not — the store/direct path), and the session spine (pipewire, wireplumber, dbus-broker) gets a
     lower OOMScoreAdjust than 200; or
  2. set `min_ttl_ms=0` and make earlyoom able to fire. Its `-S 400 MB` free-swap condition never holds
     with a RAM-sized zram, so it needs a swap percentage or no swap condition.

  Option 1 keeps the thrash protection and fixes the victim choice behind both killers. It touches
  launch and session units, not the kernel.
- **Also seen:** 8 order-0 `page allocation failure`s in `swap_cluster_alloc_table()` during reclaim
  (GFP_KERNEL|__GFP_HIGH|__GFP_NOMEMALLOC). That is the 7.2 swap-table allocation failing under pressure;
  check a later 7.2.y for a fix before the next bump.

### Transparent huge pages
- **Current:** PMD THP `madvise`, defrag `madvise`, shmem `never`. 64 KB mTHP for anon set to `always` by
  `retroforge-mm.conf` (measured on SM8550). msm GEM uses its own `within_size` huge mount (patch 0220,
  `msm.transparent_hugepage=Y`).
- **Evidence (Air X, page-granular random chase, one process opted out with `PR_SET_THP_DISABLE`):**
  | core | working set | 64 KB mTHP on | off |
  |---|---|---|---|
  | A73 | 16 MB (L2-resident lines, TLB-bound) | 18 ns/load | 36 ns |
  | A53 | 16 MB | 45 ns | 78 ns |
  | A73 / A53 | 128 MB (DRAM-bound) | 201 / 215 ns | 219 / 221 ns |

  Both cores honour contiguous PTEs. Faulting in 128 MB: 21 vs 61 ms (A73), 28 vs 118 ms (A53). Bloat
  is small: 775 live 64 KB folios, 152 partially mapped.
- **Recommendation:** keep everything as is.

### zram and swappiness
- **Current:** zram0 = RAM size (3.5 GB), `zstd(level=1)`, prio 100; `swappiness=180`, `page-cluster=0`,
  `watermark_scale_factor=125`, `watermark_boost_factor=0`, `min_free_kbytes=45056`.
- **Evidence:** `mm_stat` now 149 MB stored in 60 MB; max used 1.1 GB. `huge_pages_since=797,459`: ~3 GB of
  incompressible pages went in raw over the boot. They save nothing in zram. They are likely evicted GPU
  buffers (`msm.enable_eviction=Y`) and already-compressed game data.
- **Recommendation:** keep (zstd(1) is already the measured choice for Hades). No writeback device
  exists, so incompressible pages have nowhere better to go.

### cpuidle
- **Current:** TEO (`cpuidle.governor=teo`); PSCI OSI mode; per-CPU power collapse at 621 us (A53) /
  666 us (A73) exit latency, 1.1–1.2 ms target residency, plus cluster states.
- **Evidence:** too-deep (`above`) ratio cpu0 50%, cpu3 20%, cpu4 27%, cpu7 29%. cpu0 rarely sleeps deeply
  because it takes every device IRQ.
- **Recommendation:** keep TEO.

### PSI
- **Current:** `CONFIG_PSI=y`, on by default.
- **Evidence:** 16 PSI trigger fds are open, held by systemd components (PID 1, the user manager,
  journald, logind, resolved, networkd, homed, ...) that release memory under pressure.
- **Recommendation:** keep. Turning it off would remove the memory-pressure reactions they already make.

### IRQ placement
- **Current:** no irqaffinity, no irqbalance. Every device IRQ lands on cpu0 (an A53): gpu-irq, MDSS
  vblank, WLAN_CE, SD, USB, the gamepad MCU UART (~249/s) and glink-rpm (~456/s).
- **Evidence:** cpu0 hard-IRQ time 1,672 s vs ~590 s for cpu1-3 and ~250 s for the A73s over 7 h.
- **Recommendation:** a userspace experiment, not a kernel change. Pin gpu-irq + MDSS to cpu3 (ROCKNIX)
  or to cpu1-3, and measure frame-time variance against the default. Not done: it changes the device.

### Memory carve-outs (DT), for later
- 295 MB is `no-map` reserved-memory. Candidates: the 15 MB + 1 MB splash/dfps regions at 0x5c000000
  (unused once msm DRM owns the display) and 2x30 MB for the CDSP, if nothing on the image needs the CDSP.
  High risk (firmware may touch them; a wrong removal does not boot), so: investigate only.

### Small things
- `nosoftlockup` is an unknown parameter on this kernel (`SOFTLOCKUP_DETECTOR` is off), so it is passed
  to init. Harmless; drop it at the next cmdline edit.
- `NR_CPUS=512` (pmOS uses 8) and `NUMA=y` on a one-node SoC (`numa_balancing=0` at runtime): tiny static
  memory and indirection costs, not worth a change in the unified kernel.
- Already good: `cgroup.memory=nokmem,nosocket`, RCU NOCB + LAZY, `TRANSPARENT_HUGEPAGE_MADVISE`, BTF for
  sched_ext, KFENCE/KASAN/lockdep off.

## Recheck, 2026-10-24 21:55 (same boot, up 18 h, no game running)
The first round ran while games were starting and stopping, so every benchmark was repeated in a known
state (OGUI idle, MemAvailable 2.5 GB, three 5 s samples each):

| measurement | first round | recheck |
|---|---|---|
| CPU freq changes | ~110/s | 117–124/s (policy0 68–74, policy4 45–52) |
| RPM vote per change, median / p90 | 1.0–1.1 / 1.5–2.3 ms | 1.18–1.28 / 1.70–1.87 ms |
| kworker time blocked on those votes | ~120 ms/s | 145–150 ms/s |
| glink-rpm IRQs | 456/s | 606–629/s |
| SD 4K direct read: unmap / sync median | 7.3 / 1.8 us | 7.1–7.4 / 1.8 us (~3.8% of a core at ~4,300 IOPS) |
| Wi-Fi: unmaps per packet, unmap time per packet | 3.2, 31 us | 3.3, 36 us (sync 27%) |
| swiotlb high-water | 2 slabs | 2 slabs (18 h) |
| 64 KB mTHP, 16 MB chase A73 / A53 | 18 vs 36 / 45 vs 78 ns | 15–16.5 vs 32–33 / 41–43 vs 77 ns |
| cpuidle too-deep ratio cpu0 / A73s | 50% / 27–29% | 47–67% (15 entries) / 21–37% |

Everything repeats within ~20%. Two things moved since the first round: 19 kernel OOM runs now (16 then),
and the last three, at 21:35, 21:38 and 21:44, killed `Grip-Win64-Ship` rather than the session. The
victim fix on `steam-armv8-proton` (f270ba3, 06ebb7d) is doing its job, and GRIP still does not fit in RAM.
Audit records grow by ~10 per SSH login (6,536 now).

## Does it apply to the other SoCs?
Fleet: SM8250 (Kryo 585 = A77 + A55, ARMv8.2), SM8550 / SM8650 (Cortex-X/A7xx/A5xx, ARMv9), SM8750
(Oryon), SM6115 (Kryo 260 = A73 + A53, ARMv8.0). Only the Air X was measured; "expected" below is
reasoning from the code, not a measurement.

| change | SM6115 | SM8250 | SM8550 / SM8650 | SM8750 |
|---|---|---|---|---|
| `audit=0` (committed) | yes | yes | yes | yes — same systemd/journald on every board |
| full preempt pinned + `PREEMPT_DYNAMIC` (committed) | yes | yes | yes | yes — one unified kernel |
| OOM victim fix (on `steam-armv8-proton`) | yes | yes | yes | yes — userspace; min_ttl fires less with 8–16 GB |
| `iommu.strict=0` (committed for SM6115) | measured | expected to help more: UFS and PCIe Wi-Fi (ath11k) run far higher I/O rates than SD | same, plus ath12k Wi-Fi 7 and the PCIe USB3 hub | same arm-smmu; expected |
| `swiotlb=4096` (committed for SM6115) | measured | same 64 MB pool, under 1% of 8+ GB; check `io_tlb_used_hiwater` first (PCIe devices) | same | same |
| ondemand's ~1 ms bandwidth vote per freq change | measured (SMD-RPM) | votes go through RPMh, expected to be tens of us | RPMh, same | unknown (SCMI/EPSS) — trace `icc_set_bw` on one board |
| HZ=1000 (proposal) | ondemand's 8 ms floor | same floor | same | same |
| `kpti=off` | already set | **probably KPTI is ON**: A77/A55 have no E0PD, so KASLR forces it (`cpufeature.c:1883`); check `dmesg \| grep -i isolation` and add `kpti=off` to the SM8250 rows if so | no: ARMv9 has E0PD | no |
| `nospectre_v2` (proposal) | firmware SMC per mm switch on the A73s | the A77 mitigates in hardware (CSV2), the A55 is unaffected | same (CSV2) | same — nothing to gain |
| 64 KB mTHP (kept) | measured here | measured on SM8550 originally | same | expected |
| MGLRU MMU walk | inert (no hardware access flag) | active (ARMv8.2 HAFDBS) | active | active |
| IRQ placement | all on cpu0, no irqaffinity | none set either | `irqaffinity=0-2` / `0-1` already | `irqaffinity=0-1` already |
| DT carve-outs | SM6115 only | — | — | — |

## Next steps (each needs your OK)
1. Build the kernel on the buildbox with be0fc47 (`~/retroforge-steamtest`), and the image with bad7a19
   and 6abd0e2.
2. Flash/OTA the Air X and reboot. Check: `/proc/cmdline` has `audit=0 iommu.strict=0 swiotlb=4096`;
   dmesg shows `lazy mode` and `(8MB)`; iommu groups show `DMA-FQ`; `/sys/kernel/debug/sched/preempt` reads
   `(full)`; no `audit:` lines.
3. Decide the OOM policy (option 1 or 2 above).
4. Governor A/B (schedutil + EAS off vs ondemand) on the Air X, then HZ=1000 if ondemand stays.
