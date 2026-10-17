#!/usr/bin/env bash
# Offline test for the image's sysctl drop-ins (rootfs/overlay/usr/lib/sysctl.d).
#
#   tests/test-sysctl.sh
#
# WHY THIS EXISTS. systemd-sysctl skips a line it cannot parse and goes on booting, so a typo turns a
# setting off without a word. Each drop-in must be key=value lines, and the settings a fix depends on
# must stay at the value it was measured with.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ROOT/rootfs/overlay/usr/lib/sysctl.d"

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

# value <key>: the value the drop-ins set for it, the last one read winning (systemd-sysctl order).
value() { cat "$DIR"/*.conf | sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" | tail -n1; }

CASE="syntax"
for f in "$DIR"/*.conf; do
  if grep -vE '^[[:space:]]*(#.*)?$' "$f" | grep -vqE '^-?[a-z0-9_.*/-]+[[:space:]]*=[[:space:]]*[^[:space:]].*$'; then
    bad "$(basename "$f"): a line is neither a comment nor key=value"
  else
    ok "$(basename "$f"): every line is a comment or key=value"
  fi
done

CASE="network"
[ "$(value net.ipv4.tcp_mtu_probing)" = 1 ] \
  && ok "tcp_mtu_probing=1: a connection whose full-size packets vanish retries smaller instead of timing out" \
  || bad "tcp_mtu_probing is '$(value net.ipv4.tcp_mtu_probing)', not 1"

echo
echo "test-sysctl: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
