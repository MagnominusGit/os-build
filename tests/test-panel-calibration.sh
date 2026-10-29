#!/usr/bin/env bash
# Offline check for the panel frame-length calibration library
# (rootfs/overlay/usr/lib/retroforge/retroforge_panel.py).
#
#   tests/test-panel-calibration.sh
#
# WHY THIS EXISTS. The calibration loop's whole job is a convergence policy — settle AT OR ABOVE
# nominal, never below, because a panel under nominal is exactly the gamescope floor-division
# failure the feature fixes — and policies regress silently: a flipped comparison still exits 0
# and "calibrates" every unit 0.2 Hz slow. The per-unit serial stamping is the other sharp edge:
# a card moved between two boards must never apply one unit's trim to the other. Both are pure
# decision logic, so this drives the REAL module against a fabricated sysfs and a simulated
# panel (rate as a linear function of the frame-length knob) and asserts on the answers.
#
# NOT covered here: the DRM vblank measurement (needs a live display — the ioctl path is
# exercised on hardware by `panel-calibration status`) and the sysfs knob's kernel-side
# range clamping.
#
# Runs on the host with no root and no device.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$ROOT/rootfs/overlay/usr/lib/retroforge"

[[ -f $LIB_DIR/retroforge_panel.py ]] || { echo "retroforge_panel.py missing: $LIB_DIR" >&2; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Keep import bytecode out of rootfs/overlay/ (same trap as test-perf.sh: the assembler copies
# the tree verbatim).
export PYTHONPYCACHEPREFIX="$TMP/pycache"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1" >&2; }

run_py() { python3 - "$@" <<PYEOF
import json, os, sys
sys.path.insert(0, "$LIB_DIR")
import retroforge_panel as np

$PY_BODY
PYEOF
}

# --- fabricated panel: one mipi-dsi device with 120/60 knobs, plus a knobless neighbour
SYS="$TMP/sys"
mkdir -p "$SYS/ae94000.dsi.0" "$SYS/ae94000.dsi.1"
echo 76 > "$SYS/ae94000.dsi.0/frame_len_120"
echo 2006 > "$SYS/ae94000.dsi.0/frame_len_60"
printf 'SERIAL-A\0' > "$TMP/serial"

export RETROFORGE_PANEL_SYSFS_GLOB="$SYS/*"
export RETROFORGE_PANEL_STATE="$TMP/state/panel-calibration.json"
export RETROFORGE_PANEL_SERIAL="$TMP/serial"

# ---------- knob discovery + serial + status (unmeasured) ----------
PY_BODY='
dev, knobs = np.panel_knobs()
assert dev.endswith("ae94000.dsi.0"), dev
assert sorted(knobs) == [60, 120], knobs
assert np.device_serial() == "SERIAL-A", np.device_serial()
s = np.status(measure=False)
assert s["supported"] is True
assert s["rates"] == [60, 120]
assert s["current"] == {"120": 76, "60": 2006}, s["current"]
assert s["saved"] == {}
assert s["measuredHz"] is None
print("ok")
'
[[ $(run_py) == ok ]] && ok || fail "knob discovery / status"

# ---------- nominal inference ----------
PY_BODY='
assert np.infer_nominal(118.35, [60, 120]) == 120   # the Odin 3 field case
assert np.infer_nominal(59.97, [60, 120]) == 60
assert np.infer_nominal(90.0, [60, 120]) is None    # between modes: refuse, do not guess
assert np.infer_nominal(50.0, []) is None
print("ok")
'
[[ $(run_py) == ok ]] && ok || fail "nominal inference"

# ---------- calibration converges from BELOW nominal and settles at-or-above ----------
# Simulated panel: 0.05 Hz per knob count, stock value 76 scans 118.4 Hz (the measured Odin 3
# shape). Lower frame length -> faster. The fake clock advances on every sleep and measure.
PY_BODY='
class Panel:
    def __init__(self, stock, stock_hz, slope, knob):
        self.stock, self.stock_hz, self.slope, self.knob = stock, stock_hz, slope, knob
        self.t = 0.0
    def rate(self):
        self.t += np.MEASURE_S
        value = int(open(self.knob).read())
        return self.stock_hz + (self.stock - value) * self.slope
    def sleep(self, s):
        self.t += s
    def clock(self):
        return self.t

knob = np.panel_knobs()[1][120]
panel = Panel(76, 118.4, 0.05, knob)
result = np.calibrate(rate_fn=panel.rate, sleep=panel.sleep, clock=panel.clock)
assert result["rate"] == 120, result
final = int(open(knob).read())
assert final == result["value"], (final, result)
hz = panel.stock_hz + (panel.stock - final) * panel.slope
assert 0 <= hz - 120 <= np.tolerance_for(120), hz   # AT OR ABOVE nominal, never below
state = json.load(open(os.environ["RETROFORGE_PANEL_STATE"]))
assert state["SERIAL-A"]["120"] == final, state
print("ok")
'
[[ $(run_py) == ok ]] && ok || fail "calibration convergence from below"

# ---------- calibration from ABOVE nominal, 60 Hz knob, tighter tolerance ----------
PY_BODY='
knob = np.panel_knobs()[1][60]
class Panel:
    t = 0.0
    def rate(self):
        Panel.t += np.MEASURE_S
        return 60.9 + (2006 - int(open(knob).read())) * 0.01
    def sleep(self, s):
        Panel.t += s
    def clock(self):
        return Panel.t
p = Panel()
result = np.calibrate(rate_fn=p.rate, sleep=p.sleep, clock=p.clock)
assert result["rate"] == 60, result
hz = 60.9 + (2006 - result["value"]) * 0.01
assert 0 <= hz - 60 <= np.tolerance_for(60), hz
state = json.load(open(os.environ["RETROFORGE_PANEL_STATE"]))
assert state["SERIAL-A"]["60"] == result["value"]
assert state["SERIAL-A"]["120"] is not None   # the earlier rate survives the merge
print("ok")
'
[[ $(run_py) == ok ]] && ok || fail "calibration convergence from above (60 Hz)"

# ---------- an unreachable target restores the stock value and raises ----------
PY_BODY='
knob = np.panel_knobs()[1][120]
open(knob, "w").write("76")
class Panel:                       # knob has no effect: a broken DDIC never settles
    t = 0.0
    def rate(self):
        Panel.t += np.MEASURE_S
        return 110.0
    def sleep(self, s):
        Panel.t += s
    def clock(self):
        return Panel.t
p = Panel()
try:
    np.calibrate(rate_fn=p.rate, sleep=p.sleep, clock=p.clock, deadline_s=30.0)
except RuntimeError:
    assert int(open(knob).read()) == 76   # restored, not left at the last wild guess
    print("ok")
'
[[ $(run_py) == ok ]] && ok || fail "failure restores the stock value"

# ---------- a rate matching no knob refuses instead of guessing ----------
PY_BODY='
class Panel:
    t = 0.0
    def rate(self):
        Panel.t += np.MEASURE_S
        return 90.0
    def sleep(self, s):
        Panel.t += s
    def clock(self):
        return Panel.t
p = Panel()
try:
    np.calibrate(rate_fn=p.rate, sleep=p.sleep, clock=p.clock)
    print("no-error")
except RuntimeError as e:
    assert "matches no calibratable rate" in str(e), e
    print("ok")
'
[[ $(run_py) == ok ]] && ok || fail "unmatchable rate refuses"

# ---------- the display going away mid-run restores the stock value too ----------
# NoDisplay is not an OSError: a screen that blanks during a calibration must not leave the
# trial value scanning (only saved values are re-applied at boot).
PY_BODY='
knob = np.panel_knobs()[1][120]
open(knob, "w").write("76")
class Panel:
    t = 0.0
    n = 0
    def rate(self):
        Panel.t += np.MEASURE_S
        Panel.n += 1
        if Panel.n > 3:
            raise np.NoDisplay("no CRTC answers")
        return 118.4 + (76 - int(open(knob).read())) * 0.05
    def sleep(self, s):
        Panel.t += s
    def clock(self):
        return Panel.t
p = Panel()
try:
    np.calibrate(rate_fn=p.rate, sleep=p.sleep, clock=p.clock)
    print("no-error")
except np.NoDisplay:
    assert int(open(knob).read()) == 76, open(knob).read()
    print("ok")
'
[[ $(run_py) == ok ]] && ok || fail "a blank screen mid-run restores the stock value"

# ---------- apply: this unit's values land, another unit's never do ----------
PY_BODY='
knobs = np.panel_knobs()[1]
open(knobs[120], "w").write("76")
open(knobs[60], "w").write("2006")
json.dump({"SERIAL-A": {"120": 48, "60": 1996}, "SERIAL-B": {"120": 999}},
          open(os.environ["RETROFORGE_PANEL_STATE"], "w"))
applied = np.apply_saved()
assert applied == {"120": 48, "60": 1996}, applied
assert int(open(knobs[120]).read()) == 48
assert int(open(knobs[60]).read()) == 1996
print("ok")
'
[[ $(run_py) == ok ]] && ok || fail "apply writes this unit's values"

# ---------- apply on the OTHER unit: nothing written (the stamped-to-device contract) ----------
PY_BODY='
open(os.environ["RETROFORGE_PANEL_SERIAL"], "wb").write(b"SERIAL-C\x00")
knob = np.panel_knobs()[1][120]
open(knob, "w").write("76")
applied = np.apply_saved()
assert applied == {}, applied
assert int(open(knob).read()) == 76
print("ok")
'
[[ $(run_py) == ok ]] && ok || fail "apply is inert on a different unit"

# ---------- no knobs: status degrades, calibrate refuses ----------
PY_BODY='
os.environ["RETROFORGE_PANEL_SYSFS_GLOB"] = os.environ["RETROFORGE_PANEL_SYSFS_GLOB"].replace("*", "ae94000.dsi.1")
s = np.status(measure=False)
assert s["supported"] is False and s["rates"] == []
try:
    np.calibrate(rate_fn=lambda: 120.0)
    print("no-error")
except RuntimeError as e:
    assert "no frame_len" in str(e), e
    print("ok")
'
[[ $(run_py) == ok ]] && ok || fail "knobless board degrades cleanly"

# ---------- the CLI wrapper emits JSON and the right exit codes ----------
CLI="$LIB_DIR/panel-calibration"
out=$("$CLI" status --quick) && echo "$out" | python3 -c 'import json,sys; s=json.load(sys.stdin); assert s["supported"] is True' && ok || fail "CLI status --quick"
out=$("$CLI" bogus 2>/dev/null); [[ $? -eq 1 && $out == *'"error"'* ]] && ok || fail "CLI unknown command errors"

# ---------- the boot re-apply unit is enabled without waiting for preset-all ----------
# The preset only fires on a first boot. A unit that arrives by OTA never gets one (the /etc
# overlay upper carries over), so without the shipped symlink it stays disabled and every reboot
# comes back uncalibrated (HW, Odin 3 internal install, 2026-10-23).
[[ -L $ROOT/rootfs/overlay/etc/systemd/system/multi-user.target.wants/retroforge-panel-calibration.service ]] \
  && ok || fail "retroforge-panel-calibration.service has no multi-user.target.wants symlink: enablement rides on first-boot presets alone"

# ---------- retroforge-paneld: the shell's root side, over a private D-Bus ----------
# The quick bar's Hardware card calibrates through org.retroforge.Panel1, so the daemon is driven
# for real here: its own code on a dbus-run-session bus, the module patched only where hardware
# would answer (the vblank measurement, as the simulated panel above) and the loop's wall-time
# windows shortened. Pinned: the JSON the card parses, Busy refusing a second measurement while a
# calibration runs (an extra vblank waiter jitters it) while a quick status still answers, a
# failure as Error.Failed with the module's reason, and the idle exit that lets D-Bus activation
# start it again on the next call.
DAEMON="$ROOT/rootfs/overlay/usr/bin/retroforge-paneld"
if ! command -v dbus-run-session >/dev/null || ! python3 -c 'import gi' 2>/dev/null; then
  echo "skip: retroforge-paneld (no dbus-run-session or python gi)" >&2
else
  printf 'SERIAL-D\0' > "$TMP/serial"
  echo 76 > "$SYS/ae94000.dsi.0/frame_len_120"
  cat > "$TMP/paneld_test.py" <<PYEOF
import importlib.util, json, os, threading, time
from importlib.machinery import SourceFileLoader
os.environ.update(RETROFORGE_PANEL_LIB="$LIB_DIR", RETROFORGE_PANELD_BUS="session", RETROFORGE_PANELD_IDLE_S="2")
loader = SourceFileLoader("paneld", "$DAEMON")
paneld = importlib.util.module_from_spec(importlib.util.spec_from_loader("paneld", loader))
loader.exec_module(paneld)
rp = paneld.retroforge_panel
rp.SETTLE_S, rp.ADJUST_WINDOW_S, rp.VERIFY_WINDOW_S = 0.01, 1.0, 0.3

def fake_rate(seconds=rp.MEASURE_S):  # the simulated Odin 3: 76 scans 118.4 Hz, 0.05 Hz per count
    time.sleep(0.05)
    return 118.4 + (76 - rp.read_knob(rp.panel_knobs()[1][120])) * 0.05
rp.measure_rate = fake_rate

# Before the daemon thread starts: paneld.main imports gi too, and two threads loading GLib's
# overrides at once can leave one with a half-initialised module (CI: "GLib has no attribute Idle").
from gi.repository import Gio, GLib
daemon = threading.Thread(target=paneld.main)
daemon.start()
bus = Gio.bus_get_sync(Gio.BusType.SESSION)
def call(method, args=None):
    try:
        reply = bus.call_sync("org.retroforge.Panel", "/org/retroforge/Panel", "org.retroforge.Panel1", method,
                              args, GLib.VariantType("(s)"), Gio.DBusCallFlags.NONE, 30000, None)
        return json.loads(reply.unpack()[0])
    except GLib.Error as e:
        return {"dbus_error": Gio.DBusError.get_remote_error(e), "message": e.message}
for _ in range(100):
    if bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner",
                     GLib.Variant("(s)", ("org.retroforge.Panel",)), None, 0, 1000, None).unpack()[0]:
        break
    time.sleep(0.05)

def check(name, cond):
    print(("ok " if cond else "FAIL ") + name)

s = call("Status", GLib.Variant("(b)", (False,)))
check("quick Status is the module's JSON", s.get("supported") is True and s.get("rates") == [60, 120] and s.get("measuredHz") is None)
s = call("Status", GLib.Variant("(b)", (True,)))
check("measured Status names the nominal rate", abs(s.get("measuredHz", 0) - 118.4) < 0.01 and s.get("nominalHz") == 120)

result = {}
calibrating = threading.Thread(target=lambda: result.update(call("Calibrate")))
calibrating.start()
time.sleep(0.3)
busy = call("Status", GLib.Variant("(b)", (True,)))
check("a measurement during a calibration is refused", busy.get("dbus_error") == "org.retroforge.Panel.Error.Busy")
check("a second Calibrate is refused", call("Calibrate").get("dbus_error") == "org.retroforge.Panel.Error.Busy")
check("a quick Status still answers", call("Status", GLib.Variant("(b)", (False,))).get("supported") is True)
calibrating.join()
check("Calibrate returns the module's result", result.get("rate") == 120 and 0 <= result.get("endHz", 0) - 120 <= 0.2)
state = json.load(open(os.environ["RETROFORGE_PANEL_STATE"]))
check("Calibrate persisted this unit's value", state.get("SERIAL-D", {}).get("120") == result.get("value"))

os.environ["RETROFORGE_PANEL_SYSFS_GLOB"] = "$TMP/nowhere/*"
failed = call("Calibrate")
check("a failure is Error.Failed with the reason", failed.get("dbus_error") == "org.retroforge.Panel.Error.Failed" and "no frame_len" in failed.get("message", ""))

daemon.join(timeout=6)
check("idle exit after RETROFORGE_PANELD_IDLE_S", not daemon.is_alive())
PYEOF
  out=$(PYTHONDONTWRITEBYTECODE=1 timeout 60 dbus-run-session -- python3 "$TMP/paneld_test.py" 2>&1)
  while IFS= read -r line; do
    case $line in
      "ok "*) ok ;;
      "FAIL "*) fail "paneld: ${line#FAIL }" ;;
    esac
  done <<< "$out"
  [[ $out == *"idle exit"* ]] || fail "paneld harness did not finish: $(tail -3 <<< "$out")"
fi

# ---------- paneld's bus wiring: activation file, policy and unit agree ----------
OV="$ROOT/rootfs/overlay"
ACT="$OV/usr/share/dbus-1/system-services/org.retroforge.Panel.service"
POL="$OV/usr/share/dbus-1/system.d/org.retroforge.Panel.conf"
UNIT="$OV/usr/lib/systemd/system/retroforge-paneld.service"
grep -qx 'SystemdService=retroforge-paneld.service' "$ACT" && grep -qx 'BusName=org.retroforge.Panel' "$UNIT" \
  && ok || fail "the activation file and retroforge-paneld.service do not name each other"
python3 - "$POL" <<'PYEOF' && ok || fail "the bus policy must let root own and wheel (player) call org.retroforge.Panel"
import sys, xml.etree.ElementTree as ET
pol = {p.get("user") or p.get("group"): [(a.attrib) for a in p] for p in ET.parse(sys.argv[1]).getroot()}
assert {"own": "org.retroforge.Panel"} in pol["root"]
assert {"send_destination": "org.retroforge.Panel"} in pol["wheel"]
PYEOF
! grep -q '^\[Install\]' "$UNIT" && ok || fail "retroforge-paneld.service has an [Install] section: it is activated by its first call, never at boot"
[[ -x $DAEMON ]] && ok || fail "retroforge-paneld is not executable"

echo
echo "panel-calibration: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
