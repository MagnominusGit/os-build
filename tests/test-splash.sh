#!/usr/bin/env bash
# Offline layout + rotation check for the boot splash drawer.
#
#   tests/test-splash.sh
#
# WHY THIS EXISTS. The splash is the one thing on this device whose failures are invisible by
# construction: it runs before there is a journal to read, on a board with no serial console
# ([[sm8650-no-uart]]), and every way it can be wrong looks the same from the outside — a black
# panel. "Logo clipped off the edge", "text rendered outside the visible area", "rotation applied
# the wrong way round" and "the binary never started" are one symptom on hardware, and finding
# out which costs a power-down, a card mount and an offline journal read.
#
# So this drives the REAL drawer through its `ppm` backend, which renders into PANEL space using
# exactly the same rotation the DRM and fbdev backends use, and asserts on the PIXELS. Every
# geometry in the device registry, every rotation, at build-host speed.
#
# WHAT IT CANNOT TELL YOU, so that a green run is not over-read: this proves the drawer's
# arithmetic, not the image's tool inventory and not one line of KMS. The DRM path — master,
# modeset, DirtyFB, the handover — is only answerable on hardware ([[offline-suite-inherits-host-path]]).
#
# Runs on the host, no root, no device. Needs a C compiler and python3.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRCDIR="$ROOT/apps/retroforge-splash"
BIN="$SRCDIR/build/retroforge-splash.host"
DEVDIR="$ROOT/rootfs/overlay/usr/lib/retroforge/devices"
ASSET="$ROOT/work/splash/logo.nds1"

PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

command -v python3 >/dev/null 2>&1 || { echo "python3 not found" >&2; exit 1; }

# The host build is a test artifact, not a shipped one, so building it here rather than depending
# on a make target keeps this suite runnable on its own.
if ! make -C "$SRCDIR" host >"$TMP/build.log" 2>&1; then
    echo "host build failed:" >&2; cat "$TMP/build.log" >&2; exit 1
fi

# A font is needed for the text assertions. Prefer the one the image actually ships so the metrics
# under test are the metrics that will ship; fall back to any host TTF so the suite still runs on a
# checkout that has never built a rootfs.
FONT=""
for cand in "$ROOT/work/base/usr/share/fonts/noto/NotoSansMono-Medium.ttf" \
            /usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf \
            /usr/share/fonts/TTF/DejaVuSansMono.ttf; do
    [[ -f $cand ]] && { FONT=$cand; break; }
done
# Neither path exists on every distro (Arch ships DejaVu only when ttf-dejavu is installed), so ask
# fontconfig for whatever monospace TrueType the host has.
if [[ -z $FONT ]] && command -v fc-match >/dev/null 2>&1; then
    cand=$(fc-match -f '%{file}' 'monospace:fontformat=TrueType' 2>/dev/null)
    [[ $cand == *.ttf && -f $cand ]] && FONT=$cand
fi
[[ -n $FONT ]] || { echo "no TrueType font available to test with" >&2; exit 1; }

# Likewise the logo: use the real asset when the build has produced one, otherwise synthesise one.
#
# The stand-in MUST be the size mksplash.sh renders the real asset at. The drawer warns "logo
# upscaled" whenever the requested size exceeds the asset's LONG EDGE, and the geometry loop below
# turns that warning into a failure — so a token 64px stand-in trips it on every panel in the
# registry (the smallest asks for 960*480/1080 = 426px) and reports 80 failures that say nothing
# about the shipped asset or about RENDER_PX. That is exactly what it did in CI, where this
# fallback is ALWAYS taken: the offline suites build no image, so work/splash/ never exists, while
# a dev checkout that has run `make` has the real asset and passes. A suite that only fails where
# nobody looks is worse than no suite.
#
# Reading RENDER_PX out of mksplash.sh rather than repeating the number keeps the stand-in and the
# real asset from drifting apart, and keeps the upscale assertion meaningful here: it still fails
# if the registry ever outgrows the render box, which is the thing it was written to catch.
if [[ ! -f $ASSET ]]; then
    ASSET="$TMP/logo.nds1"
    RENDER_PX=$(sed -n 's/^RENDER_PX=\([0-9][0-9]*\).*/\1/p' "$ROOT/image/mksplash.sh")
    [[ -n $RENDER_PX ]] || {
        echo "cannot read RENDER_PX from image/mksplash.sh — the synthetic logo would be the" >&2
        echo "wrong size and every geometry assertion below would fail for that reason alone." >&2
        exit 1
    }
    python3 - "$ASSET" "$RENDER_PX" <<'PY'
import struct, sys
w = h = int(sys.argv[2])
px = bytearray()
for y in range(h):
    for x in range(w):
        # An opaque disc on a transparent field: enough to test placement and clipping.
        # The radius is 44% of the box: image/splash/logo.svg renders to 685x768px of ink inside
        # its 768px box, so the real asset fills about that much of it.
        inside = (x - w / 2) ** 2 + (y - h / 2) ** 2 < (0.44 * w) ** 2
        px += bytes((255, 255, 255, 255)) if inside else bytes(4)
open(sys.argv[1], "wb").write(b"NDS1" + struct.pack("<II", w, h) + bytes(px))
PY
fi

# ---------------------------------------------------------------------------------------------
# Pixel probe. Reports the PPM's dimensions and the bounding box of everything that is not the
# background, which is all the assertions below need.
# ---------------------------------------------------------------------------------------------
probe() {  # probe <file> [threshold] -> "w h x0 y0 x1 y1 nonbg"  (bbox is -1s when nothing was drawn)
    python3 - "$1" "${2:-8}" <<'PY'
import sys
t = int(sys.argv[2])
d = open(sys.argv[1], 'rb').read()
parts = d.split(b'\n', 3)
w, h = map(int, parts[1].split())
px = parts[3]
x0 = y0 = 1 << 30; x1 = y1 = -1; n = 0
for y in range(h):
    row = px[y * w * 3:(y + 1) * w * 3]
    for x in range(w):
        # >8 rather than >0: the logo's halo fades asymptotically, and a single unit of blue in
        # the far corner is not "drawn content" for the purpose of a clipping check.
        if row[x*3] > t or row[x*3+1] > t or row[x*3+2] > t:
            n += 1
            if x < x0: x0 = x
            if x > x1: x1 = x
            if y < y0: y0 = y
            if y > y1: y1 = y
print(w, h, (x0 if x1 >= 0 else -1), (y0 if y1 >= 0 else -1), x1, y1, n)
PY
}

render() {  # render <out.ppm> <panel_w> <panel_h> <rotate> <status-text> [extra args...]
    local out=$1 pw=$2 ph=$3 rot=$4 text=$5; shift 5
    printf '%s\n' "$text" >"$TMP/status"
    "$BIN" --backend ppm --width "$pw" --height "$ph" --rotate "$rot" \
           --image "$ASSET" --font "$FONT" --status "$TMP/status" --out "$out" \
           "$@" >"$TMP/stderr" 2>&1
}

# ---------------------------------------------------------------------------------------------
# 1. Every panel in the device registry, every rotation
# ---------------------------------------------------------------------------------------------
# Rotation is the arithmetic most likely to be wrong and least likely to be noticed until a device
# shows a sideways logo, so it is checked against the real panel line-up rather than one size.
echo "device registry:"
geoms=()
if [[ -d $DEVDIR ]]; then
    while IFS= read -r conf; do
        w=$(sed -n 's/^[[:space:]]*RETROFORGE_PANEL_NATIVE_WIDTH=["'"'"']*\([0-9]*\).*/\1/p' "$conf" | head -1)
        h=$(sed -n 's/^[[:space:]]*RETROFORGE_PANEL_NATIVE_HEIGHT=["'"'"']*\([0-9]*\).*/\1/p' "$conf" | head -1)
        [[ -n $w && -n $h ]] && geoms+=("$(basename "$conf" .conf) $w $h")
    done < <(find "$DEVDIR" -name '*.conf' | sort)
fi
# A checkout with no registry must not silently pass an empty loop.
if [[ ${#geoms[@]} -eq 0 ]]; then
    bad "device registry declared no panel geometries (looked in ${DEVDIR#"$ROOT"/})"
else
    ok "found ${#geoms[@]} panel geometries in the registry"
fi

for g in "${geoms[@]}"; do
    read -r name pw ph <<<"$g"
    for rot in 0 90 180 270; do
        tag="$name ${pw}x${ph} rot=$rot"
        if ! render "$TMP/o.ppm" "$pw" "$ph" "$rot" "Starting RetroForge"; then
            bad "$tag: drawer exited non-zero"; continue
        fi
        # The asset must never be scaled up; the drawer says so and mksplash.sh sizes for it.
        if grep -q "upscaled" "$TMP/stderr"; then
            bad "$tag: logo was upscaled — raise RENDER_PX in image/mksplash.sh"; continue
        fi
        read -r ow oh x0 y0 x1 y1 n < <(probe "$TMP/o.ppm")
        # Panel-space output is always the panel's real size, whatever the rotation.
        if [[ $ow != "$pw" || $oh != "$ph" ]]; then
            bad "$tag: rendered ${ow}x${oh}, expected ${pw}x${ph}"; continue
        fi
        if [[ $n -lt 100 ]]; then
            bad "$tag: only $n pixels drawn — the frame is effectively blank"; continue
        fi
        # Nothing may touch the outermost row/column. A logo or a status line that runs off the
        # edge is the failure mode this whole suite exists to catch, and it is invisible on a
        # device until someone photographs the panel.
        if [[ $x0 -le 0 || $y0 -le 0 || $x1 -ge $((pw - 1)) || $y1 -ge $((ph - 1)) ]]; then
            bad "$tag: content touches the panel edge (bbox ${x0},${y0}..${x1},${y1})"; continue
        fi
        ok "$tag"
    done
done

# ---------------------------------------------------------------------------------------------
# 2. Rotation actually rotates, and in the direction the panel property asks for
# ---------------------------------------------------------------------------------------------
# A rotation bug that swapped the sense of 90 and 270 would still satisfy every check above. This
# pins the direction: with the canvas in landscape and the panel portrait, rot=90 must put the
# logical TOP of the frame against the panel's RIGHT edge (DRM's RIGHT_UP), and rot=270 against
# its LEFT. Each rotated frame is compared pixel for pixel against the unrotated 800x400 frame
# turned by hand: clockwise for 90, counter-clockwise for 270. Exact, and blind to the artwork --
# an earlier bbox-midpoint version of this check broke on a logo change (2026-10-27) because the
# drawer centres logo+text as one group, so the midpoint only moved by accident of the threshold.
echo
echo "rotation direction:"
render "$TMP/r0.ppm" 800 400 0 "x"
render "$TMP/r90.ppm" 400 800 90 "x"
render "$TMP/r270.ppm" 400 800 270 "x"
rotcheck() {  # rotcheck <rot0.ppm> <rotated.ppm> cw|ccw -> number of mismatched pixels
    python3 - "$@" <<'PY'
import sys
def rd(p):
    parts = open(p, 'rb').read().split(b'\n', 3)
    w, h = map(int, parts[1].split())
    return w, h, parts[3]
w, h, a = rd(sys.argv[1])
W, H, b = rd(sys.argv[2])
if (W, H) != (h, w):
    print(w * h); raise SystemExit
cw = sys.argv[3] == 'cw'
bad = 0
for y in range(h):
    for x in range(w):
        # Clockwise: logical top -> panel right. Counter-clockwise: logical top -> panel left.
        px, py = (h - 1 - y, x) if cw else (y, w - 1 - x)
        i, j = (y * w + x) * 3, (py * W + px) * 3
        bad += a[i:i + 3] != b[j:j + 3]
print(bad)
PY
}
a_bad=$(rotcheck "$TMP/r0.ppm" "$TMP/r90.ppm" cw)
b_bad=$(rotcheck "$TMP/r0.ppm" "$TMP/r270.ppm" ccw)
if [[ $a_bad -eq 0 && $b_bad -eq 0 ]]; then
    ok "rot=90 is the frame turned clockwise, rot=270 counter-clockwise"
else
    bad "rotation direction is wrong or mirrored (rot90 off by $a_bad px, rot270 off by $b_bad px)"
fi

# ---------------------------------------------------------------------------------------------
# 2b. The activity bar, and the handoff gamescope keeps it up from
# ---------------------------------------------------------------------------------------------
# At the yield the drawer writes its frame and the bar's frames (strips of the panel buffer, one
# per tick) for gamescope's patch 0050, which shows nothing else until the shell's first frame.
# gamescope copies the strips in blind, so every number in the header has to be right: the frame
# is the panel buffer exactly, the strip rect is where the bar is on THIS panel's rotation, and the
# strips are the bar turned the same way as the rest of the frame.
echo
echo "activity bar and handoff:"
render "$TMP/h0.ppm" 800 400 0 "x" --tick 7 --handoff "$TMP/h0.bin"
render "$TMP/h90.ppm" 400 800 90 "x" --tick 7 --handoff "$TMP/h90.bin"
render "$TMP/h270.ppm" 400 800 270 "x" --tick 7 --handoff "$TMP/h270.bin"
render "$TMP/hairx.ppm" 1080 1920 270 "Starting RetroForge" --tick 33 --handoff "$TMP/hairx.bin"
while IFS= read -r line; do
    case $line in ok\ *) ok "${line#ok }" ;; *) bad "$line" ;; esac
done < <(python3 - "$TMP" <<'PY'
import struct, sys
T = sys.argv[1]
HDR = struct.Struct('<12IQ')
def ppm(p):
    parts = open(p, 'rb').read().split(b'\n', 3)
    w, h = map(int, parts[1].split())
    return w, h, parts[3]
def handoff(p):
    d = open(p, 'rb').read()
    f = dict(zip('magic w h rot sx sy sw sh n tick_ms tick0 pad t0'.split(), HDR.unpack_from(d)))
    f['size'] = len(d)
    off = HDR.size + f['w'] * f['h'] * 4
    f['frame'] = d[HDR.size:off]
    n = f['sw'] * f['sh'] * 4
    f['strips'] = [d[off + k * n:off + (k + 1) * n] for k in range(f['n'])]
    return f
def rgb(v):  # XRGB8888 little endian -> the ppm's RGB
    return bytes((v[2], v[1], v[0]))
out = []
H = {}
for tag, pw, ph, rot, tick in (('h0', 800, 400, 0, 7), ('h90', 400, 800, 90, 7), ('h270', 400, 800, 270, 7),
                               ('hairx', 1080, 1920, 270, 33)):
    h = H[tag] = handoff(f'{T}/{tag}.bin')
    w, hh, px = ppm(f'{T}/{tag}.ppm')
    want = (0x31534652, pw, ph, rot, 40, 40, tick % 40)
    if (h['magic'], h['w'], h['h'], h['rot'], h['n'], h['tick_ms'], h['tick0']) != want:
        out.append(f'{tag}: header {h["magic"]:#x} {h["w"]}x{h["h"]} rot {h["rot"]} {h["n"]} strips/{h["tick_ms"]} ms tick0 {h["tick0"]}')
        continue
    if h['size'] != HDR.size + pw * ph * 4 + 40 * h['sw'] * h['sh'] * 4:
        out.append(f'{tag}: {h["size"]} bytes, not header + frame + 40 strips'); continue
    if not (h['sw'] and h['sh'] and h['sx'] + h['sw'] <= pw and h['sy'] + h['sh'] <= ph):
        out.append(f'{tag}: strip {h["sx"]},{h["sy"]} {h["sw"]}x{h["sh"]} is not inside the frame'); continue
    fr = h['frame']
    if any(rgb(fr[i * 4:i * 4 + 3]) != px[i * 3:i * 3 + 3] for i in range(pw * ph)):
        out.append(f'{tag}: the frame is not the panel buffer'); continue
    cur = h['strips'][h['tick0']]
    region = b''.join(fr[((h['sy'] + y) * pw + h['sx']) * 4:((h['sy'] + y) * pw + h['sx'] + h['sw']) * 4] for y in range(h['sh']))
    if cur != region:
        out.append(f'{tag}: strip {h["tick0"]} is not what the frame shows at its tick'); continue
    out.append(f'ok {tag}: header, frame and the strip on screen match the panel buffer')

h0, h90, h270 = H['h0'], H['h90'], H['h270']
s = h0['strips']
if all(s[k] == s[(40 - k) % 40] for k in range(40)) and s[0] != s[10]:
    out.append('ok the bar sweeps out and back: strip k is strip 40-k, and it moves')
else:
    out.append('the strips do not sweep out and back')
def seg(strip, sw):  # first and last bright column of the bar's first row
    cols = [i for i in range(sw) if strip[i * 4 + 1] > 128]
    return (cols[0], cols[-1]) if cols else (-1, -1)
segs = [seg(s[k], h0['sw']) for k in range(21)]
if segs[0][0] == 0 and segs[20][1] == h0['sw'] - 1 and all(segs[k][0] <= segs[k + 1][0] for k in range(20)) \
        and len({b - a for a, b in segs}) == 1:
    out.append('ok the segment runs edge to edge at a constant width')
else:
    out.append(f'the segment does not run edge to edge at a constant width: {segs[0]} .. {segs[20]}')

# The strip rect and pixels on a turned panel are the unturned ones turned the same way as the
# rotation check above: clockwise for 90, counter-clockwise for 270.
x0, y0, bw, bh = h0['sx'], h0['sy'], h0['sw'], h0['sh']
for tag, h, rect, cw in (('rot=90', h90, (400 - y0 - bh, x0, bh, bw), True), ('rot=270', h270, (y0, 800 - x0 - bw, bh, bw), False)):
    if (h['sx'], h['sy'], h['sw'], h['sh']) != rect:
        out.append(f'{tag}: strip at {h["sx"]},{h["sy"]} {h["sw"]}x{h["sh"]}, the bar is at {rect}'); continue
    bad = 0
    for k in (0, 7, 20):
        a, b = h0['strips'][k], h['strips'][k]
        for j in range(bh):
            for i in range(bw):
                X, Y = x0 + i, y0 + j
                PX, PY = (400 - 1 - Y, X) if cw else (Y, 800 - 1 - X)
                q = ((PY - h['sy']) * h['sw'] + PX - h['sx']) * 4
                bad += a[(j * bw + i) * 4:(j * bw + i) * 4 + 4] != b[q:q + 4]
    out.append(f'ok {tag}: the strips are the bar turned with the frame' if not bad else f'{tag}: {bad} strip pixels are not the bar turned')
print('\n'.join(out))
PY
)

# ---------------------------------------------------------------------------------------------
# 3. Text: wrapping, the error marker, and the empty case
# ---------------------------------------------------------------------------------------------
echo
echo "status text:"

render "$TMP/long.ppm" 1920 1080 0 \
    "Installing Steam. First boot downloads and installs the Steam client, which can take several minutes on a slow connection."
read -r _ _ lx0 _ lx1 _ _ < <(probe "$TMP/long.ppm")
if [[ $lx0 -gt 0 && $lx1 -lt 1919 ]]; then
    ok "a long status line wraps inside the panel"
else
    bad "a long status line ran off the panel (x ${lx0}..${lx1})"
fi

# The '!' prefix is a marker, not content: it must colour the line red and never be drawn.
#
# Measured by DIFFING the two renders rather than summing each. The only thing that differs
# between them is the text, so the differing pixels ARE the text -- which makes the assertion
# independent of the logo's size and position. An earlier version summed green over the whole
# frame and silently coupled itself to the logo: enlarging the logo diluted the text's share and
# broke a test that was measuring the right thing for the wrong reason.
render "$TMP/plain.ppm" 1920 1080 0 "Steam launch failed"
render "$TMP/err.ppm"   1920 1080 0 "!Steam launch failed"
read -r ndiff plain_rg err_rg < <(python3 - "$TMP/plain.ppm" "$TMP/err.ppm" <<'REDCHECK'
import sys
def load(p):
    d = open(p, 'rb').read(); parts = d.split(b'\n', 3)
    w, h = map(int, parts[1].split()); return w * h, parts[3]
n, a = load(sys.argv[1]); _, b = load(sys.argv[2])
# Redness = R - G. Near-white text scores ~0; red text scores strongly positive.
n_diff = pa = pb = 0
for i in range(0, n * 3, 3):
    if a[i] != b[i] or a[i+1] != b[i+1] or a[i+2] != b[i+2]:
        n_diff += 1
        pa += a[i] - a[i+1]
        pb += b[i] - b[i+1]
print(n_diff, pa // max(n_diff, 1), pb // max(n_diff, 1))
REDCHECK
)
if [[ $ndiff -lt 100 ]]; then
    bad "the '!' marker changed nothing at all ($ndiff pixels differ)"
elif [[ $err_rg -gt $((plain_rg + 40)) ]]; then
    ok "a '!' status line renders red (R-G $err_rg vs $plain_rg over $ndiff text pixels)"
else
    bad "the '!' line is not red (R-G $err_rg vs $plain_rg over $ndiff text pixels)"
fi

# ...and the marker itself must never be drawn. If '!' were rendered as a glyph the error line
# would be visibly wider than the same text without it.
render "$TMP/errwidth.ppm" 1920 1080 0 "!AAAA"
render "$TMP/plainwidth.ppm" 1920 1080 0 "AAAA"
read -r _ _ ex0 _ ex1 _ _ < <(probe "$TMP/errwidth.ppm")
read -r _ _ px0 _ px1 _ _ < <(probe "$TMP/plainwidth.ppm")
if [[ $(( (ex1 - ex0) - (px1 - px0) )) -le 2 ]]; then
    ok "the '!' marker is stripped, not drawn"
else
    bad "the '!' appears to be drawn (error line is $(( (ex1-ex0) - (px1-px0) ))px wider)"
fi

# An empty status must still draw the logo — a blank panel is exactly what we are trying to avoid.
render "$TMP/empty.ppm" 1920 1080 0 ""
read -r _ _ _ _ _ _ en < <(probe "$TMP/empty.ppm")
[[ $en -gt 100 ]] && ok "an empty status still draws the logo" \
                  || bad "an empty status drew nothing at all ($en pixels)"

# ---------------------------------------------------------------------------------------------
# 4. Degraded inputs must degrade, not abort
# ---------------------------------------------------------------------------------------------
# On a device with no console, a drawer that exits because one input was missing is strictly worse
# than one that shows a partial frame: the first is a black screen, the second still says
# something. These pin that choice so a later refactor cannot quietly turn it into an exit.
echo
echo "degraded inputs:"

printf 'Preparing\n' >"$TMP/status"
"$BIN" --backend ppm --width 800 --height 600 --font "$FONT" --status "$TMP/status" \
       --image "$TMP/nonexistent.nds1" --out "$TMP/nologo.ppm" >"$TMP/e1" 2>&1
rc=$?
read -r _ _ _ _ _ _ n1 < <(probe "$TMP/nologo.ppm" 2>/dev/null || echo "0 0 -1 -1 -1 -1 0")
[[ $rc -eq 0 && $n1 -gt 0 ]] && ok "a missing logo still renders the status text" \
                             || bad "a missing logo aborted the render (rc=$rc, $n1 pixels)"

"$BIN" --backend ppm --width 800 --height 600 --image "$ASSET" --status "$TMP/status" \
       --font "$TMP/nonexistent.ttf" --out "$TMP/nofont.ppm" >"$TMP/e2" 2>&1
rc=$?
read -r _ _ _ _ _ _ n2 < <(probe "$TMP/nofont.ppm" 2>/dev/null || echo "0 0 -1 -1 -1 -1 0")
[[ $rc -eq 0 && $n2 -gt 0 ]] && ok "a missing font still renders the logo" \
                             || bad "a missing font aborted the render (rc=$rc, $n2 pixels)"

# A truncated or corrupt asset must be refused by name, not read past its end.
head -c 200 "$ASSET" >"$TMP/trunc.nds1"
"$BIN" --backend ppm --width 800 --height 600 --image "$TMP/trunc.nds1" --font "$FONT" \
       --status "$TMP/status" --out "$TMP/trunc.ppm" >"$TMP/e3" 2>&1
grep -q "bad NDS1 header" "$TMP/e3" && ok "a truncated NDS1 asset is rejected by name" \
                                    || bad "a truncated NDS1 asset was not reported ($(head -1 "$TMP/e3"))"

# An invalid rotation is a caller bug and must fail loudly rather than silently drawing upright.
"$BIN" --backend ppm --rotate 45 --out "$TMP/bad.ppm" >"$TMP/e4" 2>&1
[[ $? -ne 0 ]] && ok "an invalid --rotate is refused" || bad "--rotate 45 was accepted"

# ---------------------------------------------------------------------------------------------
# 5. The handover loop, and surviving switch_root
# ---------------------------------------------------------------------------------------------
# THIS IS THE REGRESSION TEST FOR THE BUG THAT REACHED HARDWARE. The drawer is started from the
# initramfs and keeps running across switch_root, which chroots its children and then deletes the
# old root's contents -- so the drawer is left with an empty root and every path-based open()
# fails from then on. It painted correctly, ticked forever, and never yielded the display, with
# nothing in any log to say why. The fix is to hold a dirfd on the run directory instead of
# re-resolving paths, and this proves it: the run directory is made UNREACHABLE BY PATH after the
# drawer starts, exactly as the pivot does, and the handshake must still work.
#
# The `null` backend exists for this: it runs the real control loop and presents nowhere, so the
# loop is reachable without a display.
echo
echo "handover across switch_root:"

RUN="$TMP/run/retroforge/splash"
mkdir -p "$RUN"
printf 'Starting RetroForge\n' >"$RUN/status"

"$BIN" --backend null --width 640 --height 480 --image "$ASSET" --font "$FONT" \
       --status "$RUN/status" --takeover "$RUN/takeover" >"$TMP/null.log" 2>&1 &
drawer=$!
# Give it time to announce ownership before anything moves.
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -s "$RUN/takeover" ]] && break; sleep 0.2; done

if [[ "$(cat "$RUN/takeover" 2>/dev/null)" == "$drawer" ]]; then
    ok "the drawer announces its own pid in the takeover file"
else
    bad "the drawer did not announce ownership (takeover='$(cat "$RUN/takeover" 2>/dev/null)', pid=$drawer)"
fi

# Simulate the pivot: the directory keeps existing and keeps its inode (as the moved /run tmpfs
# does), but the PATH the drawer was given no longer resolves to it. A path-based implementation
# reads nothing from here on; a dirfd-based one is unaffected.
mv "$TMP/run" "$TMP/run-moved"
RUN="$TMP/run-moved/retroforge/splash"
if [[ -e "$TMP/run/retroforge/splash/takeover" ]]; then
    bad "the pivot simulation did not actually break the path"
else
    ok "the run directory is no longer reachable by its original path"
fi

# Status must still flow. A regression here is the "splash says Starting RetroForge forever" half.
printf 'Installing Steam\n' >"$RUN/status"
sleep 1
# Then the handover. A regression here is the half that black-screens the session.
printf 'sddm\n' >"$RUN/takeover"

gone=0
for _ in $(seq 1 25); do
    kill -0 "$drawer" 2>/dev/null || { gone=1; break; }
    sleep 0.2
done
if [[ $gone -eq 1 ]]; then
    ok "the drawer yields and exits after the pivot (dirfd survived)"
else
    bad "the drawer did NOT yield after the pivot -- it is re-resolving paths, not using a dirfd"
    kill "$drawer" 2>/dev/null
fi
wait "$drawer" 2>/dev/null
grep -q "yielding display to 'sddm'" "$TMP/null.log" \
    && ok "it names who it yielded to" \
    || bad "no 'yielding display' line (log: $(tr '\n' '|' <"$TMP/null.log" | head -c 200))"

# The diagnostics themselves: one write() per message, because in the initramfs stderr is
# /dev/kmsg and every write becomes a separate record. Splitting a message across three writes
# lost the text entirely on hardware.
if [[ -s "$TMP/null.log" ]] && ! grep -qE '^retroforge-splash: *$' "$TMP/null.log"; then
    ok "log lines carry their message (not split across writes)"
else
    bad "empty 'retroforge-splash:' lines -- note() is splitting one message into several writes"
fi

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
