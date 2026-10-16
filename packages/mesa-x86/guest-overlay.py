#!/usr/bin/env python3
"""Lay the built x86 Mesa over an unpacked guest root, then prove the guest uses it.

    guest-overlay.py ROOT PAYLOAD --epoch N [--add DEST=SRC ...] [--report FILE]

Called by container-compose.sh between unsquashfs and mksquashfs. Standard library only, and it
needs no root for anything but the ownership it copies, so tests/test-fex-guest.sh drives it on
fabricated trees.

What it does, in order:

1. Checks the guest before touching it: /graphics_provider.json is a v0 manifest that names
   x86_64-linux-gnu and i386-linux-gnu.
2. Copies every file and symlink under PAYLOAD to the same path under ROOT. Existing files are
   replaced; a directory is never replaced; a symlink in the payload must be relative. New files
   take the owner of the directory they land in (FEX's image is all uid 1000) and the mtime
   --epoch. Directories it writes into keep their old mtime, so the same inputs give the same
   image bytes.
3. Proves the result, and fails on any doubt:
   - graphics_provider.json still parses and every directory it names exists;
   - each arch's freedreno ICD resolves, inside ROOT and the way the Vulkan loader and
     pressure-vessel would, to OUR libvulkan_freedreno.so (same bytes), with the right ELF class;
   - libEGL_mesa.so.0 and libGLX_mesa.so.0 resolve, through each arch's library paths, to ours;
   - every ELF in the payload is the arch of the directory it is in;
   - every Vulkan layer manifest we ship finds its library for both arches.
"""
import argparse
import hashlib
import json
import os
import shutil
import stat
import sys

ARCHES = {
    # tuple in graphics_provider.json -> (libdir, ICD file suffix, ELF class, e_machine, ICD arch)
    "x86_64-linux-gnu": ("usr/lib", "x86_64", 2, 62, "64"),
    "i386-linux-gnu": ("usr/lib32", "i686", 1, 3, "32"),
}
ELF_NAME = {(2, 62): "ELF64 x86-64", (1, 3): "ELF32 i386"}


class Fail(Exception):
    pass


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def elf_kind(path):
    """(EI_CLASS, e_machine) of an ELF file, or None if it is not one."""
    with open(path, "rb") as f:
        head = f.read(20)
    if len(head) < 20 or head[:4] != b"\x7fELF":
        return None
    order = "little" if head[5] == 1 else "big"
    return head[4], int.from_bytes(head[18:20], order)


def resolve_in_root(root, path, hops=40):
    """Resolve an absolute guest path the way the guest would see it: symlinks are followed
    component by component, and an absolute link target means ROOT/target, never the host's.
    Returns the host path of the final object, or None when a component does not exist."""
    parts = [p for p in path.split("/") if p]
    cur = root
    while parts:
        part = parts.pop(0)
        if part == ".":
            continue
        if part == "..":
            cur = os.path.dirname(cur) if cur != root else root
            continue
        nxt = os.path.join(cur, part)
        if os.path.islink(nxt):
            hops -= 1
            if hops < 0:
                raise Fail(f"symlink loop resolving {path}")
            target = os.readlink(nxt)
            if target.startswith("/"):
                cur = root
            parts = [p for p in target.split("/") if p] + parts
            continue
        if not os.path.lexists(nxt):
            return None
        cur = nxt
    return cur


def load_provider(root):
    gp = os.path.join(root, "graphics_provider.json")
    if not os.path.isfile(gp) or os.path.islink(gp):
        raise Fail("/graphics_provider.json is missing (or a symlink): this is not a graphics provider")
    try:
        with open(gp) as f:
            doc = json.load(f)
    except ValueError as e:
        raise Fail(f"/graphics_provider.json does not parse: {e}")
    v0 = doc.get("graphics_provider_v0")
    if not isinstance(v0, dict):
        raise Fail("/graphics_provider.json has no graphics_provider_v0 object")
    if v0.get("root", "./") not in ("./", ".", ""):
        raise Fail(f"/graphics_provider.json root is {v0.get('root')!r}; compose expects the image root")
    archs = v0.get("architectures")
    if isinstance(archs, list):
        archs = {a: {} for a in archs}
    if not isinstance(archs, dict):
        raise Fail("/graphics_provider.json has no architectures")
    for tup in ARCHES:
        if tup not in archs:
            raise Fail(f"/graphics_provider.json does not list {tup}")
    return archs


def lib_paths(archs, tup):
    """Where glibc in the guest finds a bare soname for this arch: the manifest's fallback paths
    (what pressure-vessel uses), else the arch's libdir."""
    paths = archs.get(tup, {}).get("fallback_library_paths") or ["/" + ARCHES[tup][0]]
    return [p if p.startswith("/") else "/" + p for p in paths]


def find_lib(root, archs, tup, name):
    if "/" in name:
        return resolve_in_root(root, name if name.startswith("/") else "/" + name)
    for d in lib_paths(archs, tup):
        hit = resolve_in_root(root, f"{d.rstrip('/')}/{name}")
        if hit and os.path.isfile(hit):
            return hit
    return None


def overlay(root, payload, epoch, extra, report):
    entries = []  # (relpath, source path)
    for dirpath, dirnames, filenames in os.walk(payload):
        dirnames.sort()
        for name in sorted(filenames + [d for d in dirnames if os.path.islink(os.path.join(dirpath, d))]):
            src = os.path.join(dirpath, name)
            entries.append((os.path.relpath(src, payload), src))
    for spec in extra:
        dest, _, src = spec.partition("=")
        if not dest or not src:
            raise Fail(f"--add wants DEST=SRC, got {spec!r}")
        entries.append((dest.lstrip("/"), src))
    if not entries:
        raise Fail(f"the payload {payload} is empty")

    root_real = os.path.realpath(root)
    saved = {}  # existing directory -> its mtime before we wrote into it

    def ensure_dir(rel):
        """Create ROOT/rel (and parents) owned like their parent; remember the mtimes of the
        existing directories we are about to modify."""
        host = os.path.join(root, rel) if rel else root
        if os.path.isdir(host):
            real = os.path.realpath(host)
            if os.path.commonpath([real, root_real]) != root_real:
                raise Fail(f"/{rel} resolves outside the guest root ({real})")
            saved.setdefault(real, os.stat(real).st_mtime_ns)
            return real
        if os.path.lexists(host):
            raise Fail(f"/{rel} exists and is not a directory")
        parent = ensure_dir(os.path.dirname(rel))
        os.mkdir(host, 0o755)
        st = os.stat(parent)
        os.lchown(host, st.st_uid, st.st_gid)
        saved[os.path.realpath(host)] = epoch * 10**9  # new: stamped with the epoch at the end
        return os.path.realpath(host)

    for rel, src in entries:
        st = os.lstat(src)
        if not (stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode)):
            raise Fail(f"payload {rel} is neither a file nor a symlink")
        if stat.S_ISLNK(st.st_mode) and os.readlink(src).startswith("/"):
            raise Fail(f"payload {rel} is an absolute symlink ({os.readlink(src)}); a graphics "
                       "provider's links must be relative")
        parent = ensure_dir(os.path.dirname(rel))
        dst = os.path.join(parent, os.path.basename(rel))
        if os.path.isdir(dst) and not os.path.islink(dst):
            raise Fail(f"payload {rel} would replace the directory /{rel}")
        action = "replace" if os.path.lexists(dst) else "add"
        if action == "replace":
            os.unlink(dst)
        if stat.S_ISLNK(st.st_mode):
            os.symlink(os.readlink(src), dst)
        else:
            shutil.copyfile(src, dst)
            os.chmod(dst, stat.S_IMODE(st.st_mode))
        pst = os.stat(parent)
        os.lchown(dst, pst.st_uid, pst.st_gid)
        os.utime(dst, ns=(epoch * 10**9, epoch * 10**9), follow_symlinks=False)
        report.append(f"{action} /{rel}")

    # Deepest first, so restoring a child cannot disturb a parent restored before it.
    for d in sorted(saved, key=len, reverse=True):
        os.utime(d, ns=(saved[d], saved[d]))


def verify(root, payload, archs):
    errors = []

    for tup, info in archs.items():
        if not isinstance(info, dict):
            continue
        for key in ("dri", "gconv", "gbm"):
            if key in info and resolve_in_root(root, info[key]) is None:
                errors.append(f"graphics_provider.json: {tup} {key} {info[key]} does not exist")
        for p in info.get("fallback_library_paths", []):
            if resolve_in_root(root, p) is None:
                errors.append(f"graphics_provider.json: {tup} fallback path {p} does not exist")

    for tup, (libdir, cpu, ei_class, machine, icd_arch) in ARCHES.items():
        want = ELF_NAME[(ei_class, machine)]

        # Vulkan: the ICD names our driver.
        ours = os.path.join(payload, libdir, "libvulkan_freedreno.so")
        icd_rel = f"usr/share/vulkan/icd.d/freedreno_icd.{cpu}.json"
        icd = os.path.join(root, icd_rel)
        if not os.path.isfile(ours):
            errors.append(f"payload has no {libdir}/libvulkan_freedreno.so")
        elif not os.path.isfile(icd):
            errors.append(f"/{icd_rel} is missing")
        else:
            try:
                with open(icd) as f:
                    doc = json.load(f)["ICD"]
                lib = doc["library_path"]
            except (ValueError, KeyError, TypeError) as e:
                errors.append(f"/{icd_rel} is not a Vulkan ICD manifest ({e})")
            else:
                hit = find_lib(root, archs, tup, lib)
                if hit is None:
                    errors.append(f"/{icd_rel}: library_path {lib} does not resolve in the guest")
                elif sha256(hit) != sha256(ours):
                    errors.append(f"/{icd_rel}: library_path {lib} is not our libvulkan_freedreno.so")
                elif elf_kind(hit) != (ei_class, machine):
                    errors.append(f"/{icd_rel}: {lib} is not {want}")
                if doc.get("library_arch", icd_arch) != icd_arch:
                    errors.append(f"/{icd_rel}: library_arch {doc.get('library_arch')} is not {icd_arch}")

        # GL: what libglvnd loads by soname.
        for soname in ("libEGL_mesa.so.0", "libGLX_mesa.so.0"):
            mine = os.path.join(payload, libdir, soname)
            if not os.path.lexists(mine):
                errors.append(f"payload has no {libdir}/{soname}")
                continue
            hit = find_lib(root, archs, tup, soname)
            if hit is None:
                errors.append(f"{tup}: {soname} does not resolve in the guest")
            elif sha256(hit) != sha256(os.path.realpath(mine)):
                errors.append(f"{tup}: {soname} resolves to {os.path.relpath(hit, root)}, not ours")

        # Every ELF we ship under this libdir is this arch.
        base = os.path.join(payload, libdir)
        for dirpath, _, filenames in os.walk(base):
            for name in filenames:
                p = os.path.join(dirpath, name)
                if os.path.islink(p):
                    continue
                kind = elf_kind(p)
                if kind is not None and kind != (ei_class, machine):
                    errors.append(f"payload {os.path.relpath(p, payload)} is not {want}")

    # Vulkan layers we ship: a bare library_path is looked up by each arch's loader, so one
    # manifest has to find the right ELF class on both sides.
    for kind in ("implicit_layer.d", "explicit_layer.d"):
        ldir = os.path.join(payload, "usr/share/vulkan", kind)
        if not os.path.isdir(ldir):
            continue
        for name in sorted(os.listdir(ldir)):
            rel = f"usr/share/vulkan/{kind}/{name}"
            try:
                with open(os.path.join(ldir, name)) as f:
                    lib = json.load(f)["layer"]["library_path"]
            except (ValueError, KeyError, TypeError) as e:
                errors.append(f"/{rel} is not a Vulkan layer manifest ({e})")
                continue
            if "/" in lib:
                errors.append(f"/{rel}: library_path {lib} is a path; one manifest for two "
                              "arches needs a bare file name")
                continue
            for tup, (libdir, _, ei_class, machine, _) in ARCHES.items():
                hit = find_lib(root, archs, tup, lib)
                if hit is None or elf_kind(hit) != (ei_class, machine):
                    errors.append(f"/{rel}: {lib} has no {ELF_NAME[(ei_class, machine)]} copy "
                                  f"on the {tup} library path")

    if errors:
        raise Fail("the composed guest does not use our Mesa:\n  " + "\n  ".join(errors))


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("root")
    ap.add_argument("payload")
    ap.add_argument("--epoch", type=int, required=True)
    ap.add_argument("--add", action="append", default=[], metavar="DEST=SRC")
    ap.add_argument("--report")
    a = ap.parse_args()

    report = []
    try:
        archs = load_provider(a.root)
        before = sha256(os.path.join(a.root, "graphics_provider.json"))
        overlay(a.root, a.payload, a.epoch, a.add, report)
        if sha256(os.path.join(a.root, "graphics_provider.json")) != before:
            raise Fail("the payload replaced /graphics_provider.json; it belongs to the guest")
        verify(a.root, a.payload, load_provider(a.root))
    except Fail as e:
        print(f"ERROR: guest-overlay: {e}", file=sys.stderr)
        return 1
    if a.report:
        with open(a.report, "w") as f:
            f.write("\n".join(report) + "\n")
    print(f"guest-overlay: {sum(r.startswith('replace') for r in report)} replaced, "
          f"{sum(r.startswith('add') for r in report)} added; ICDs and GL resolve to ours",
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
