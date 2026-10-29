#!/usr/bin/env bash
# run.sh <gog|epic> — on the device, as OGUI starts it from its library (store-signin-<store>.desktop):
# the sign-in window, then the code it printed signed in through the store helper's own sign_in(),
# as the LAN page's code is. Everything goes to <store>.log beside this script; the code itself never
# does (its length and first 4 characters only).
#
# run.sh <gog|epic> chromium: the real Chromium in app mode (chromium-signin.py) instead of Electron:
# Google refused its sign-in inside Electron (2026-10-28).
# run.sh <gog|epic> nogpu: Chromium without the GPU (--disable-gpu, CPU rendering). The first GPU run
# hard-reset the Air X (2026-10-28), like Flycast on Vulkan did.
# NO_SANDBOX=1 runs Chromium without its sandbox, to tell a sandbox failure from anything else.
# EXCHANGE=0 stops after the code, without signing in.
set -u
here="$(dirname "$(readlink -f "$0")")"
store="${1:-}"
case "$store" in gog|epic|google) ;;  # google: the google-direct diagnostic only
 *) echo "usage: run.sh <gog|epic>" >&2; exit 2 ;; esac
logf="$here/$store.log"
exec 2>>"$logf"
echo "=== $(date -Is) $store DISPLAY=${DISPLAY:-} WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}" >&2

# Chromium's sandbox: user namespaces, else the setuid chrome-sandbox (which cannot be setuid in /home).
if unshare --user --map-root-user true 2>/dev/null; then
  echo "sandbox: unprivileged user namespaces work" >&2
else
  echo "sandbox: unprivileged user namespaces refused ($(cat /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null || echo no knob))" >&2
fi
flags=(--ozone-platform=x11)
[ "${2:-}" = nogpu ] && flags+=(--disable-gpu) && echo "gpu: OFF (--disable-gpu)" >&2
sync  # the log so far survives a hard reset
[ "${NO_SANDBOX:-0}" = 1 ] && flags+=(--no-sandbox) && echo "sandbox: OFF (NO_SANDBOX=1)" >&2

start=$(date +%s)
if [ "${2:-}" = google-direct ]; then
  # Diagnostic: Google's own sign-in, full-screen, in the same Chromium, without Epic or its popup.
  # Google rejected the sign-in from Epic's popup after the password ("Something went wrong",
  # 2026-10-28); this tells the popup flow from the browser on this device.
  echo "browser: Chromium, Google direct (no Epic, no capture)" >&2
  profile="$(mktemp -d)"
  LD_LIBRARY_PATH="$here/lib" GSETTINGS_SCHEMA_DIR="$here/schemas" "$here/chromium/chromium" \
    --app="https://accounts.google.com/ServiceLogin?continue=https://myaccount.google.com/" \
    --user-data-dir="$profile" --ozone-platform=x11 --start-fullscreen --no-first-run \
    --no-default-browser-check --disable-sync --password-store=basic >&2
  echo "browser: exit $? (google-direct)" >&2; rm -rf "$profile"; exit 0
elif [ "${2:-}" = chromium-plain ]; then
  # Diagnostic: the same window without the DevTools pipe, so no code is captured. Tells whether
  # Cloudflare's loop on Epic comes from the pipe (2026-10-28).
  echo "browser: Chromium, plain (no DevTools pipe, no code capture)" >&2
  profile="$(mktemp -d)"
  LD_LIBRARY_PATH="$here/lib" GSETTINGS_SCHEMA_DIR="$here/schemas" "$here/chromium/chromium" \
    --app="https://www.epicgames.com/id/login" --user-data-dir="$profile" --ozone-platform=x11 \
    --start-fullscreen --no-first-run --no-default-browser-check --disable-sync --password-store=basic \
    >&2
  echo "browser: exit $? (plain)" >&2; rm -rf "$profile"; exit 0
elif [ "${2:-}" = chromium ]; then
  # Device scale: the screen's height over 720 (1.5 on 1080p, a 1280 x 720 page, about OGUI's own
  # 1280 x 800): at 2 the sign-in forms were taller than the 540-high page and scrolled. SCALE= overrides.
  height="$(xwininfo -root 2>/dev/null | sed -n 's/^ *Height: *//p')"
  scale="${SCALE:-$(python3 -I -c "print(round(${height:-1080} / 720, 2))")}"
  echo "browser: Chromium $(LD_LIBRARY_PATH="$here/lib" "$here/chromium/chromium" --version 2>/dev/null | cut -d' ' -f2), scale $scale (screen height ${height:-unknown})" >&2
  out="$(LD_LIBRARY_PATH="$here/lib" GSETTINGS_SCHEMA_DIR="$here/schemas" RF_SIGNIN_SCALE="$scale" \
         python3 -I "$here/chromium-signin.py" "$here/chromium/chromium" "$store")"
else
  out="$(LD_LIBRARY_PATH="$here/lib" GSETTINGS_SCHEMA_DIR="$here/schemas" "$here/electron/electron" "${flags[@]}" "$here/app" "$store")"
fi
rc=$?
echo "browser: exit $rc after $(( $(date +%s) - start )) s" >&2
[ "$rc" = 0 ] || exit "$rc"

code="$(python3 -I -c 'import json,sys; print(json.loads(sys.stdin.read())["code"])' <<<"$out")" || {
  echo "electron printed no code: ${out:0:200}" >&2; exit 1; }
echo "code: ${#code} characters, starts ${code:0:4}" >&2
[ "${EXCHANGE:-1}" = 1 ] || exit 0

python3 -I - "$store" "$code" >&2 <<'EOF'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("rf_store", "/usr/lib/retroforge/store")
spec = importlib.util.spec_from_loader("rf_store", loader)
store = importlib.util.module_from_spec(spec)
loader.exec_module(store)
try:
    print(f"signed in to {sys.argv[1]} as {store.STORES[sys.argv[1]]().sign_in(sys.argv[2])!r}")
except store.Failed as err:
    print(f"sign-in failed: {err}")
    sys.exit(1)
EOF
