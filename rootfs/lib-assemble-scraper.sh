#!/usr/bin/env bash
# retroforge read-only root assembler — stages `scraper-login`.
#
# SOURCED by rootfs/assemble-rootfs.sh, never executed.
#
# Runs on EVERY build, release included.
#
# Reads the assembler's globals rather than taking arguments -- $stage (the staged tree) -- and the
# environment make forwards: RETROFORGE_SS_DEVID + RETROFORGE_SS_DEVPASSWORD (dev.env.local on a
# host, repository secrets of the same names in CI; never in the repo).

# STAGE scraper-login — RetroForge's ScreenScraper developer login, which every request of
# /usr/bin/retroforge-scrape carries (plan scraper D1). The scraper runs as the player, so the file
# is world-readable: anyone holding the card can read it, as on every ES-based firmware. Without
# both values the image has no scraper (retroforge-scrape exits 9, the plugin's page says so) and
# the build says it loudly rather than failing: a fork without RetroForge's login still builds.
scraper_devid="/usr/share/retroforge/scraper/devid"
if [ -n "${RETROFORGE_SS_DEVID:-}" ] && [ -n "${RETROFORGE_SS_DEVPASSWORD:-}" ]; then
  case "$RETROFORGE_SS_DEVID$RETROFORGE_SS_DEVPASSWORD" in
    *$'\n'*|*$'\r'*) echo "RETROFORGE_SS_DEVID / RETROFORGE_SS_DEVPASSWORD hold a line break" >&2; exit 1 ;;
  esac
  echo "  injecting the ScreenScraper developer login -> $scraper_devid"
  install -d -m 0755 "$stage${scraper_devid%/*}"
  ( umask 022; printf 'devid=%s\ndevpassword=%s\n' "$RETROFORGE_SS_DEVID" "$RETROFORGE_SS_DEVPASSWORD" >"$stage$scraper_devid" )
else
  echo "  [WARN] no ScreenScraper developer login (RETROFORGE_SS_DEVID + RETROFORGE_SS_DEVPASSWORD):"
  echo "  [WARN] this image cannot scrape ROM art."
  rm -f "$stage$scraper_devid"
fi
unset scraper_devid
