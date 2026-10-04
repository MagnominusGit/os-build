extends RefCounted

## qforge-launch's command line for a ROM, and the key its per-game options are saved under.
## Plain functions with no OGUI types, so tests/test-plugin.sh can run them in a stock Godot.


## A ROM's identity for per-game options: "<system>/<file name>". Not the card name, which
## changes when a same-named ROM appears (rom_names.gd).
static func rom_id(system: String, path: String) -> String:
	return system + "/" + path.get_file()


## Arguments for qforge-launch. fast_cores puts the emulator on the device's fast cores
## (qforge-launch --cpus big); off, nothing is pinned. An array, not a command line: a ROM path
## with spaces stays one argument.
static func for_rom(system: String, path: String, fast_cores: bool) -> PackedStringArray:
	var args := PackedStringArray()
	if fast_cores:
		args.append_array(["--cpus", "big"])
	args.append_array([system, path])
	return args
