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
	quit(1 if failed else 0)

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
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
