extends Library

## QForge ROM library: one launch item per ROM under ~/roms/<system>/, each started by
## qforge-launch in the emulator /etc/qforge/launch.conf maps the system to.

const LAUNCHER := "/usr/bin/qforge-launch"

## Systems the image can launch. Tab label, and the file extensions that are a game. An .m3u
## playlist wins over the disc images it lists, so a multi-disc game is one card.
const SYSTEMS := {
	"psx": {"name": "PlayStation", "exts": ["chd", "cue", "pbp", "m3u", "iso"]},
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
## itself is never held back: downloads happen in the QForge store, not on a card.
func get_app_lifecycle_hooks() -> Array[AppLifecycleHook]:
	var hooks: Array[AppLifecycleHook] = [LaunchFailure.new()]
	return hooks


func roms_dir() -> String:
	return OS.get_environment("HOME").path_join("roms")


func get_library_launch_items() -> Array[LibraryLaunchItem]:
	var started := Time.get_ticks_msec()
	var items: Array[LibraryLaunchItem] = []
	for system in SYSTEMS:
		for path in _scan_system(system):
			items.append(_launch_item(system, path))
	logger.info("Found %d ROM(s) in %d ms" % [items.size(), Time.get_ticks_msec() - started])
	return items


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


func _launch_item(system: String, path: String) -> LibraryLaunchItem:
	var item := LibraryLaunchItem.new()
	item.name = path.get_file().get_basename()
	item.provider_app_id = system + "/" + path.get_file()
	item.command = LAUNCHER
	# An array, not a command line: a ROM path with spaces stays one argument.
	item.args = PackedStringArray([system, path])
	item.tags = PackedStringArray(["qforge", system])
	item.categories = PackedStringArray(["game"])
	item.installed = true
	item.metadata = {"system": system, "rom": path}
	return item


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
		if words.size() != 2:
			return
		var name := _emulator_name(words[1])
		var msg: String
		match words[0]:
			"not-installed":
				msg = "%s is not installed.\nDownload it from the QForge store first." % name
			"mount-failed":
				msg = "%s could not be started.\nTry downloading it again from the QForge store." % name
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
