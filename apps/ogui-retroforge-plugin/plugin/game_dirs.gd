extends RefCounted

## Games that are FOLDERS, not files: a PlayStation 3 disc dump is a folder holding
## PS3_GAME/USRDIR/EBOOT.BIN, and RPCS3 boots the folder itself. A system lists the files inside a
## game folder that make it one (library_roms.gd SYSTEMS "dirs"); any other subfolder of
## ~/roms/<system> is ignored. No OGUI types, so tests/test-plugin.sh runs it in a stock headless
## Godot.


## The first marker file present in a folder (its full path), or "" when the folder is no game.
static func marker(dir_path: String, markers: Array) -> String:
	for m in markers:
		var path := dir_path.path_join(str(m))
		if FileAccess.file_exists(path):
			return path
	return ""


## The game folders of a system folder (full paths), sorted. Hidden folders are skipped.
static func scan(system_path: String, markers: Array) -> PackedStringArray:
	var found := PackedStringArray()
	if markers.is_empty():
		return found
	var dir := DirAccess.open(system_path)
	if not dir:
		return found
	for sub in dir.get_directories():
		var path := system_path.path_join(sub)
		if marker(path, markers) != "":
			found.append(path)
	found.sort()
	return found
