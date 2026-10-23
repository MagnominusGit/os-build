#!/usr/bin/env bash
# Offline test for zram's two algorithms: lz4 for what is swapped out, zstd for what then sits idle.
#
#   tests/test-zram.sh
#
# Rules: /usr/lib/retroforge/zram-recompress recompresses idle pages, then marks every page idle,
# on each zram device that is set up and has a second algorithm selected; it leaves alone a device
# not set up, one with no second algorithm selected, and one on a kernel without recompression; a
# failed recompression still marks the pages idle and says so. zram-generator.conf asks for
# `lz4 zstd(level=1)`; kernel.config builds both backends and recompression, and kernel/build.sh
# asserts them; the timer is enabled (preset and fallback link) and runs the script at idle priority.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
O="$ROOT/rootfs/overlay"
SCRIPT="$O/usr/lib/retroforge/zram-recompress"
CONF="$O/usr/lib/systemd/zram-generator.conf"
UNIT="$O/usr/lib/systemd/system/retroforge-zram-recompress"
for f in "$SCRIPT" "$CONF" "$UNIT.service" "$UNIT.timer"; do [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }; done

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

T="$(mktemp -d)" && [ -d "$T" ] || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT

zram() {  # zram <n> <initstate> [recomp_algorithm text]: a fake /sys/block/zram<n>
  local d="$T/sys/block/zram$1"
  mkdir -p "$d"; echo "$2" >"$d/initstate"
  [ $# -ge 3 ] && printf '%s\n' "$3" >"$d/recomp_algorithm"
  return 0
}

# ================================================================================================
CASE="script"
zram 0 1 "#1: lzo lzo-rle lz4 lz4hc [zstd] 842"
zram 1 0 "#1: lzo lzo-rle lz4 lz4hc [zstd] 842"
zram 2 1 "#1: lzo lzo-rle lz4 lz4hc zstd 842"
zram 3 1
ERR="$(RETROFORGE_SYS="$T/sys" sh "$SCRIPT" 2>&1)"; RC=$?
[ "$RC" = 0 ] && [ "$(cat "$T/sys/block/zram0/recompress")" = type=idle ] && [ "$(cat "$T/sys/block/zram0/idle")" = all ] \
  && ok "a device with its second algorithm: idle pages recompressed, then all marked idle" || bad "rc=$RC err=$ERR"
[ ! -e "$T/sys/block/zram1/recompress" ] && [ ! -e "$T/sys/block/zram1/idle" ] && ok "a device not set up is left alone" || bad "zram1 touched"
[ ! -e "$T/sys/block/zram2/recompress" ] && [ ! -e "$T/sys/block/zram2/idle" ] && ok "no second algorithm selected: left alone" || bad "zram2 touched"
[ ! -e "$T/sys/block/zram3/recompress" ] && [ ! -e "$T/sys/block/zram3/idle" ] && ok "a kernel without recompression: left alone" || bad "zram3 touched"
rm -rf "$T/sys"; zram 0 1 "#1: lz4 [zstd]"; mkdir "$T/sys/block/zram0/recompress"
ERR="$(RETROFORGE_SYS="$T/sys" sh "$SCRIPT" 2>&1)"; RC=$?
[ "$(cat "$T/sys/block/zram0/idle")" = all ] && grep -q "zram0: recompression failed" <<<"$ERR" \
  && ok "a failed recompression: pages still marked idle, and that is said" || bad "rc=$RC err=$ERR"
rm -rf "$T/sys"; mkdir -p "$T/sys/block"
ERR="$(RETROFORGE_SYS="$T/sys" sh "$SCRIPT" 2>&1)"; RC=$?
[ "$RC" = 0 ] && [ -z "$ERR" ] && ok "no zram device: nothing to do" || bad "rc=$RC err=$ERR"

CASE="configuration"
[ "$(sed -n 's/^compression-algorithm *= *//p' "$CONF")" = "lz4 zstd(level=1)" ] \
  && ok "zram-generator: lz4, then zstd level 1 to recompress" || bad "$(grep compression-algorithm "$CONF")"
for sym in ZRAM ZRAM_BACKEND_LZ4 ZRAM_BACKEND_ZSTD ZRAM_MULTI_COMP; do
  grep -qx "CONFIG_$sym=y" "$ROOT/kernel/kernel.config" && grep -q " $sym=y" "$ROOT/kernel/build.sh" \
    || { bad "CONFIG_$sym=y is not both in kernel.config and asserted by build.sh"; continue; }
  ok "CONFIG_$sym=y, and build.sh asserts it"
done
grep -qx "ExecStart=/usr/lib/retroforge/zram-recompress" "$UNIT.service" && grep -qx "CPUSchedulingPolicy=idle" "$UNIT.service" \
  && grep -qx "Nice=19" "$UNIT.service" && ok "the service runs the script at idle priority" || bad "$(cat "$UNIT.service")"
grep -qx "OnUnitActiveSec=10min" "$UNIT.timer" && grep -qx "WantedBy=timers.target" "$UNIT.timer" \
  && ok "the timer: every 10 minutes" || bad "$(cat "$UNIT.timer")"
grep -qx "enable retroforge-zram-recompress.timer" "$O/usr/lib/systemd/system-preset/60-retroforge-zram-recompress.preset" \
  && [ "$(readlink "$O/etc/systemd/system/timers.target.wants/retroforge-zram-recompress.timer")" = /usr/lib/systemd/system/retroforge-zram-recompress.timer ] \
  && ok "enabled: preset, and the fallback link" || bad "preset or link missing"
[ -x "$SCRIPT" ] && ok "the script is executable" || bad "not executable"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
