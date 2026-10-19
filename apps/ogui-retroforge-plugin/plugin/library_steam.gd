extends Library

## The Steam games installed in the player's Steam client (steam_apps.gd), without the second
## sign-in the OGUI Steam plugin needs: one launch item per game, started as that plugin starts
## them, `steam ... -silent steam://rungameid/<appid>`. OGUI takes the Steam app id from that
## argument (LibraryLaunchItem.get_app_id), so gamescope focuses the game's window, and runs its
## Steam handling (RunningApp.is_steam_app). With the Steam plugin installed too, OGUI shows a game
## the two share as one card with both launch items.

const SteamApps := preload("steam_apps.gd")
const RomNames := preload("rom_names.gd")


# Set in _ready, not _init: overriding _init skips Library._init, which is what registers the
# library with the LibraryManager (on ready). Ready handlers run before ready is emitted.
func _ready() -> void:
	library_id = "retroforge-steam"
	store_id = "retroforge"
	supports_uninstall = false
	logger = Log.get_logger("RetroForgeSteam", Log.LEVEL.INFO)


func steam_root() -> String:
	return SteamApps.steam_root()


func get_library_launch_items() -> Array[LibraryLaunchItem]:
	var items: Array[LibraryLaunchItem] = []
	for game in SteamApps.installed(steam_root()):
		items.append(_launch_item(game))
	_drop_stale(items)
	logger.info("Found %d installed Steam game(s)" % items.size())
	return items


## OGUI's load_library only ever adds: remove our cards whose game was uninstalled, before
## LibraryManager adds this scan's items (deferred).
func _drop_stale(items: Array[LibraryLaunchItem]) -> void:
	var wanted := {}
	for item in items:
		wanted[item.name] = item.provider_app_id
	var current := {}
	for app in library_manager.get_library_items([]):
		var launch := app.get_launch_item(library_id)
		if launch:
			current[app.name] = launch.provider_app_id
	for name in RomNames.stale(current, wanted):
		logger.info("Steam game uninstalled: " + name)
		library_manager.remove_library_launch_item(library_id, name)


func _launch_item(game: Dictionary) -> LibraryLaunchItem:
	var item := LibraryLaunchItem.new()
	item.name = game["name"]
	item.provider_app_id = str(game["appid"])
	item.command = "steam"
	item.args = SteamApps.launch_args(game["appid"])
	item.tags = PackedStringArray(["retroforge", "steam"])
	item.categories = PackedStringArray(["game"])
	item.installed = true
	item.metadata = {"steam_app": game["appid"], "dir": game["dir"]}
	return item
