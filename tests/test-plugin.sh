#!/usr/bin/env bash
# Offline test for the RetroForge OpenGamepadUI plugin's packaging (plan Phase 4).
#
#   tests/test-plugin.sh
#
# WHY THIS EXISTS. OGUI loads a plugin with no feedback when it is subtly wrong, and none of it
# shows until a card fails to appear on a device:
#
#   - a zip without plugins/<id>/plugin.json, or a plugin.json missing one of the fields
#     PluginLoader requires, is skipped with a warning nobody sees;
#   - a min-api-version OGUI's API (2.0.0 in v0.46.1) is not feature-compatible with: skipped;
#   - an entrypoint that is not in the zip: "Unable to load plugin";
#   - a script that overrides _init() replaces its base class's constructor: Library._init is what
#     registers a library on ready, so the ROM library silently never loaded (HW, 2026-10-04).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/apps/ogui-retroforge-plugin/plugin"
BUILD="$ROOT/apps/ogui-retroforge-plugin/build.sh"
OGUI_API="2.0.0"   # PluginLoader.PLUGIN_API_VERSION in the pinned OGUI (packages/opengamepadui)

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

[ -f "$SRC/plugin.json" ] && [ -x "$BUILD" ] || { echo "missing plugin sources or build.sh" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }
T="$(mktemp -d)" && [ -d "$T" ] || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT

# =================================================================================================
CASE="plugin.json"
meta() { python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); print(m.get(sys.argv[2], ""))' "$SRC/plugin.json" "$1"; }
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$SRC/plugin.json" 2>/dev/null \
  && ok "is valid JSON" || bad "does not parse"
for field in plugin.id plugin.name plugin.version plugin.min-api-version entrypoint; do
  [ -n "$(meta "$field")" ] && ok "has $field (PluginLoader requires it)" || bad "lacks $field: OGUI skips the plugin"
done
[ "$(meta plugin.id)" = retroforge ] && ok "id is retroforge (the zip must be retroforge.zip)" || bad "id is '$(meta plugin.id)'"
[[ $(meta plugin.version) =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && ok "version is semver (upgrades compare it)" || bad "version '$(meta plugin.version)' is not x.y.z"
# SemanticVersion.is_feature_compatible: same major, and min-api minor/patch not above OGUI's.
api="$(meta plugin.min-api-version)"
python3 - "$api" "$OGUI_API" <<'PY' && ok "min-api-version $api works with OGUI's API $OGUI_API" || bad "min-api-version $api is not compatible with OGUI's API $OGUI_API"
import sys
want, have = ([int(x) for x in v.split(".")] for v in sys.argv[1:3])
sys.exit(0 if want[0] == have[0] and want[1:] <= have[1:] else 1)
PY
[ -f "$SRC/$(meta entrypoint)" ] && ok "entrypoint $(meta entrypoint) exists" || bad "entrypoint $(meta entrypoint) is not in plugin/"

# =================================================================================================
CASE="scripts"
for gd in "$SRC"/*.gd; do
  name="$(basename "$gd")"
  head -1 "$gd" | grep -Eq '^extends ' && ok "$name starts with extends" || bad "$name has no extends line"
  grep -Eq '^func _init\(' "$gd" \
    && bad "$name overrides _init(): it replaces the base constructor (Library._init registers the library)" \
    || ok "$name does not override _init()"
done
grep -q '^extends Plugin$' "$SRC/$(meta entrypoint)" && ok "the entrypoint extends Plugin" || bad "the entrypoint does not extend Plugin"
# OGUI is a release export: a component's method called before it is in the tree (its @onready
# children still null) segfaults OGUI instead of erroring. scraper_settings.gd filled its dropdown
# before add_child and OGUI crashed at every start (ACE, 2026-10-17).
python3 - "$SRC/scraper_settings.gd" <<'PY2' && ok "scraper_settings.gd fills its dropdown only once it is in the tree" || bad "scraper_settings.gd calls the dropdown before add_child: OGUI segfaults"
import sys
s = open(sys.argv[1]).read()
add, fill = s.find("box.add_child(node)"), s.find("_region.clear()")
sys.exit(0 if 0 <= add < fill and s.find("_region.add_item") > add else 1)
PY2
# The same crash rule for the Updates section: the channel dropdown is filled after add_child.
python3 - "$SRC/retroforge_os.gd" <<'PY2' && ok "retroforge_os.gd fills its dropdown only once it is in the tree" || bad "retroforge_os.gd calls the dropdown before add_child: OGUI segfaults"
import sys
s = open(sys.argv[1]).read()
add, fill = s.find("box.add_child(node)"), s.find("_fill_channels()\n\t_channel.item_selected")
sys.exit(0 if 0 <= add < fill and s.find("_channel.clear()") > 0 and s.find("_channel.add_item") > 0 else 1)
PY2
# OGUI never calls ready() on our OS platform (it knows no `retroforge` OS): plugin.gd must, and
# only where OGUI detected none.
grep -q 'if platform.os or not platform.os_info or platform.os_info.id != "retroforge":' "$SRC/plugin.gd" \
  && grep -q '_os.ready(get_tree().root)' "$SRC/plugin.gd" \
  && ok "plugin.gd installs the RetroForge OS platform only over none, and calls its ready()" \
  || bad "plugin.gd does not install retroforge_os.gd as platform.os (or would replace OGUI's)"
grep -q '^extends OSPlatform$' "$SRC/retroforge_os.gd" && ok "retroforge_os.gd extends OSPlatform" || bad "retroforge_os.gd does not extend OSPlatform"

# BoxArtManager refuses a provider whose provider_id is empty when it becomes ready.
grep -q 'add_boxart(.*boxart_retroforge.gd' "$SRC/plugin.gd" && grep -q '^	provider_id = "retroforge"$' "$SRC/boxart_retroforge.gd" \
  && ok "the art provider is added, with an id (BoxArtManager refuses an empty one)" || bad "boxart_retroforge.gd is not added by plugin.gd, or has no provider_id"

# =================================================================================================
CASE="zip"
"$BUILD" "$T" >/dev/null && [ -f "$T/retroforge.zip" ] && ok "build.sh writes retroforge.zip" || bad "build.sh failed"
sum1="$(sha256sum "$T/retroforge.zip" | cut -d' ' -f1)"
mapfile -t files < <(python3 -c 'import sys,zipfile; print("\n".join(zipfile.ZipFile(sys.argv[1]).namelist()))' "$T/retroforge.zip")
want=(); for f in "$SRC"/*; do want+=("plugins/retroforge/$(basename "$f")"); done
[ "$(printf '%s\n' "${files[@]}" | sort)" = "$(printf '%s\n' "${want[@]}" | sort)" ] \
  && ok "holds exactly plugin/* under plugins/retroforge/ (where PluginLoader looks)" \
  || bad "zip contents: ${files[*]}"
"$BUILD" "$T" >/dev/null
[ "$(sha256sum "$T/retroforge.zip" | cut -d' ' -f1)" = "$sum1" ] \
  && ok "rebuilding gives the same bytes (store sha256 stays valid)" || bad "the zip changes between builds"

# =================================================================================================
# OGUI keys its library by item name across every provider: two ROMs with the same name became one
# card and the second ROM was lost; a rescan never dropped a deleted ROM. rom_names.gd has no OGUI
# types, so a stock Godot runs it (RETROFORGE_GODOT=<godot 4 binary>, or godot on PATH; skipped without).
CASE="rom helpers"
GODOT="${RETROFORGE_GODOT:-$(command -v godot || true)}"
if [ -z "$GODOT" ]; then
  printf '  skip %s -- no Godot (set RETROFORGE_GODOT to a Godot 4 binary)\n' "$CASE"
else
  cat >"$T/names_test.gd" <<GD
extends SceneTree

const RomNames := preload("$SRC/rom_names.gd")
const LaunchArgs := preload("$SRC/launch_args.gd")
const RomWatch := preload("$SRC/rom_watch.gd")
const Credits := preload("$SRC/credits.gd")
const GameDirs := preload("$SRC/game_dirs.gd")
const EmuOptions := preload("$SRC/emu_options.gd")
const EmuState := preload("$SRC/emu_state.gd")
const ArtPaths := preload("$SRC/art_paths.gd")
const UpdateStates := preload("$SRC/update_states.gd")
const SYSTEMS := {"psx": "PlayStation", "ps2": "PlayStation 2"}
var failed := 0

func check(what: String, got, want) -> void:
	if got == want:
		print("  ok   $CASE -- ", what)
	else:
		failed += 1
		print("  FAIL $CASE -- ", what, ": got ", got, ", want ", want)

func names(roms: Array) -> PackedStringArray:
	var list := []
	for r in roms:
		list.append({"system": r[0], "path": "/home/player/roms/%s/%s" % r})
	return RomNames.names_for(list, SYSTEMS)

func _init() -> void:
	check("a unique ROM keeps its file name",
		names([["psx", "Crash Bandicoot.chd"], ["ps2", "Jak.iso"]]),
		PackedStringArray(["Crash Bandicoot", "Jak"]))
	check("the same name on two systems gets the system",
		names([["psx", "Tetris.chd"], ["ps2", "Tetris.iso"]]),
		PackedStringArray(["Tetris (PlayStation)", "Tetris (PlayStation 2)"]))
	check("the same name in one system gets the extension",
		names([["psx", "Tetris.cue"], ["psx", "Tetris.chd"]]),
		PackedStringArray(["Tetris (CUE)", "Tetris (CHD)"]))
	check("names differing only in case collide (OGUI settings are lower-cased)",
		names([["psx", "tetris.chd"], ["ps2", "TETRIS.iso"]]),
		PackedStringArray(["tetris (PlayStation)", "TETRIS (PlayStation 2)"]))
	check("both rules together stay unique",
		names([["psx", "T.cue"], ["psx", "T.chd"], ["ps2", "T.iso"]]),
		PackedStringArray(["T (PlayStation) (CUE)", "T (PlayStation) (CHD)", "T (PlayStation 2)"]))
	check("names still equal after both rules are numbered",
		names([["psx", "A.chd"], ["psx", "a.chd"], ["psx", "B (CUE).chd"], ["psx", "B.cue"], ["psx", "B.chd"]]),
		PackedStringArray(["A (CHD)", "a (CHD) (2)", "B (CUE)", "B (CUE) (2)", "B (CHD)"]))
	check("a ROM still there is kept",
		RomNames.stale({"A": "/r/A.chd"}, {"A": "/r/A.chd", "B": "/r/B.chd"}), PackedStringArray())
	check("a deleted ROM is dropped",
		RomNames.stale({"A": "/r/A.chd", "B": "/r/B.chd"}, {"A": "/r/A.chd"}), PackedStringArray(["B"]))
	check("a name now meaning another file is dropped (re-added with the new ROM)",
		RomNames.stale({"A": "/r/A.cue"}, {"A": "/r/A.chd"}), PackedStringArray(["A"]))
	# Every choice is in the player confs (retroforge-launch reads them): a card is just system + ROM.
	var rom := "/home/player/roms/psx/Crash Team Racing (USA).chd"
	check("launch args: system and ROM, nothing else (choices live in the confs)",
		LaunchArgs.for_rom("psx", rom), PackedStringArray(["psx", rom]))
	check("options are saved per system + file, not per card name",
		LaunchArgs.rom_id("psx", rom), "psx/Crash Team Racing (USA).chd")
	var launch_conf := "# system=emulator\npsx=duckstation\nps2=armsx2\npsx=other  \npsxx=nope\n"
	check("launch.conf: last system=emulator line wins, like retroforge-launch",
		LaunchArgs.emulator_for("psx", launch_conf), "other")
	check("launch.conf: an unmapped system has no emulator",
		LaunchArgs.emulator_for("gc", launch_conf), "")
	check("player conf: CPUS read like retroforge-launch (last line)",
		LaunchArgs.conf_cpus("CPUS=all\n# x\nCPUS=big\n"), "big")
	check("player conf: an unknown CPUS value reads as unset",
		LaunchArgs.conf_cpus("CPUS=fast\n"), "")
	check("player conf: CPUS rewritten once, other lines kept",
		LaunchArgs.conf_with("# mine\nCPUS=all\nFOO=1\nCPUS=all\n", "CPUS", "big"), "# mine\nFOO=1\nCPUS=big\n")
	check("player conf: an empty value removes the key",
		LaunchArgs.conf_with("CPUS=all\naspect=4:3\n", "CPUS", ""), "aspect=4:3\n")
	check("player conf: removing the last key leaves nothing",
		LaunchArgs.conf_with("CPUS=all\n", "CPUS", ""), "")
	check("player conf: any key read like retroforge-launch (last line, prefix-safe)",
		LaunchArgs.conf_value("aspect_x=1\naspect=4:3\naspect=16:9\n", "aspect"), "16:9")
	check("player conf: written under XDG_CONFIG_HOME, where retroforge-launch looks",
		LaunchArgs.player_conf_path("duckstation"), OS.get_environment("XDG_CONFIG_HOME") + "/retroforge/emulators/duckstation.conf")
	check("emulator default: off before anything is saved", LaunchArgs.emulator_fast_cores("duckstation"), false)
	check("emulator default: saving On succeeds", LaunchArgs.set_emulator_fast_cores("duckstation", true), true)
	check("emulator default: reads back On", LaunchArgs.emulator_fast_cores("duckstation"), true)
	check("emulator default: the file holds CPUS=big",
		FileAccess.get_file_as_string(LaunchArgs.player_conf_path("duckstation")), "CPUS=big\n")
	LaunchArgs.set_emulator_fast_cores("duckstation", false)
	check("emulator default: Off reads back off", LaunchArgs.emulator_fast_cores("duckstation"), false)
	# Game settings > RetroForge: the game's own conf, named after the ROM file like retroforge-launch's.
	check("game conf: under XDG_CONFIG_HOME/retroforge/games/<system>/<rom file>.conf",
		LaunchArgs.game_conf_path("psx", rom), OS.get_environment("XDG_CONFIG_HOME") + "/retroforge/games/psx/Crash Team Racing (USA).chd.conf")
	check("game conf: a folder ROM (PS3 dump) is named after the folder",
		LaunchArgs.game_conf_path("ps3", "/home/player/roms/ps3/GAME/"), OS.get_environment("XDG_CONFIG_HOME") + "/retroforge/games/ps3/GAME.conf")
	check("game fast cores: the emulator default before anything is saved", LaunchArgs.game_cpus("psx", rom), "")
	check("game fast cores: choosing the default writes no file",
		LaunchArgs.set_game_cpus("psx", rom, "") and not FileAccess.file_exists(LaunchArgs.game_conf_path("psx", rom)), true)
	check("game fast cores: saving On succeeds", LaunchArgs.set_game_cpus("psx", rom, "big"), true)
	check("game fast cores: reads back On", LaunchArgs.game_cpus("psx", rom), "big")
	check("game fast cores: the file holds CPUS=big", FileAccess.get_file_as_string(LaunchArgs.game_conf_path("psx", rom)), "CPUS=big\n")
	LaunchArgs.set_game_cpus("psx", rom, "")
	check("game fast cores: back to the emulator default", LaunchArgs.game_cpus("psx", rom), "")
	check("game fast cores: an unknown value saves the default", LaunchArgs.set_game_cpus("psx", rom, "fast") and LaunchArgs.game_cpus("psx", rom) == "", true)
	test_rom_watch()
	test_game_dirs()
	test_credits()
	test_emu_options()
	test_emu_state()
	test_art_paths()
	test_update_states()
	quit(1 if failed else 0)

# Settings > General > Updates (retroforge_os.gd): retroforge-update's answers -> what is shown.
func test_update_states() -> void:
	check("channels: stable and beta, not pinned",
		UpdateStates.parse_channels("stable\nbeta\n"), {"channels": ["stable", "beta"], "pinned": ""})
	check("channels: a dev card's pin is listed and named",
		UpdateStates.parse_channels("stable\nbeta\ndev\npinned\t/etc/retroforge/ota.conf\n"),
		{"channels": ["stable", "beta", "dev"], "pinned": "/etc/retroforge/ota.conf"})
	check("channel: the name before the tab", UpdateStates.parse_channel("beta\t/home/player/.config/retroforge/ota.conf\n"), "beta")
	check("channel: nothing read is empty", UpdateStates.parse_channel(""), "")
	check("channel names: Stable, Beta, others as they are",
		[UpdateStates.channel_name("stable"), UpdateStates.channel_name("beta"), UpdateStates.channel_name("dev")], ["Stable", "Beta", "dev"])
	var S := UpdateStates.Step
	check("button: one button walks Check -> Install -> Restart now",
		[UpdateStates.button_for(S.IDLE, "0.0.3")["button"], UpdateStates.button_for(S.AVAILABLE, "0.0.3", "0.0.4")["button"],
		 UpdateStates.button_for(S.STAGED, "0.0.3", "0.0.4")["button"]],
		["Check for updates", "Install", "Restart now"])
	check("button: pressable only when it does something",
		[UpdateStates.button_for(S.IDLE, "1")["disabled"], UpdateStates.button_for(S.CHECKING, "1")["disabled"],
		 UpdateStates.button_for(S.AVAILABLE, "1", "2")["disabled"], UpdateStates.button_for(S.INSTALLING, "1", "2")["disabled"],
		 UpdateStates.button_for(S.STAGED, "1", "2")["disabled"]],
		[false, true, false, true, false])
	check("button: the install's progress is in its description",
		"42%" in UpdateStates.button_for(S.INSTALLING, "0.0.3", "0.0.4", 42)["description"], true)
	check("button: both versions when one is available",
		UpdateStates.button_for(S.AVAILABLE, "0.0.4-beta.1", "0.0.3")["description"], "RetroForge 0.0.3 is available (you have 0.0.4-beta.1).")
	check("background check: only when idle and no game runs",
		[UpdateStates.background_check_wanted(S.IDLE, false), UpdateStates.background_check_wanted(S.IDLE, true),
		 UpdateStates.background_check_wanted(S.CHECKING, false), UpdateStates.background_check_wanted(S.AVAILABLE, false),
		 UpdateStates.background_check_wanted(S.INSTALLING, false), UpdateStates.background_check_wanted(S.STAGED, false)],
		[true, false, false, false, false, false])
	check("background check: the notification names the version and where to install it",
		UpdateStates.available_text("0.0.4"), "RetroForge 0.0.4 is available: Settings > General > Updates")
	check("channel description: says what pins it",
		UpdateStates.channel_description("/etc/retroforge/ota.conf"), "Set by /etc/retroforge/ota.conf on this device.")

## OGUI's card is 2:3 and draws its texture whole, top-left: a SNES box (wider than tall) left two
## thirds of the card empty (ACE, 2026-10-17). A card image is the box scaled to cover the card,
## its centre cut out (user decision 2026-10-17, over a fitted box on a blurred backdrop); cached
## as a small JPEG until the box changes.
func test_card_images(media: String) -> void:
	# A wide box in thirds, red | blue | green: the card keeps the middle, cut at both sides.
	var wide := Image.create(640, 468, false, Image.FORMAT_RGBA8)
	wide.fill_rect(Rect2i(0, 0, 214, 468), Color(1, 0, 0))
	wide.fill_rect(Rect2i(214, 0, 213, 468), Color(0, 0, 1))
	wide.fill_rect(Rect2i(427, 0, 213, 468), Color(0, 1, 0))
	var card := ArtPaths.card_image(wide)
	check("card: a wide box becomes a 300x450 card", card.get_size(), Vector2i(300, 450))
	var mid := card.get_pixel(150, 225)
	var left := card.get_pixel(1, 225)
	var right := card.get_pixel(298, 225)
	check("card: the box's centre, full height, cut at both sides",
		[mid.b > 0.9, left.r > 0.9, right.g > 0.9, card.get_pixel(150, 1).b > 0.9, card.get_pixel(150, 448).b > 0.9],
		[true, true, true, true, true])
	# A tall box: top and bottom bands, cut; the middle row fills the card's width.
	var tall := Image.create(200, 600, false, Image.FORMAT_RGB8)
	tall.fill(Color(0, 1, 0))
	tall.fill_rect(Rect2i(0, 200, 200, 200), Color(0, 0, 1))
	var card2 := ArtPaths.card_image(tall)
	check("card: a tall box fills the width, its middle kept",
		[card2.get_size(), card2.get_pixel(1, 225).b > 0.9, card2.get_pixel(298, 225).b > 0.9, card2.get_pixel(150, 1).g > 0.9],
		[Vector2i(300, 450), true, true, true])
	var exact := Image.create(600, 900, false, Image.FORMAT_RGB8)
	exact.fill(Color(1, 1, 0))
	check("card: a 2:3 box is only scaled", ArtPaths.card_image(exact).get_pixel(0, 0).is_equal_approx(Color(1, 1, 0)), true)
	var box_path := media + "/snes/Wide.zip-box.png"
	DirAccess.make_dir_recursive_absolute(box_path.get_base_dir())
	wide.save_png(box_path)
	var cache := ArtPaths.card_cache_path("$T/art/cards", "snes", "/r/snes/Wide.zip")
	check("card cache: under <cards>/<system>/<rom>.jpg", cache, "$T/art/cards/snes/Wide.zip.jpg")
	check("card cache: nothing cached yet", ArtPaths.cached_card(cache, box_path), null)
	var made: Image = ArtPaths.make_card(box_path, cache)
	check("card cache: made and saved", [made.get_size() if made else null, FileAccess.file_exists(cache)], [Vector2i(300, 450), true])
	var again: Image = ArtPaths.cached_card(cache, box_path)
	check("card cache: read back (a JPEG, by its bytes)", again.get_size() if again else null, Vector2i(300, 450))
	var webp := Image.create(5, 4, false, Image.FORMAT_RGBA8)
	webp.save_webp(media + "/psx/Webp-named.png")
	var w: Image = ArtPaths.load_image(media + "/psx/Webp-named.png")
	check("art: a WebP loads too, by its bytes", w.get_size() if w else null, Vector2i(5, 4))
	OS.delay_msec(1100)  # file times are in seconds
	wide.save_png(box_path)
	check("card cache: a newer box makes it stale", ArtPaths.cached_card(cache, box_path), null)
	check("card cache: no box -> no card", ArtPaths.make_card(media + "/snes/None.zip-box.png", cache + ".x"), null)


## PortMaster ports are never scraped: each port PortMaster installs carries a gameinfo.xml (ES
## gameList) whose <path> is the launch script and <image> its screenshot, both relative to
## ~/roms/ports (seen for Apotris and 8-Bit Buccaneer, 2026-10-17). Every layout but the logo uses it.
func test_port_art(media: String) -> void:
	var ports := "$T/art/roms/ports"
	write(ports + "/8bitbuccaneer/gameinfo.xml", '<?xml version="1.0" encoding="utf-8"?>\n<gameList>\n  <game>\n    <path>./8-BIT BUCCANEER.sh</path>\n    <name>8-BIT BUCCANEER</name>\n    <image>./8bitbuccaneer/screenshot.png</image>\n  </game>\n</gameList>\n')
	write(ports + "/8bitbuccaneer/screenshot.png", "png")
	write(ports + "/apotris/gameinfo.xml", "<?xml version='1.0' encoding='utf-8'?>\n<gameList><game><path>./Apotris.sh</path><name>Apotris</name><image>./apotris/screenshot.png</image></game></gameList>")
	write(ports + "/apotris/screenshot.png", "png")
	write(ports + "/evil/gameinfo.xml", "<gameList><game><path>./Evil.sh</path><image>../../../etc/passwd</image></game></gameList>")
	write(ports + "/gone/gameinfo.xml", "<gameList><game><path>./Gone.sh</path><image>./gone/screenshot.png</image></game></gameList>")
	write(ports + "/broken/gameinfo.xml", "<gameList><game><path>./Broken.sh</pa")
	check("ports: a card is the port's screenshot",
		ArtPaths.path_for(media, "ports", ports + "/8-BIT BUCCANEER.sh", 0, ports), ports + "/8bitbuccaneer/screenshot.png")
	check("ports: the wide layouts too, no logo",
		[ArtPaths.path_for(media, "ports", ports + "/Apotris.sh", 1, ports), ArtPaths.path_for(media, "ports", ports + "/Apotris.sh", 2, ports), ArtPaths.path_for(media, "ports", ports + "/Apotris.sh", 3, ports)],
		[ports + "/apotris/screenshot.png", ports + "/apotris/screenshot.png", ""])
	check("ports: an image outside ~/roms/ports, a missing image, a broken file, an unknown port -> none",
		[ArtPaths.path_for(media, "ports", ports + "/Evil.sh", 0, ports), ArtPaths.path_for(media, "ports", ports + "/Gone.sh", 0, ports),
		 ArtPaths.path_for(media, "ports", ports + "/Broken.sh", 0, ports), ArtPaths.path_for(media, "ports", ports + "/Other.sh", 0, ports)],
		["", "", "", ""])
	check("ports: the default ports folder is ~/roms/ports", ArtPaths.ports_dir(), OS.get_environment("HOME").path_join("roms/ports"))


## Art retroforge-scrape fetched, per OGUI layout (0 portrait, 1 landscape, 2 banner, 3 logo).
## Keyed by the ROM's file (or folder) name, so Game.cue and Game.chd never share art.
func test_art_paths() -> void:
	var media := "$T/art/media"
	write(media + "/psx/Game.chd-box.png", "png")
	write(media + "/psx/Game.chd-screen.png", "png")
	write(media + "/psx/Game.chd-wheel.jpg", "jpg")
	write(media + "/psx/Other.cue-fanart.jpg", "jpg")
	write(media + "/psx/Other.cue-screen.png", "png")
	write(media + "/ps3/Flower-box.png", "png")
	var rom := "/home/player/roms/psx/Game.chd"
	check("art: a card is the box", ArtPaths.path_for(media, "psx", rom, 0), media + "/psx/Game.chd-box.png")
	check("art: wide layouts fall back to the screenshot without fan art",
		[ArtPaths.path_for(media, "psx", rom, 1), ArtPaths.path_for(media, "psx", rom, 2)],
		[media + "/psx/Game.chd-screen.png", media + "/psx/Game.chd-screen.png"])
	check("art: wide layouts prefer fan art", ArtPaths.path_for(media, "psx", "/r/psx/Other.cue", 2), media + "/psx/Other.cue-fanart.jpg")
	check("art: the logo is the wheel, as .jpg too", ArtPaths.path_for(media, "psx", rom, 3), media + "/psx/Game.chd-wheel.jpg")
	check("art: none scraped -> no path (OGUI shows its placeholder)", ArtPaths.path_for(media, "psx", "/r/psx/Other.cue", 0), "")
	check("art: same name, other extension: not shared", ArtPaths.path_for(media, "psx", "/r/psx/Game.cue", 0), "")
	check("art: same file, other system: not shared", ArtPaths.path_for(media, "ps2", rom, 0), "")
	check("art: a game folder by its name (trailing slash too)",
		[ArtPaths.path_for(media, "ps3", "/r/ps3/Flower", 0), ArtPaths.path_for(media, "ps3", "/r/ps3/Flower/", 0)],
		[media + "/ps3/Flower-box.png", media + "/ps3/Flower-box.png"])
	# Loaded by the file's bytes, not its name (a PNG saved as .jpg loaded nothing in Godot).
	var img := Image.create(4, 3, false, Image.FORMAT_RGBA8)
	img.save_png(media + "/psx/Png-named.jpg")
	img.save_jpg(media + "/psx/Jpg-named.png")
	var a: Image = ArtPaths.load_image(media + "/psx/Png-named.jpg")
	var b: Image = ArtPaths.load_image(media + "/psx/Jpg-named.png")
	check("art: a PNG named .jpg and a JPEG named .png both load", [a.get_size() if a else null, b.get_size() if b else null], [Vector2i(4, 3), Vector2i(4, 3)])
	check("art: not an image, or no file -> null",
		[ArtPaths.load_image(media + "/psx/Game.chd-box.png"), ArtPaths.load_image(media + "/nothing.png")], [null, null])
	test_card_images(media)
	test_port_art(media)
	check("art: no system or ROM, or an unknown layout -> no path",
		[ArtPaths.path_for(media, "", rom, 0), ArtPaths.path_for(media, "psx", "", 0), ArtPaths.path_for(media, "psx", rom, 9)],
		["", "", ""])

## Games that are folders: a PS3 disc dump is PS3_GAME/USRDIR/EBOOT.BIN in a folder RPCS3 boots.
func test_game_dirs() -> void:
	var ps3 := "$T/dirs/roms/ps3"
	var markers := ["PS3_GAME/USRDIR/EBOOT.BIN", "USRDIR/EBOOT.BIN"]
	write(ps3 + "/Demon's Souls [BLUS30443]/PS3_GAME/USRDIR/EBOOT.BIN", "elf")
	write(ps3 + "/Flower/USRDIR/EBOOT.BIN", "elf")
	write(ps3 + "/Half copied/PS3_GAME/PARAM.SFO", "sfo")
	write(ps3 + "/.hidden/PS3_GAME/USRDIR/EBOOT.BIN", "elf")
	check("game folders: a disc dump and a bare PS3_GAME count; a folder with no EBOOT.BIN and a hidden one do not",
		GameDirs.scan(ps3, markers), PackedStringArray([ps3 + "/Demon's Souls [BLUS30443]", ps3 + "/Flower"]))
	check("game folders: a system without markers lists none", GameDirs.scan(ps3, []), PackedStringArray())
	check("game folders: a folder keeps its whole name (no extension cut at a dot)",
		RomNames.names_for([{"system": "ps3", "path": ps3 + "/Uncharted 2. Among Thieves", "dir": true}], {"ps3": "PlayStation 3"}),
		PackedStringArray(["Uncharted 2. Among Thieves"]))
	check("game folders: a folder and an .iso of one game are told apart",
		RomNames.names_for([{"system": "ps3", "path": ps3 + "/Flower", "dir": true}, {"system": "ps3", "path": ps3 + "/Flower.iso"}],
			{"ps3": "PlayStation 3"}),
		PackedStringArray(["Flower (FOLDER)", "Flower (ISO)"]))
	var watch = RomWatch.new().setup("$T/dirs/roms", ["ps3"], {"ps3": markers})
	watch.mark_loaded()
	write(ps3 + "/Half copied/PS3_GAME/USRDIR/EBOOT.BIN", "e")
	check("rescan: a game folder is due once its EBOOT.BIN arrived and settled",
		[watch.poll(false), watch.poll(false)], [false, true])
	watch.mark_loaded()
	append(ps3 + "/Half copied/PS3_GAME/USRDIR/EBOOT.BIN", "lf")
	check("rescan: an EBOOT.BIN still growing keeps it waiting", [watch.poll(false), watch.poll(false)], [false, true])
	watch.mark_loaded()
	write(ps3 + "/Other/PS3_GAME/PARAM.SFO", "sfo")
	check("rescan: a folder without its marker is no change", [watch.poll(false), watch.poll(false)], [false, false])

## Attribution the emulators' licences ask for (DuckStation: CC BY-NC-ND, link duckstation.org).
func test_credits() -> void:
	var lic := {"name": "CC BY-NC-ND 4.0", "url": "https://x.org/LICENSE"}
	check("credits: author, homepage and licence on one short line",
		Credits.credit_text({"author": "A. Dev", "homepage": "https://www.x.org/", "licence": lic}),
		"By A. Dev · x.org · Licence CC BY-NC-ND 4.0")
	check("credits: no author still shows the homepage",
		Credits.credit_text({"homepage": "https://x.org/", "licence": lic}), "x.org · Licence CC BY-NC-ND 4.0")
	check("credits: JSON nulls (retroforge-emu list of an old catalog) are skipped",
		Credits.credit_text({"author": null, "homepage": null, "licence": null}), "")
	check("version: a pkgforge tag shows its version only",
		Credits.version_text("2609@2026-10-01_1790876487"), "2609")
	check("version: other tags are shown as they are",
		Credits.version_text("v0.1-11894"), "v0.1-11894")
	check("version: a nightly build (retroforge-emu's nightly-<id>) says Nightly",
		[Credits.version_text("nightly-cc6fea125"), Credits.version_text("nightly")], ["Nightly cc6fea125", "Nightly"])
	check("version: an RPCS3 build-<commit> keeps 8 digits",
		Credits.version_text("build-64ba740c27be6946074cd91db85be4d48146d768"), "Build 64ba740c")

## The Emulators page's rows (plan emulator-latest Phase 2): latest by default, tested kept, Revert.
func test_emu_state() -> void:
	var mb := 50 * 1048576
	var follows := {"tested": "v1", "follows_latest": true, "installed": null, "previous": null, "size": mb}
	var r := EmuState.rows("x", follows, {})
	check("state: not installed, no check yet: Download the newest, tested named",
		[r.main.text, r.main.button, r.main.args, r.main.description],
		["Not installed", "Download", ["install", "x"], "The newest version from upstream, about 50 MB. RetroForge tested v1."])
	check("state: not installed: Install tested offered right below Download, nothing else",
		[r.tested, r.extra], [{"text": "Install tested version (v1)", "button": "Install",
			"description": "The version RetroForge tested, 50 MB.", "args": ["install", "x", "--tested"]}, []])
	r = EmuState.rows("x", follows, {"latest": "v3", "error": null})
	check("state: not installed, check answered: names the newest", r.main.description,
		"Version v3, the newest from upstream, about 50 MB. RetroForge tested v1.")
	var inst := follows.merged({"installed": "v1"}, true)
	r = EmuState.rows("x", inst, {"latest": "v1", "error": null})
	check("state: the tested build installed and newest: Open, Tested, Check says up to date",
		[r.main.text, r.main.button, r.main.args, r.extra.map(func(e): return [e.args, e.description])],
		["Version v1 · Tested", "Open", [], [[["check", "x", "--refresh"], "Up to date: v1 is the newest from upstream."]]])
	r = EmuState.rows("x", inst, {})
	check("state: installed, never checked: no Update, a Check row that asks upstream on demand",
		[r.main.button, r.extra.map(func(e): return [e.button, e.description])],
		["Open", [["Check", "Asks upstream whether a newer version is out."]]])
	r = EmuState.rows("x", inst, {"latest": "v3", "error": null})
	check("state: a newer build upstream: Update to it (and no Check row)",
		[r.main.text, r.main.button, r.main.args, r.main.description],
		["Version v1 · Tested", "Update", ["install", "x"], "Update to v3 available, about 50 MB."])
	check("state: ... with no Check row beside the Update", r.extra.map(func(e): return e.button), [])
	r = EmuState.rows("x", inst, {"latest": null, "error": "GitHub answered HTTP 403"})
	check("state: a failed check (offline, rate limit): no Update, Check stays offered",
		[r.main.button, r.main.description, r.extra.map(func(e): return e.button)], ["Open", "Installed.", ["Check"]])
	var newer := follows.merged({"installed": "v3", "previous": "v1"}, true)
	r = EmuState.rows("x", newer, {"latest": "v3", "error": null})
	check("state: an untested build installed: says so, Install tested below it, Check and Revert before Delete",
		[r.main.text, r.main.description, r.tested.args, r.extra.map(func(e): return e.args)],
		["Version v3", "Installed straight from upstream. RetroForge tested v1.", ["install", "x", "--tested"],
			[["check", "x", "--refresh"], ["rollback", "x"]]])
	var cemu := {"tested": null, "follows_latest": true, "installed": "nightly-abc", "previous": "nightly-def", "size": mb}
	r = EmuState.rows("x", cemu, {"latest": "nightly-123", "error": null})
	check("state: a nightly-only entry: Update to the newer nightly (no Check beside it), Revert, never Install tested",
		[r.main.text, r.main.button, r.tested, r.extra.map(func(e): return e.text)],
		["Nightly abc", "Update", null, ["Revert to Nightly def"]])
	var pinned := {"tested": "v2", "follows_latest": false, "installed": "v1", "update": true, "previous": null, "size": mb}
	r = EmuState.rows("x", pinned, {})
	check("state: a pinned-only entry keeps the offline Update to its pin, no Install tested",
		[r.main.button, r.main.description, r.tested, r.extra], ["Update", "Update to v2 available, 50 MB.", null, []])
	var pm := {"tested": "2026.1", "follows_latest": true, "self_update": true, "installed": "2026.9", "previous": null, "size": mb}
	r = EmuState.rows("x", pm, {"latest": "2026.10", "error": null})
	check("state: PortMaster installed updates itself: Open only, no Update, no Install tested",
		[r.main.button, r.main.description, r.tested, r.extra], ["Open", "Installed. Updates itself: open it to check.", null, []])

## Per-emulator options: what the pages offer from options.json, and the choice at each level.
func test_emu_options() -> void:
	var json := JSON.stringify({"files": {"main": {"path": "x.ini", "format": "ini"}},
		"options": [{"id": "aspect", "label": "Aspect ratio", "description": "How the picture fills the screen.",
			"choices": [{"value": "4:3", "label": "4:3", "set": [{"args": ["-a"]}]},
				{"value": "16:9", "label": "16:9 (widescreen)", "set": [{"args": ["-w"]}]}]}]})
	var opts := EmuOptions.parse(json)
	check("options: parsed in order, choices without their actions",
		opts, [{"id": "aspect", "label": "Aspect ratio", "description": "How the picture fills the screen.",
			"choices": [{"value": "4:3", "label": "4:3"}, {"value": "16:9", "label": "16:9 (widescreen)"}]}])
	check("options: none without an options.json", EmuOptions.parse(""), [])
	check("options: an option missing its choices hides them all (never offer what cannot apply)",
		EmuOptions.parse('{"options": [{"id": "a", "label": "A"}]}'), [])
	check("options: not JSON", EmuOptions.parse("{"), [])
	# What the launcher refuses is never offered: a saved value would not apply (or would break the conf).
	var bad_cases := {
		"an id that is the CPUS key": {"id": "CPUS"},
		"an uppercase id": {"id": "Aspect"},
		"an id with =": {"id": "a=b"},
		"an empty value (it is the unset item)": {"choices": [{"value": "", "label": "x", "set": [{"args": ["-x"]}]}]},
		"a value with a space": {"choices": [{"value": "a b", "label": "x", "set": [{"args": ["-x"]}]}]},
		"a value with a newline": {"choices": [{"value": "a\nCPUS=big", "label": "x", "set": [{"args": ["-x"]}]}]},
		"a repeated value": {"choices": [{"value": "a", "label": "x", "set": [{"args": ["-x"]}]},
			{"value": "a", "label": "y", "set": [{"args": ["-y"]}]}]},
		"a choice with nothing to do": {"choices": [{"value": "a", "label": "x", "set": []}]},
		"a choice without set": {"choices": [{"value": "a", "label": "x"}]},
		"a two-line label": {"label": "A\nB"},
	}
	for what in bad_cases:
		var option := {"id": "aspect", "label": "A", "choices": [{"value": "a", "label": "x", "set": [{"args": ["-x"]}]}]}
		option.merge(bad_cases[what], true)
		check("options: refused with " + what, EmuOptions.parse(JSON.stringify({"options": [option]})), [])
	var one := {"id": "aspect", "label": "A", "choices": [{"value": "a", "label": "x", "set": [{"args": ["-x"]}]}]}
	check("options: refused with a repeated option id", EmuOptions.parse(JSON.stringify({"options": [one, one]})), [])
	write(OS.get_environment("XDG_CONFIG_HOME") + "/../data/fakeemu/options.json", json)
	check("options: read from <data dir>/<emulator>/options.json",
		EmuOptions.options_for("fakeemu", OS.get_environment("XDG_CONFIG_HOME") + "/../data").size(), 1)
	# Every options.json the image ships: the pages offer it in full (emuopts loads them in test-emuopts.sh).
	var data_dir := "$ROOT/rootfs/overlay/usr/share/retroforge/emulators"
	for emu in DirAccess.get_directories_at(data_dir):
		var path := data_dir.path_join(emu).path_join("options.json")
		if FileAccess.file_exists(path):
			var raw = JSON.parse_string(FileAccess.get_file_as_string(path))
			check("image %s/options.json: every option offered" % emu, EmuOptions.options_for(emu, data_dir).size(), raw["options"].size())
	check("options: an emulator without options.json has none",
		EmuOptions.options_for("nope", OS.get_environment("XDG_CONFIG_HOME") + "/../data"), [])
	var aspect: Dictionary = opts[0]
	check("emulator level: the emulator's own setting first, then the choices",
		EmuOptions.emulator_items(aspect), PackedStringArray(["Emulator's setting", "4:3", "16:9 (widescreen)"]))
	check("game level: the emulator's choice named in the default",
		EmuOptions.game_items(aspect, "16:9"), PackedStringArray(["Emulator default (16:9 (widescreen))", "4:3", "16:9 (widescreen)"]))
	check("game level: no emulator choice",
		EmuOptions.game_items(aspect, "")[0], "Emulator default (emulator's setting)")
	check("items stand for: unset, then each value", EmuOptions.values(aspect), ["", "4:3", "16:9"])
	check("a saved value selects its item", EmuOptions.index_of(aspect, "16:9"), 2)
	check("an unknown saved value selects unset", EmuOptions.index_of(aspect, "21:9"), 0)
	check("conf: the option id is the key, last line wins",
		EmuOptions.conf_choice("aspect=4:3\nCPUS=big\naspect=16:9\n", aspect), "16:9")
	check("conf: a value the option does not have reads as unset", EmuOptions.conf_choice("aspect=21:9\n", aspect), "")
	var rom := "/home/player/roms/psx/Crash Team Racing (USA).chd"
	check("emulator choice: unset at first", EmuOptions.emulator_choice("duckstation", aspect), "")
	EmuOptions.set_emulator_choice("duckstation", aspect, "4:3")
	LaunchArgs.set_emulator_fast_cores("duckstation", true)
	check("emulator choice: saved beside CPUS", FileAccess.get_file_as_string(LaunchArgs.player_conf_path("duckstation")),
		"aspect=4:3\nCPUS=big\n")
	EmuOptions.set_game_choice("psx", rom, aspect, "16:9")
	check("game choice: in the game's conf", EmuOptions.game_choice("psx", rom, aspect), "16:9")
	EmuOptions.set_game_choice("psx", rom, aspect, "")
	check("game choice: back to the emulator default, no file left", FileAccess.file_exists(LaunchArgs.game_conf_path("psx", rom)), false)
	LaunchArgs.set_game_cpus("psx", rom, "big")
	EmuOptions.set_game_choice("psx", rom, aspect, "16:9")
	EmuOptions.set_game_choice("psx", rom, aspect, "")
	check("game choice: clearing an option keeps the game's CPUS line",
		FileAccess.get_file_as_string(LaunchArgs.game_conf_path("psx", rom)), "CPUS=big\n")
	LaunchArgs.set_game_cpus("psx", rom, "")
	write(LaunchArgs.game_conf_path("psx", rom), "# mine\naspect=4:3\nother=1\naspect=21:9\n")
	EmuOptions.set_game_choice("psx", rom, aspect, "16:9")
	check("game choice: other lines kept, repeated lines collapse to one",
		FileAccess.get_file_as_string(LaunchArgs.game_conf_path("psx", rom)), "# mine\nother=1\naspect=16:9\n")
	DirAccess.remove_absolute(LaunchArgs.game_conf_path("psx", rom))
	EmuOptions.set_emulator_choice("duckstation", aspect, "")
	LaunchArgs.set_emulator_fast_cores("duckstation", false)
	check("emulator choice: back to the emulator's setting", EmuOptions.emulator_choice("duckstation", aspect), "")


func write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()

func append(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.READ_WRITE)
	f.seek_end()
	f.store_string(text)
	f.close()

## Automatic rescan: ROMs copied over SMB only showed after Refresh Library or a restart.
func test_rom_watch() -> void:
	var roms := "$T/roms"
	write(roms + "/psx/A.chd", "aaaa")
	var watch = RomWatch.new().setup(roms, ["psx", "ps2"])
	check("rescan: nothing before OGUI's first library load", [watch.poll(false), watch.poll(false)], [false, false])
	watch.mark_loaded()
	check("rescan: nothing while the folders match the library", [watch.poll(false), watch.poll(false)], [false, false])
	write(roms + "/psx/B.chd", "bb")
	check("rescan: a new ROM waits one poll (copy may still run)", watch.poll(false), false)
	check("rescan: then it is due once two polls agree", watch.poll(false), true)
	watch.mark_loaded()
	check("rescan: not again after the reload", watch.poll(false), false)
	write(roms + "/psx/C.chd", "c")
	watch.poll(false)
	append(roms + "/psx/C.chd", "cc")
	check("rescan: a file still growing keeps it waiting", watch.poll(false), false)
	check("rescan: due once the file stopped growing", watch.poll(false), true)
	watch.mark_loaded()
	OS.execute("touch", ["-d", "@1000000000", roms + "/psx/C.chd"])
	watch.poll(false)
	OS.execute("touch", ["-d", "@1000000100", roms + "/psx/C.chd"])
	check("rescan: same size but a new mtime (SMB copy into a preallocated file) keeps it waiting", watch.poll(false), false)
	check("rescan: due once the mtime settled", watch.poll(false), true)
	watch.mark_loaded()
	DirAccess.remove_absolute(roms + "/psx/A.chd")
	check("rescan: a deleted ROM is due too", [watch.poll(false), watch.poll(false)], [false, true])
	watch.mark_loaded()
	write(roms + "/ps2/J.iso", "j")
	check("rescan: a system folder created later is watched", [watch.poll(false), watch.poll(false)], [false, true])
	watch.mark_loaded()
	write(roms + "/gc/G.iso", "g")
	write(roms + "/psx/sub/D.chd", "d")
	check("rescan: other folders and subfolders are not ROMs", [watch.poll(false), watch.poll(false)], [false, false])
	write(roms + "/psx/E.chd", "e")
	check("rescan: never while a game runs", [watch.poll(false), watch.poll(true), watch.poll(true)], [false, false, false])
	check("rescan: after the game, two settled polls again", [watch.poll(false), watch.poll(false)], [false, true])
	write(roms + "/psx/F.chd", "f")
	watch.mark_loaded()
	check("rescan: a ROM copied between our scan and library_loaded is still picked up",
		[watch.poll(false), watch.poll(false)], [false, true])
GD
  out="$(XDG_CONFIG_HOME="$T/config" "$GODOT" --headless --script "$T/names_test.gd" 2>&1)"; rc=$?
  printf '%s\n' "$out" | grep -E '^  (ok|FAIL) '
  n_ok="$(printf '%s\n' "$out" | grep -c '^  ok ')"; n_bad="$(printf '%s\n' "$out" | grep -c '^  FAIL ')"
  PASS=$((PASS + n_ok)); FAIL=$((FAIL + n_bad))
  if [ "$rc" -ne 0 ] && [ "$n_bad" -eq 0 ]; then
    bad "Godot failed: $(printf '%s\n' "$out" | grep -E 'ERROR|error' | head -3)"
  fi
  # Godot exits 0 when a preloaded script does not compile: the checks using it just never run.
  if printf '%s\n' "$out" | grep -q 'SCRIPT ERROR'; then
    bad "a script did not compile: $(printf '%s\n' "$out" | grep 'SCRIPT ERROR' | head -3)"
  fi

  # scrape_runner.gd runs /usr/bin/retroforge-scrape on a worker thread; here against a fake tool
  # that behaves like it (progress lines, a JSON summary, warnings on stderr, an exit code). Its
  # signals arrive over frames, so this is a script of its own that awaits them.
  CASE="scrape runner"
  cat >"$T/fake-scrape" <<'SH'
#!/bin/bash
# $FAKE_MODE: ok | quota | login (reads the password on stdin) | slow (until SIGTERM)
printf '%s\n' "$*" > "$FAKE_ARGS"
case $FAKE_MODE in
  login) read -r pw; [ "$pw" = pw-secret ] && exit 0; echo "retroforge-scrape: ScreenScraper refused the player's login" >&2; exit 7 ;;
  slow) trap 'echo "{\"scraped\": 1, \"not_found\": 0, \"skipped\": 0, \"failed\": 0, \"quota_left\": 9}"; echo "retroforge-scrape: cancelled" >&2; exit 5' TERM
        echo "10%"; while :; do sleep 0.1; done ;;
esac
for i in $(seq 1 3000); do echo "retroforge-scrape: warning: $i: no image (200 text/html)" >&2; done
echo "50%"; echo "100%"
echo '{"scraped": 3, "not_found": 1, "skipped": 5, "failed": 1, "quota_left": 9000}'
[ "$FAKE_MODE" = quota ] && { echo "retroforge-scrape: ScreenScraper's daily request quota is used up: try again tomorrow" >&2; exit 6; }
exit 0
SH
  chmod +x "$T/fake-scrape"
  cat >"$T/runner_test.gd" <<GD
extends SceneTree

const ScrapeRunner := preload("$SRC/scrape_runner.gd")
var failed := 0

func check(what: String, got, want) -> void:
	if got == want:
		print("  ok   $CASE -- ", what)
	else:
		failed += 1
		print("  FAIL $CASE -- ", what, ": got ", got, ", want ", want)

func _initialize() -> void:
	run()

func job(mode: String, args: Array, stdin_text := "", cancel_at := -1) -> Dictionary:
	OS.set_environment("FAKE_MODE", mode)
	OS.set_environment("FAKE_ARGS", "$T/fake-args")
	var r := ScrapeRunner.new()
	r.tool = "$T/fake-scrape"
	var seen: Array[int] = []
	r.progressed.connect(func(p: int) -> void:
		seen.append(p)
		if p == cancel_at:
			r.cancel())
	check(mode + ": starts", r.start(args, stdin_text), true)
	check(mode + ": a second start while running is refused", r.start(args), false)
	var res: Array = await r.finished
	return {"code": res[0], "summary": res[1], "error": res[2], "seen": seen, "running": r.running}

func run() -> void:
	check("line: progress", ScrapeRunner.parse_line("42%"), {"percent": 42})
	check("line: the summary (JSON numbers are floats)", ScrapeRunner.parse_line('{"scraped": 1}'), {"summary": {"scraped": 1.0}})
	check("line: anything else is ignored", [ScrapeRunner.parse_line("x"), ScrapeRunner.parse_line("101%"), ScrapeRunner.parse_line("[1]")], [{}, {}, {}])
	check("summary text", ScrapeRunner.summary_text({"scraped": 3, "not_found": 1, "skipped": 5, "failed": 1}),
		"Art for 3 games. 1 not found on ScreenScraper. 1 failed: try again later.")
	check("summary text: nothing new", ScrapeRunner.summary_text({"scraped": 0, "not_found": 0, "skipped": 5, "failed": 0}), "No new art: every game is up to date.")
	check("failure: no developer login in this build", "cannot scrape" in ScrapeRunner.failure_text(9, ""), true)
	check("failure: login refused", "user name or password" in ScrapeRunner.failure_text(7, ""), true)
	check("failure: network", "network" in ScrapeRunner.failure_text(3, "retroforge-scrape: ScreenScraper unreachable (curl exit 6)"), true)
	check("failure: quota and closed say the tool's own reason, without its prefix",
		[ScrapeRunner.failure_text(6, "retroforge-scrape: warning: x\nretroforge-scrape: ScreenScraper's daily request quota is used up: try again tomorrow"),
		 ScrapeRunner.failure_text(8, "retroforge-scrape: ScreenScraper is closed for maintenance")],
		["ScreenScraper's daily request quota is used up: try again tomorrow", "ScreenScraper is closed for maintenance"])
	check("failure: cancelled", ScrapeRunner.failure_text(5, "retroforge-scrape: cancelled"), "Cancelled.")
	# Auto-scrape after a library load: on, a build that can scrape, nothing running, no game, and not
	# the reload a scrape itself asked for (that would only loop).
	check("auto: a library load with everything allowed scrapes", ScrapeRunner.auto_scrape_wanted(true, true, false, false, false), true)
	check("auto: not when off, without a login in the build, while a scrape or a game runs, or after its own reload",
		[ScrapeRunner.auto_scrape_wanted(false, true, false, false, false), ScrapeRunner.auto_scrape_wanted(true, false, false, false, false),
		 ScrapeRunner.auto_scrape_wanted(true, true, true, false, false), ScrapeRunner.auto_scrape_wanted(true, true, false, true, false),
		 ScrapeRunner.auto_scrape_wanted(true, true, false, false, true)],
		[false, false, false, false, false])

	var a := await job("ok", ["run", "--all"])
	check("ok: exit 0, progress in order, the summary", [a.code, a.seen, a.summary.get("scraped")], [0, [50, 100], 3.0])
	check("ok: arguments reach the tool", FileAccess.get_file_as_string("$T/fake-args").strip_edges(), "run --all")
	check("ok: 3,000 warnings on stderr did not stall it, and are not the error", a.error, "")
	check("ok: not running any more", a.running, false)
	var b := await job("quota", ["run"])
	check("quota: exit 6 with the tool's last stderr line", [b.code, b.error], [6, "retroforge-scrape: ScreenScraper's daily request quota is used up: try again tomorrow"])
	var c := await job("login", ["login", "good"], "pw-secret")
	check("login: the password goes on stdin", c.code, 0)
	check("login: never in the arguments", FileAccess.get_file_as_string("$T/fake-args").strip_edges(), "login good")
	var d := await job("login", ["login", "good"], "wrong")
	check("login: refused is exit 7", d.code, 7)
	var e := await job("slow", ["run"], "", 10)
	check("cancel: SIGTERM, the tool's summary and exit 5", [e.code, e.summary.get("scraped"), e.seen], [5, 1.0, [10]])
	var r := ScrapeRunner.new()
	r.tool = "$T/no-such-tool"
	r.start(["run"])
	var f: Array = await r.finished
	check("a tool that cannot start: exit -1", f[0], -1)
	quit(1 if failed else 0)
GD
  out="$(XDG_CONFIG_HOME="$T/config" timeout 60 "$GODOT" --headless --script "$T/runner_test.gd" 2>&1)"; rc=$?
  printf '%s\n' "$out" | grep -E '^  (ok|FAIL) '
  n_ok="$(printf '%s\n' "$out" | grep -c '^  ok ')"; n_bad="$(printf '%s\n' "$out" | grep -c '^  FAIL ')"
  PASS=$((PASS + n_ok)); FAIL=$((FAIL + n_bad))
  if [ "$rc" -ne 0 ] && [ "$n_bad" -eq 0 ]; then
    bad "Godot failed (rc $rc): $(printf '%s\n' "$out" | grep -E 'ERROR|error' | head -3)"
  fi
  if printf '%s\n' "$out" | grep -q 'SCRIPT ERROR'; then
    bad "a script did not compile: $(printf '%s\n' "$out" | grep 'SCRIPT ERROR' | head -3)"
  fi

  # =================================================================================================
  # Settings > General > Updates (retroforge_os.gd) in OGUI's own settings scene, against a fake
  # retroforge-update: OGUI's updater goes, the one button walks Check -> Install -> Restart now, the
  # channel switch checks at once, and a session restarted with an update waiting offers Restart now.
  # Needs OGUI's classes, so a copy of the pinned OGUI source tree whose addons/core/bin also holds
  # upstream's x86_64 core library (from the same release's opengamepadui-x86_64.tar.gz, named
  # template_debug and template_release): RETROFORGE_OGUI_PROJECT=<dir>. Skipped without. The plugin
  # is copied into <dir>/plugins/retroforge on every run.
  CASE="updates-ui"
  OGUI_PROJECT="${RETROFORGE_OGUI_PROJECT:-}"
  if [ -z "$OGUI_PROJECT" ] || [ ! -f "$OGUI_PROJECT/project.godot" ]; then
    printf '  skip %s -- no OGUI project (set RETROFORGE_OGUI_PROJECT)\n' "$CASE"
  else
    mkdir -p "$OGUI_PROJECT/plugins/retroforge" "$T/updates/d"
    cp "$SRC"/* "$OGUI_PROJECT/plugins/retroforge/"
    cat >"$T/updates/fake-update" <<'SH'
#!/bin/bash
# Fake retroforge-update. State in $FAKE_DIR: channel, staged (version), latest.<channel>
D=$FAKE_DIR; echo "$*" >> $D/calls
ch=$(cat $D/channel 2>/dev/null || echo stable)
case "$1" in
  version) echo 0.0.3 ;;
  channels) printf 'stable\nbeta\n' ;;
  channel) printf '%s\t/home/player/.config/retroforge/ota.conf\n' "$ch" ;;
  set-channel) [ -e $D/slow-set ] && sleep 0.5; echo "$2" > $D/channel ;;
  staged) [ -s $D/staged ] && { cat $D/staged; exit 0; }; exit 7 ;;
  check) [ -s $D/staged ] && { cat $D/staged; exit 0; }
         v=$(cat $D/latest.$ch 2>/dev/null); [ -n "$v" ] && [ "$v" != 0.0.3 ] && { echo "$v"; exit 0; }; exit 7 ;;
  "") v=$(cat $D/latest.$ch); for p in 10 50 100; do echo "$p%"; sleep 0.2; done; echo "$v" > $D/staged ;;
esac
SH
    printf '#!/bin/sh\ntouch "$FAKE_DIR/rebooted"\n' >"$T/updates/fake-reboot"
    cat >"$T/updates/fake-systemctl" <<'SH'
#!/bin/bash
# Fake systemctl for retroforge-pairingd: the unit runs while $FAKE_DIR/pairing exists.
echo "$*" >> "$FAKE_DIR/systemctl-calls"
case "$1" in
  is-active) [ -e "$FAKE_DIR/pairing" ] ;;
  start) touch "$FAKE_DIR/pairing" ;;
  stop) rm -f "$FAKE_DIR/pairing" ;;
  *) exit 1 ;;
esac
SH
    chmod +x "$T/updates/fake-update" "$T/updates/fake-reboot" "$T/updates/fake-systemctl"
    cat >"$OGUI_PROJECT/retroforge_updates_test.gd" <<'GD'
extends SceneTree

var failed := 0
var D := OS.get_environment("FAKE_DIR")

func check(what: String, got, want) -> void:
	if got == want:
		print("  ok   updates-ui -- ", what)
	else:
		failed += 1
		print("  FAIL updates-ui -- ", what, ": got ", got, ", want ", want)

func _initialize() -> void:
	run.call_deferred()

func wait(sec: float) -> void:
	await create_timer(sec).timeout

func put(name: String, text: String) -> void:
	var f := FileAccess.open(D.path_join(name), FileAccess.WRITE)
	f.store_string(text)
	f.close()

func run() -> void:
	var processor := ResourceProcessor.new()  # card_ui.tscn has one: it drives every Command
	processor.registry = load("res://core/systems/resource/resource_registry.tres") as ResourceRegistry
	root.add_child(processor)
	var menu: Node = load("res://core/ui/card_ui/settings/general_settings_menu.tscn").instantiate()
	root.add_child(menu)
	await process_frame
	var os = load("res://plugins/retroforge/retroforge_os.gd").new()
	os.tool = D.path_join("../fake-update")
	os.reboot_command.assign([D.path_join("../fake-reboot")])
	os.systemctl = D.path_join("../fake-systemctl")
	put("latest.stable", "0.0.3")
	put("latest.beta", "0.0.4-beta.1")
	os.ready(root)
	await wait(0.5)
	var box: Node = menu.get_node("MarginContainer/VBoxContainer/VBoxContainer")
	check("OGUI's updater controls are gone", [box.has_node("AutoUpdateToggle"), box.has_node("CheckUpdateButton"), box.has_node("UpdateButton"), menu.has_node("SoftwareUpdater"), menu.has_node("UpdateTimer")], [false, false, false, false, false])
	var button: Node = box.get_node_or_null("RetroForgeUpdateButton")
	var channel: Node = box.get_node_or_null("RetroForgeUpdateChannel")
	check("the button and dropdown sit right under the Updates label",
		[box.get_node("UpdatesLabel").get_index() + 1, box.get_node("UpdatesLabel").get_index() + 2], [button.get_index(), channel.get_index()])
	check("focus starts on the button", box.get_node("FocusGroup").current_focus, button)
	check("idle: Check for updates, version shown", [button.button_text, button.description], ["Check for updates", "RetroForge 0.0.3."])
	check("dropdown: Stable, Beta; Stable selected", [channel.option_button.item_count, channel.option_button.get_item_text(0), channel.option_button.get_item_text(1), channel.selected], [2, "Stable", "Beta", 0])
	await test_pairing(box, channel)
	button.button_up.emit()
	await wait(0.5)
	check("stable is up to date: still Check, says so", [button.button_text, button.description], ["Check for updates", "No update found on the Stable channel."])
	put("slow-set", "")
	channel.option_button.select(1)
	channel.item_selected.emit(1)
	await wait(0.2)
	check("while the channel is being written, the button and the dropdown wait", [button.disabled, channel.disabled], [true, true])
	DirAccess.remove_absolute(D.path_join("slow-set"))
	await wait(1.2)
	check("switching to Beta writes it and checks at once", FileAccess.get_file_as_string(D.path_join("channel")).strip_edges(), "beta")
	check("beta offers 0.0.4-beta.1: Install", [button.button_text, button.disabled], ["Install", false])
	button.button_up.emit()
	await wait(0.3)
	check("installing: disabled, channel locked", [button.button_text, button.disabled, channel.disabled], ["Installing...", true, true])
	await wait(1.5)
	check("installed: Restart now", [button.button_text, button.disabled, channel.disabled], ["Restart now", false, false])
	button.button_up.emit()
	await wait(0.3)
	check("Restart now runs the reboot command", FileAccess.file_exists(D.path_join("rebooted")), true)
	# A new session with the update still waiting: Restart now from the start.
	var menu2: Node = load("res://core/ui/card_ui/settings/general_settings_menu.tscn").instantiate()
	menu.queue_free()
	await process_frame
	root.add_child(menu2)
	await process_frame
	var os2 = load("res://plugins/retroforge/retroforge_os.gd").new()
	os2.tool = os.tool
	os2.systemctl = os.systemctl
	os2.ready(root)
	await wait(0.5)
	var b2: Node = menu2.get_node("MarginContainer/VBoxContainer/VBoxContainer/RetroForgeUpdateButton")
	check("restarted session: staged update shows Restart now", [b2.button_text, b2.description], ["Restart now", "RetroForge 0.0.4-beta.1 is installed. Restart to use it."])
	check("restarted session: Beta still selected", menu2.get_node("MarginContainer/VBoxContainer/VBoxContainer/RetroForgeUpdateChannel").selected, 1)
	await test_background_check(menu2)
	quit(1 if failed else 0)

# A background check (here 0.3 s after start instead of 3 min) finds an update: Install, and one
# notification naming it -- never an install.
func test_background_check(previous: Node) -> void:
	DirAccess.remove_absolute(D.path_join("staged"))
	put("channel", "stable")
	put("latest.stable", "0.0.5")
	var menu3: Node = load("res://core/ui/card_ui/settings/general_settings_menu.tscn").instantiate()
	previous.queue_free()
	await process_frame
	root.add_child(menu3)
	await process_frame
	# A method, disconnected before quit: lambdas left on the NotificationManager resource abort
	# Godot's teardown ("double free").
	var nm = load("res://core/global/notification_manager.tres")
	nm.notification_queued.connect(note)
	nm.notification_sent.connect(note)
	var os3 = load("res://plugins/retroforge/retroforge_os.gd").new()
	os3.tool = D.path_join("../fake-update")
	os3.systemctl = D.path_join("../fake-systemctl")
	os3.first_check_delay = 0.3
	os3.in_game = func() -> bool: return false  # LaunchManager needs InputPlumber, absent here
	os3.ready(root)
	await wait(1.2)
	var b3: Node = menu3.get_node("MarginContainer/VBoxContainer/VBoxContainer/RetroForgeUpdateButton")
	check("background check: found 0.0.5, offers Install", [b3.button_text, b3.description], ["Install", "RetroForge 0.0.5 is available (you have 0.0.3)."])
	nm.notification_queued.disconnect(note)
	nm.notification_sent.disconnect(note)
	check("background check: one notification naming it", notes.has("RetroForge 0.0.5 is available: Settings > General > Updates"), true)
	check("background check: nothing installed", FileAccess.file_exists(D.path_join("staged")), false)

var notes: Array[String] = []
func note(n) -> void:
	notes.append(n.text)

# A player's press on an OGUI Toggle, as its _gui_input does on ui_accept.
func press(toggle: Node) -> void:
	toggle.button_pressed = not toggle.button_pressed
	toggle.toggled.emit(toggle.button_pressed)

# Remote access: the switch starts and stops retroforge-pairingd and shows its real state.
func test_pairing(box: Node, channel: Node) -> void:
	var pairing: Node = box.get_node_or_null("RetroForgePairing")
	check("pairing: a Remote access switch right under the update channel", pairing.get_index(), channel.get_index() + 2)
	check("pairing: off at start, says how to turn it on", [pairing.button_pressed, "Turn on" in pairing.description], [false, true])
	press(pairing)
	await wait(0.5)
	check("pairing: on starts the unit", FileAccess.file_exists(D.path_join("pairing")), true)
	check("pairing: on says where to send the key", [pairing.button_pressed, ":32000/register" in pairing.description], [true, true])
	DirAccess.remove_absolute(D.path_join("pairing"))  # stopped elsewhere (a crash, ssh)
	load("res://assets/state/states/settings_general.tres").state_entered.emit(null)
	await wait(0.2)
	check("pairing: reopening Settings > General shows a stop made elsewhere, without acting on it",
		[pairing.button_pressed, FileAccess.get_file_as_string(D.path_join("systemctl-calls")).count("stop")], [false, 0])
	press(pairing)
	await wait(0.5)
	press(pairing)
	await wait(0.5)
	check("pairing: off stops the unit", [FileAccess.file_exists(D.path_join("pairing")), pairing.button_pressed], [false, false])
	check("pairing: only start, stop and is-active are asked",
		Array(FileAccess.get_file_as_string(D.path_join("systemctl-calls")).split("\n", false)).filter(func(l): return not (l.begins_with("is-active") or l == "start retroforge-pairingd.service" or l == "stop retroforge-pairingd.service")), [])
GD
    out="$(cd "$OGUI_PROJECT" && FAKE_DIR="$T/updates/d" timeout 120 "$GODOT" --headless --path . --script res://retroforge_updates_test.gd 2>&1)"; rc=$?
    rm -f "$OGUI_PROJECT/retroforge_updates_test.gd"
    printf '%s\n' "$out" | grep -E '^  (ok|FAIL) '
    n_ok="$(printf '%s\n' "$out" | grep -c '^  ok ')"; n_bad="$(printf '%s\n' "$out" | grep -c '^  FAIL ')"
    PASS=$((PASS + n_ok)); FAIL=$((FAIL + n_bad))
    if [ "$rc" -ne 0 ] && [ "$n_bad" -eq 0 ]; then
      bad "Godot failed (rc $rc): $(printf '%s\n' "$out" | grep -E 'ERROR' | head -3)"
    fi
    if printf '%s\n' "$out" | grep -q 'SCRIPT ERROR'; then
      bad "a script did not compile: $(printf '%s\n' "$out" | grep 'SCRIPT ERROR' | head -3)"
    fi
  fi
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
