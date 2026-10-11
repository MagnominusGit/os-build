#!/usr/bin/env bash
# Offline test for the emulator catalog the QForge plugin downloads from (plan Phase 4, part 4).
#
#   tests/test-catalog.sh                    # offline: shape and cross-checks against the image
#   QFORGE_NET_TEST=1 tests/test-catalog.sh  # also asks GitHub that every pin still matches
#
# WHY THIS EXISTS. The catalog decides which emulator build a player gets, so a bad row is a
# broken game for everyone who downloads after it:
#
#   - a rolling tag (DuckStation's `latest` / `preview`) replaces its asset in place, so a pin on
#     one silently ships an untested build: pins must be numbered releases -- unless the entry says
#     so with "channel": "nightly" (Cemu, user decision 2026-10-07): then no sha256 (qforge-emu
#     checks GitHub's own digest), "size" is an estimate, and the tag must be the rolling one;
#   - the sha256 is what the plugin checks the download against (and must match GitHub's per-asset
#     digest): a malformed one would make every install fail, or, if skipped, verify nothing;
#   - an emulator the image cannot launch (no /usr/share/qforge/emulators/<emu>/emulator.json), or one serving a
#     system launch.conf maps elsewhere, would download fine and then never start;
#   - a plain-http URL would let anyone on the path swap the AppImage;
#   - an "unpack" entry (PortMaster, a zip unpacked into the player's home) with a target outside
#     the home, or "self_update" on an AppImage, would be refused by qforge-emu at every install.
#
# Launch details (format, binary, args, first-run seed) live in the image's emulator.json, NOT here: the
# catalog only says what to download and how to verify it.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CATALOG="${QFORGE_CATALOG:-$ROOT/rootfs/overlay/usr/share/qforge/catalog.json}"
LAUNCH_CONF="$ROOT/rootfs/overlay/etc/qforge/launch.conf"
EMU_DATA_DIR="$ROOT/rootfs/overlay/usr/share/qforge/emulators"

for f in "$CATALOG" "$LAUNCH_CONF"; do
  [ -f "$f" ] || { echo "missing input: $f" >&2; exit 1; }
done
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }

# The checks are in Python (JSON + regex); each prints "ok|FAIL <TAB> case <TAB> message".
out="$(QFORGE_NET_TEST="${QFORGE_NET_TEST:-0}" python3 - "$CATALOG" "$LAUNCH_CONF" "$EMU_DATA_DIR" <<'PY'
import json, os, re, sys, urllib.request

catalog_path, launch_conf, emu_conf_dir = sys.argv[1:4]
net = os.environ.get("QFORGE_NET_TEST") == "1"

def ok(case, msg):  print(f"ok\t{case}\t{msg}")
def bad(case, msg): print(f"FAIL\t{case}\t{msg}")

case = "catalog file"
try:
    with open(catalog_path) as f:
        cat = json.load(f)
    ok(case, "is valid JSON")
except Exception as e:
    bad(case, f"does not parse: {e}")
    sys.exit(0)

if cat.get("schema") == 1:
    ok(case, "schema 1")
else:
    bad(case, f"schema is {cat.get('schema')!r}, the plugin reads 1")
emus = cat.get("emulators")
if isinstance(emus, dict) and emus:
    ok(case, f"lists {len(emus)} emulator(s)")
else:
    bad(case, "has no 'emulators' object")
    sys.exit(0)

# system -> emulator, last match wins (as in qforge-launch)
launch = {}
for line in open(launch_conf):
    m = re.match(r"^([a-z0-9_]+)=([a-z0-9_-]+)\s*$", line)
    if m:
        launch[m.group(1)] = m.group(2)

ROLLING = {"latest", "preview", "nightly", "continuous", "dev", "master", "main"}
REQUIRED = {"name", "author", "systems", "github", "tag", "asset", "sha256", "size", "homepage", "licence"}
OPTIONAL = {"data", "unpack", "self_update"}
CHANNELS = {"nightly"}

def check_github(case, e, rx):
    url = f"https://api.github.com/repos/{e['github']}/releases/tags/{e['tag']}"
    try:
        req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json"})
        tok = os.environ.get("GITHUB_TOKEN")
        if tok:
            req.add_header("Authorization", f"Bearer {tok}")
        rel = json.load(urllib.request.urlopen(req, timeout=20))
    except Exception as err:
        bad(case, f"release {e['tag']} not readable: {err}")
        return
    assets = [a for a in rel.get("assets", []) if rx.fullmatch(a["name"])]
    if len(assets) != 1:
        bad(case, f"asset pattern matches {len(assets)} assets of {e['tag']}, want exactly 1")
        return
    a = assets[0]
    if "channel" in e:
        if re.fullmatch(r"sha256:[0-9a-f]{64}", str(a.get("digest"))):
            ok(case, f"GitHub publishes a sha256 digest for {a['name']} (the nightly is checked against it)")
        else:
            bad(case, f"no sha256 digest on {a['name']}: qforge-emu would refuse every install")
        if isinstance(a.get("size"), int) and e["size"] / 2 <= a["size"] <= e["size"] * 2:
            ok(case, f"size estimate {e['size']} is near today's {a['size']}")
        else:
            bad(case, f"size estimate {e['size']} is far from today's {a.get('size')}")
        return
    if a.get("digest") == f"sha256:{e['sha256']}":
        ok(case, f"sha256 matches GitHub's digest for {a['name']}")
    else:
        bad(case, f"GitHub's digest is {a.get('digest')}, the catalog says sha256:{e['sha256']}")
    if a.get("size") == e["size"]:
        ok(case, "size matches the release asset")
    else:
        bad(case, f"size {e['size']} != asset size {a.get('size')}")
    if str(a.get("browser_download_url", "")).startswith("https://"):
        ok(case, "download URL is https")
    else:
        bad(case, f"download URL {a.get('browser_download_url')!r} is not https")

for emu, e in emus.items():
    case = f"emulator {emu}"
    if not re.fullmatch(r"[a-z0-9_-]+", emu):
        bad(case, "id is not [a-z0-9_-]+ (it names a folder and a conf)")
        continue
    channel = e.get("channel")
    required = REQUIRED - {"sha256"} if channel is not None else REQUIRED
    missing = required - set(e)
    if missing:
        bad(case, f"lacks {sorted(missing)}")
        continue
    ok(case, "has every field")
    extra = set(e) - REQUIRED - OPTIONAL - {"channel"}
    if extra:
        bad(case, f"unknown fields {sorted(extra)} (launch settings belong in the image's emulator.json)")
    # Optional data files qforge-emu fetches after an install (RPCS3's config database): https only,
    # a normalised path under $HOME. qforge-emu skips a bad entry; the catalog must not carry one.
    data = e.get("data", [])
    good = isinstance(data, list) and all(
        isinstance(d, dict) and set(d) == {"url", "to"} and isinstance(d["url"], str)
        and d["url"].startswith("https://") and isinstance(d["to"], str) and d["to"]
        and not d["to"].startswith("/") and os.path.normpath(d["to"]) == d["to"]
        and ".." not in d["to"].split("/") for d in data)
    if good:
        if data:
            ok(case, f"data files: {[d['to'] for d in data]} (https, under the player's home)")
    else:
        bad(case, f"bad data entries {data!r}: each needs an https url and a relative path, nothing else")

    # An unpacked archive (PortMaster): a folder under the player's home and the version file in it,
    # both normalised relative paths; self_update only on one (qforge-emu refuses it otherwise).
    unpack = e.get("unpack")
    rel = lambda p: (isinstance(p, str) and p and not p.startswith("/")
                     and os.path.normpath(p) == p and ".." not in p.split("/"))
    if unpack is not None:
        if isinstance(unpack, dict) and set(unpack) == {"to", "version"} and rel(unpack["to"]) and rel(unpack["version"]):
            ok(case, f"unpacks into ~/{unpack['to']} (version in {unpack['version']})")
        else:
            bad(case, f"bad unpack {unpack!r}: needs exactly 'to' and 'version', relative paths")
    if "self_update" in e:
        if e["self_update"] is True and unpack is not None and channel is None:
            ok(case, "updates itself after the pinned first install (no update offered)")
        else:
            bad(case, "self_update must be true, on a pinned unpacked archive only")

    if os.path.isfile(os.path.join(emu_conf_dir, emu, "emulator.json")):
        ok(case, f"the image can launch it (/usr/share/qforge/emulators/{emu}/emulator.json)")
    else:
        bad(case, f"no /usr/share/qforge/emulators/{emu}/emulator.json: it would download and never start")
    systems = e["systems"]
    if isinstance(systems, list) and systems:
        wrong = [s for s in systems if launch.get(s) != emu]
        if wrong:
            bad(case, f"systems {wrong} are not mapped to {emu} in launch.conf")
        else:
            ok(case, f"systems {systems} map to it in launch.conf")
    else:
        bad(case, "systems is not a non-empty list")

    tag = e["tag"]
    if channel is not None:
        if channel not in CHANNELS:
            bad(case, f"unknown channel {channel!r} (qforge-emu knows {sorted(CHANNELS)})")
        elif "sha256" in e:
            bad(case, "a nightly entry has no sha256: its build changes, GitHub's digest is checked")
        elif tag.lower() in ROLLING:
            ok(case, f"follows the rolling {tag!r} release on purpose (channel {channel})")
        else:
            bad(case, f"channel {channel} but tag {tag!r} is not a rolling one")
    elif tag.lower() in ROLLING or not re.search(r"\d", tag):
        bad(case, f"tag {tag!r} is rolling: its asset can change under the pin")
    else:
        ok(case, f"pinned to a numbered release ({tag})")
    if re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", e["github"]):
        ok(case, f"source github.com/{e['github']}")
    else:
        bad(case, f"github {e['github']!r} is not owner/repo")
    pattern = e["asset"]
    try:
        rx = re.compile(pattern)
    except re.error as err:
        rx = None
        bad(case, f"asset pattern does not compile: {err}")
    if rx:
        anchored = pattern.startswith("^") and pattern.endswith("$")
        arm = "arm64" in pattern.lower() or "aarch64" in pattern.lower()
        # An unpacked archive carries every architecture's helpers (PortMaster.zip: aarch64, armhf,
        # x86_64) and its tool picks the right one: one asset for all, no arch in the name.
        if anchored and (arm or unpack is not None):
            ok(case, f"asset pattern {pattern} is anchored and {'arm64' if arm else 'multi-arch (unpacked)'}")
        else:
            bad(case, f"asset pattern {pattern!r} must be ^...$ and name arm64/aarch64")
    if channel is not None:
        if rx and rx.groups >= 1:
            ok(case, "asset pattern captures the build id (installed as nightly-<id>)")
        elif rx:
            bad(case, "a nightly asset pattern needs a capture group for the build id")
    elif re.fullmatch(r"[0-9a-f]{64}", str(e["sha256"])):
        ok(case, "sha256 is 64 lowercase hex")
    else:
        bad(case, f"sha256 {e['sha256']!r} is not 64 lowercase hex")
    if isinstance(e["size"], int) and not isinstance(e["size"], bool) and e["size"] > 0:
        ok(case, "size is a positive byte count (shown before download)")
    else:
        bad(case, f"size {e['size']!r} is not a positive integer")
    lic = e["licence"]
    if isinstance(lic, dict) and lic.get("name") and str(lic.get("url", "")).startswith("https://"):
        ok(case, f"licence attributed ({lic['name']})")
    else:
        bad(case, "licence needs a name and an https:// url (attribution is owed)")
    if isinstance(e["author"], str) and e["author"].strip():
        ok(case, f"author credited ({e['author']})")
    else:
        bad(case, "author needs a name (the Emulators page credits it)")
    if str(e["homepage"]).startswith("https://"):
        ok(case, "homepage is https")
    else:
        bad(case, f"homepage {e['homepage']!r} is not https")

    if net and rx:
        check_github(f"emulator {emu} (GitHub)", e, rx)

# Every system the image launches has an emulator in the catalog, or the plugin cannot offer it.
case = "coverage"
served = {s for e in emus.values() if isinstance(e.get("systems"), list) for s in e["systems"]}
for system, emu in launch.items():
    if system in served:
        ok(case, f"system {system} ({emu}) is downloadable")
    else:
        bad(case, f"system {system} maps to {emu} in launch.conf but no catalog entry serves it")
PY
)"
rc=$?
[ $rc -eq 0 ] || { echo "the catalog checker crashed (exit $rc)" >&2; exit 1; }

PASS=0; FAIL=0
while IFS=$'\t' read -r verdict case msg; do
  case $verdict in
    ok)   PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$case" "$msg" ;;
    FAIL) FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$case" "$msg" ;;
  esac
done <<< "$out"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ]
