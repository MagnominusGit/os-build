#!/usr/bin/env python3
# chromium-signin.py <chromium binary> <gog|epic> — the store's own sign-in page in Chromium's app
# mode (one window, no address bar, a throwaway profile), and the code it ends with on stdout.
#
# WHY CHROMIUM AND NOT ELECTRON. Google refused "Sign in with Google" on Epic inside our Electron
# window (Air X, 2026-10-28): Google blocks sign-in in embedded web views by policy. Chromium is the
# browser itself, which Google treats as one.
#
# THE CODE. Chromium runs with --remote-debugging-pipe: the DevTools protocol on fds 3 (our commands)
# and 4 (its answers and events), JSON messages ending in a NUL. No port is opened. Every page's
# address arrives as Target.targetInfoChanged: GOG's code is in the address it redirects to at the
# end; Epic's is in the JSON page it ends on, read with Runtime.evaluate in that page.
#
# Exit 0 with {"store": ..., "code": ...} on stdout; 1 when the window was closed or 15 minutes passed
# without a code; 2 for a bad invocation. Everything else goes to stderr.
import json
import os
import re
import select
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse

TIMEOUT = 15 * 60  # as the store helper's sign-in
EPIC_REDIRECT = ("https://www.epicgames.com/id/api/redirect?clientId=34a02cf8f4414e29b15921876da36f9a"
                 "&responseType=code")
STORES = {
    "gog": {"start": "https://auth.gog.com/auth?client_id=46899977096215655&redirect_uri=https%3A%2F%2F"
                     "embed.gog.com%2Fon_login_success%3Forigin%3Dclient&response_type=code&layout=galaxy",
            "shape": r"[A-Za-z0-9_\-.~]{10,2048}"},
    "epic": {"start": "https://www.epicgames.com/id/login?redirectUrl=" + urllib.parse.quote(EPIC_REDIRECT, safe=""),
             "shape": r"[0-9a-f]{32}"},
}


def log(msg):
    print(f"chromium-signin: {msg}", file=sys.stderr, flush=True)


def gog_code(url):
    u = urllib.parse.urlsplit(url)
    if u.hostname == "embed.gog.com" and u.path == "/on_login_success":
        return (urllib.parse.parse_qs(u.query).get("code") or [None])[0]
    return None


def is_epic_code_page(url):
    u = urllib.parse.urlsplit(url)
    return u.hostname == "www.epicgames.com" and u.path == "/id/api/redirect"


class Pipe:
    """The DevTools protocol over Chromium's fds 3 and 4."""

    def __init__(self, write_fd, read_fd):
        self.w, self.r, self.buf, self.next_id = write_fd, read_fd, b"", 0

    def send(self, method, params=None, session=None):
        self.next_id += 1
        msg = {"id": self.next_id, "method": method, "params": params or {}}
        if session:
            msg["sessionId"] = session
        os.write(self.w, json.dumps(msg).encode() + b"\0")
        return self.next_id

    def messages(self, timeout):
        """The messages that arrive within timeout seconds; None once Chromium has gone."""
        ready, _, _ = select.select([self.r], [], [], timeout)
        if ready:
            chunk = os.read(self.r, 1 << 16)
            if not chunk:
                return None
            self.buf += chunk
        *whole, self.buf = self.buf.split(b"\0")
        return [json.loads(m) for m in whole if m]


def start(binary, url, profile):
    """Chromium in app mode, its DevTools pipe on our side."""
    cmd_r, cmd_w = os.pipe()  # we write commands, it reads them on fd 3
    ans_r, ans_w = os.pipe()  # it writes on fd 4, we read
    # Out of the way of 3 and 4 first, so the dup2s below cannot overwrite one another.
    hi = [os.dup(fd) for fd in (cmd_r, ans_w)]
    for fd in (cmd_r, ans_w):
        os.close(fd)

    def child():
        os.dup2(hi[0], 3)
        os.dup2(hi[1], 4)

    args = [binary, f"--app={url}", f"--user-data-dir={profile}", "--remote-debugging-pipe",
            "--ozone-platform=x11", "--start-fullscreen", "--no-first-run", "--no-default-browser-check",
            "--disable-sync", "--password-store=basic", "--disable-features=Translate",
            # The pipe alone marks every page automation-controlled (navigator.webdriver is true), and
            # Cloudflare's check on Epic then loops forever (Air X and Pocket FIT, 2026-10-29).
            "--disable-blink-features=AutomationControlled"]
    # A handheld's 1080p panel is ~6": at Chromium's own 1:1 the pages are tiny (Pocket FIT,
    # 2026-10-29). run.sh picks the factor from the screen.
    if os.environ.get("RF_SIGNIN_SCALE"):
        args.append(f"--force-device-scale-factor={os.environ['RF_SIGNIN_SCALE']}")
    proc =subprocess.Popen(args, preexec_fn=child, pass_fds=(3, 4), stdout=sys.stderr)
    for fd in hi:
        os.close(fd)
    return proc, Pipe(cmd_w, ans_r)


def main(argv):
    if len(argv) != 3 or argv[2] not in STORES:
        log("usage: chromium-signin.py <chromium> <gog|epic>")
        return 2
    store, name = STORES[argv[2]], argv[2]
    profile = tempfile.mkdtemp(prefix="rf-store-signin-")
    proc, pipe = start(argv[1], store["start"], profile)
    pending = {}  # message id -> what its answer is for
    code, deadline = None, time.monotonic() + TIMEOUT
    try:
        pipe.send("Target.setDiscoverTargets", {"discover": True})
        while code is None and time.monotonic() < deadline:
            msgs = pipe.messages(1.0)
            if msgs is None:
                log("closed without a code")
                return 1
            for m in msgs:
                method, params = m.get("method"), m.get("params", {})
                if method in ("Target.targetCreated", "Target.targetInfoChanged"):
                    info = params.get("targetInfo", {})
                    if info.get("type") != "page":
                        continue
                    url = info.get("url", "")
                    if name == "gog":
                        code = gog_code(url) or code
                    elif is_epic_code_page(url):
                        pending[pipe.send("Target.attachToTarget",
                                          {"targetId": info["targetId"], "flatten": True})] = "attach"
                elif m.get("id") in pending:
                    what = pending.pop(m["id"])
                    if what == "attach" and "result" in m:
                        session = m["result"]["sessionId"]
                        pending[pipe.send("Runtime.evaluate", {"expression": "document.body.innerText",
                                                                "returnByValue": True}, session)] = ("read", session)
                    elif isinstance(what, tuple) and what[0] == "read":
                        text = m.get("result", {}).get("result", {}).get("value") or ""
                        try:
                            code = json.loads(text).get("authorizationCode") or None
                        except ValueError:
                            code = None
                        if code is None:  # not loaded yet: read it again
                            time.sleep(0.5)
                            pending[pipe.send("Runtime.evaluate", {"expression": "document.body.innerText",
                                                                    "returnByValue": True}, what[1])] = what
            if code and not re.fullmatch(store["shape"], code):
                log(f"the {name} page gave something that is not a code ({len(code)} characters); still waiting")
                code = None
        if code is None:
            log("15 minutes without a code; giving up")
            return 1
        print(json.dumps({"store": name, "code": code}), flush=True)
        return 0
    finally:
        try:
            pipe.send("Browser.close")
            proc.wait(timeout=10)
        except (OSError, subprocess.TimeoutExpired):
            proc.kill()
        shutil.rmtree(profile, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
