#!/usr/bin/env bash
# Offline test for /usr/lib/retroforge/hw-map (the standard hardware tree, /run/retroforge/hw).
#
#   tests/test-hw-map.sh
#
# Drives the real script against a fabricated sysfs (RETROFORGE_HW_SYS) and checks the rules that
# matter on the boards we have: the charger's companion "battery" node (no capacity) is not the
# battery; the charger IC (reports `status`) wins over a bare Type-C source; thermal roles by
# profile type name or by pattern, every zone under all/; LED groups in natural order (l10 after
# l2); the profile's RETROFORGE_HW_* pins, and a stale pin falling back to detection; the soc link;
# hw.env is sourceable; every board profile's pins are well-formed. Host only, no root, no Godot.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/rootfs/overlay/usr/lib/retroforge/hw-map"
PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }
[ -x "$SCRIPT" ] || { echo "missing or not executable: $SCRIPT" >&2; exit 1; }
T="$(mktemp -d)" && [ -d "$T" ] || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT

S="$T/sys"
mk() { mkdir -p "$(dirname "$S/$1")"; printf '%s\n' "$2" > "$S/$1"; }
# Air X-shaped board
mk class/power_supply/bq256xx-battery/type Battery          # the charger's companion: no capacity
mk class/power_supply/bq256xx-battery/charge_full_design 5000000
mk class/power_supply/battery/type Battery
mk class/power_supply/battery/capacity 73
mk class/power_supply/tcpm-source/type USB                  # bare Type-C source: online only
mk class/power_supply/tcpm-source/online 1
mk class/power_supply/bq256xx-charger/type USB              # the charger IC: online + status
mk class/power_supply/bq256xx-charger/online 1
mk class/power_supply/bq256xx-charger/status Charging
mk class/backlight/backlight/brightness 20
mk class/thermal/thermal_zone0/type mapss-thermal
mk class/thermal/thermal_zone6/type cpu4-thermal
mk class/thermal/thermal_zone11/type cpu67-thermal
mk class/thermal/thermal_zone12/type cpu0123-thermal
mk class/thermal/thermal_zone15/type gpu-thermal
mk class/thermal/thermal_zone17/type battery
mk class/thermal/thermal_zone18/type battery-thermal
mk class/hwmon/hwmon2/name wlan_thermal
mk class/hwmon/hwmon20/name gpio_fan
mk class/hwmon/hwmon20/fan1_input 0
mkdir -p "$S/class/devfreq/5900000.gpu" "$S/devices/system/cpu"
for l in rgb:l1 rgb:l2 rgb:l10 rgb:l3 rgb:r1 rgb:r2 left_red_1 mmc0::; do mkdir -p "$S/class/leds/$l"; done
for z in "$S"/class/thermal/thermal_zone*; do printf '%s\n' 40000 > "$z/temp"; done

run() { RETROFORGE_HW_SYS="$S" RETROFORGE_HW_RUN="$T/run/hw" RETROFORGE_HW_DEVICE_ENV= "$@" bash "$SCRIPT" 2>"$T/stderr"; }
target() { readlink "$T/run/hw/$1" 2>/dev/null | sed "s|^$S/||"; }

# =================================================================================================
CASE="detection"
run env && ok "runs" || bad "exit $? -- $(cat "$T/stderr")"
[ "$(target battery)" = class/power_supply/battery ] && ok "the battery is the one with a capacity, not the charger's companion node" || bad "battery -> $(target battery)"
[ "$(target charger)" = class/power_supply/bq256xx-charger ] && ok "the charger IC (with status) wins over the bare Type-C source" || bad "charger -> $(target charger)"
[ "$(target backlight)" = class/backlight/backlight ] && ok "backlight" || bad "backlight -> $(target backlight)"
[ "$(target thermal/cpu)" = class/thermal/thermal_zone6 ] && ok "cpu role: first cpu* zone in zone order" || bad "thermal/cpu -> $(target thermal/cpu)"
[ "$(target thermal/gpu)" = class/thermal/thermal_zone15 ] && ok "gpu role" || bad "thermal/gpu -> $(target thermal/gpu)"
[ "$(target thermal/battery)" = class/thermal/thermal_zone17 ] && ok "battery role" || bad "thermal/battery -> $(target thermal/battery)"
[ ! -e "$T/run/hw/thermal/skin" ] && ok "no skin zone, no skin link" || bad "thermal/skin exists"
[ "$(ls "$T/run/hw/thermal/all" | wc -l | tr -d ' ')" = 7 ] && ok "every zone under thermal/all" || bad "thermal/all has $(ls "$T/run/hw/thermal/all" | tr '\n' ' ')"
[ "$(target fan)" = class/hwmon/hwmon20 ] && ok "the hwmon with a fan1_input is the fan" || bad "fan -> $(target fan)"
[ "$(target gpu)" = class/devfreq/5900000.gpu ] && ok "gpu devfreq" || bad "gpu -> $(target gpu)"
[ "$(target cpu)" = devices/system/cpu ] && ok "cpu" || bad "cpu -> $(target cpu)"
[ ! -e "$T/run/hw/leds/power" ] && ok "no power-led, no default LED group" || bad "leds/power exists"
grep -q '^RETROFORGE_HW_BATTERY=battery$' "$T/run/hw/hw.env" && ok "hw.env records the battery" || bad "hw.env: $(grep BATTERY "$T/run/hw/hw.env")"
( set -e; . "$T/run/hw/hw.env"; [ "$RETROFORGE_HW_CHARGER" = bq256xx-charger ] ) && ok "hw.env is sourceable" || bad "hw.env does not source"

# =================================================================================================
CASE="profile pins"
run env RETROFORGE_HW_THERMAL_CPU=cpu67-thermal RETROFORGE_HW_LED_GROUPS="ring-left=rgb:l* ring-right=rgb:r*" RETROFORGE_HW_CHARGER=tcpm-source && ok "runs" || bad "exit $?"
[ "$(target thermal/cpu)" = class/thermal/thermal_zone11 ] && ok "RETROFORGE_HW_THERMAL_CPU picks the zone by type name" || bad "thermal/cpu -> $(target thermal/cpu)"
[ "$(target charger)" = class/power_supply/tcpm-source ] && ok "RETROFORGE_HW_CHARGER pins the charger" || bad "charger -> $(target charger)"
[ "$(ls "$T/run/hw/leds/ring-left" | tr '\n' ' ')" = "01 02 03 04 " ] && ok "a glob group numbers its LEDs 01.." || bad "ring-left: $(ls "$T/run/hw/leds/ring-left" | tr '\n' ' ')"
[ "$(target leds/ring-left/03)" = class/leds/rgb:l3 ] && [ "$(target leds/ring-left/04)" = class/leds/rgb:l10 ] && ok "natural order: l3 before l10" || bad "03 -> $(target leds/ring-left/03), 04 -> $(target leds/ring-left/04)"
[ "$(ls "$T/run/hw/leds/ring-right" | wc -l | tr -d ' ')" = 2 ] && ok "second group" || bad "ring-right: $(ls "$T/run/hw/leds/ring-right")"
grep -q '^RETROFORGE_HW_LED_GROUPS=ring-left=4\\ ring-right=2$' "$T/run/hw/hw.env" && ok "hw.env summarises the groups" || bad "hw.env: $(grep LED "$T/run/hw/hw.env")"

# =================================================================================================
CASE="rebuild"
mkdir -p "$S/class/leds/power-led"
run env && [ "$(target leds/power/01)" = class/leds/power-led ] && ok "a later run replaces the tree (power-led now the default group)" || bad "leds/power/01 -> $(target leds/power/01)"
[ ! -e "$T/run/hw/leds/ring-left" ] && ok "stale links from the previous tree are gone" || bad "ring-left survived"
[ -z "$(ls -d "$T"/run/hw.tmp.* "$T"/run/hw.old.* 2>/dev/null)" ] && ok "no temporary trees left behind" || bad "leftovers: $(ls -d "$T"/run/hw.* )"

# =================================================================================================
CASE="bare board"
rm -rf "$S"; mkdir -p "$S/class"
run env && ok "runs with nothing to map" || bad "exit $?"
[ -z "$(find "$T/run/hw" -type l)" ] && ok "no links" || bad "links: $(find "$T/run/hw" -type l)"
grep -q '^RETROFORGE_HW_BATTERY=.*$' "$T/run/hw/hw.env" && ok "hw.env still written" || bad "no hw.env"

# =================================================================================================
CASE="pwm fan without a tachometer"
rm -rf "$S"; mkdir -p "$S/class"
mk class/hwmon/hwmon3/name cpu_thermal
mk class/hwmon/hwmon9/name pwmfan
mk class/hwmon/hwmon9/pwm1 0
run env && [ "$(target fan)" = class/hwmon/hwmon9 ] && ok "a hwmon with only pwm1 is the fan (the SM8250 boards' pwm-fan)" || bad "fan -> $(target fan)"

# =================================================================================================
CASE="stale pins"
# An SM8550-shaped board whose profile names things it does not have: each pin is logged and the
# node is detected instead, so a wrong name costs a warning and not the link.
rm -rf "$S"; mkdir -p "$S/class"
mk class/power_supply/qcom-battmgr-bat/type Battery
mk class/power_supply/qcom-battmgr-bat/capacity 55
mk class/power_supply/qcom-battmgr-usb/type USB
mk class/power_supply/qcom-battmgr-usb/online 1
mk class/backlight/ae94000.dsi.0/brightness 100
mk class/thermal/thermal_zone0/type aoss0-thermal
mk class/thermal/thermal_zone1/type cpuss0-thermal
mk class/thermal/thermal_zone30/type gpuss-0-thermal
mk class/hwmon/hwmon5/name pwmfan
mk class/hwmon/hwmon5/fan1_input 3000
mkdir -p "$S/class/devfreq/3d00000.gpu"
run env RETROFORGE_HW_BATTERY=battery RETROFORGE_HW_CHARGER=pm8150b-charger RETROFORGE_HW_BACKLIGHT=backlight \
    RETROFORGE_HW_THERMAL_CPU=cpu7-top-thermal RETROFORGE_HW_FAN=gpio_fan RETROFORGE_HW_GPU_DEVFREQ=5900000.gpu \
    && ok "runs" || bad "exit $?"
[ "$(target battery)" = class/power_supply/qcom-battmgr-bat ] && ok "absent battery pin -> detected battery" || bad "battery -> $(target battery)"
[ "$(target charger)" = class/power_supply/qcom-battmgr-usb ] && ok "absent charger pin -> detected charger" || bad "charger -> $(target charger)"
[ "$(target backlight)" = class/backlight/ae94000.dsi.0 ] && ok "absent backlight pin -> detected backlight" || bad "backlight -> $(target backlight)"
[ "$(target thermal/cpu)" = class/thermal/thermal_zone1 ] && ok "absent zone pin -> the pattern's zone" || bad "thermal/cpu -> $(target thermal/cpu)"
[ "$(target fan)" = class/hwmon/hwmon5 ] && ok "absent fan pin -> detected fan" || bad "fan -> $(target fan)"
[ "$(target gpu)" = class/devfreq/3d00000.gpu ] && ok "absent devfreq pin -> detected devfreq" || bad "gpu -> $(target gpu)"
n=$(grep -c 'is not on this board -- detecting instead' "$T/stderr")
[ "$n" = 6 ] && ok "each stale pin is logged" || bad "$n warnings: $(cat "$T/stderr")"
run env RETROFORGE_HW_BATTERY=qcom-battmgr-bat RETROFORGE_HW_THERMAL_GPU=gpuss-0-thermal && ! grep -q 'detecting instead' "$T/stderr" \
    && ok "pins that exist are not logged" || bad "stderr: $(cat "$T/stderr")"

# =================================================================================================
CASE="charge pump"
# The Air Y Pro: an HL7139 charge pump (Mains, online+status, but `online` = pump engaged) sorts
# before the PM8150B's smb5 charger, so detection takes the pump; the profile pins smb5.
rm -rf "$S"; mkdir -p "$S/class"
mk class/power_supply/battery/type Battery
mk class/power_supply/battery/capacity 80
mk class/power_supply/hl7139-charger/type Mains
mk class/power_supply/hl7139-charger/online 0
mk class/power_supply/hl7139-charger/status "Not charging"
mk class/power_supply/pm8150b-charger/type USB
mk class/power_supply/pm8150b-charger/online 1
mk class/power_supply/pm8150b-charger/status Charging
run env && [ "$(target charger)" = class/power_supply/hl7139-charger ] && ok "unpinned, the charge pump wins (why the profile pins)" || bad "charger -> $(target charger)"
run env RETROFORGE_HW_CHARGER=pm8150b-charger && [ "$(target charger)" = class/power_supply/pm8150b-charger ] && ok "pinned, the smb5 charger" || bad "charger -> $(target charger)"

# =================================================================================================
CASE="soc"
mk devices/soc0/machine SM8550
mk devices/soc0/serial_number 1234567890
run env && [ "$(target soc)" = devices/soc0 ] && ok "soc -> socinfo" || bad "soc -> $(target soc)"
grep -q '^RETROFORGE_HW_SOC=SM8550$' "$T/run/hw/hw.env" && ok "hw.env records the SoC" || bad "hw.env: $(grep SOC "$T/run/hw/hw.env")"
[ "$(cat "$T/run/hw/soc/serial_number")" = 1234567890 ] && ok "the serial number reads through the link" || bad "no serial"

# =================================================================================================
CASE="single-colour LED channels"
# The Pocket Max: two aw20036s, no multicolor grouping, {red,green,blue}:indicator-0..15; pixels
# 0-7 are the left ring, 8-15 the right. A bracket glob must not take indicator-10 into the left.
for i in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    for c in red green blue; do mkdir -p "$S/class/leds/$c:indicator-$i"; done
done
run env RETROFORGE_HW_LED_GROUPS="ring-left=*:indicator-[0-7] ring-right=*:indicator-[89],*:indicator-1[0-5] logo=logo-led" \
    && ok "runs" || bad "exit $?"
[ "$(ls "$T/run/hw/leds/ring-left" | wc -l | tr -d ' ')" = 24 ] && ok "left: 8 pixels x 3 channels" || bad "ring-left: $(ls "$T/run/hw/leds/ring-left" | wc -l)"
[ "$(ls "$T/run/hw/leds/ring-right" | wc -l | tr -d ' ')" = 24 ] && ok "right: 8 pixels x 3 channels" || bad "ring-right: $(ls "$T/run/hw/leds/ring-right" | wc -l)"
! (cd "$T/run/hw/leds/ring-left" && for l in *; do readlink "$l"; done) | grep -q 'indicator-1[0-5]$' \
    && ok "no right-ring pixel in the left group" || bad "left group took a right pixel"
[ ! -e "$T/run/hw/leds/logo" ] && grep -q 'LED group logo matched nothing' "$T/stderr" \
    && ok "a group that matches nothing is left out, and logged" || bad "logo: $(cat "$T/stderr")"

# =================================================================================================
CASE="board profiles"
# Every profile's pins, as device-env exports them. A zone type keeps its -thermal suffix and fits
# THERMAL_NAME_LENGTH (20 with the NUL); a missing suffix or a typo would only show on a device.
DEV="$ROOT/rootfs/overlay/usr/lib/retroforge/devices"
ENV_SCRIPT="$ROOT/rootfs/overlay/usr/lib/retroforge/device-env"
for conf in "$DEV"/*.conf; do
    id=$(basename "$conf" .conf); [ "$id" = defaults ] && continue
    vals=$( . "$DEV/defaults.conf"; . "$conf"
        printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s' "$RETROFORGE_HW_BATTERY" "$RETROFORGE_HW_CHARGER" "$RETROFORGE_HW_BACKLIGHT" \
            "$RETROFORGE_HW_THERMAL_CPU" "$RETROFORGE_HW_THERMAL_GPU" "$RETROFORGE_HW_FAN" "$RETROFORGE_HW_GPU_DEVFREQ" \
            "$RETROFORGE_HW_THERMAL_BATTERY" "$RETROFORGE_HW_THERMAL_SKIN" "$RETROFORGE_HW_LED_GROUPS" )
    IFS='|' read -r b c bl tc tg f g tb ts leds <<<"$vals"
    # Backlight is not in the required set: empty = hw-map detects it (defaults.conf), and that is
    # the deliberate state on a single-backlight board whose name is a register address (the
    # Odin 3's icna35xx registers the DSI dev name). Boards where detection sorts wrong (the Thor's
    # two backlights) still pin theirs; this suite can't tell those apart from a conf.
    if [ -n "$b" ] && [ -n "$c" ] && [ -n "$tc" ] && [ -n "$tg" ] && [ -n "$f" ] && [ -n "$g" ]; then
        ok "$id pins battery, charger, cpu/gpu zones, fan, devfreq"
    else bad "$id leaves a pin empty: $vals"; fi
    zbad=""
    for z in "$tc" "$tg" "$tb" "$ts"; do
        [ -z "$z" ] && continue
        case $z in *-thermal) ;; *) zbad="$zbad $z(no -thermal)";; esac
        [ ${#z} -le 19 ] || zbad="$zbad $z(>19 chars)"
    done
    [ -z "$zbad" ] && ok "$id zone types well-formed" || bad "$id zone types:$zbad"
    lbad=""
    for spec in $leds; do case $spec in [a-z]*=?*) ;; *) lbad="$lbad $spec";; esac; done
    # Empty is valid: a board with no LED surface (the PF Elite: sysbtn RGB stripped) declares no
    # groups and hw-map falls back to power=power-led when that LED exists.
    if [ -z "$leds" ]; then ok "$id declares no LED groups (power-led fallback)"
    elif [ -z "$lbad" ]; then ok "$id LED groups well-formed"
    else bad "$id LED groups:$lbad"; fi
done
# device-env exports the pins (the Thor: the backlight detection would get wrong)
out=$(RETROFORGE_DEVICE_DIR="$DEV" RETROFORGE_MODEL="AYN Thor" bash "$ENV_SCRIPT")
printf '%s\n' "$out" | grep -q '^RETROFORGE_HW_BACKLIGHT=ae96000.dsi.0$' && ok "device-env exports the Thor's top-screen backlight" \
    || bad "device-env: $(printf '%s\n' "$out" | grep HW_BACKLIGHT)"
out=$(RETROFORGE_DEVICE_DIR="$DEV" RETROFORGE_MODEL="MANGMI Air Y Pro" bash "$ENV_SCRIPT")
printf '%s\n' "$out" | grep -q '^RETROFORGE_HW_CHARGER=pm8150b-charger$' && ok "device-env exports the Air Y Pro's smb5 charger, not the charge pump" \
    || bad "device-env: $(printf '%s\n' "$out" | grep HW_CHARGER)"
leds=$( eval "$(RETROFORGE_DEVICE_DIR="$DEV" RETROFORGE_MODEL="MANGMI Pocket Max" bash "$ENV_SCRIPT")"; printf '%s' "$RETROFORGE_HW_LED_GROUPS" )
[ "$leds" = 'ring-left=*:indicator-[0-7] ring-right=*:indicator-[89],*:indicator-1[0-5]' ] \
    && ok "a glob survives device-env's quoting and eval" || bad "Pocket Max LED groups after eval: '$leds'"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
