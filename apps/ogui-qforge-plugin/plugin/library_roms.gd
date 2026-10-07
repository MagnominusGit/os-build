extends Library

## QForge ROM library: one launch item per ROM under ~/roms/<system>/, each started by
## qforge-launch in the emulator /etc/qforge/launch.conf maps the system to.

const LAUNCHER := "/usr/bin/qforge-launch"

# Relative to this script, so it resolves under res://plugins/qforge/ once the zip is loaded.
const RomNames := preload("rom_names.gd")
const LaunchArgs := preload("launch_args.gd")
const GameDirs := preload("game_dirs.gd")

## OGUI settings section of a game's "Run on fast cores" override: key = ROM id (launch_args.gd),
## value "big" (on) or "all" (off). Absent = the emulator's default (Settings > Emulators).
const CPUS_SECTION := "qforge.cpus"

var settings_manager := load("res://core/global/settings_manager.tres") as SettingsManager

## Systems the image can launch, in tab order (by maker, then by age). Tab label, and the file
## extensions that are a game. An .m3u playlist wins over the disc images it lists, so a multi-disc
## game is one card. "dirs": the files that make a subfolder a game (game_dirs.gd): a PS3 disc dump
## is a folder, and the folder is what RPCS3 boots.
const SYSTEMS := {
	"gb": {"name": "Game Boy", "exts": ["gb", "zip", "7z"]},
	"gbc": {"name": "Game Boy Color", "exts": ["gbc", "gb", "zip", "7z"]},
	"gba": {"name": "Game Boy Advance", "exts": ["gba", "zip", "7z"]},
	"snes": {"name": "Super Nintendo", "exts": ["sfc", "smc", "zip"]},
	"nds": {"name": "Nintendo DS", "exts": ["nds", "zip", "7z"]},
	"3ds": {"name": "Nintendo 3DS", "exts": ["3ds", "cci", "cxi", "3dsx", "zcci", "zcxi", "z3dsx"]},
	"gc": {"name": "GameCube", "exts": ["iso", "gcm", "gcz", "rvz", "ciso", "wia"]},
	"wii": {"name": "Wii", "exts": ["iso", "wbfs", "rvz", "gcz", "ciso", "wia"]},
	"wiiu": {"name": "Wii U", "exts": ["wua", "wud", "wux", "rpx"]},
	"psx": {"name": "PlayStation", "exts": ["chd", "cue", "pbp", "m3u", "iso"]},
	"ps2": {"name": "PlayStation 2", "exts": ["chd", "iso", "cso", "zso", "gz", "cue"]},
	"psp": {"name": "PSP", "exts": ["iso", "cso", "chd", "pbp"]},
	"ps3": {"name": "PlayStation 3", "exts": ["iso"], "dirs": ["PS3_GAME/USRDIR/EBOOT.BIN", "USRDIR/EBOOT.BIN"]},
	"md": {"name": "Mega Drive", "exts": ["md", "gen", "bin", "zip"]},
	"segacd": {"name": "Mega CD", "exts": ["chd", "cue"]},
	"32x": {"name": "32X", "exts": ["32x", "zip"]},
	"dc": {"name": "Dreamcast", "exts": ["chd", "gdi", "cdi", "cue"]},
	"xbox": {"name": "Xbox", "exts": ["iso", "xiso"]},
}


# Set in _ready, not _init: overriding _init skips Library._init, which is what registers the
# library with the LibraryManager (on ready). Ready handlers run before ready is emitted.
func _ready() -> void:
	library_id = "qforge-roms"
	store_id = "qforge"
	supports_uninstall = false
	logger = Log.get_logger("QForgeRoms", Log.LEVEL.INFO)


## When a ROM's launch fails because its emulator is not installed (or its AppImage did not
## mount), tell the player. OGUI never sees qforge-launch's exit code (games run through its
## reaper), so qforge-launch leaves the reason in a status file this EXIT hook reads. The launch
## itself is never held back: downloads happen in Settings > Emulators, not on a card.
func get_app_lifecycle_hooks() -> Array[AppLifecycleHook]:
	var hooks: Array[AppLifecycleHook] = [LaunchFailure.new()]
	return hooks


## system -> the files that make a subfolder of ~/roms/<system> a game (SYSTEMS "dirs").
func dir_markers() -> Dictionary:
	var markers := {}
	for system in SYSTEMS:
		if SYSTEMS[system].has("dirs"):
			markers[system] = SYSTEMS[system]["dirs"]
	return markers


func roms_dir() -> String:
	return OS.get_environment("HOME").path_join("roms")


func get_library_launch_items() -> Array[LibraryLaunchItem]:
	var started := Time.get_ticks_msec()
	var roms: Array[Dictionary] = []
	var system_names := {}
	for system in SYSTEMS:
		system_names[system] = SYSTEMS[system]["name"]
		for path in _scan_system(system):
			roms.append({"system": system, "path": path})
		for path in GameDirs.scan(roms_dir().path_join(system), SYSTEMS[system].get("dirs", [])):
			roms.append({"system": system, "path": path, "dir": true})
	var names := RomNames.names_for(roms, system_names)
	var items: Array[LibraryLaunchItem] = []
	for i in roms.size():
		items.append(_launch_item(names[i], roms[i]["system"], roms[i]["path"]))
	_drop_stale(items)
	logger.info("Found %d ROM(s) in %d ms" % [items.size(), Time.get_ticks_msec() - started])
	return items


## OGUI's load_library only ever adds: remove our cards whose ROM is gone, or whose name now
## stands for another file, before LibraryManager adds this scan's items (deferred).
func _drop_stale(items: Array[LibraryLaunchItem]) -> void:
	var wanted := {}
	for item in items:
		wanted[item.name] = item.metadata["rom"]
	var current := {}
	for app in library_manager.get_library_items([]):
		var launch := app.get_launch_item(library_id)
		if launch:
			current[app.name] = launch.metadata.get("rom", "")
	for name in RomNames.stale(current, wanted):
		logger.info("ROM gone or renamed: " + name)
		library_manager.remove_library_launch_item(library_id, name)


## ROM files of one system, one level deep, minus the members of any .m3u playlist.
func _scan_system(system: String) -> PackedStringArray:
	var dir_path := roms_dir().path_join(system)
	var dir := DirAccess.open(dir_path)
	if not dir:
		return PackedStringArray()
	var exts: Array = SYSTEMS[system]["exts"]
	var roms := PackedStringArray()
	var in_playlist := {}
	for file in dir.get_files():
		var ext := file.get_extension().to_lower()
		if not ext in exts:
			continue
		roms.append(dir_path.path_join(file))
		if ext == "m3u":
			for member in _m3u_members(dir_path.path_join(file)):
				in_playlist[member] = true
	var result := PackedStringArray()
	for rom in roms:
		if not rom.get_file() in in_playlist:
			result.append(rom)
	return result


## File names an .m3u lists (comments and blank lines skipped).
func _m3u_members(path: String) -> PackedStringArray:
	var members := PackedStringArray()
	var f := FileAccess.open(path, FileAccess.READ)
	if not f:
		return members
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line != "" and not line.begins_with("#"):
			members.append(line.get_file())
	return members


func _launch_item(name: String, system: String, path: String) -> LibraryLaunchItem:
	var item := LibraryLaunchItem.new()
	item.name = name
	item.provider_app_id = LaunchArgs.rom_id(system, path)
	item.command = LAUNCHER
	item.args = LaunchArgs.for_rom(system, path, _cpus_saved(item.provider_app_id))
	item.tags = PackedStringArray(["qforge", system])
	item.categories = PackedStringArray(["game"])
	item.installed = true
	item.metadata = {"system": system, "rom": path}
	return item


func _cpus_saved(rom_id: String) -> String:
	var value = settings_manager.get_value(CPUS_SECTION, rom_id, "")
	return value if value in LaunchArgs.CPUS_VALUES else ""


## A game's fast-cores override: "" (the emulator's default), "big" or "all".
func get_cpus(item: LibraryLaunchItem) -> String:
	return _cpus_saved(item.provider_app_id)


## Whether the emulator this game runs in defaults to the fast cores (Settings > Emulators).
func emulator_fast_cores(item: LibraryLaunchItem) -> bool:
	var emulator := LaunchArgs.emulator_for(item.metadata["system"], LaunchArgs.read_text(LaunchArgs.LAUNCH_CONF))
	return emulator != "" and LaunchArgs.emulator_fast_cores(emulator)


## Save a game's override and rewrite its arguments: OGUI builds the command line from them at
## each launch, so the next launch follows without a rescan.
func set_cpus(item: LibraryLaunchItem, cpus: String) -> void:
	if cpus in LaunchArgs.CPUS_VALUES:
		settings_manager.set_value(CPUS_SECTION, item.provider_app_id, cpus)
	elif settings_manager.get_value(CPUS_SECTION, item.provider_app_id) != null:
		# ConfigFile logs an error when erasing a key that is not there.
		settings_manager.erase_section_key(CPUS_SECTION, item.provider_app_id)
	# A rescan may have replaced the item the settings page holds: update the library's live one
	# too, by ROM id (its name can have changed).
	var args := LaunchArgs.for_rom(item.metadata["system"], item.metadata["rom"], cpus)
	item.args = args
	for app in library_manager.get_library_items([]):
		var live := app.get_launch_item(library_id)
		if live and live != item and live.provider_app_id == item.provider_app_id:
			live.args = args
	logger.info("%s: fast cores %s" % [item.name, {"big": "on", "all": "off"}.get(cpus, "emulator default")])


class LaunchFailure extends AppLifecycleHook:
	const EMU_TOOL := "/usr/bin/qforge-emu"
	var logger := Log.get_logger("QForgeRoms", Log.LEVEL.INFO)

	func _init() -> void:
		super(AppLifecycleHook.TYPE.EXIT)

	func get_name() -> String:
		return "QForgeLaunchFailure"

	## Same default as qforge-launch: $XDG_RUNTIME_DIR/qforge-launch.status.
	static func status_path() -> String:
		var run := OS.get_environment("XDG_RUNTIME_DIR")
		return (run if run != "" else "/tmp").path_join("qforge-launch.status")

	func execute(item: LibraryLaunchItem) -> void:
		var path := status_path()
		if not FileAccess.file_exists(path):
			return
		var words := FileAccess.get_file_as_string(path).strip_edges().split(" ")
		DirAccess.remove_absolute(path)
		if words.size() < 2:
			return
		var name := _emulator_name(words[1])
		var msg: String
		match words[0]:
			"not-installed":
				msg = "%s is not installed.\nDownload it in Settings > Emulators first." % name
			"mount-failed":
				msg = "%s could not be started.\nDelete it and download it again in Settings > Emulators." % name
			"missing-file":
				# qforge-launch: `missing-file <emulator> <path under the player's home>`
				if words.size() != 3:
					return
				msg = "%s needs %s.\nCopy it to the %s folder (network share), then start the game again." \
						% [name, words[2].get_file(), words[2].get_base_dir()]
			"install-failed":
				msg = "%s could not install its firmware or system files.\nCheck the file in the bios folder, then try again." % name
			_:
				return
		logger.info("%s: %s %s" % [item.name, words[0], words[1]])
		var dialog := Engine.get_main_loop().get_first_node_in_group("dialog") as Dialog
		if not dialog:
			logger.warn("no OGUI dialog to show: " + msg)
			return
		var cancel_was_visible := dialog.cancel_visible
		dialog.cancel_visible = false
		dialog.open(null, msg, "OK")
		await dialog.choice_selected
		# The dialog is shared: put its Cancel button back, but only once it has faded out, or
		# the button reappears on screen while it closes.
		if dialog.visible:
			await dialog.visibility_changed
		dialog.cancel_visible = cancel_was_visible

	## The catalog's display name for an emulator id (qforge-emu list), or the id itself.
	func _emulator_name(emu_id: String) -> String:
		var output: Array = []
		if OS.execute(EMU_TOOL, ["list"], output) == 0 and not output.is_empty():
			var parsed = JSON.parse_string(str(output[0]))
			if parsed is Dictionary and emu_id in parsed.get("emulators", {}):
				return str(parsed["emulators"][emu_id].get("name", emu_id))
		return emu_id
