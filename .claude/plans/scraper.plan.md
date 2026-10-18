# ROM artwork scraper — plan

Status: decisions D1-D3 AGREED 2026-10-17; the user already has a ScreenScraper dev account.
Auto-scrape DONE 2026-10-17 (plugin 0.1.53, HW-OK on the ACE, issue #9): every ROM library load
(start, rescan, Refresh Library) starts a background "scrape missing art" unless off (Settings > Library
> ROM Art > "Scrape new games automatically", default on), the build cannot scrape, a scrape or a game
runs, or the load is the reload a scrape asked for. Quiet: a notification only when art arrives,
failures logged. ACE: a ROM copied in got its art 14 s later and its card rebuilt, no loop.
REPLACED 2026-10-18 (plugin 0.1.59, Pocket FIT): only our own tabs rebuilt; OGUI's All Games /
Installed and Home keep a card and ask its art once, so new art stayed on the placeholder until a
launch. User decision: no OGUI patch, do it like the Steam plugin. Now art_fetch.gd: a card asking
for a ROM with no art and no scrape.json entry runs `retroforge-scrape run --rom` and awaits it (one
run at a time, deduped, waits for a Settings run, holds 10 min after a network/quota failure); the
library-load background run is gone, the setting gates on-demand fetches. FIT: a GBA ROM copied in
had its box 1 s after the rescan, card built with it. Visual check by the user pending.
Port art DONE 2026-10-17 (plugin 0.1.52, HW-OK on the ACE): PortMaster ports are never scraped; the
plugin reads each port's gameinfo.xml (ES gameList: <path> launch script, <image> screenshot, relative
to ~/roms/ports) and uses the screenshot for every layout but LOGO; cards are its centre crop (user
decision: keep the crop). Its desc/developer/date wait for the text-metadata step (D3).
Phase 3 DONE 2026-10-17 (plugin 0.1.51): image stage scraper-login (rootfs/lib-assemble-scraper.sh,
RETROFORGE_SS_DEVID/DEVPASSWORD from dev.env.local or repository secrets; SCRAPER_STAMP), Settings >
Library > ROM Art (scraper_settings.gd), Game settings > RetroForge > Box art, scrape_runner.gd
(worker thread + OS.execute_with_pipe: live N%, password on stdin, SIGTERM cancel). HW on the ACE:
game page Box art seen by the user; 0.1.49 crash-looped OGUI (dropdown filled before add_child
segfaults the release export) -> fixed in 0.1.50 + test. CI repository secrets set by the user 2026-10-17.
Settings > Library > ROM Art HW-OK on the ACE (plugin 0.1.51; user): scrape missing ("nothing new"),
scrape all with progress, sign-in with the user's account (limits 10,000 -> 20,000 a day; conf 0600; the
password in no log, file or command line). 0.1.50 left "Scraping... 100%" on the Scrape all button
after its run (description not restored): fixed in 0.1.51. Known OGUI issue
(not ours): game settings opened from a HOME screen card carry no library item (OGUI's own Library
section warns too), so the RetroForge button stays hidden there; needs an OGUI patch.
Phase 2 DONE 2026-10-17, HW-OK on the Pocket ACE (plugin 0.1.47; user: "looks right"). HW findings
fixed: cards are 2:3 card images composed by the plugin (OGUI's card draws a texture whole from
the top-left, so a SNES box filled a third of it): the box's centre crop (user decision 2026-10-17,
after comparing it on the ACE with the whole box fitted over a blurred copy, and with fan art + logo
"posters"; a wide box loses its sides), cached as 300x450 JPEGs in ~/.cache/retroforge/cards; boxes
asked 450 high (maxheight) so the crop never scales up (plugin 0.1.48); every decode on a worker thread and
our tabs do not await card art (301-card tab: 2,690 ms frozen -> 126 ms, = no art; 301 card images
composed in parallel within 12 s of a session restart; ~50 KB a card). Scraper on HW: Wi-Fi connects
to ScreenScraper sometimes never answer (1 in 5 once, 0 in 30 later; Wi-Fi power save on, not
investigated): lookups and images retried once, images that still fail are fetched next run
("incomplete"), connect timeout 8 s; a lookup still lost after its retry makes that ROM "failed"
and the run goes on, 3 such ROMs in a row stop it (exit 3).
Player ScreenScraper account: optional (more threads/quota, access when ScreenScraper closes to
non-members at peak hours); `retroforge-scrape login` exists, its UI is Phase 3.
Other card sources looked at (2026-10-17), not taken: ScreenScraper steamgrid is 460x215 landscape
(fits GRID_LANDSCAPE, not cards); SteamGridDB has 600x900 grids (API key, name search only); IGDB
covers ~3:4 (Twitch credentials, name only); fan art + logo posters (not every game has fan art). Phase 1 DONE 2026-10-17 on branch feat/scraper: `retroforge-scrape` + systems.json +
tests/test-scrape.sh (98 ok, in `make test`; python-reviewer findings fixed: one bad ROM is
"failed" not fatal, stale quota, redirect host check, no answer bodies on disk, cancel); live run on 4 ROMs (2 CHDs > 128 MiB by name + size,
a single-file zip, a Mega Drive .bin): 4/4 found, 15 images, 8 s, second run 0 requests.
`status` subcommand dropped (YAGNI: the plugin reads the media files). Next: Phase 2 (plugin art
provider, done); the image-build devid step moves to Phase 3. Next: HW check of Phase 2 on the ACE (library build time with art, wide boxes), then Phase 3.

Live facts (2026-10-17): not found = HTTP 404 with a French text body, not JSON; a refused login
is 403 with a text body ("utilisateurs" = player, "développeur" = developer); jeuInfos ignores a
wrong player login (200); answers echo the full request incl. passwords (header.commandRequested,
media URLs); resized media come back as PNG labelled image/jpeg (format taken from magic bytes);
without a player login: maxthreads 1, 10,000 requests / 1,000 not-found a day. requeststoday is NOT
a live count: it rose by 10 between two runs, then not at all for the next lookup + 4 images; how
lookups vs media are counted is unknown -- confirm before telling players a number.

## Why

ROM cards are bare placeholders. retroforge.plan.md has "Artwork scraping later (ScreenScraper needs
credentials)" (Phase 4) and "`BoxArtProvider` … artwork per item, later"; this is that work, and the
first slice of the Phase 4c metadata cache ("comes with the per-ROM work that needs it").

## Decisions

- **D1 — ScreenScraper, with RetroForge's own developer id.** The user already has a ScreenScraper
  developer account (2026-10-17). `RETROFORGE_SS_DEVID` / `RETROFORGE_SS_DEVPASSWORD` come from the
  gitignored `dev.env.local` for local builds (same pattern as the Wi-Fi credentials) and from CI
  secrets of the same names for release builds; never in the repo. Readable in the image, as with
  every ES-based firmware.
  The player's own ScreenScraper account is optional (more threads, higher daily quota).
  TheGamesDB / IGDB (name-only matching, more keys) and ArcadeDB / HfsDB (arcade, a system we do not
  have) are out.
- **D2 — Art lives outside the ROM share:** `~/.local/share/retroforge/media/<system>/`. Not visible
  over SMB, not mixed with ROMs.
- **D3 — Art only first.** No description / year / developer / scraped title in this plan; the card
  name stays the file name (`rom_names.gd` untouched). Text metadata is a later plan.

## Reference: what ES-next does (ROCKNIX/emulationstation-next 40343cf, MIT)

Read 2026-10-17; tables taken from it keep the attribution (MIT, Alec Lofquist 2014 + contributors).
- Request: `https://api.screenscraper.fr/api2/jeuInfos.php?devid&devpassword&softname=<name ver>
  &output=xml&ssid&sspassword&romnom=<file>&romtype=rom&romtaille=<bytes>&md5&crc&systemeid=N`
  (`es-app/src/scrapers/ScreenScraper.cpp:254-339, 838-862`).
- Hashes (`ApiSystem.cpp:1335-1460`): whole file, MD5/CRC uppercase; a zip with exactly one non-.txt
  entry hashes that entry; .m3u hashes its first disc; nothing hashed above 128 MiB (name + size).
- `systemeid` table: `ScreenScraper.cpp:32-193`. ES-next bug: several ids for one platform are
  concatenated into one URL (`path +=`); we try them one by one, stop at the first match.
- Region order for media: [user region or auto, romlang, region, wor, us, eu, jp, ss, cus, ""]
  (`findMedia`, 375-417); auto region from filename tags, else the locale.
- Media fallback (`getRipList`, 419-446): ss -> sstitle; box-2D <-> box-3D; mixrbv1 <-> mixrbv2;
  wheel -> wheel-hd -> wheel-steel -> wheel-carbon -> screenmarqueesmall -> screenmarquee.
  Server-side resize via `maxwidth`/`maxheight` on media URLs (549-565).
- Quota: `ssuserInfos.php` -> `maxthreads` (used), `requeststoday` / `maxrequestsperday` (parsed,
  ignored: we use them). Run-stopping HTTP codes: 430/431 quota, 426 blacklisted, 423 maintenance,
  401/403 login (`ThreadedScraper.cpp:143-155`); 429 retried after Retry-After.

## Phase 1 — `retroforge-scrape` (Python CLI, Medium)

Shape mirrors `retroforge-emu` (stdout is a contract, numbered exits, env seams for tests).
- `retroforge-scrape run [--system S] [--rom PATH] [--missing|--all]`: `N%` lines, then one JSON
  summary line (`scraped`, `not_found`, `skipped`, `quota_left`).
  `retroforge-scrape account`: JSON (configured?, maxthreads, requests today / max), no network.
  `retroforge-scrape login <ssid>` (password on stdin) / `logout` / `region auto|wor|us|eu|jp`.
- Exits: 0 ok, 2 bad invocation, 3 network, 5 local (space, fs, busy, cancelled), 6 quota / rate
  limit (stderr says which), 7 player login refused, 8 ScreenScraper closed (401 non-members,
  423 maintenance, 426 blacklisted), 9 no working developer login in this build.
- `/usr/share/retroforge/scraper/systems.json`: our 18 system ids -> ScreenScraper `systemeid` list
  (from ES-next's table, each checked against `systemesListe.php`). `ports` has none: never scraped.
- Identity: file name, size; CRC32 + MD5 when <= 128 MiB; single-entry zip -> its entry (7z: name +
  size only, no 7z dependency); .m3u -> first disc; PS3 folder -> folder name, no hash.
- Cache: `~/.cache/retroforge/scrape.json`, keyed by path + size + mtime: hashes, ScreenScraper
  game id, last result (found / not found + date), so `--missing` does not re-ask for ROMs the
  database does not know (retry after N days).
- Media per ROM (stem = ROM file name without extension, folder name for PS3):
  `<stem>-box.png` (box-2D chain), `<stem>-screen.png` (ss chain), `<stem>-fanart.jpg`,
  `<stem>-wheel.png` (wheel chain); downloaded at maxwidth 640 (fanart 1280), written atomically
  (`.part` + rename), extension from the file's magic bytes (stem = the full ROM file name, so
  `Game.cue` and `Game.chd` never share art).
- Network: curl via `RETROFORGE_CURL`, `--proto =https --proto-redir =https`, hosts limited to
  `*.screenscraper.fr` (the API answers from mirrors: `neoclone.screenscraper.fr` seen 2026-10-17);
  `output=json` (dev creds verified live 2026-10-17 with `ssinfraInfos.php`, softname RetroForge); one request at a time (maxthreads is 1 without a player
  login; threads only if a real library proves too slow); stops before the daily quota is spent.
- Credentials: dev id from `/usr/share/retroforge/scraper/devid` (build input, image build step),
  player login in `~/.config/retroforge/scraper.conf` (0600, written by the plugin through
  `retroforge-scrape login`; password read from stdin, never on argv).
- Test `tests/test-scrape.sh` (curl stub, fake XML answers, no network): hash rules, systemeid
  retry order, region/media fallback, `--missing` skips, every exit code, stdout contract, atomic
  write, https-only, conf mode 0600, no devid in the repo (guard).
- Optional live check behind `RETROFORGE_NET_TEST=1` once the dev id exists.

## Phase 2 — plugin art provider (Low-Medium)

- `plugin/boxart_retroforge.gd` extends `BoxArtProvider` (`provider_id "retroforge"`), added with
  `add_boxart()` right after the library (the first cards already ask); finds the ROM through the
  item's launch item `metadata.rom` (NOT `item.name`: names carry "(System)" / numbering from
  `rom_names.gd`).
  GRID_PORTRAIT <- box (every library card), GRID_LANDSCAPE (home banner) and BANNER (launch
  menu backdrop) <- fanart else screen (fan art is 16:9), LOGO <- wheel; null when missing (OGUI's
  `local` provider registers first and still wins; then its placeholder).
- `plugin/art_paths.gd` (no OGUI types, tested on stock Godot in `tests/test-plugin.sh`): the path
  per layout, and the image decoded by its magic bytes (Godot's loader goes by extension; a PNG
  named .jpg loaded nothing -- seen with art from before the scraper's magic-bytes fix).
- No texture cache (a card holds its texture; a cache would pin a whole library's textures).
- Plugin 0.1.44.

## Phase 3 — Scraper page + per-game action (Medium)

- Settings > Scraper: account (OSK), region (auto/eu/us/jp/wor), "Scrape missing" / "Rescan all"
  (all systems or one), progress, quota left, error text per exit code.
- Game settings > RetroForge: "Scrape this game".
- Never while a game runs (same rule as `rom_watch.gd`); art shows after a library refresh.
- Image build: devid file from the CI secret; without it the scraper is off and the page says so.

## Later (not in this plan)

Text metadata in the launch menu and scraped titles as card names; auto-scrape new ROMs; disc
serial lookup for big PSX/PS2 images; libretro-thumbnails as a credential-free fallback.

## Risks

- MEDIUM: dev id quota / thread limits unknown until `ssuserInfos.php` is asked with it -> first
  live check in Phase 1 reads them.
- MEDIUM: VRAM / load time on 2,000+ cards (Phase 4c, ogui-vram-tiers) -> 640 px art; measure on
  the ACE with a large library before shipping.
- MEDIUM: renamed CHD/ISO over 128 MiB may not match -> serial lookup later.
- MEDIUM: decode is synchronous on the main thread, per card (OGUI awaits get_boxart while it
  builds cards) -> measure library build time on the ACE with a few hundred scraped ROMs.
- LOW: a wide box (SNES, MD) is letterboxed in a portrait card (OGUI's card keeps the aspect);
  box-3D or a mix image could fill it better -- a look decision for HW.
