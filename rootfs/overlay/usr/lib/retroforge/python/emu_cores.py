# emu_cores — the libretro cores retroforge-emu installs with an emulator whose catalog entry has
# "cores" (RetroArch; plan retroarch Phase 1, D1/D1b). Imported by /usr/bin/retroforge-emu, which
# hands in its own helpers (Ctx below): one exit-status contract, one curl, one GitHub client.
#
# CATALOG: "cores": {"<core>": <source>, ...}, <core> = [a-z0-9_]+, the library's file name stem
# (<core>_libretro.so). Only the cores listed are ever installed: RetroArch's Online Updater is off
# (user decision 2026-11-09, players do not install cores for other systems). Two sources:
#
#   {"buildbot": "<core>_libretro.so.zip"}   libretro's nightly for linux/aarch64. latest/ keeps no
#       history, so there is no tested pin: install takes today's build, named
#       nightly-<date>-<crc32> from latest/.index-extended, and the unpacked .so must have that CRC32
#       (the index's CRC is the .so's, not the zip's). --tested installs it only when missing.
#   {"github", "tag", "tag_pattern"?, "asset", "sha256"?, "size"?}   a release zip (armGBA), checked
#       exactly like an AppImage entry (retroforge-emu's tested_build / newest_build): the pin is the
#       tested build, latest by default when tag_pattern is set.
#
# From the zip, ONE member is written: <core>_libretro.so at its top level, a plain file of at most
# CORE_MAX bytes. Anything else in it (the .info, a readme) is never read.
#
# LAYOUT under <EMU_DIR>/<emulator>/:
#   core-builds/<core>/<build>.so            the builds on disk: the active one and the previous one
#   cores/<core>_libretro.so -> ../core-builds/<core>/<build>.so   what RetroArch loads (-L, and its
#                                            libretro_directory): flipped atomically, like `current`
#
# A failed core changes nothing of what was installed (its .part is deleted, its link untouched);
# the install stops there with that core's exit status, the cores before it stay updated.
import os
import re
import shutil
import stat
import subprocess
import zipfile
import zlib

BUILDBOT = "https://buildbot.libretro.com/nightly/linux/aarch64/latest/"
CORE_NAME = re.compile(r"[a-z0-9_]+")
INDEX_ROW = re.compile(r"(\d{4}-\d{2}-\d{2}) ([0-9a-f]{8}) ([a-z0-9_]+_libretro\.so\.zip)")
GITHUB_KEYS = {"github", "tag", "tag_pattern", "asset", "sha256", "size"}
CORE_MAX = 128 << 20   # bytes: a core's zip, and the .so unpacked from it (hard caps)
CORE_ROOM = 64 << 20   # bytes free a core install wants (the largest core today, N64, is ~7 MB)
INDEX_MAX = 1 << 20    # bytes: latest/.index-extended (about 11 KB today)


class Ctx:
    """What emu_cores needs from retroforge-emu: Fail and its exit codes, log, curl_base, the GitHub
    build resolvers, verify, emit (one forward-only N% line), SAFE_TAG and SPACE_MARGIN."""

    def __init__(self, **kw):
        self.__dict__.update(kw)


def so_name(core):
    return f"{core}_libretro.so"


def specs(ctx, emu, e):
    """The entry's cores as [(core, source)], each checked; exit 4 before any download otherwise."""
    cores = e.get("cores")
    if not isinstance(cores, dict) or not cores:
        raise ctx.Fail(ctx.EXIT_VERIFY, f"{emu}: 'cores' must be a non-empty object")
    out = []
    for core, src in cores.items():
        if not (isinstance(core, str) and CORE_NAME.fullmatch(core) and isinstance(src, dict)):
            raise ctx.Fail(ctx.EXIT_VERIFY, f"{emu}: bad core {core!r}")
        if "buildbot" in src:
            if src != {"buildbot": f"{so_name(core)}.zip"}:
                raise ctx.Fail(ctx.EXIT_VERIFY, f"{emu}: core {core}: a buildbot core is exactly "
                                                f"{{\"buildbot\": \"{so_name(core)}.zip\"}}")
        elif not (set(src) <= GITHUB_KEYS and {"github", "tag", "asset"} <= set(src)
                  and ctx.SAFE_TAG.fullmatch(str(src["tag"]))
                  and ("tag_pattern" in src or "sha256" in src)
                  and ("sha256" not in src or ("size" in src and re.fullmatch(r"[0-9a-f]{64}", str(src["sha256"]))))):
            raise ctx.Fail(ctx.EXIT_VERIFY, f"{emu}: core {core}: a GitHub core needs github, a safe tag, "
                                            f"asset, and a sha256 + size pin or a tag_pattern")
        else:
            check_github_source(ctx, emu, core, src)
        out.append((core, src))
    return out


def check_github_source(ctx, emu, core, src):
    """github is owner/repo; asset and tag_pattern are strings that compile (as an AppImage entry's)."""
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", str(src["github"])):
        raise ctx.Fail(ctx.EXIT_VERIFY, f"{emu}: core {core}: github {src['github']!r} is not owner/repo")
    for key in ("asset", "tag_pattern"):
        if key in src:
            try:
                re.compile(src[key])
            except (re.error, TypeError) as err:
                raise ctx.Fail(ctx.EXIT_VERIFY, f"{emu}: core {core}: bad {key} {src[key]!r}: {err}")


def link_path(d, core):
    return os.path.join(d, "cores", so_name(core))


def builds_dir(d, core):
    return os.path.join(d, "core-builds", core)


def installed(ctx, d, core):
    """The active build of a core, or None."""
    link = link_path(d, core)
    target = os.readlink(link) if os.path.islink(link) else ""
    prefix = f"../core-builds/{core}/"
    build = target[len(prefix):-len(".so")] if target.startswith(prefix) and target.endswith(".so") else ""
    return build if ctx.SAFE_TAG.fullmatch(build) and os.path.isfile(link) else None


def previous(ctx, d, core):
    """The build kept beside the active one (activate keeps at most one), or None."""
    active = installed(ctx, d, core)
    bd = builds_dir(d, core)
    try:
        names = [n for n in os.listdir(bd) if n.endswith(".so") and not n.startswith(".")
                 and n != f"{active}.so" and os.path.isfile(os.path.join(bd, n))]
    except OSError:
        return None
    if active is None or not names:
        return None
    return max(names, key=lambda n: os.path.getmtime(os.path.join(bd, n)))[: -len(".so")]


def activate(d, core, build):
    """Point cores/<core>_libretro.so at the build atomically; keep the previous build, delete the rest."""
    link = link_path(d, core)
    os.makedirs(os.path.dirname(link), exist_ok=True)
    old = os.readlink(link) if os.path.islink(link) else None
    tmp = os.path.join(os.path.dirname(link), f".{core}.link-tmp")
    if os.path.lexists(tmp):
        os.unlink(tmp)
    os.symlink(f"../core-builds/{core}/{build}.so", tmp)
    os.replace(tmp, link)
    keep = {f"{build}.so", os.path.basename(old) if old else None}
    bd = builds_dir(d, core)
    for name in os.listdir(bd):
        if name.endswith(".so") and name not in keep:
            os.unlink(os.path.join(bd, name))


def fetch_index(ctx):
    """latest/.index-extended as {zip name: (date, crc)}; exit 3 when it cannot be read."""
    try:
        out = subprocess.run(ctx.curl_base() + ["--max-time", "60", "--max-filesize", str(INDEX_MAX),
                                                f"{BUILDBOT}.index-extended"],
                             capture_output=True, check=True, timeout=90).stdout
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError) as err:
        raise ctx.Fail(ctx.EXIT_NET, f"libretro buildbot index not readable: {err}")
    if len(out) > INDEX_MAX:
        raise ctx.Fail(ctx.EXIT_VERIFY, "libretro buildbot index is larger than expected")
    rows = {}
    for line in out.decode(errors="replace").splitlines():
        m = INDEX_ROW.fullmatch(line.strip())
        if m:
            rows[m.group(3)] = (m.group(1), m.group(2))
    return rows


def resolve(ctx, core, src, newest, index):
    """The build to fetch: {"url", "tag", and "sha256"+"size" (GitHub) or "crc" (buildbot)}."""
    if "buildbot" in src:
        row = index.get(src["buildbot"])
        if row is None:
            raise ctx.Fail(ctx.EXIT_NET, f"core {core}: not on the libretro buildbot today")
        date, crc = row
        return {"url": f"{BUILDBOT}{src['buildbot']}", "tag": f"nightly-{date}-{crc}", "crc": crc}
    return ctx.newest_build(src) if newest else ctx.tested_build(src)


def tested_pin(src):
    return src.get("tag") if "sha256" in src else None


def install(ctx, emu, e, d, tested, lo=80, hi=99):
    """Install or update every core of the entry (see the header); progress lo..hi."""
    cores = specs(ctx, emu, e)
    index = fetch_index(ctx) if any("buildbot" in s for _, s in cores) else {}
    for i, (core, src) in enumerate(cores):
        have, pinned = installed(ctx, d, core), tested_pin(src)
        # --tested: the pin; a core with no tested build (a nightly) only when it is missing.
        keep = tested and have is not None and (pinned is None or have == pinned)
        if not keep:
            build = resolve(ctx, core, src, follows_newest(src, tested), index)
            if build["tag"] != have:
                fetch(ctx, d, core, build)
                ctx.log(f"{emu}: core {core} {build['tag']} installed")
        ctx.emit(lo + (hi - lo) * (i + 1) // len(cores))


def follows_newest(src, tested=False):
    """Whether a GitHub core installs upstream's newest release rather than its pin."""
    return tested_pin(src) is None or (not tested and "tag_pattern" in src)


def fetch(ctx, d, core, build):
    """Download one build's zip, check it, unpack its .so and make it the active build."""
    if not ctx.SAFE_TAG.fullmatch(build["tag"]):
        raise ctx.Fail(ctx.EXIT_VERIFY, f"core {core}: unsafe build name {build['tag']!r}")
    bd = builds_dir(d, core)
    zpart = os.path.join(d, f".{core}.zip.part")
    spart = os.path.join(bd, f".{core}.so.part")  # fixed: a killed run leaves one, reused next time
    try:
        os.makedirs(bd, exist_ok=True)
        if shutil.disk_usage(d).free < CORE_ROOM + ctx.SPACE_MARGIN:
            raise ctx.Fail(ctx.EXIT_LOCAL, f"not enough free space in {d} for core {core}")
        download(ctx, build["url"], zpart)
        if os.path.getsize(zpart) > CORE_MAX:  # --max-filesize only holds with a Content-Length
            raise ctx.Fail(ctx.EXIT_VERIFY, f"core {core}: the download is larger than {CORE_MAX} bytes")
        if "sha256" in build:
            ctx.verify(zpart, build)
        crc = unpack_so(ctx, zpart, so_name(core), spart)
        if "crc" in build and crc != build["crc"]:
            raise ctx.Fail(ctx.EXIT_VERIFY, f"core {core}: CRC {crc} is not the buildbot index's {build['crc']} "
                                            f"(the nightly may have been rebuilt meanwhile: try again)")
        os.chmod(spart, 0o644)
        os.replace(spart, os.path.join(bd, f"{build['tag']}.so"))
        activate(d, core, build["tag"])
    except OSError as err:
        raise ctx.Fail(ctx.EXIT_LOCAL, f"core {core} {build['tag']}: {err}")
    finally:
        for p in (zpart, spart):
            if os.path.lexists(p):
                os.unlink(p)


def download(ctx, url, part):
    try:
        subprocess.run(ctx.curl_base() + ["--max-time", "600", "--max-filesize", str(CORE_MAX),
                                          "-o", part, url],
                       stdout=subprocess.DEVNULL, check=True, timeout=660)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError) as err:
        raise ctx.Fail(ctx.EXIT_NET, f"download failed: {url} ({err})")


def unpack_so(ctx, archive, name, dest):
    """Write the zip's top-level member `name` to `dest`; its CRC32 as 8 hex digits."""
    try:
        with zipfile.ZipFile(archive) as z:
            try:
                m = z.getinfo(name)
            except KeyError:
                raise ctx.Fail(ctx.EXIT_VERIFY, f"the archive has no {name} at its top level")
            kind = stat.S_IFMT(m.external_attr >> 16)
            if m.is_dir() or kind not in (0, stat.S_IFREG) or m.file_size > CORE_MAX:
                raise ctx.Fail(ctx.EXIT_VERIFY, f"{name} in the archive is not a plain file under {CORE_MAX} bytes")
            crc, total = 0, 0
            with z.open(m) as src, open(dest, "wb") as dst:
                for block in iter(lambda: src.read(1 << 20), b""):
                    total += len(block)
                    if total > CORE_MAX:
                        raise ctx.Fail(ctx.EXIT_VERIFY, f"{name} is larger than it says")
                    crc = zlib.crc32(block, crc)
                    dst.write(block)
            return f"{crc:08x}"
    except (zipfile.BadZipFile, zipfile.LargeZipFile, zlib.error, EOFError, ValueError,
            RuntimeError, NotImplementedError) as err:
        raise ctx.Fail(ctx.EXIT_VERIFY, f"cannot read the archive: {err}")


def listing(ctx, e, d):
    """`list`'s "cores": per core its installed, previous and tested build, and its source."""
    out = {}
    for core, src in (e.get("cores") or {}).items():
        if not (isinstance(core, str) and CORE_NAME.fullmatch(core) and isinstance(src, dict)):
            continue
        out[core] = {"installed": installed(ctx, d, core), "previous": previous(ctx, d, core),
                     "tested": tested_pin(src),
                     "follows_latest": "buildbot" in src or "tag_pattern" in src,
                     "source": "buildbot" if "buildbot" in src else "github"}
    return out


def check(ctx, emu, e, cache, refresh, now):
    """`check`'s "cores": per core {"latest", "error"}; one bad core never hides the others. A
    GitHub core's answer is kept in retroforge-emu's check cache (key "<emu>/<core>", same TTL):
    GitHub allows 60 unauthenticated requests an hour. The buildbot index is one plain file."""
    out, index, index_err = {}, None, None
    for core, src in specs(ctx, emu, e):
        key = f"{emu}/{core}"
        try:
            if "buildbot" in src:
                if index is None and index_err is None:
                    try:
                        index = fetch_index(ctx)
                    except ctx.Fail as f:
                        index_err = f
                if index_err is not None:
                    raise index_err
            elif not follows_newest(src):
                out[core] = {"latest": src["tag"], "error": None}
                continue
            elif ctx.cached(cache, key, src, refresh, now) is not None:
                out[core] = {"latest": cache[key]["latest"], "error": None}
                continue
            build = resolve(ctx, core, src, follows_newest(src), index or {})
            if "buildbot" not in src:
                cache[key] = {"key": ctx.check_key(src), "at": now, "latest": build["tag"]}
            out[core] = {"latest": build["tag"], "error": None}
        except ctx.Fail as f:
            out[core] = {"latest": None, "error": str(f)}
    return out


def rollback(ctx, d, core, e):
    """Flip one core back to its kept previous build."""
    if not (CORE_NAME.fullmatch(core or "") and core in (e.get("cores") or {})):
        raise ctx.Fail(ctx.EXIT_USAGE, f"no core '{core}' in the catalog entry")
    prev = previous(ctx, d, core)
    if prev is None:
        raise ctx.Fail(ctx.EXIT_USAGE, f"core {core} has no previous build to go back to")
    try:
        activate(d, core, prev)
    except OSError as err:
        raise ctx.Fail(ctx.EXIT_LOCAL, f"rollback of core {core} failed: {err}")
    return prev
