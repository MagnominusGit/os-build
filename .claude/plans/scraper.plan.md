# ROM artwork scraper — plan

Status: decisions D1-D3 AGREED 2026-10-17; the user already has a ScreenScraper dev account.
Phase 1 DONE 2026-10-17 on branch feat/scraper: `retroforge-scrape` + systems.json +
tests/test-scrape.sh (98 ok, in `make test`; python-reviewer findings fixed: one bad ROM is
"failed" not fatal, stale quota, redirect host check, no answer bodies on disk, cancel); live run on 4 ROMs (2 CHDs > 128 MiB by name + size,
a single-file zip, a Mega Drive .bin): 4/4 found, 15 images, 8 s, second run 0 requests.
`status` subcommand dropped (YAGNI: the plugin reads the media files). Next: Phase 2 (plugin art
provider); the image-build devid step moves to Phase 3.

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
  `add_boxart()`; finds the ROM through the item's launch item `metadata.rom` (NOT `item.name`:
  names carry "(System)" / numbering from `rom_names.gd`).
  GRID_PORTRAIT <- box, GRID_LANDSCAPE <- screen, BANNER <- fanart else screen, LOGO <- wheel;
  null when missing (OGUI then tries `local`, then its placeholder).
- Pure path mapping in its own file, tested headless in `tests/test-plugin.sh`.
- Plugin version bump.

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
- LOW: OGUI fetches art per card on every view -> provider caches textures per path + mtime.
