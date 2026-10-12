#!/usr/bin/env python3
"""Spike 0.1: do two CRTCs flip independently with separate atomic commits?

Modesets every connected DSI connector on its own CRTC + primary plane, then for
DURATION seconds keeps exactly one NONBLOCK|PAGE_FLIP_EVENT commit in flight per
CRTC (each commit touches only that CRTC's plane). Reports, per CRTC: flips,
vblank interval stats, commit ioctl latency, EBUSY count; plus the phase offset
between the two CRTCs. Needs DRM master: stop the session first.
"""
import ctypes as C, errno, fcntl, mmap, os, select, struct, sys, time

DURATION = float(sys.argv[1]) if len(sys.argv) > 1 else 10.0
drm = C.CDLL("libdrm.so.2", use_errno=True)

class ModeInfo(C.Structure):
    _fields_ = [("clock", C.c_uint32)] + [(n, C.c_uint16) for n in
        ("hdisplay", "hsync_start", "hsync_end", "htotal", "hskew",
         "vdisplay", "vsync_start", "vsync_end", "vtotal", "vscan")] + [
        ("vrefresh", C.c_uint32), ("flags", C.c_uint32), ("type", C.c_uint32),
        ("name", C.c_char * 32)]

class Res(C.Structure):
    _fields_ = [("count_fbs", C.c_int), ("fbs", C.POINTER(C.c_uint32)),
                ("count_crtcs", C.c_int), ("crtcs", C.POINTER(C.c_uint32)),
                ("count_connectors", C.c_int), ("connectors", C.POINTER(C.c_uint32)),
                ("count_encoders", C.c_int), ("encoders", C.POINTER(C.c_uint32)),
                ("min_width", C.c_uint32), ("max_width", C.c_uint32),
                ("min_height", C.c_uint32), ("max_height", C.c_uint32)]

class Connector(C.Structure):
    _fields_ = [("connector_id", C.c_uint32), ("encoder_id", C.c_uint32),
                ("connector_type", C.c_uint32), ("connector_type_id", C.c_uint32),
                ("connection", C.c_int), ("mmWidth", C.c_uint32), ("mmHeight", C.c_uint32),
                ("subpixel", C.c_int), ("count_modes", C.c_int), ("modes", C.POINTER(ModeInfo)),
                ("count_props", C.c_int), ("props", C.POINTER(C.c_uint32)),
                ("prop_values", C.POINTER(C.c_uint64)),
                ("count_encoders", C.c_int), ("encoders", C.POINTER(C.c_uint32))]

class Encoder(C.Structure):
    _fields_ = [(n, C.c_uint32) for n in
                ("encoder_id", "encoder_type", "crtc_id", "possible_crtcs", "possible_clones")]

class PlaneRes(C.Structure):
    _fields_ = [("count_planes", C.c_uint32), ("planes", C.POINTER(C.c_uint32))]

class Plane(C.Structure):
    _fields_ = [("count_formats", C.c_uint32), ("formats", C.POINTER(C.c_uint32))] + [
        (n, C.c_uint32) for n in ("plane_id", "crtc_id", "fb_id", "crtc_x", "crtc_y",
                                  "x", "y", "possible_crtcs", "gamma_size")]

class ObjProps(C.Structure):
    _fields_ = [("count_props", C.c_uint32), ("props", C.POINTER(C.c_uint32)),
                ("prop_values", C.POINTER(C.c_uint64))]

class PropRes(C.Structure):
    _fields_ = [("prop_id", C.c_uint32), ("flags", C.c_uint32), ("name", C.c_char * 32)]

for fn, rt in (("drmModeGetResources", Res), ("drmModeGetConnector", Connector),
               ("drmModeGetEncoder", Encoder), ("drmModeGetPlaneResources", PlaneRes),
               ("drmModeGetPlane", Plane), ("drmModeObjectGetProperties", ObjProps),
               ("drmModeGetProperty", PropRes)):
    getattr(drm, fn).restype = C.POINTER(rt)
drm.drmModeAtomicAlloc.restype = C.c_void_p
drm.drmModeAtomicAddProperty.argtypes = [C.c_void_p, C.c_uint32, C.c_uint32, C.c_uint64]
drm.drmModeAtomicCommit.argtypes = [C.c_int, C.c_void_p, C.c_uint32, C.c_void_p]
drm.drmModeAtomicFree.argtypes = [C.c_void_p]

DRM_MODE_OBJECT_CRTC, DRM_MODE_OBJECT_CONNECTOR, DRM_MODE_OBJECT_PLANE = 0xcccccccc, 0xc0c0c0c0, 0xeeeeeeee
EVENT, NONBLOCK, MODESET = 0x1, 0x200, 0x400
DSI = 16

fd = os.open("/dev/dri/card0", os.O_RDWR | os.O_CLOEXEC)
assert drm.drmSetClientCap(fd, 2, 1) == 0 and drm.drmSetClientCap(fd, 3, 1) == 0, "client caps"

def props(obj, typ):
    p = drm.drmModeObjectGetProperties(fd, obj, typ).contents
    out = {}
    for i in range(p.count_props):
        pr = drm.drmModeGetProperty(fd, p.props[i]).contents
        out[pr.name.decode()] = (pr.prop_id, p.prop_values[i])
    return out

def ioc_rw(nr, size):
    return (3 << 30) | (size << 16) | (ord("d") << 8) | nr

def dumb_fb(w, h, colour):
    req = bytearray(struct.pack("IIIIIIQ", h, w, 32, 0, 0, 0, 0))
    fcntl.ioctl(fd, ioc_rw(0xB2, 32), req)
    _, _, _, _, handle, pitch, size = struct.unpack("IIIIIIQ", req)
    m = bytearray(struct.pack("IIQ", handle, 0, 0))
    fcntl.ioctl(fd, ioc_rw(0xB3, 16), m)
    off = struct.unpack("IIQ", m)[2]
    mm = mmap.mmap(fd, size, mmap.MAP_SHARED, mmap.PROT_WRITE, offset=off)
    mm.write(struct.pack("<I", colour) * (size // 4))
    mm.close()
    fb = C.c_uint32()
    if drm.drmModeAddFB(fd, w, h, 24, 32, pitch, handle, C.byref(fb)):
        raise OSError(C.get_errno(), "AddFB")
    return fb.value

res = drm.drmModeGetResources(fd).contents
crtcs = [res.crtcs[i] for i in range(res.count_crtcs)]
pres = drm.drmModeGetPlaneResources(fd).contents
planes = []
for i in range(pres.count_planes):
    pl = drm.drmModeGetPlane(fd, pres.planes[i]).contents
    planes.append((pl.plane_id, pl.possible_crtcs, props(pl.plane_id, DRM_MODE_OBJECT_PLANE)))

outs, used_crtc, used_plane = [], set(), set()
for i in range(res.count_connectors):
    c = drm.drmModeGetConnector(fd, res.connectors[i]).contents
    if c.connector_type != DSI or c.connection != 1:
        continue
    mask = 0
    for e in range(c.count_encoders):
        mask |= drm.drmModeGetEncoder(fd, c.encoders[e]).contents.possible_crtcs
    ci = next(k for k in range(len(crtcs)) if mask & (1 << k) and k not in used_crtc)
    used_crtc.add(ci)
    pid, _, pprops = next(p for p in planes if p[0] not in used_plane and p[1] & (1 << ci)
                          and p[2]["type"][1] == 1)
    used_plane.add(pid)
    mode = c.modes[0]
    for m in range(c.count_modes):
        if c.modes[m].type & 0x8:  # preferred
            mode = c.modes[m]
    blob = C.c_uint32()
    drm.drmModeCreatePropertyBlob(fd, C.byref(mode), C.sizeof(ModeInfo), C.byref(blob))
    name = f"DSI-{c.connector_type_id}"
    w, h = mode.hdisplay, mode.vdisplay
    outs.append(dict(name=name, conn=c.connector_id, cprops=props(c.connector_id, DRM_MODE_OBJECT_CONNECTOR),
                     crtc=crtcs[ci], crtcprops=props(crtcs[ci], DRM_MODE_OBJECT_CRTC),
                     plane=pid, pprops=pprops, blob=blob.value, w=w, h=h, vrefresh=mode.vrefresh,
                     fbs=[dumb_fb(w, h, 0x00202020), dumb_fb(w, h, 0x00222222)], cur=0,
                     pending=False, flips=[], lat=[], ebusy=0, other_err=0))
    print(f"{name}: conn {c.connector_id} crtc {crtcs[ci]} (idx {ci}) plane {pid} {w}x{h}@{mode.vrefresh}")

assert len(outs) == 2, f"need 2 connected DSI connectors, got {len(outs)}"

def add_plane(req, o, fb):
    P = o["pprops"]
    for k, v in (("FB_ID", fb), ("CRTC_ID", o["crtc"]), ("SRC_X", 0), ("SRC_Y", 0),
                 ("SRC_W", o["w"] << 16), ("SRC_H", o["h"] << 16), ("CRTC_X", 0), ("CRTC_Y", 0),
                 ("CRTC_W", o["w"]), ("CRTC_H", o["h"])):
        drm.drmModeAtomicAddProperty(req, o["plane"], P[k][0], v)

# Modeset both together; detach every other plane.
req = drm.drmModeAtomicAlloc()
for pid, _, P in planes:
    if pid not in used_plane:
        drm.drmModeAtomicAddProperty(req, pid, P["FB_ID"][0], 0)
        drm.drmModeAtomicAddProperty(req, pid, P["CRTC_ID"][0], 0)
for o in outs:
    drm.drmModeAtomicAddProperty(req, o["conn"], o["cprops"]["CRTC_ID"][0], o["crtc"])
    drm.drmModeAtomicAddProperty(req, o["crtc"], o["crtcprops"]["MODE_ID"][0], o["blob"])
    drm.drmModeAtomicAddProperty(req, o["crtc"], o["crtcprops"]["ACTIVE"][0], 1)
    add_plane(req, o, o["fbs"][0])
r = drm.drmModeAtomicCommit(fd, req, MODESET, None)
drm.drmModeAtomicFree(req)
if r:
    sys.exit(f"modeset failed: {os.strerror(C.get_errno())}")
print("modeset OK; flipping both CRTCs independently for", DURATION, "s")
time.sleep(0.5)

by_crtc = {o["crtc"]: o for o in outs}

def flip(o):
    o["cur"] ^= 1
    req = drm.drmModeAtomicAlloc()
    add_plane(req, o, o["fbs"][o["cur"]])
    t0 = time.monotonic()
    r = drm.drmModeAtomicCommit(fd, req, EVENT | NONBLOCK, C.c_void_p(o["crtc"]))
    o["lat"].append(time.monotonic() - t0)
    drm.drmModeAtomicFree(req)
    if r == 0:
        o["pending"] = True
    elif C.get_errno() == errno.EBUSY:
        o["ebusy"] += 1
        o["cur"] ^= 1
    else:
        o["other_err"] += 1
        o["cur"] ^= 1

end = time.monotonic() + DURATION
while time.monotonic() < end:
    for o in outs:
        if not o["pending"]:
            flip(o)
    if select.select([fd], [], [], 0.1)[0]:
        buf = os.read(fd, 4096)
        off = 0
        while off < len(buf):
            typ, ln = struct.unpack_from("II", buf, off)
            if typ == 2:  # FLIP_COMPLETE
                _, sec, usec, seq, crtc = struct.unpack_from("QIIII", buf, off + 8)
                o = by_crtc[crtc]
                o["pending"] = False
                o["flips"].append(sec + usec / 1e6)
            off += ln

def stats(xs):
    xs = sorted(xs)
    return f"min {xs[0]*1e3:.2f} med {xs[len(xs)//2]*1e3:.2f} max {xs[-1]*1e3:.2f} ms"

for o in outs:
    iv = [b - a for a, b in zip(o["flips"], o["flips"][1:])]
    late = sum(1 for x in iv if x > 1.5 / o["vrefresh"])
    print(f"{o['name']}: {len(o['flips'])} flips ({len(o['flips'])/DURATION:.1f}/s), interval {stats(iv)}, "
          f"intervals >1.5 frames: {late}; commit ioctl {stats(o['lat'])}; EBUSY {o['ebusy']}, other errors {o['other_err']}")

a, b = outs[0]["flips"], outs[1]["flips"]
ph = []
j = 0
for t in a:
    while j + 1 < len(b) and b[j + 1] <= t:
        j += 1
    if b and b[j] <= t:
        ph.append(t - b[j])
if ph:
    print(f"phase {outs[0]['name']} after {outs[1]['name']}: first {ph[0]*1e3:.2f} ms, last {ph[-1]*1e3:.2f} ms, "
          f"{stats(ph)}")
