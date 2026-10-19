extends "rom_watch.gd"

## Automatic rescan of the installed Steam games: rom_watch.gd's rules (a change counts once two
## polls in a row agree, never while a game runs), over the client's app manifests instead of
## ~/roms. A game installed or removed in Steam's UI shows in the library once Steam is closed (Steam
## is a running app while its UI is open). No OGUI types, as rom_watch.gd.

const SteamApps := preload("steam_apps.gd")

var steam_root: String


## Returns self: SteamWatch.new().watch_steam(root).
func watch_steam(root: String) -> RefCounted:
	steam_root = root
	return self


func snapshot() -> PackedStringArray:
	return SteamApps.snapshot(steam_root)
