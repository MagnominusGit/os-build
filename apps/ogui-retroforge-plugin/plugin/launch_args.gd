extends RefCounted

## retroforge-launch's command line for a ROM, the key a ROM's options are saved under, and the
## player's per-emulator defaults retroforge-launch reads. No OGUI types, so tests/test-plugin.sh can
## run them in a stock Godot.
##
## "Run on fast cores" is decided in two places, like retroforge-launch does:
##   - per emulator, Settings > Emulators: CPUS=big|all in ~/.config/retroforge/emulators/<emu>.conf
##     (retroforge-launch reads it for every launch of that emulator, Open included);
##   - per game, Game settings > RetroForge: "" = the emulator's default, "big" / "all" = an override,
##     put on the game's command line as --cpus.

const LAUNCH_CONF := "/etc/retroforge/launch.conf"
const CPUS_VALUES := ["big", "all"]


## A ROM's identity for per-game options: "<system>/<file name>". Not the card name, which
## changes when a same-named ROM appears (rom_names.gd).
static func rom_id(system: String, path: String) -> String:
	return system + "/" + path.get_file()


## Arguments for retroforge-launch. cpus: "" follows the emulator's default (no --cpus), "big" or
## "all" overrides it. An array, not a command line: a ROM path with spaces stays one argument.
static func for_rom(system: String, path: String, cpus: String) -> PackedStringArray:
	var args := PackedStringArray()
	if cpus in CPUS_VALUES:
		args.append_array(["--cpus", cpus])
	args.append_array([system, path])
	return args


## The emulator launch.conf maps a system to ("" if none). Same rule as retroforge-launch: a
## `system=emulator` line, the last one wins.
static func emulator_for(system: String, launch_conf: String) -> String:
	var emulator := ""
	var line_re := RegEx.create_from_string("^" + system + "=([a-z0-9_-]+)\\s*$")
	for line in launch_conf.split("\n"):
		var m := line_re.search(line)
		if m:
			emulator = m.get_string(1)
	return emulator


## The CPUS value of a player conf ("big", "all", or "" when unset or not one of those), read the
## way retroforge-launch reads it: the last CPUS= line.
static func conf_cpus(conf: String) -> String:
	var value := ""
	for line in conf.split("\n"):
		if line.begins_with("CPUS="):
			value = line.trim_prefix("CPUS=")
	return value if value in CPUS_VALUES else ""


## The player conf with CPUS set to value: every CPUS= line replaced by one, other lines kept.
static func conf_with_cpus(conf: String, value: String) -> String:
	var lines := PackedStringArray()
	for line in conf.split("\n"):
		if line != "" and not line.begins_with("CPUS="):
			lines.append(line)
	lines.append("CPUS=" + value)
	return "\n".join(lines) + "\n"


## Where retroforge-launch looks for the player's settings of an emulator.
static func player_conf_path(emulator: String) -> String:
	var config := OS.get_environment("XDG_CONFIG_HOME")
	if config == "":
		config = OS.get_environment("HOME").path_join(".config")
	return config.path_join("retroforge/emulators/%s.conf" % emulator)


static func read_text(path: String) -> String:
	return FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""


## The player's fast-cores default for an emulator: true when its conf says CPUS=big.
static func emulator_fast_cores(emulator: String) -> bool:
	return conf_cpus(read_text(player_conf_path(emulator))) == "big"


## Save the player's fast-cores default for an emulator. False when the file could not be written.
## Written to a temporary file and renamed over the conf, so a full disk or a power cut never
## leaves it half written.
static func set_emulator_fast_cores(emulator: String, on: bool) -> bool:
	var path := player_conf_path(emulator)
	if DirAccess.make_dir_recursive_absolute(path.get_base_dir()) != OK:
		return false
	var text := conf_with_cpus(read_text(path), "big" if on else "all")
	var tmp := path + ".part"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if not f:
		return false
	var written := f.store_string(text)
	f.close()
	if not written or DirAccess.rename_absolute(tmp, path) != OK:
		DirAccess.remove_absolute(tmp)
		return false
	return true
