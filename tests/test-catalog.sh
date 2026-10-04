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
#     one silently ships an untested build: pins must be numbered releases;
#   - the sha256 is what the plugin checks the download against (and must match GitHub's per-asset
#     digest): a malformed one would make every install fail, or, if skipped, verify nothing;
#   - an emulator the image cannot launch (no /etc/qforge/emulators/<emu>.conf), or one serving a
#     system launch.conf maps elsewhere, would download fine and then never start;
#   - a plain-http URL would let anyone on the path swap the AppImage.
#
# Launch details (binary, args, first-run seed) live in the image's emulator conf, NOT here: the
# catalog only says what to download and how to verify it.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CATALOG="${QFORGE_CATALOG:-$ROOT/apps/ogui-qforge-plugin/catalog.json}"
LAUNCH_CONF="$ROOT/rootfs/overlay/etc/qforge/launch.conf"
EMU_CONF_DIR="$ROOT/rootfs/overlay/etc/qforge/emulators"

for f in "$CATALOG" "$LAUNCH_CONF"; do
  [ -f "$f" ] || { echo "missing input: $f" >&2; exit 1; }
done
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }

# The checks are in Python (JSON + regex); each prints "ok|FAIL <TAB> case <TAB> message".
out="$(QFORGE_NET_TEST="${QFORGE_NET_TEST:-0}" python3 - "$CATALOG" "$LAUNCH_CONF" "$EMU_CONF_DIR" <<'PY'
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
REQUIRED = {"name", "systems", "github", "tag", "asset", "sha256", "size", "homepage", "licence"}

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
    missing = REQUIRED - set(e)
    if missing:
        bad(case, f"lacks {sorted(missing)}")
        continue
    ok(case, "has every field")
    extra = set(e) - REQUIRED
    if extra:
        bad(case, f"unknown fields {sorted(extra)} (launch settings belong in the image's emulator conf)")

    if os.path.isfile(os.path.join(emu_conf_dir, f"{emu}.conf")):
        ok(case, f"the image can launch it (/etc/qforge/emulators/{emu}.conf)")
    else:
        bad(case, f"no /etc/qforge/emulators/{emu}.conf: it would download and never start")
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
    if tag.lower() in ROLLING or not re.search(r"\d", tag):
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
        if anchored and arm:
            ok(case, f"asset pattern {pattern} is anchored and arm64")
        else:
            bad(case, f"asset pattern {pattern!r} must be ^...$ and name arm64/aarch64")
    if re.fullmatch(r"[0-9a-f]{64}", str(e["sha256"])):
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
