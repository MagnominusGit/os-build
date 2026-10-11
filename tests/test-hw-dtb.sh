#!/usr/bin/env bash
# Offline test for tools/check-hw-paths.py (board profiles' hardware-map pins against the DTBs).
#
#   tests/test-hw-dtb.sh
#
# 1. The kernel's naming rules the checker reimplements, on fabricated devicetrees compiled with
#    dtc: led_compose_name, of_device_make_bus_id through `ranges`, the DSI connector order (bridge
#    and bonded hosts included), a zone or LED whose provider is disabled not registering, a
#    THERMAL_NAME_LENGTH overflow, the SY7758 enable rule, the supplies; a wrong pin, a backlight
#    that dims the other screen, a known gap and a known gap that stopped failing.
# 2. The PANELS table against the panel drivers in kernel/patches: a panel marked "dcs" must
#    register its own backlight, one marked "borrows" must link the devicetree's.
# 3. The real fleet, when there is something to read: out/dtbs (after `make kernel`), or
#    QFORGE_LINUX_SRC=<a Linux tree> to compile kernel/dts/qcom here. Skipped otherwise.
# Needs python3; parts 1 and 3 need dtc (device-tree-compiler) and are skipped without it.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/tools/check-hw-paths.py"
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }
[ -f "$CHECK" ] || { echo "missing $CHECK" >&2; exit 1; }
T="$(mktemp -d)" && [ -d "$T" ] || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0; SKIP=0

(python3 - "$CHECK" "$ROOT" "$T" "$(command -v dtc || true)" <<'PYEOF'
import importlib.util, os, subprocess, sys
from pathlib import Path

check_py, root, tmp, dtc = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4]
spec = importlib.util.spec_from_file_location("chk", check_py)
chk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(chk)
passed = failed = skipped = 0


def ok(name, cond, detail=""):
    global passed, failed
    if cond:
        passed += 1
        print(f"  ok   {name}")
    else:
        failed += 1
        print(f"  FAIL {name}{' -- ' + str(detail) if detail else ''}")


def compile_dts(name, text):
    src = tmp / f"{name}.dts"
    src.write_text(text)
    out = tmp / "dtbs" / f"{name}.dtb"
    out.parent.mkdir(exist_ok=True)
    subprocess.run([dtc, "-q", "-I", "dts", "-O", "dtb", "-o", str(out), str(src)], check=True)
    return out


# A Thor-shaped board: two DSI panels (dsi0 the bottom ch13726a, dsi1 the top icna3520), an RGB
# stick group over a channel chip, the PM8550 power LED, a PWM multicolor LED whose PWM chip is
# disabled, a pwm-fan with a tachometer, pmic-glink, an SY7758 without its enable, and zones with
# an enabled, a disabled and an over-long name. Colors: 1 red, 2 green, 3 blue, 9 rgb.
BOARD = r"""
/dts-v1/;
/ {
	model = "AYN Thor";
	#address-cells = <2>;
	#size-cells = <2>;

	backlight { compatible = "pwm-backlight"; pwms = <&lpg 0 1000>; };
	fan { compatible = "pwm-fan"; pwms = <&lpg 3 40000>; interrupts = <13 2>; };
	pmic-glink { compatible = "qcom,sm8550-pmic-glink", "qcom,pmic-glink"; };

	multi-led-l1 {
		compatible = "leds-group-multicolor";
		color = <9>; function = "l"; function-enumerator = <1>;
		leds = <&ch_b1>, <&ch_g1>, <&ch_r1>;
	};

	pwm-leds {
		compatible = "pwm-leds-multicolor";
		multi-led { label = "left-joystick"; color = <9>;
			led-red { color = <1>; pwms = <&sn3112 0 1000>; };
		};
	};

	soc@0 {
		compatible = "simple-bus";
		#address-cells = <2>;
		#size-cells = <2>;
		ranges = <0 0 0 0 0x10 0>;

		lpg: pwm@1000 {
			compatible = "qcom,pm8550-pwm";
			reg = <0 0x1000 0 0x100>;
			#pwm-cells = <2>;
			#address-cells = <1>;
			#size-cells = <0>;
			multi-led@1 { reg = <1>; label = "power-led"; color = <9>;
				led@1 { reg = <1>; color = <1>; };
			};
		};

		sn3112: pwm@2000 { compatible = "si-en,sn3112-pwm"; reg = <0 0x2000 0 0x100>; #pwm-cells = <2>; status = "disabled"; };

		i2c@a80000 {
			compatible = "qcom,geni-i2c";
			reg = <0 0xa80000 0 0x4000>;
			#address-cells = <1>;
			#size-cells = <0>;
			led-controller@34 {
				compatible = "heroic,htr3212";
				reg = <0x34>;
				#address-cells = <1>;
				#size-cells = <0>;
				ch_b1: led@1 { reg = <1>; label = "l:b1"; color = <3>; };
				ch_g1: led@2 { reg = <2>; label = "l:g1"; color = <2>; };
				ch_r1: led@3 { reg = <3>; label = "l:r1"; color = <1>; };
				led@4 { reg = <4>; color = <1>; function = "indicator"; function-enumerator = <10>; };
			};
			backlight@2e { compatible = "silergy,sy7758"; reg = <0x2e>; };
		};

		tsens: thermal-sensor@c228000 { compatible = "qcom,tsens-v2"; reg = <0 0xc228000 0 0x1000>; #thermal-sensor-cells = <1>; };
		tsens_off: thermal-sensor@c229000 { compatible = "qcom,tsens-v2"; reg = <0 0xc229000 0 0x1000>; #thermal-sensor-cells = <1>; status = "disabled"; };

		gpu@3d00000 { compatible = "qcom,adreno-43050c01", "qcom,adreno"; reg = <0 0x3d00000 0 0x40000>; };
		gmu@3d6a000 { compatible = "qcom,adreno-gmu-740.1", "qcom,adreno-gmu"; reg = <0 0x3d6a000 0 0x30000>; };

		display-subsystem@ae00000 {
			compatible = "qcom,sm8550-mdss";
			reg = <0 0xae00000 0 0x1000>;
			#address-cells = <2>;
			#size-cells = <2>;
			ranges;

			display-controller@ae01000 {
				compatible = "qcom,sm8550-dpu";
				reg = <0 0xae01000 0 0x8f000>;
				ports { #address-cells = <1>; #size-cells = <0>;
					port@0 { reg = <0>; dpu_intf1_out: endpoint { remote-endpoint = <&dsi0_in>; }; };
					port@1 { reg = <1>; dpu_intf2_out: endpoint { remote-endpoint = <&dsi1_in>; }; };
				};
			};

			dsi@ae96000 {
				compatible = "qcom,sm8550-dsi-ctrl", "qcom,mdss-dsi-ctrl";
				reg = <0 0xae96000 0 0x400>;
				#address-cells = <1>;
				#size-cells = <0>;
				panel@0 { compatible = "chipone,icna3520"; reg = <0>;
					port { top_in: endpoint { remote-endpoint = <&dsi1_out>; }; };
				};
				ports { #address-cells = <1>; #size-cells = <0>;
					port@0 { reg = <0>; dsi1_in: endpoint { remote-endpoint = <&dpu_intf2_out>; }; };
					port@1 { reg = <1>; dsi1_out: endpoint { remote-endpoint = <&top_in>; }; };
				};
			};

			dsi@ae94000 {
				compatible = "qcom,sm8550-dsi-ctrl", "qcom,mdss-dsi-ctrl";
				reg = <0 0xae94000 0 0x400>;
				#address-cells = <1>;
				#size-cells = <0>;
				panel@0 { compatible = "ch13726a,thor"; reg = <0>;
					port { bottom_in: endpoint { remote-endpoint = <&dsi0_out>; }; };
				};
				ports { #address-cells = <1>; #size-cells = <0>;
					port@0 { reg = <0>; dsi0_in: endpoint { remote-endpoint = <&dpu_intf1_out>; }; };
					port@1 { reg = <1>; dsi0_out: endpoint { remote-endpoint = <&bottom_in>; }; };
				};
			};
		};
	};

	thermal-zones {
		cpu7-top-thermal { thermal-sensors = <&tsens 10>; };
		gpuss-0-thermal { thermal-sensors = <&tsens 20>; };
		cpu0-thermal { thermal-sensors = <&tsens_off 1>; };
		parked-thermal { thermal-sensors = <&tsens 2>; status = "disabled"; };
		a-name-of-twenty-chr { thermal-sensors = <&tsens 3>; };
	};
};
"""

GOOD = {
    "QFORGE_PRIMARY_CONNECTOR": "DSI-2",
    "QFORGE_HW_BATTERY": "qcom-battmgr-bat",
    "QFORGE_HW_CHARGER": "qcom-battmgr-usb",
    "QFORGE_HW_BACKLIGHT": "ae96000.dsi.0",
    "QFORGE_HW_THERMAL_CPU": "cpu7-top-thermal",
    "QFORGE_HW_THERMAL_GPU": "gpuss-0-thermal",
    "QFORGE_HW_FAN": "pwmfan",
    "QFORGE_HW_GPU_DEVFREQ": "3d00000.gpu",
    "QFORGE_HW_LED_GROUPS": "power=power-led ring=rgb:l*",
}


def run_check(pins):
    return {f: (o, d) for f, o, d in chk.check(board, pins)}


if not dtc:
    print("  skip naming rules and fixtures: no dtc (device-tree-compiler)")
    skipped += 1
else:
    print("== the kernel's naming, on a fabricated board")
    dtb = compile_dts("thor", BOARD)
    tree = chk.Tree(dtb.read_bytes())
    board = chk.Board(tree)
    ok("model read from the root", tree.model == "AYN Thor", tree.model)
    ok("LED: a label is the name", "power-led" in board.leds)
    ok("LED: color:function-enumerator", "red:indicator-10" in board.leds, sorted(board.leds))
    ok("LED: a multicolor group registers over its members", "rgb:l-1" in board.leds, sorted(board.leds))
    ok("LED: a PWM LED whose PWM chip is disabled never registers", "left-joystick" not in board.leds)
    ok("LED: an LPG multi-led's channels are not LEDs of their own",
       not any(l.startswith("red:") and "indicator" not in l for l in board.leds), sorted(board.leds))
    ok("zones: available, with an enabled sensor", {"cpu7-top-thermal", "gpuss-0-thermal"} <= set(board.zones))
    ok("zones: a disabled sensor provider registers no zone", "cpu0-thermal" not in board.zones)
    ok("zones: a disabled zone is not one", "parked-thermal" not in board.zones)
    ok("zones: 20 characters is one too many",
       "a-name-of-twenty-chr" not in board.zones and any("20 characters" in p for p in board.problems))
    ok("backlights: pwm-backlight at the root is its node name", "backlight" in board.backlights)
    ok("backlights: a DCS panel is <dsi device>.<reg>, through `ranges`",
       {"ae94000.dsi.0", "ae96000.dsi.0"} <= set(board.backlights), sorted(board.backlights))
    ok("backlights: an SY7758 without enable-gpios does not register, and says so",
       "sy7758-backlight" not in board.backlights and any("enable-gpios" in p for p in board.problems))
    ok("GPU devfreq: the Adreno, not its GMU", list(board.gpus) == ["3d00000.gpu"], list(board.gpus))
    ok("supplies: pmic-glink's battmgr", board.supplies.get("qcom-battmgr-bat") == "battery"
       and board.supplies.get("qcom-battmgr-usb") == "charger", board.supplies)
    ok("fan: pwm-fan with an enabled PWM", "pwmfan" in board.fans)
    conns = [(c, h.name, p.strings("compatible")[0]) for c, h, p in board.dsi_connectors()]
    ok("DSI connectors in host address order, whatever the source order",
       conns == [("DSI-1", "dsi@ae94000", "ch13726a,thor"), ("DSI-2", "dsi@ae96000", "chipone,icna3520")], conns)

    print("== the checks")
    r = run_check(GOOD)
    ok("every good pin passes", all(o for o, _ in r.values()), {k: v for k, v in r.items() if not v[0]})
    ok("the primary-panel check ran", "QFORGE_HW_BACKLIGHT:primary" in r)
    r = run_check(dict(GOOD, QFORGE_HW_BACKLIGHT="ae94000.dsi.0"))
    ok("the bottom screen's backlight exists but is not the primary's",
       r["QFORGE_HW_BACKLIGHT"][0] and not r["QFORGE_HW_BACKLIGHT:primary"][0], r.get("QFORGE_HW_BACKLIGHT:primary"))
    r = run_check(dict(GOOD, QFORGE_HW_THERMAL_CPU="cpu7-top"))
    ok("a zone without its -thermal suffix fails", not r["QFORGE_HW_THERMAL_CPU"][0])
    r = run_check(dict(GOOD, QFORGE_HW_THERMAL_CPU="cpu0-thermal"))
    ok("a zone whose sensor is disabled fails", not r["QFORGE_HW_THERMAL_CPU"][0])
    r = run_check(dict(GOOD, QFORGE_HW_BATTERY="battery", QFORGE_HW_CHARGER="qcom-battmgr-bat"))
    ok("a battery that is not there, and a battery pinned as the charger, fail",
       not r["QFORGE_HW_BATTERY"][0] and not r["QFORGE_HW_CHARGER"][0])
    r = run_check(dict(GOOD, QFORGE_HW_FAN="gpio_fan", QFORGE_HW_GPU_DEVFREQ="3d6a000.gmu"))
    ok("a fan and a devfreq that are not there fail", not r["QFORGE_HW_FAN"][0] and not r["QFORGE_HW_GPU_DEVFREQ"][0])
    r = run_check(dict(GOOD, QFORGE_HW_LED_GROUPS="ring=*:indicator-[0-9] sticks=left-joystick"))
    ok("a bracket glob does not take indicator-10", not r["QFORGE_HW_LED_GROUPS:ring"][0])
    ok("a group of LEDs that never register fails", not r["QFORGE_HW_LED_GROUPS:sticks"][0])

    # The S2K/S2: one panel bonded over both links (DSI-1 only); the Odin 2: an HDMI bridge on dsi0,
    # so the panel on dsi1 is DSI-1.
    bonded = BOARD.replace('compatible = "ch13726a,thor"; reg = <0>;\n\t\t\t\t\tport { bottom_in: endpoint { remote-endpoint = <&dsi0_out>; }; };',
                           'compatible = "chipone,icna3520"; reg = <0>;\n\t\t\t\t\tport { bottom_in: endpoint { remote-endpoint = <&dsi0_out>; }; };')
    bonded = bonded.replace("remote-endpoint = <&top_in>;", "remote-endpoint = <&bottom_in>;")
    bonded = bonded.replace('panel@0 { compatible = "chipone,icna3520"; reg = <0>;\n\t\t\t\t\tport { top_in: endpoint { remote-endpoint = <&dsi1_out>; }; };\n\t\t\t\t};', "")
    bt = chk.Board(chk.Tree(compile_dts("bonded", bonded).read_bytes()))
    conns = [(c, h.name) for c, h, _ in bt.dsi_connectors()]
    ok("a bonded pair is one connector, on the first host", conns == [("DSI-1", "dsi@ae94000")], conns)
    bridged = BOARD.replace('panel@0 { compatible = "ch13726a,thor"; reg = <0>;\n\t\t\t\t\tport { bottom_in: endpoint { remote-endpoint = <&dsi0_out>; }; };\n\t\t\t\t};', "")
    bridged = bridged.replace("remote-endpoint = <&bottom_in>;", "remote-endpoint = <&hdmi_in>;")
    bridged = bridged.replace("\tthermal-zones {", "\thdmi-bridge { compatible = \"lontium,lt8912b\";\n\t\tport { hdmi_in: endpoint { remote-endpoint = <&dsi0_out>; }; };\n\t};\n\n\tthermal-zones {")
    br = chk.Board(chk.Tree(compile_dts("bridged", bridged).read_bytes()))
    conns = [(c, h.name) for c, h, _ in br.dsi_connectors()]
    ok("a bridge on dsi0 makes the dsi1 panel DSI-1", conns == [("DSI-1", "dsi@ae96000")], conns)

    print("== a run, with known gaps")
    devdir = tmp / "devices"
    devdir.mkdir()
    (devdir / "defaults.conf").write_text((root / "rootfs/overlay/usr/lib/qforge/devices/defaults.conf").read_text())
    for name in ("bonded", "bridged"):
        (tmp / "dtbs" / f"{name}.dtb").unlink()
    conf = "".join(f"{k}='{v}'\n" for k, v in dict(GOOD, QFORGE_DEVICE_ID="ayn-thor",
                   QFORGE_HW_LED_GROUPS="power=power-led ring=rgb:l* sticks=left-joystick").items())
    (devdir / "ayn-thor.conf").write_text(conf)
    xf = tmp / "xfail"

    def run(xfail_text):
        xf.write_text(xfail_text)
        return subprocess.run([sys.executable, str(check_py), "--dtbs", str(tmp / "dtbs"), "--xfail", str(xf),
                               "--device-dir", str(devdir)], capture_output=True, text=True)

    p = run("")
    ok("an unlisted failure fails the run", p.returncode == 1 and "FAIL  QFORGE_HW_LED_GROUPS:sticks" in p.stdout, p.stdout)
    p = run("ayn-thor QFORGE_HW_LED_GROUPS:sticks the PWM chip is disabled\n")
    ok("a listed one is a known gap", p.returncode == 0 and "xfail QFORGE_HW_LED_GROUPS:sticks" in p.stdout, p.stdout)
    p = run("ayn-thor QFORGE_HW_LED_GROUPS:ring not a gap any more\n"
            "ayn-thor QFORGE_HW_LED_GROUPS:sticks the PWM chip is disabled\n")
    ok("a listed one that passes fails the run (XPASS)", p.returncode == 1 and "XPASS" in p.stdout, p.stdout)
    p = run("ayn-thor QFORGE_HW_LED_GROUPS:sticks the PWM chip is disabled\nno-such-board QFORGE_HW_FAN gone\n")
    ok("a listed check that never ran fails the run", p.returncode == 1 and "names no check that ran" in p.stdout, p.stdout)

print("== patch filtering")
git = ("diff --git a/drivers/x.c b/drivers/x.c\n--- a/drivers/x.c\n+++ b/drivers/x.c\n@@ -1 +1 @@\n-a\n+b\n"
       "diff --git a/arch/arm64/boot/dts/qcom/y.dtsi b/arch/arm64/boot/dts/qcom/y.dtsi\n"
       "--- a/arch/arm64/boot/dts/qcom/y.dtsi\n+++ b/arch/arm64/boot/dts/qcom/y.dtsi\n@@ -1 +1 @@\n-c\n+d\n")
h = chk.dts_patch_hunks(git)
ok("git: the devicetree file is kept, the driver dropped", "y.dtsi" in h and "x.c" not in h, h)
plain = ("Subject: x\n--- linux.orig/arch/arm64/boot/dts/qcom/pm8150b.dtsi\t2024\n+++ linux/arch/arm64/boot/dts/qcom/pm8150b.dtsi\t2024\n@@ -1 +1 @@\n-e\n+f\n"
         "--- linux.orig/drivers/z.c\n+++ linux/drivers/z.c\n@@ -1 +1 @@\n-g\n+h\n")
h = chk.dts_patch_hunks(plain)
ok("plain: the same, by its ---/+++ pair", "pm8150b.dtsi" in h and "z.c" not in h, h)
h = chk.dts_patch_hunks("diff --git a/include/dt-bindings/x.h b/include/dt-bindings/x.h\nnew file mode 100644\n--- /dev/null\n+++ b/include/dt-bindings/x.h\n@@ -0,0 +1 @@\n+#define X 1\n")
ok("a new binding header is kept", "dt-bindings/x.h" in h, h)

print("== the PANELS table against the panel drivers")
patches = sorted((root / "kernel/patches").glob("*.patch"))
for compat, kind in sorted(chk.PANELS.items()):
    src = next((p.read_text(errors="replace") for p in patches if f'"{compat}"' in p.read_text(errors="replace")), None)
    if src is None:
        ok(f"{compat}: its driver is in kernel/patches", False, "not found")
        continue
    own = "backlight_device_register" in src
    borrows = "drm_panel_of_backlight" in src
    want = {"dcs": own and not borrows, "borrows": borrows and not own, "none": not own and not borrows}[kind]
    ok(f"{compat} is {kind}", want, f"registers own={own}, drm_panel_of_backlight={borrows}")

print(f"RESULT {passed} {failed} {skipped}")
PYEOF
) 2>&1 | tee "$T/out" | grep -v '^RESULT'
read -r _ p f s < <(grep '^RESULT' "$T/out" || echo "RESULT 0 1 0")
PASS=$((PASS + p)); FAIL=$((FAIL + f)); SKIP=$((SKIP + s))

# ------------------------------------------------------------------------------------ the fleet
echo "== the fleet"
if ls "$ROOT"/out/dtbs/*.dtb >/dev/null 2>&1; then
  python3 "$CHECK" --dtbs "$ROOT/out/dtbs" && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
elif [ -n "${QFORGE_LINUX_SRC:-}" ] && command -v dtc >/dev/null; then
  python3 "$CHECK" --linux-src "$QFORGE_LINUX_SRC" && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
else
  echo "  skip: no out/dtbs (make kernel) and no QFORGE_LINUX_SRC to compile kernel/dts/qcom against"
  SKIP=$((SKIP+1))
fi

printf '\ntest-hw-dtb: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
