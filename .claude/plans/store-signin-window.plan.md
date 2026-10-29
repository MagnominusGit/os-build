# Plan: store sign-in on the device (Chromium window)

**Complexity**: Medium-High. **Branch**: `steam-armv8-proton`. **Status**: prototype committed at
f8f62179 (2026-10-29), HW-OK on Pocket FIT for GOG and Epic + Google; plan not yet agreed.

## Summary

Settings > Stores signs in with the phone today (stores.plan.md D6: a QR code for a one-time LAN page).
This replaces it with the store's own sign-in page in a window on the device: Sign in opens it, the
player signs in there (touch or on-screen keyboard), the window closes by itself and the row says whom
it signed in. The prototype in `apps/retroforge-store-signin/` proved the pieces on the Pocket FIT
(2026-10-29): Chromium in app mode, the code read over the DevTools pipe, the existing `sign_in(code)`.

## What the prototype established

| | Finding |
|---|---|
| F1 | **Chromium, not Electron.** Google refuses sign-in in embedded web views (Electron, WebKit, Servo) by policy; the real Chromium passes. GOG works in both, so one browser covers both stores. |
| F2 | **`--disable-blink-features=AutomationControlled`.** `--remote-debugging-pipe` alone makes `navigator.webdriver` true in every page (probed on the device) and Cloudflare's check on Epic loops forever. |
| F3 | **Scale = screen height / 720** (`--force-device-scale-factor`, 1.5 on 1080p, a 1280x720 page). 1.0 is unreadable on a 6" panel, 2.0 (960x540) makes the forms scroll. Chromium sees the rotated DSI panel as landscape. |
| F4 | **Size.** Chromium 147 is 162 MB to download (396 MB unpacked) plus 19 MB of packages the image lacks (GTK3 and its closure). The rootfs is 1.85 GB of its 2 GB slot: it does not fit in the image. |
| F5 | **Focus.** OGUI ties windows to apps by `OGUI_ID` in `/proc/<pid>/environ`; Chromium overwrites its environ (process titles), so its window is an orphan and stays behind OGUI (black screen). The test used a `/run` helper setting `GAMESCOPECTRL_BASELAYER_APPID`. |
| F6 | **Sandbox** works with unprivileged user namespaces (no setuid helper needed in /home). |
| F7 | **The Air X failure is its network**: Google fails after the password there and works on the Pocket FIT with the same card ([[ace-wifi-stalls]]-like stalls). Not a blocker for the design. |

## Decisions (proposed, to agree)

| | Decision |
|---|---|
| D1 | **Chromium downloaded at the first sign-in, never shipped** (as legendary/gogdl, stores D1). The packages come from the image's own snapshot (`rootfs/manifest.lock`), listed with their sha256 in a pin the build writes when it relocks (`/usr/share/retroforge/stores/chromium.pin`: filename, sha256, size; measured, not copied). Unpacked into the player's home (`~/.local/share/retroforge/chromium/`), checked against the pin, replaced when the pin changes. Progress shows on the Sign in row. Chromium is only ever pointed at the two stores' sign-in pages, so a snapshot-old Chromium is acceptable; it moves with each relock. |
| D2 | **One helper verb**: `store <gog\|epic> sign-in` keeps its name and events but opens the window instead of the LAN page: `chromium-signin.py` folds into the helper (or `/usr/lib/retroforge/python/`), then `sign_in(code)` as now. New events: `browser` (`setup` progress, `open` with Chromium's pid, `closed`). |
| D3 | **The plugin owns the window's focus.** On `open` it finds the window of that pid in gamescope's focusable windows and puts its app id in the base layer, and puts OGUI back when it closes (the `/run` helper's logic, in GDScript). No OGUI patch. |
| D4 | **The LAN/QR page is removed** (its server was awaiting a security review; `qr.py` goes if nothing else uses it). |
| D5 | **Input**: touch and the OGUI on-screen keyboard (works since b4d6e5a9). Devices without a touchscreen need a pointer: open question Q2. |
| D6 | **Cancel**: B / the Guide menu's Close ends the window; the row goes back to Sign in. The 15-minute limit stays. |

## Open questions

- **Q1** Drop the LAN/QR sign-in entirely (D4), or keep it as a fallback when the 181 MB download is not possible?
- **Q2** Non-touch devices (RP Classic, RG55G1?): an InputPlumber profile for the sign-in window (stick = mouse, A = click, D-pad = Tab/arrows), or out of scope for now?
- **Q3** Download the Chromium in the background at the first visit to Settings > Stores (as the tools' setup), or only when Sign in is pressed?

## Phases

1. **Pin + set-up**: the build writes `chromium.pin` from the snapshot db at relock; `store chromium-setup`
   downloads, checks, unpacks, with progress. `tests/test-store.sh` against a fake snapshot.
2. **Helper**: `sign-in` opens Chromium (flags F2, F3, profile in a private temp folder deleted after),
   reads the code, signs in. Fake-Chromium test for the code reading (GOG address, Epic JSON page).
3. **Plugin**: Sign in row runs it, progress, focus (D3), Cancel, the QR panel removed.
   `tests/test-plugin.sh` cases.
4. **HW**: Pocket FIT (touch), one non-touch device (Q2), and Air X once its Wi-Fi is sorted. Then
   remove `hw-test/`, `main.js`, `package.json`.
