# psn_inbox — retroforge-launch --psn-install: PSN packages and licences into RPCS3.
#
# PSN inbox (--psn-install, plan psn-pkg): the player drops PSN .pkg files (base game, updates,
# DLC) and their .rap/.edat licences into ~/roms/ps3/psn/, and the RetroForge plugin runs this verb
# (threaded, with progress; never at library load). It runs ps3's emulator once, headless, on the
# whole folder — `--headless --installpkg <inbox>` copies every licence into dev_hdd0's exdata and
# extracts every .pkg; RPCS3 processes raps before pkgs itself, and the order never matters (the
# licence is only read at boot). RPCS3's exit code is 0 even on failure, so success is verified on
# disk per file: a pkg's title id comes from its own header (content id at 0x30, title id chars
# 7..15), and the install must have produced dev_hdd0/game/<id>/PARAM.SFO *in this run* (something
# under game/<id> is newer than the run's start — a stale install from an earlier run never
# verifies a re-dropped broken pkg; dev_hdd0 as ~/.config/rpcs3/vfs.yml places it, and the
# emulator's seed runs first, so a first install still lands where RetroForge puts dev_hdd0).
# Several pkgs of one game (base, update, DLC) share a title id and are verified COLLECTIVELY: when
# one of them installs, the batch's others count as installed too. A verified base game (PARAM.SFO
# CATEGORY "HG" with USRDIR/EBOOT.BIN; updates and DLC make no card) gets a stub
# ~/roms/ps3/<TITLE>.psn — PARAM.SFO's TITLE, sanitized, the title id when it is missing, " (<id>)"
# appended on a collision; an id that already has a stub keeps it. The
# INBOX IS CONSUMED: a verified pkg and a copied licence are deleted; failures stay, visible and
# retryable, and nothing outside the inbox is ever deleted. A new card's box art is seeded from
# the game's own ICON0.PNG into the scraper's media folder when no box exists yet (digital-only
# titles often have no box scan on ScreenScraper; a later real box download overwrites the seed). Results go to stdout for the plugin,
# one tab-separated line per file: `ok|failed <TAB> <file> <TAB> <title id or -> <TAB> <stub name
# or ->` (`nothing-to-do` for an empty inbox); other files (the folder's README) are ignored
# silently. Exit 0 when everything succeeded, 3 otherwise (also when ps3's emulator is not
# installed or does not start). No status file: the plugin reads this run directly, and no OGUI
# EXIT hook fires. ONE RPCS3 AT A TIME: the installer and a ps3 game launch take the same lock
# (PSN_LOCK, held for the process's life) — they share dev_hdd0, and two RPCS3s do not fit in a
# handheld's RAM (earlyoom killed the game on the 8 GiB ACE, 2026-10-20). A ps3 launch while an
# install runs fails with `psn-installing`; an install while a game runs is refused (the plugin
# also refuses earlier, with the friendlier message). A --gui session is not guarded.

import errno
import fcntl
import os
import re
import struct
import subprocess
import sys
import tempfile
import time

import emuopts
from launch_common import CONFIG_HOME, EMU_DIR, ENV, HOME, VRAM_REPORT_LIMIT_VARS, Exit, log, no_core_dumps
from launch_def import emulator_for, load_definition, seed_first_run
from launch_formats import FORMATS

PSN_SYSTEM = "ps3"
PSN_INBOX = os.path.join(HOME, "roms", "ps3", "psn")
PSN_STUB_DIR = os.path.join(HOME, "roms", "ps3")
PSN_LICENCES = (".rap", ".edat")
RPCS3_USER = "00000001"  # RPCS3's default (and only RetroForge) user: exdata lives under it
SFO_MAX = 1 << 20  # a PARAM.SFO is a few KB; one bigger than this is not one
STUB_NAME_BYTES = 180  # a stub name's TITLE part, in UTF-8 BYTES: name + suffixes must fit NAME_MAX
PSN_LOCK = ENV.get("RETROFORGE_PSN_LOCK",
                   os.path.join(ENV.get("XDG_RUNTIME_DIR") or "/tmp", "retroforge-psn-install.lock"))
# retroforge-scrape's media folder (same env knob): a new card's box art is seeded here.
MEDIA_DIR = ENV.get("RETROFORGE_MEDIA_DIR", os.path.join(HOME, ".local/share/retroforge/media"))


def try_psn_lock():
    """The one-RPCS3-at-a-time lock (header): taken by --psn-install AND by a ps3 game launch —
    they share one dev_hdd0, and two RPCS3s do not fit in a handheld's RAM. Returns the lock file
    HELD (the caller keeps it referenced and hands its fd to the RPCS3 it starts via pass_fds, so
    the flock — owned by the open file description — survives even a SIGKILLed launcher for as
    long as either process lives), or None when the other side has it. A broken lock PATH raises
    the OSError instead: that is a system problem, not contention, and each caller words it
    honestly (a launch proceeds unguarded, the installer refuses)."""
    lock = open(PSN_LOCK, "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as err:
        lock.close()
        if err.errno == errno.EWOULDBLOCK:
            return None
        raise
    return lock


def pkg_title_id(path):
    """The title id from a retail .pkg header (magic \\x7fPKG, the content id at 0x30, the title id
    its chars 7..15: UP0001-NPUB30024_00-... -> NPUB30024), or None when the file is no package."""
    try:
        with open(path, "rb") as f:
            header = f.read(0x60)
    except OSError:
        return None
    if len(header) < 0x60 or header[:4] != b"\x7fPKG":
        return None
    title_id = header[0x37:0x40].decode("ascii", "replace")
    return title_id if re.fullmatch(r"[A-Z0-9]{9}", title_id) else None


def sfo_values(path):
    """PARAM.SFO's string entries as {key: value}, {} when it is unreadable or no SFO. The format
    is a small binary key/value table: index entries of (key offset, format, length, max, data
    offset) after a 20-byte header; format 0x0204 is a NUL-terminated UTF-8 string."""
    try:
        with open(path, "rb") as f:
            data = f.read(SFO_MAX)
        if data[:4] != b"\0PSF":
            return {}
        key_start, data_start, count = struct.unpack_from("<III", data, 8)
        values = {}
        for i in range(count):
            key_off, fmt, length, _, data_off = struct.unpack_from("<HHIII", data, 20 + 16 * i)
            # The NUL search is capped: a crafted file must not cost a megabyte scan per entry.
            key_end = data.index(b"\0", key_start + key_off, key_start + key_off + 64)
            key = data[key_start + key_off:key_end].decode("utf-8", "replace")
            if fmt == 0x0204:
                raw = data[data_start + data_off:data_start + data_off + length]
                values[key] = raw.split(b"\0", 1)[0].decode("utf-8", "replace")
        return values
    except (OSError, ValueError, struct.error):
        return {}


def dev_hdd0_dir():
    """Where RPCS3 keeps the PS3's internal drive: vfs.yml's /dev_hdd0/ row (RetroForge's seed puts
    it in ~/saves/ps3/dev_hdd0; RPCS3 may rewrite the file with quotes or its $(EmulatorDir)
    placeholder, its own config folder), else RPCS3's default under that folder."""
    rpcs3_dir = os.path.join(CONFIG_HOME, "rpcs3")
    try:
        with open(os.path.join(rpcs3_dir, "vfs.yml"), errors="replace") as f:
            for line in f:
                if not line.startswith("/dev_hdd0/:"):
                    continue
                value = line.split(":", 1)[1].strip().strip("\"'")
                value = value.replace("$(EmulatorDir)", rpcs3_dir + "/")
                if value.startswith("/"):
                    return os.path.normpath(value)
    except OSError:
        pass
    return os.path.join(rpcs3_dir, "dev_hdd0")


def psn_stub_title(title, title_id):
    """PARAM.SFO's TITLE as a stub file name: no /, \\ or control characters, whitespace collapsed,
    no leading/trailing dots (a hidden file), truncated by UTF-8 BYTES so name + " (<id>)" +
    ".psn" (and write_atomic's temp suffix) stays under NAME_MAX; the title id when nothing usable
    is left."""
    name = re.sub(r"[\x00-\x1f\x7f/\\]", " ", title)
    name = re.sub(r"\s+", " ", name).strip(" .")
    name = name.encode()[:STUB_NAME_BYTES].decode("utf-8", "ignore")
    return name.rstrip(" .") or title_id


def psn_stub_for(title_id):
    """The .psn stub already holding this id (never rewritten), or None."""
    try:
        names = os.listdir(PSN_STUB_DIR)
    except OSError:
        return None
    for name in sorted(names):
        path = os.path.join(PSN_STUB_DIR, name)
        if not name.lower().endswith(".psn") or not os.path.isfile(path):  # isfile: a FIFO would hang
            continue
        try:
            with open(path, encoding="utf-8") as f:
                if f.readline(128).strip() == title_id:
                    return name
        except (OSError, UnicodeDecodeError):
            continue
    return None


def psn_write_stub(title_id, title):
    """A new stub for an installed game: ~/roms/ps3/<TITLE>.psn holding the id, " (<id>)" appended
    when another game took the name. -> the stub's file name."""
    base = psn_stub_title(title, title_id)
    for name in (f"{base}.psn", f"{base} ({title_id}).psn"):
        path = os.path.join(PSN_STUB_DIR, name)
        if os.path.lexists(path):
            continue  # another id's stub (this id's was looked up before): disambiguate
        emuopts.write_atomic(path, f"{title_id}\n".encode())
        return name
    # Both names taken and neither is this id's stub (psn_stub_for ran first): never report a
    # stranger's file as this game's card.
    raise OSError(f"{base} ({title_id}).psn exists and is not this game's stub")


PSN_ICON_MAX = 1 << 20  # an ICON0.PNG is tens of KB; bigger is not one
PSN_ICON_DIM = 2048  # sane pixel bound for a seeded box (IHDR claims beyond it are hostile)


def psn_seed_box(stub, game_dir):
    """The card's box art, seeded from the installed game's own ICON0.PNG (Sony mandates one; it
    is what the PS3's XMB shows). Digital-only titles often have no box scan on ScreenScraper,
    which left the card blank (RCR DX on the ACE, 2026-10-20). Only when no box exists yet: a
    fresh stub is still scraped in full (it has no scrape-cache entry), and a real box download
    then overwrites this seed. The icon comes out of a player-supplied pkg, so it is checked —
    size-capped, PNG signature, sane IHDR dimensions (the scraper treats any existing box as art,
    so a junk seed would silence a real one forever) — and landed with os.link, which never
    replaces an existing name: art racing in from the scraper wins. Art is COSMETIC: any failure
    is a log line, never a result line, never a failed install."""
    folder = os.path.join(MEDIA_DIR, PSN_SYSTEM)
    dest = os.path.join(folder, f"{stub}-box.png")
    try:
        if any(os.path.exists(os.path.join(folder, f"{stub}-box.{ext}")) for ext in ("png", "jpg")):
            return
        icon = os.path.join(game_dir, "ICON0.PNG")
        if not os.path.isfile(icon):
            return  # no icon: the scraper may still find a box
        if os.path.getsize(icon) > PSN_ICON_MAX:
            raise ValueError("bigger than an icon can be")
        with open(icon, "rb") as f:
            data = f.read(PSN_ICON_MAX)
        if data[:8] != b"\x89PNG\r\n\x1a\n" or len(data) < 24:
            raise ValueError("not a PNG")
        width, height = struct.unpack_from(">II", data, 16)
        if not (0 < width <= PSN_ICON_DIM and 0 < height <= PSN_ICON_DIM):
            raise ValueError(f"unreasonable dimensions {width}x{height}")
        os.makedirs(folder, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=folder, prefix=".box.")
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(data)
            os.link(tmp, dest)
        finally:
            os.unlink(tmp)
        log(f"psn-install: {stub}: card art seeded from the game's ICON0.PNG")
    except FileExistsError:
        pass  # someone else's art landed between the check and the link: it wins
    except Exception as err:  # noqa: BLE001 — cosmetic by contract, whatever goes wrong
        log(f"psn-install: {stub}: could not seed card art from ICON0.PNG: {err}")


def fs_now_ns(dir_path):
    """The filesystem's idea of "now": a probe file's fresh mtime. File timestamps come from the
    kernel's coarse clock, which can lag time.time_ns() by milliseconds — a run-start stamp taken
    from the same clock keeps tree_changed from missing a file written right after the start."""
    try:
        fd, path = tempfile.mkstemp(dir=dir_path)
    except OSError:
        return time.time_ns()
    try:
        return os.fstat(fd).st_mtime_ns
    finally:
        os.close(fd)
        os.unlink(path)


def tree_changed(path, since_ns):
    """Whether anything under path (the dir itself, a subfolder, a file) is as new as since_ns:
    did THIS run's install touch the game dir? A stale install from an earlier run must never
    verify a re-dropped broken package."""
    for base, _dirs, files in os.walk(path):
        for entry in [base] + [os.path.join(base, f) for f in files]:
            try:
                if os.stat(entry).st_mtime_ns >= since_ns:
                    return True
            except OSError:
                continue
    return False


def result_safe(name):
    """A file name the tab-separated result lines (and the plugin's line split) can carry."""
    try:
        name.encode()
    except UnicodeEncodeError:  # undecodable bytes (surrogates): print would raise
        return False
    return name.isprintable()  # no tabs, newlines, \r, or other control/separator characters


def same_file_content(a, b):
    try:
        with open(a, "rb") as fa, open(b, "rb") as fb:
            return fa.read(SFO_MAX) == fb.read(SFO_MAX)  # licences are tiny
    except OSError:
        return False


def psn_install():
    """--psn-install (header): one headless `--installpkg <inbox>` run installs every package and
    licence the player dropped into ~/roms/ps3/psn/, then each file is verified on disk, a base
    game gets its .psn stub, and what succeeded is deleted — the inbox is consumed. One result line
    per file on stdout for the plugin; 0 when everything succeeded, 3 otherwise."""
    emulator = emulator_for(PSN_SYSTEM)
    definition = load_definition(emulator)
    if definition["root"] is not None:
        raise Exit(2, f"{emulator}: --psn-install needs an emulator, not the scripts format")
    image = installed = os.path.join(EMU_DIR, emulator, "current")
    if not os.access(installed, os.X_OK):
        raise Exit(3, f"{emulator} is not installed ({installed} missing or not executable)")
    # One RPCS3 at a time: two writing the same dev_hdd0 corrupt it, and two do not fit in RAM.
    # A running ps3 GAME holds this lock too (run()); the plugin also guards, but a double start
    # must be safe here. Held until this process exits (and by the RPCS3 below, via its fd).
    try:
        lock = try_psn_lock()
    except OSError as err:
        raise Exit(3, f"cannot take the PSN install lock: {err}") from None
    if lock is None:
        raise Exit(3, "a PSN install or a PlayStation 3 game is already running")
    try:
        names = sorted(os.listdir(PSN_INBOX))
    except OSError:
        names = []
    # A name the result lines cannot carry (control characters, undecodable bytes) is left alone.
    names = [n for n in names if result_safe(n) and os.path.isfile(os.path.join(PSN_INBOX, n))]
    pkgs = [n for n in names if n.lower().endswith(".pkg")]
    licences = [n for n in names if n.lower().endswith(PSN_LICENCES)]
    if not pkgs and not licences:
        print("nothing-to-do")
        return 0

    # The seed first: a first install must land dev_hdd0 where RetroForge's vfs.yml puts it.
    seed_first_run(emulator, definition["seed"])
    started_ns = fs_now_ns(PSN_INBOX)
    package = FORMATS[definition["format"]](emulator, image)
    try:
        try:
            root = package.prepare()
        except Exit as err:
            raise Exit(3, f"{emulator} could not start: {err}") from None
        binary = os.path.join(root, definition["binary"])
        inherited = {k: v for k, v in ENV.items() if k not in VRAM_REPORT_LIMIT_VARS}
        env = {**inherited, **package.env(), **definition["env"]}
        log(f"psn-install: {binary} --headless --installpkg {PSN_INBOX}")
        try:
            # No timeout: extracting a multi-GB package on the card takes minutes. RPCS3 exits 0
            # even on failure (like --installfw), so success is per file, on disk, below. Its own
            # output goes to the log, never onto the result lines the plugin parses.
            # The installer RPCS3 inherits the lock's fd (flock follows the open file
            # description): a SIGKILLed launcher then cannot free a game launch mid-extract.
            subprocess.run([binary, "--headless", "--installpkg", PSN_INBOX],
                           env=env, start_new_session=True, preexec_fn=no_core_dumps,
                           pass_fds=(lock.fileno(),),
                           stdin=subprocess.DEVNULL, stdout=sys.stderr)
        except (OSError, ValueError) as err:
            raise Exit(3, f"could not run {binary}: {err}") from None
    finally:
        package.release()

    hdd0 = dev_hdd0_dir()
    log(f"psn-install: dev_hdd0 at {hdd0}")
    failed = 0

    def consume(name):
        try:
            os.unlink(os.path.join(PSN_INBOX, name))
        except OSError as err:
            log(f"psn-install: could not consume {name}: {err}")

    for name in pkgs:
        title_id = pkg_title_id(os.path.join(PSN_INBOX, name))
        if title_id is None:
            log(f"psn-install: {name}: not a PSN package (no title id in its header)")
            print(f"failed\t{name}\t-\t-")
            failed += 1
            continue
        game_dir = os.path.join(hdd0, "game", title_id)
        sfo = sfo_values(os.path.join(game_dir, "PARAM.SFO"))
        # Installed = the game dir's PARAM.SFO is there and THIS run touched the dir (header: an
        # update or DLC may bring no EBOOT.BIN, and one id's packages verify collectively); only a
        # base game (HG) with its boot file makes a card.
        if not sfo or not tree_changed(game_dir, started_ns):
            log(f"psn-install: {name}: {game_dir} "
                + ("was not touched by this install" if sfo else "has no PARAM.SFO"))
            print(f"failed\t{name}\t{title_id}\t-")
            failed += 1
            continue
        stub = "-"
        if sfo.get("CATEGORY") == "HG" \
                and os.path.isfile(os.path.join(game_dir, "USRDIR", "EBOOT.BIN")):
            try:
                stub = psn_stub_for(title_id) or psn_write_stub(title_id, sfo.get("TITLE", ""))
            except OSError as err:
                log(f"psn-install: {name}: could not write the stub: {err}")
                print(f"failed\t{name}\t{title_id}\t-")
                failed += 1
                continue
            psn_seed_box(stub, game_dir)
        consume(name)
        print(f"ok\t{name}\t{title_id}\t{stub}")

    exdata = os.path.join(hdd0, "home", RPCS3_USER, "exdata")
    for name in licences:
        stem, ext = os.path.splitext(name)
        copy = os.path.join(exdata, stem + ext.lower())  # RPCS3 lowercases the extension
        if same_file_content(os.path.join(PSN_INBOX, name), copy):
            consume(name)
            print(f"ok\t{name}\t-\t-")
        else:
            log(f"psn-install: {name}: no identical copy in {exdata} after the install")
            print(f"failed\t{name}\t-\t-")
            failed += 1
    return 3 if failed else 0
