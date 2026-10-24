#!/usr/bin/env bash
# Offline test for /usr/lib/retroforge/store (GOG and Epic, .claude/plans/stores.plan.md) and its QR
# encoder (/usr/lib/retroforge/python/qr.py).
#
#   tests/test-store.sh
#
# Fake legendary and gogdl (RETROFORGE_STORE_TOOL_*), a fake runtime, Proton and game runner, and a
# local server for every https:// request (RETROFORGE_STORE_API): GOG's APIs, the tools' releases and
# the runtime's channel. Rules: a tool is set up only from its pinned sha256, unpacked and compiled; the
# sign-in page takes a code only through its one-time path, sealed with the link's fragment key, and
# uses it only after `accept`; tokens are the player's only (0600); the libraries list owned Windows
# games with art and their install state; installs report N% and fail on what the tool logs (legendary
# exits 0 either way); a launch sets the prefix up once, syncs saves down, runs the game through
# Proton in the runtime, syncs them up, and does not upload after a failed download; a GOG conflict
# keeps the last sync time.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STORE="$ROOT/rootfs/overlay/usr/lib/retroforge/store"
[ -f "$STORE" ] || { echo "missing: $STORE" >&2; exit 1; }
T="$(mktemp -d)" && [ -d "$T" ] || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT

python3 - "$STORE" "$T" "$ROOT" <<'PY'
import base64, hashlib, http.server, io, json, os, re, shutil, stat, subprocess, sys, tarfile, threading
import urllib.error, urllib.request, zipfile

STORE, T, ROOT = sys.argv[1:4]
PASS = FAIL = 0
CASE = ""


def ok(cond, what, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  ok   {CASE} -- {what}")
    else:
        FAIL += 1
        print(f"  FAIL {CASE} -- {what}" + (f": {detail}" if detail else ""))


# ---- the fake world --------------------------------------------------------------------------------
HOME = os.path.join(T, "home")
FAKE = os.path.join(T, "fake")
for d in (HOME, FAKE):
    os.makedirs(d)
DATA = os.path.join(HOME, ".local/share/retroforge/stores")
CONF = os.path.join(HOME, ".config/retroforge/stores")
CALLS = os.path.join(FAKE, "calls")

buf = io.BytesIO()
with zipfile.ZipFile(buf, "w") as z:
    z.writestr("__main__.py", "import sys\nprint('fake tool', sys.argv[1:])\n")
    z.writestr("pkg/__init__.py", "X = 1\n")
ZIPAPP = b"#!/usr/bin/env python3\n" + buf.getvalue()
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w:xz") as tar:
    body = b"#!/bin/sh\nexit 0\n"
    info = tarfile.TarInfo("SteamLinuxRuntime_4-arm64/_v2-entry-point")
    info.size, info.mode = len(body), 0o755
    tar.addfile(info, io.BytesIO(body))
RT = buf.getvalue()
ROUTES = {
    "/github.com/x/tool": ZIPAPP,
    "/repo.steampowered.com/rt/VERSION.txt": b"4.0.1\n",
    "/repo.steampowered.com/rt/SHA256SUMS": (hashlib.sha256(RT).hexdigest() + " *SteamLinuxRuntime_4-arm64.tar.xz\n").encode(),
    "/repo.steampowered.com/rt/SteamLinuxRuntime_4-arm64.tar.xz": RT,
    "/users.gog.com/users/u1": {"username": "gogtester"},
    "/galaxy-library.gog.com/users/u1/releases": {"items": [{"platform_id": "gog", "external_id": "1"},
                                                            {"platform_id": "steam", "external_id": "9"}],
                                                  "next_page_token": "p2"},
    "/galaxy-library.gog.com/users/u1/releases?page_token=p2": {"items": [{"platform_id": "gog", "external_id": "2"},
                                                                          {"platform_id": "gog", "external_id": "3"}]},
    "/gamesdb.gog.com/platforms/gog/external_releases/1": {
        "type": "game", "title": {"*": "Game One"}, "supported_operating_systems": [{"slug": "windows"}],
        "game": {"visible_in_library": True, "vertical_cover": {"url_format": "https://images.gog.com/v1{formatter}.{ext}"},
                 "logo": {"url_format": "https://images.gog.com/l1{formatter}.{ext}"}}},
    "/gamesdb.gog.com/platforms/gog/external_releases/2": {"type": "dlc", "title": {"*": "A DLC"},
                                                           "supported_operating_systems": [{"slug": "windows"}]},
    "/gamesdb.gog.com/platforms/gog/external_releases/3": {"type": "game", "title": {"*": "Linux Only"},
                                                           "supported_operating_systems": [{"slug": "linux"}]},
    "/remote-config.gog.com/components/galaxy_client/clients/c1?component_version=2.0.45": {
        "content": {"Windows": {"cloudStorage": {"enabled": True, "locations": [
            {"name": "saves", "location": "<?APPLICATION_DATA_LOCAL?>/Game One/Saves"}]}}}},
}
SEEN = []


class Api(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        SEEN.append((self.path, self.headers.get("Authorization", "")))
        body = ROUTES.get(self.path)
        if body is None:
            self.send_response(404)
            self.end_headers()
            return
        body = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


api = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Api)
threading.Thread(target=api.serve_forever, daemon=True).start()
API = f"http://127.0.0.1:{api.server_address[1]}"

PINS = os.path.join(T, "pins")
os.makedirs(PINS)
for name in ("legendary", "gogdl"):
    with open(os.path.join(PINS, f"{name}.pin"), "w") as f:
        f.write(f"name: {name}\ntag: 1.0\nurl: https://github.com/x/tool\nsha256: {hashlib.sha256(ZIPAPP).hexdigest()}\n")
with open(os.path.join(PINS, "steamrt4.pin"), "w") as f:
    f.write("name: rt\nbase: https://repo.steampowered.com/rt\nasset: SteamLinuxRuntime_4-arm64.tar.xz\n")


def script(name, body):
    path = os.path.join(FAKE, name)
    with open(path, "w") as f:
        f.write("#!/usr/bin/env python3\nimport json, os, sys\n"
                f"CALLS = {CALLS!r}\n"
                "def call(*extra):\n"
                "    with open(CALLS, 'a') as f:\n"
                "        f.write(json.dumps([os.path.basename(sys.argv[0])] + sys.argv[1:] + list(extra)) + '\\n')\n"
                + body)
    os.chmod(path, 0o755)
    return path


LEGENDARY = script("legendary", r'''
cfg = os.environ["LEGENDARY_CONFIG_PATH"]
os.makedirs(cfg, exist_ok=True)
a = [x for x in sys.argv[1:] if x != "-y"]
inst = os.path.join(cfg, "installed.json")
installed = json.load(open(inst)) if os.path.exists(inst) else {}
call(os.environ.get("STEAM_COMPAT_DATA_PATH", ""))
if a[:2] == ["auth", "--delete"]:
    if os.path.exists(os.path.join(cfg, "user.json")): os.remove(os.path.join(cfg, "user.json"))
elif a[:2] == ["auth", "--code"]:
    if a[2] == "0123456789abcdef0123456789abcdef":
        json.dump({"displayName": "Tester", "refresh_token": "r", "account_id": "a"}, open(os.path.join(cfg, "user.json"), "w"))
        print('[cli] INFO: Successfully logged in as "Tester"', file=sys.stderr)
    else:
        print("[Core] ERROR: Logging in failed with InvalidCredentialsError(), please try again.", file=sys.stderr)
elif a[0] == "list":
    print(json.dumps([{"app_name": "Fortnite2", "app_title": "Game Two", "metadata": {"keyImages": [
        {"type": "DieselGameBoxTall", "url": "https://cdn.epic/tall.jpg"}, {"type": "DieselGameBox", "url": "https://cdn.epic/wide.jpg"}]}},
        {"app_name": "Plain", "app_title": "Plain Game", "metadata": {}}]))
elif a[0] == "install":
    app = a[1]
    base = a[a.index("--base-path") + 1]
    for pct in ("10.00", "55.50", "100.00"):
        print(f"[DLManager] INFO: = Progress: {pct}% (1/2), Running for 00:00:01, ETA: 00:00:01", file=sys.stderr, flush=True)
    if app == "broken":
        print("[DLManager] ERROR: Installation failed after 3 seconds.", file=sys.stderr)
    else:
        os.makedirs(os.path.join(base, app, "Bin"), exist_ok=True)
        installed[app] = {"app_name": app, "install_path": os.path.join(base, app), "is_dlc": False}
        json.dump(installed, open(inst, "w"))
elif a[0] == "uninstall":
    installed.pop(a[1], None)
    json.dump(installed, open(inst, "w"))
elif a[0] == "launch":
    g = installed[a[1]]["install_path"]
    print(json.dumps({"game_executable": "Bin\\Game.exe", "game_directory": g, "working_directory": g + "/Bin",
                      "game_parameters": ["-x"], "user_parameters": [], "egl_parameters": ["-AUTH_PASSWORD=xc"]}))
elif a[0] == "sync-saves":
    if os.environ.get("FAKE_SYNC_FAIL"):
        print("[cli] ERROR: could not reach the cloud", file=sys.stderr)
''')
GOGDL = script("gogdl", r'''
a = sys.argv[1:]
auth = a[a.index("--auth-config-path") + 1]
a = a[a.index("--auth-config-path") + 2:]
call()
creds = {"access_token": "tok", "refresh_token": "r", "user_id": "u1", "expires_in": 3600, "loginTime": 1}
if a[:2] == ["auth", "--code"]:
    if a[2] == "goodcode123":
        json.dump({"46899977096215655": creds}, open(auth, "w"))
        print(json.dumps(creds))
    else:
        print(json.dumps({"error": True}))
elif a == ["auth"]:
    print(json.dumps(creds) if os.path.exists(auth) else "null")
elif a[0] == "info":
    print(json.dumps({"folder_name": "Game One", "buildId": "b1", "versionEtag": "e1"}))
elif a[0] == "download":
    base = a[a.index("--path") + 1]
    for p in ("12.50", "99.00"):
        print(f"[PROGRESS] INFO: = Progress: {p} 1/8, Running for: 00:00:01, ETA: 00:00:01", file=sys.stderr, flush=True)
    d = os.path.join(base, "Game One")
    os.makedirs(os.path.join(d, "BIN"), exist_ok=True)
    json.dump({"clientId": "c1", "playTasks": [{"type": "FileTask", "path": "bin\\game.exe", "isPrimary": True,
               "arguments": "-a \"two words\"", "workingDir": "bin"}]}, open(os.path.join(d, f"goggame-{a[1]}.info"), "w"))
    open(os.path.join(d, "BIN", "game.exe"), "w").close()
elif a[0] == "save-sync":
    if os.environ.get("FAKE_CONFLICT"):
        print("[SAVES] WARNING: Files in conflict force downloading or uploading of files", file=sys.stderr)
        sys.stdout.write("1800000000.0")
    else:
        sys.stdout.write("1700000000.5")
''')
RUNNER = script("runner", r'''
call(os.getcwd(), os.environ.get("STEAM_COMPAT_DATA_PATH", ""), os.environ.get("STEAM_COMPAT_CLIENT_INSTALL_PATH", ""),
     os.environ.get("STEAM_COMPAT_TOOL_PATHS", ""))
if "wineboot" in sys.argv:
    pfx = os.path.join(os.environ["STEAM_COMPAT_DATA_PATH"], "pfx")
    os.makedirs(pfx, exist_ok=True)
    open(os.path.join(pfx, "user.reg"), "w").close()
sys.exit(int(os.environ.get("FAKE_GAME_RC", "0")))
''')
PROTON = os.path.join(FAKE, "proton-x")
os.makedirs(PROTON)
open(os.path.join(PROTON, "proton"), "w").close()
COMPAT = script("compat-tools", f"print({PROTON!r})\n")
RUNTIME = os.path.join(FAKE, "runtime")
os.makedirs(RUNTIME)

BASE_ENV = dict(os.environ, HOME=HOME, XDG_CONFIG_HOME=os.path.join(HOME, ".config"),
                XDG_DATA_HOME=os.path.join(HOME, ".local/share"), RETROFORGE_STORE_PINS=PINS,
                RETROFORGE_STORE_API=API, RETROFORGE_STORE_TOOL_LEGENDARY=LEGENDARY, RETROFORGE_STORE_TOOL_GOGDL=GOGDL,
                RETROFORGE_STORE_RUNTIME=RUNTIME, RETROFORGE_STEAM_COMPAT_TOOLS=COMPAT, RETROFORGE_STORE_RUN=RUNNER,
                RETROFORGE_STORE_HOST="127.0.0.1", RETROFORGE_STEAM_ROOT=os.path.join(HOME, "no-steam"))


def store(*args, env=None, unset=()):
    e = dict(BASE_ENV, **(env or {}))
    for k in unset:
        e.pop(k, None)
    return subprocess.run([sys.executable, STORE] + list(args), env=e, text=True, capture_output=True, timeout=60)


def calls():
    try:
        return [json.loads(line) for line in open(CALLS)]
    except FileNotFoundError:
        return []


def reset_calls():
    if os.path.exists(CALLS):
        os.remove(CALLS)


def mode(path):
    return stat.S_IMODE(os.stat(path).st_mode)


def game_run(cs):
    """The runner call that ran the game (not the prefix's wineboot)."""
    return next((c for c in cs if c[0] == "runner" and "waitforexitandrun" in c), None)


# ---- QR ------------------------------------------------------------------------------------------
CASE = "qr"
sys.path.insert(0, os.path.join(ROOT, "rootfs/overlay/usr/lib/retroforge/python"))
import qr
m = qr.matrix("http://192.168.1.20:40123/abcdefghijklmnopqrstuv#ABCDEFGHIJKLMNOPQRSTUV")
n = len(m)
ok(all(len(r) == n for r in m) and (n - 17) % 4 == 0 and 1 <= (n - 17) // 4 <= 10, f"a square of a valid version ({n} modules)")
finder = ["1111111", "1000001", "1011101", "1011101", "1011101", "1000001", "1111111"]
corners = [[r[:7] for r in m[:7]], [r[-7:] for r in m[:7]], [r[:7] for r in m[-7:]]]
ok(all(c == finder for c in corners), "finder patterns in three corners")
ok(m[6][8:n - 8] == "".join("1" if i % 2 == 0 else "0" for i in range(8, n - 8)), "the timing row alternates")
ok(m[n - 8][8] == "1", "the dark module")

# ---- setup ---------------------------------------------------------------------------------------
CASE = "setup"
r = store("epic", "status", unset=["RETROFORGE_STORE_TOOL_LEGENDARY"])
ok(r.returncode == 0 and json.loads(r.stdout)["ready"] is False, "not ready before setup", r.stdout + r.stderr)
bad_pins = os.path.join(T, "badpins")
os.makedirs(bad_pins)
for f in os.listdir(PINS):
    text = open(os.path.join(PINS, f)).read()
    open(os.path.join(bad_pins, f), "w").write(re.sub(r"sha256: \w+", "sha256: " + "0" * 64, text))
r = store("epic", "setup", env={"RETROFORGE_STORE_PINS": bad_pins}, unset=["RETROFORGE_STORE_TOOL_LEGENDARY"])
ok(r.returncode == 1 and "sha256 mismatch" in r.stderr and not os.path.exists(os.path.join(DATA, "tools", "legendary-1.0")),
   "a download whose sha256 is not the pin's is refused, nothing set up", r.stderr)
r = store("epic", "setup", unset=["RETROFORGE_STORE_TOOL_LEGENDARY"])
tool = os.path.join(DATA, "tools", "legendary-1.0")
pycs = [os.path.join(d, f) for d, _, fs in os.walk(tool) for f in fs if f.endswith(".pyc")]
ok(r.returncode == 0 and r.stdout.strip().endswith("100%") and os.path.isfile(os.path.join(tool, "__main__.py")) and pycs,
   "the pinned zipapp is unpacked and compiled", r.stdout + r.stderr)
ok(pycs and all(int.from_bytes(open(p, "rb").read(8)[4:8], "little") == 3 for p in pycs), "its bytecode is checked-hash")
r = store("epic", "status", unset=["RETROFORGE_STORE_TOOL_LEGENDARY"])
ok(json.loads(r.stdout)["ready"] is True, "ready after setup")
r = subprocess.run([sys.executable, tool, "x"], text=True, capture_output=True)
ok("fake tool ['x']" in r.stdout, "it runs unpacked", r.stdout + r.stderr)


# ---- sign-in -------------------------------------------------------------------------------------
def sign_in(name, codes):
    """Run the page and post each code sealed as the page does; (events, page html, statuses, replies,
    the process's exit status). The page ends once a code signs in."""
    proc = subprocess.Popen([sys.executable, STORE, name, "sign-in"], env=BASE_ENV, text=True,
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    events = [json.loads(proc.stdout.readline())]
    path_part, frag = events[0]["url"].split("#")
    key = base64.urlsafe_b64decode(frag + "==")
    statuses, replies = {}, []
    page = urllib.request.urlopen(path_part, timeout=10).read().decode()
    try:
        urllib.request.urlopen(path_part.rsplit("/", 1)[0] + "/wrong", timeout=10)
        statuses["wrong"] = 200
    except urllib.error.HTTPError as err:
        statuses["wrong"] = err.code

    def post(raw):
        req = urllib.request.Request(path_part, data=json.dumps(raw).encode(), method="POST",
                                     headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                return r.status, json.loads(r.read() or b"null")
        except urllib.error.HTTPError as err:
            return err.code, None
        except urllib.error.URLError:
            return "gone", None

    def seal(text):
        data = text.encode()
        ks, counter = b"", 0
        while len(ks) < len(data):
            ks += hashlib.sha256(key + counter.to_bytes(4, "big")).digest()
            counter += 1
        return base64.urlsafe_b64encode(bytes(a ^ b for a, b in zip(data, ks))).decode().rstrip("=")

    statuses["garbage"] = post({"c": "!!"})[0]
    statuses["plain"] = post({"c": base64.urlsafe_b64encode(codes[0].encode()).decode()})[0]
    for code in codes:
        replies.append(post({"c": seal(code)}))
        events.append(json.loads(proc.stdout.readline()))
        events.append(json.loads(proc.stdout.readline()))
    try:
        rc = proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        proc.stdin.close()
        rc = proc.wait(timeout=10)
        rc = f"still serving, stopped by closing stdin ({rc})"
    statuses["after"] = post({"c": seal(codes[-1])})[0]
    return events, page, statuses, replies, rc


CASE = "sign-in gog"
events, page, st, replies, rc = sign_in("gog", ["goodcode123"])
ok(events[0]["event"] == "page" and events[0]["url"].startswith("http://127.0.0.1:") and len(events[0]["qr"]) >= 21,
   "the page's link and QR code come first", str(events[0])[:200])
ok("auth.gog.com/auth?client_id=46899977096215655" in page and "Open GOG sign-in" in page and "password" in page
   and "'paste'" in page, "the page links to GOG's own sign-in and sends as it is pasted")
ok(st["wrong"] == 404, "any other path is a 404")
ok(st["garbage"] == 400 and st["plain"] == 400, "a code not sealed with the link's key is refused", str(st))
ok([e["event"] for e in events[1:]] == ["code", "signed_in"] and events[-1].get("account") == "gogtester",
   "a code signs in as it arrives, as the account's name", str(events[1:]))
ok(replies == [(200, {"ok": True, "account": "gogtester"})], "the phone is told whom it signed in", str(replies))
ok(rc == 0 and st["after"] == "gone", "and the page is gone", f"rc={rc} after={st['after']}")
ok(("/users.gog.com/users/u1", "Bearer tok") in SEEN, "the name comes from GOG's users API with the token")
ok(mode(os.path.join(CONF, "gog-auth.json")) == 0o600 and mode(os.path.join(CONF, "gog-account.json")) == 0o600,
   "the tokens and the account are the player's only")
r = store("gog", "status")
ok(json.loads(r.stdout) == {"ready": True, "signed_in": True, "account": "gogtester"}, "status", r.stdout)

CASE = "sign-in epic"
events, page, st, replies, rc = sign_in("epic", ["ffffffffffffffffffffffffffffffff", "0123456789abcdef0123456789abcdef"])
ok("legendary.gl/epiclogin" in page and "authorizationCode" in page, "the page links to Epic's sign-in")
ok([e["event"] for e in events[1:]] == ["code", "error", "code", "signed_in"] and events[-1]["account"] == "Tester",
   "a code Epic refuses is an error and the page stays; the next one signs in", str(events[1:]))
ok(replies[0][0] == 200 and replies[0][1]["ok"] is False and "Logging in failed" in replies[0][1]["message"]
   and replies[1] == (200, {"ok": True, "account": "Tester"}), "the phone is told each time", str(replies))
legend = [c for c in calls() if c[0] == "legendary"]
ok(legend[-2][1:3] == ["auth", "--delete"] and legend[-1][1:3] == ["auth", "--code"],
   "an earlier sign-in is dropped first (legendary keeps it over a new code)")
r = store("epic", "status")
ok(json.loads(r.stdout)["account"] == "Tester", "status reads the account without the network", r.stdout)
CASE = "sign-in cancel"
proc = subprocess.Popen([sys.executable, STORE, "gog", "sign-in"], env=BASE_ENV, text=True,
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
proc.stdout.readline()
proc.stdin.close()
ok(proc.wait(timeout=10) == 0, "closing stdin (the plugin's Cancel) ends the page")


CASE = "games gog"
r = store("gog", "games")
games = json.loads(r.stdout or "[]")
ok(r.returncode == 0 and [g["id"] for g in games] == ["1"], "owned Windows games only (no DLC, no Linux-only, no other platform)", r.stdout + r.stderr)
ok(games and games[0]["title"] == "Game One" and games[0]["art"].get("portrait") == "https://images.gog.com/v1.jpg"
   and games[0]["art"].get("logo") == "https://images.gog.com/l1_glx_logo.png" and games[0]["installed"] is False,
   "title, art sized by GOG's suffixes, not installed", str(games))
r = store("gog", "games", env={"RETROFORGE_STORE_API": "http://127.0.0.1:9"})
ok(r.returncode == 0 and [g["id"] for g in json.loads(r.stdout or "[]")] == ["1"] and "as last listed" in r.stderr,
   "offline: the library as last listed", r.stderr)

CASE = "games epic"
r = store("epic", "games")
games = {g["id"]: g for g in json.loads(r.stdout or "[]")}
ok(set(games) == {"Fortnite2", "Plain"} and games["Fortnite2"]["art"] == {
   "portrait": "https://cdn.epic/tall.jpg?w=360&resize=1&quality=medium",
   "landscape": "https://cdn.epic/wide.jpg?w=800&resize=1&quality=medium",
   "hero": "https://cdn.epic/wide.jpg?w=1600&resize=1&quality=medium"}, "games and their art, resized by Epic's CDN", r.stdout + r.stderr)
r = store("epic", "games", env={"XDG_CONFIG_HOME": os.path.join(T, "nobody")})
ok(r.returncode == 3, "not signed in: exit 3", r.stderr)


# ---- install -------------------------------------------------------------------------------------
def percents(out):
    return [int(line[:-1]) for line in out.split() if line.endswith("%")]


CASE = "install epic"
r = store("epic", "install", "Fortnite2")
p = percents(r.stdout)
ok(r.returncode == 0 and p == sorted(p) and p[-1] == 100 and all(x <= 90 for x in p[:-1]), "N% as it goes, 100% once ready", r.stdout + r.stderr)
inst = [c for c in calls() if c[0] == "legendary" and "install" in c]
ok(inst and "--skip-dlcs" in inst[-1] and "--skip-sdl" in inst[-1] and inst[-1][inst[-1].index("--max-shared-memory") + 1] == "512",
   "no DLC, no prompts, 512 MiB of shared memory", str(inst[-1:]))
r = store("epic", "games")
ok({g["id"]: g["installed"] for g in json.loads(r.stdout)}["Fortnite2"] is True, "installed in the library")
r = store("epic", "install", "broken")
ok(r.returncode == 1 and "Installation failed" in (r.stderr.splitlines() or [""])[-1], "legendary's logged failure fails the install (it exits 0)", r.stderr)

CASE = "install gog"
r = store("gog", "install", "1")
rec = json.load(open(os.path.join(DATA, "gog-installed.json")))
ok(r.returncode == 0 and percents(r.stdout)[-1] == 100 and rec["1"]["path"].endswith("games/gog/Game One"),
   "installed and recorded (gogdl keeps no record)", r.stdout + r.stderr)
ok(json.loads(store("gog", "games").stdout)[0]["installed"] is True, "installed in the library")

CASE = "runtime"
r = store("gog", "install", "1", unset=["RETROFORGE_STORE_RUNTIME"])
ours = os.path.join(DATA, "runtime", "SteamLinuxRuntime_4-arm64", "_v2-entry-point")
ok(r.returncode == 0 and os.path.isfile(ours) and open(os.path.join(DATA, "runtime", ".version")).read().strip() == "4.0.1",
   "without Steam's, the runtime's channel is downloaded and checked", r.stderr)
steam_rt = os.path.join(HOME, "steam", "steamapps", "common", "SteamLinuxRuntime_4-arm64")
os.makedirs(steam_rt)
open(os.path.join(steam_rt, "_v2-entry-point"), "w").close()
reset_calls()
store("gog", "launch", "1", env={"RETROFORGE_STEAM_ROOT": os.path.join(HOME, "steam")}, unset=["RETROFORGE_STORE_RUNTIME"])
run = game_run(calls())
ok(run and run[1] == os.path.join(steam_rt, "_v2-entry-point"), "Steam's runtime when it has one", str(run))

# ---- launch --------------------------------------------------------------------------------------
CASE = "launch gog"
shutil.rmtree(os.path.join(DATA, "prefixes"), ignore_errors=True)
for f in ("gog-saves.json", "notices-gog"):
    if os.path.exists(os.path.join(DATA, f)):
        os.remove(os.path.join(DATA, f))
reset_calls()
r = store("gog", "launch", "1", env={"FAKE_GAME_RC": "7"})
cs = calls()
order = []
for c in cs:
    if c[0] == "runner":
        order.append("boot" if "wineboot" in c else "game")
    elif c[0] == "gogdl" and "save-sync" in c:
        order.append("sync " + ("down" if "--skip-upload" in c else "up"))
ok(r.returncode == 7, "the game's exit status", r.stderr)
ok(order == ["boot", "sync down", "game", "sync up"], "prefix set up, saves down, the game, saves up", str(order))
syncs = [c for c in cs if c[0] == "gogdl" and "save-sync" in c]
pfx_saves = os.path.join(DATA, "prefixes", "gog-1", "pfx", "drive_c", "users", "steamuser", "AppData", "Local", "Game One", "Saves")
ok(syncs and syncs[0][syncs[0].index("save-sync") + 1] == pfx_saves, "the save folder inside the prefix", str(syncs[:1]))
run = game_run(cs)
i = run.index("waitforexitandrun")
gamedir = os.path.join(DATA, "games", "gog", "Game One")
ok(run[1:4] == [os.path.join(RUNTIME, "_v2-entry-point"), "--verb=waitforexitandrun", "--"] and run[4] == os.path.join(PROTON, "proton")
   and run[i + 1] == os.path.join(gamedir, "BIN", "game.exe") and run[i + 2:i + 4] == ["-a", "two words"],
   "Proton in the runtime, the primary task's program (case-insensitive) and arguments", str(run))
ok(run[-4:] == [os.path.join(gamedir, "BIN"), os.path.join(DATA, "prefixes", "gog-1"), os.path.join(DATA, "steam-client"),
                f"{PROTON}:{RUNTIME}"], "its folder, prefix, empty client folder, tools", str(run[-4:]))
ok(json.load(open(os.path.join(DATA, "gog-saves.json"))) == {"1.saves": "1700000000.5"}, "the sync time is kept per location")
reset_calls()
store("gog", "launch", "1")
ok(not [c for c in calls() if c[0] == "runner" and "wineboot" in c], "the prefix is set up once")

CASE = "gog conflict"
store("gog", "launch", "1", env={"FAKE_CONFLICT": "1"})
ok(json.load(open(os.path.join(DATA, "gog-saves.json"))) == {"1.saves": "1700000000.5"}, "a conflict keeps the last sync time")
note = open(os.path.join(DATA, "notices-gog")).read()
ok("changed both here and in GOG's cloud" in note, "and the player is told", note)

CASE = "launch epic"
reset_calls()
r = store("epic", "launch", "Fortnite2")
cs = calls()
run = game_run(cs)
i = run.index("waitforexitandrun") if run else 0
ok(run and run[i + 1:i + 4] == [os.path.join(DATA, "games", "epic", "Fortnite2", "Bin/Game.exe"), "-x", "-AUTH_PASSWORD=xc"],
   "the program with the game's and Epic's parameters", str(run))
syncs = [c for c in cs if c[0] == "legendary" and "sync-saves" in c]
ok(len(syncs) == 2 and "--accept-path" in syncs[0] and "--skip-upload" in syncs[0] and "--skip-download" in syncs[1]
   and syncs[0][-1] == os.path.join(DATA, "prefixes", "epic-Fortnite2"), "saves down (their path from the prefix), then up", str(syncs))
reset_calls()
r = store("epic", "launch", "Fortnite2", env={"FAKE_SYNC_FAIL": "1"})
syncs = [c for c in calls() if c[0] == "legendary" and "sync-saves" in c]
ok(r.returncode == 0 and len(syncs) == 1 and game_run(calls()), "no upload after a failed download, and the game still runs", str(syncs))
ok("cloud copy stays as it was" in open(os.path.join(DATA, "notices-epic")).read(), "the player is told")

# ---- uninstall, sign-out -------------------------------------------------------------------------
CASE = "uninstall"
r = store("epic", "uninstall", "Fortnite2")
ok(r.returncode == 0 and {g["id"]: g["installed"] for g in json.loads(store("epic", "games").stdout)}["Fortnite2"] is False, "epic", r.stderr)
r = store("gog", "uninstall", "1")
ok(r.returncode == 0 and not os.path.exists(gamedir) and json.loads(store("gog", "games").stdout)[0]["installed"] is False,
   "gog: the folder and the record go", r.stderr)
CASE = "sign-out"
ok(store("gog", "sign-out").returncode == 0 and json.loads(store("gog", "status").stdout)["signed_in"] is False, "gog")
ok(store("epic", "sign-out").returncode == 0 and json.loads(store("epic", "status").stdout)["signed_in"] is False, "epic")
CASE = "usage"
ok(store("steam", "games").returncode == 2 and store("gog", "install").returncode == 2, "a bad invocation is exit 2")

print(f"\n{PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
PY
