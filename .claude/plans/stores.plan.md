# Plan: GOG and Epic stores

**Complexity**: High. **Branch**: `steam-armv8-proton`. **Status**: started 2026-10-24, before the next
dev rebuild (user: "can we add gog and epic before we rebuild").

## Summary

A GOG tab and an Epic tab in the library, beside Steam: every game the account owns, installed or not.
Install, uninstall and launch from OGUI. Windows builds run with our ARMv8.0 Proton (or Proton-CachyOS on
CPUs with LSE) inside Steam Linux Runtime 4 arm64. Cloud saves sync before a game starts and after it
exits. Sign-in is on the player's phone: RetroForge never sees a password.

## Decisions

| | Decision |
|---|---|
| D1 | **The stores' own open tools**: legendary (Epic, derrod/legendary, GPL-3.0) and gogdl (GOG, Heroic-Games-Launcher/heroic-gogdl, GPL-3.0). Both publish Linux arm64 zipapps for the system `python3` (legendary's one native module is built for CPython 3.14 aarch64, the image's). Pinned to a release and its sha256 (`/usr/share/retroforge/stores/*.pin`), bumped by hand. Downloaded at the store's first sign-in, never shipped. |
| D2 | **Unpacked and compiled, not run as zipapps.** A zipapp recompiles its own modules on every run: legendary took 3.7 s to start on the Air X, gogdl 2.7 s. Unpacked into the player's home and compiled once (checked-hash), with the image's stdlib bytecode: 0.7 s and 0.56 s. Both `__main__.py` skip their own unpacking when not run from a zip. |
| D3 | **Runtime: Steam's, else our own copy** (user, 2026-10-24). `steamapps/common/SteamLinuxRuntime_4-arm64` when Steam installed it, else Valve's standalone `SteamLinuxRuntime_4-arm64.tar.xz` (repo.steampowered.com/steamrt4/images/latest-container-runtime-depot, 99 MB, checked against its SHA256SUMS) in the player's home. Proton comes from `steam-compat-tools on`, which installs the CPU's build into Steam's compatibilitytools.d whether the client is installed or not. |
| D4 | **Proton outside Steam** the way `retroforge-steam-direct` runs it: `<runtime>/_v2-entry-point --verb=waitforexitandrun -- <proton>/proton waitforexitandrun <exe>`, with the `STEAM_COMPAT_*` variables. `STEAM_COMPAT_CLIENT_INSTALL_PATH` is a fixed empty folder of ours: Proton only copies Steam's client DLLs when they are there, and their mtimes are part of its prefix check, so a Steam update would otherwise redo every store prefix's set-up. One prefix per game. |
| D5 | **Cloud saves around each launch** (user, 2026-10-24): download before the game starts, upload after it exits (`gogdl save-sync`, `legendary sync-saves`). A failed sync is shown and does not block playing. |
| D6 | **Sign-in on the phone** (user, 2026-10-24). The device shows a QR code for a one-time page it serves on the LAN only while the sign-in screen is open. The page links to the store's own sign-in, and takes back what the store shows at the end (GOG's address with `code=`, Epic's `authorizationCode`), sending it as it is pasted. The code is XORed in the page with a one-time key that is only in the QR link's `#fragment`, which browsers never send, so someone capturing the Wi-Fi traffic does not see it. It is used as it arrives and the phone shows whom it signed in: the first version's confirm on the device was dropped as clunky (user, same day). Neither store has a device sign-in to use instead: GOG's auth server has no device-code grant, and Epic's works only with its own apps' clients, whose credentials are not ours to use. Tokens stay in the player-only home (0700). |
| D9 | **Art at the size it is shown.** Epic's key images are up to 1200x1600 PNGs of 2-3 MB and GOG's logos 2 MB; both CDNs resize on request (Epic `?w=360&resize=1&quality=medium`, ~25 KB; GOG's `_800`, `_glx_logo` suffixes). Downloads and installs run at nice 10, behind OGUI (Air X, 2026-10-24: 284 new cards and a GOG download made the UI chug). |
| D7 | **Windows builds only** to start with. GOG's Linux builds are x86 and would need FEX and the x86 guest. |
| D8 | **One helper**, `/usr/lib/retroforge/store <gog|epic> <verb>`, which the plugin runs as it runs `steam-library`; a QR encoder in `/usr/lib/retroforge/python/qr.py` (checked against zbar for versions 1-10). |
| D10 | **umu-protonfixes' per-game fixes** (2026-10-24). proton-armv8 patch 0003 builds in umu-protonfixes at `protonfixes.pin` (`96b9fc07`, GE-Proton's own pin that day) and ports GE-Proton's hook in `proton` as it is (`import protonfixes`; `setup`, mount drives, winetricks, frame rate, local shader cache, `execute`), without GE's upscaler upgrades, which need GE's Wine patch. Steam games get theirs by app id. The helper passes what protonfixes reads, `UMU_ID` and `STORE` (`gog`, `egs`), as umu-run sets them (`GAMEID` is only umu-run's input): the umu id from the umu-database CSV, cached in `<data>/umu-database.csv` at install and fetched again when a day old; a game it does not list is `umu-default`, so only the store's defaults run (GOG: an OpenSSL CPU mask; Epic: `vcrun2022` and the launcher's registry key). **ARM caveat**: the fixes were written for x86 GE-Proton. Their `winetricks` verbs install x86 and x64 redistributables, which run through FEX here, and winetricks takes an ARM64 prefix's system32 for x64's, so some fixes may not work: `"protonfixes": "off"` for a game in `store-games.json` (beside `tso`) sets `PROTONFIXES_DISABLE`. |

## Phases

1. Helper: pins, tool set-up, sign-in page, status, games, install with progress, uninstall, launch with
   saves. `tests/test-store.sh` against fake tools.
2. Plugin: Settings > Stores (GOG, Epic: sign in, sign out, the QR panel), a library per store and its tab,
   install progress. `tests/test-plugin.sh` cases.
3. Air X: sign in to both by phone, install and play one free game per store, check a cloud save round
   trip.
