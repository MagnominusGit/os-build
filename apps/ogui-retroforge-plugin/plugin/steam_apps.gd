extends RefCounted

## The Steam games installed in the player's Steam client, read from the client's own files: no
## sign-in of its own. No OGUI types, so tests/test-plugin.sh runs it in a stock headless Godot.
##
## The OGUI Steam plugin builds its library from a second sign-in, through steamcmd. The client the
## player already signed into (Main menu > Emulators > Steam Client) keeps one app manifest per
## installed app, steamapps/appmanifest_<appid>.acf, in each of its library folders
## (steamapps/libraryfolders.vdf), and the art its library shows in appcache/librarycache/<appid>/.
## That gives the installed games only: what the player owns but has not installed is known to
## Steam's servers, not to these files. Installs and uninstalls happen in Steam's own UI.
##
## A manifest does not say whether the app is a game or one of Steam's tools (Proton, the Steam
## Linux Runtimes, the redistributables, Valve's FEX): that is in appinfo.vdf, a binary cache. Tools
## are told apart by app id and by name instead (TOOL_APPS, TOOL_NAMES).

## Valve's tools that install as apps beside the games (seen on the KONKR Pocket FIT, 2026-10-19,
## and Valve's other runtimes and Protons).
const TOOL_APPS := [
	228980,  # Steamworks Common Redistributables
	1070560, 1391110, 1628350, 4183110, 4185400,  # Steam Linux Runtime 1.0, 2.0, 3.0, 4.0, 4.0 - Arm64
	1493710, 2180100, 4628740,  # Proton Experimental, Proton Hotfix, Proton 11.0 (ARM64)
	1161040, 1826330,  # Proton BattlEye Runtime, Proton EasyAntiCheat Runtime
	3127680,  # FEX, Valve's x86 compat tool for arm64
]
## Name prefixes of tools with ids not listed above (every numbered Proton, a newer runtime).
const TOOL_NAMES := ["Proton ", "Proton-", "Steam Linux Runtime", "Steamworks Common Redistributables"]
## StateFlags bit: the app is fully installed (set too while an update is pending or running).
const FULLY_INSTALLED := 4
## As the OGUI Steam plugin starts a game (/usr/bin/steam): -silent keeps Steam's own UI hidden.
const LAUNCH_ARGS := ["-gamepadui", "-steamos3", "-steampal", "-steamdeck", "-silent"]
## OGUI's BoxArtProvider.LAYOUT (GRID_PORTRAIT, GRID_LANDSCAPE, BANNER, LOGO) -> the client's files.
const ART := [
	["library_600x900.jpg", "library_600x900_2x.jpg"],
	["header.jpg", "library_header.jpg"],
	["library_hero.jpg"],
	["logo.png"],
]


## Where /usr/bin/steam keeps the client: $XDG_DATA_HOME/Steam, else ~/.local/share/Steam.
static func steam_root() -> String:
	var data := OS.get_environment("XDG_DATA_HOME")
	if data == "":
		data = OS.get_environment("HOME").path_join(".local/share")
	return data.path_join("Steam")


## Every "key" "value" line of a text VDF (an .acf is one) as [depth, key, value], depth counting
## the braces it sits in. Values are unescaped (\" and \\).
static func vdf_pairs(text: String) -> Array:
	var re := RegEx.create_from_string('^\\s*"([^"]+)"\\s+"((?:[^"\\\\]|\\\\.)*)"\\s*$')
	var pairs := []
	var depth := 0
	for line in text.split("\n"):
		var s := line.strip_edges()
		if s == "{":
			depth += 1
			continue
		if s == "}":
			depth -= 1
			continue
		var m := re.search(line)
		if m:
			pairs.append([depth, m.get_string(1), m.get_string(2).replace('\\"', '"').replace("\\\\", "\\")])
	return pairs


## The client's library folders: its own root, then each "path" of steamapps/libraryfolders.vdf
## (an SD card, another drive), each once.
static func library_dirs(root: String) -> PackedStringArray:
	var dirs := PackedStringArray([root.trim_suffix("/")])
	var vdf := root.path_join("steamapps/libraryfolders.vdf")
	if not FileAccess.file_exists(vdf):
		return dirs
	for pair in vdf_pairs(FileAccess.get_file_as_string(vdf)):
		var path: String = pair[2].trim_suffix("/")
		if pair[0] == 2 and pair[1] == "path" and path != "" and not path in dirs:
			dirs.append(path)
	return dirs


## An app manifest's top-level fields: appid, name, StateFlags, installdir ({} if unreadable).
static func manifest(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var fields := {}
	for pair in vdf_pairs(FileAccess.get_file_as_string(path)):
		if pair[0] == 1 and pair[1] in ["appid", "name", "StateFlags", "installdir"] and not fields.has(pair[1]):
			fields[pair[1]] = pair[2]
	return fields


static func is_steam_tool(appid: int, name: String) -> bool:
	if appid in TOOL_APPS or name == "FEX":
		return true
	for prefix in TOOL_NAMES:
		if name.begins_with(prefix):
			return true
	return false


## The installed games, sorted by name: [{"appid": int, "name": String, "dir": String}], dir being
## the game's folder. An app still downloading, a tool, or a manifest without an id or a name is
## left out; an app id in two library folders counts once (the first folder).
static func installed(root: String) -> Array:
	var games := []
	var seen := {}
	for lib in library_dirs(root):
		var apps := lib.path_join("steamapps")
		if not DirAccess.dir_exists_absolute(apps):
			continue
		for file in DirAccess.get_files_at(apps):
			if not (file.begins_with("appmanifest_") and file.ends_with(".acf")):
				continue
			var m := manifest(apps.path_join(file))
			var id_text: String = m.get("appid", "")
			var name: String = m.get("name", "").strip_edges()
			if not id_text.is_valid_int() or name == "":
				continue
			var appid := id_text.to_int()
			var flags: String = m.get("StateFlags", "0")
			if appid in seen or is_steam_tool(appid, name):
				continue
			if not flags.is_valid_int() or (flags.to_int() & FULLY_INSTALLED) == 0:
				continue
			seen[appid] = true
			games.append({"appid": appid, "name": name, "dir": apps.path_join("common").path_join(str(m.get("installdir", "")))})
	games.sort_custom(func(a, b): return a["name"].naturalnocasecmp_to(b["name"]) < 0)
	return games


static func launch_args(appid: int) -> PackedStringArray:
	var args := PackedStringArray(LAUNCH_ARGS)
	args.append("steam://rungameid/%d" % appid)
	return args


## The client's cached art of an app for an OGUI layout, or "". Where the client keeps it:
## librarycache/<appid>/<file>, or one folder further down (newer clients put some art under a
## hashed folder), or librarycache/<appid>_<file> (older clients).
static func art_path(root: String, appid: int, kind: int) -> String:
	if kind < 0 or kind >= ART.size():
		return ""
	var cache := root.path_join("appcache/librarycache")
	var app_dir := cache.path_join(str(appid))
	for file in ART[kind]:
		var direct := app_dir.path_join(file)
		if FileAccess.file_exists(direct):
			return direct
		if DirAccess.dir_exists_absolute(app_dir):
			for sub in DirAccess.get_directories_at(app_dir):
				if FileAccess.file_exists(app_dir.path_join(sub).path_join(file)):
					return app_dir.path_join(sub).path_join(file)
		var flat := cache.path_join("%d_%s" % [appid, file])
		if FileAccess.file_exists(flat):
			return flat
	return ""


## What a rescan depends on, for steam_watch.gd: libraryfolders.vdf and every app manifest, as
## "path size mtime", sorted. Steam rewrites a manifest when an install starts, progresses and ends.
static func snapshot(root: String) -> PackedStringArray:
	var lines := PackedStringArray()
	var vdf := root.path_join("steamapps/libraryfolders.vdf")
	if FileAccess.file_exists(vdf):
		lines.append("%s %d %d" % [vdf, FileAccess.get_size(vdf), FileAccess.get_modified_time(vdf)])
	for lib in library_dirs(root):
		var apps := lib.path_join("steamapps")
		if not DirAccess.dir_exists_absolute(apps):
			continue
		for file in DirAccess.get_files_at(apps):
			if file.begins_with("appmanifest_") and file.ends_with(".acf"):
				var path := apps.path_join(file)
				lines.append("%s %d %d" % [path, FileAccess.get_size(path), FileAccess.get_modified_time(path)])
	lines.sort()
	return lines
