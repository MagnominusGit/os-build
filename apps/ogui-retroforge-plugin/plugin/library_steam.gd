extends Library

## The player's Steam games: every game the account owns, installed or not, from the Steam client
## they signed into (/usr/lib/retroforge/steam-library reads its caches), without the second sign-in
## the OGUI Steam plugin needs (steamcmd). An installed game launches as that plugin starts it,
## `steam ... -silent steam://rungameid/<appid>`: OGUI takes the Steam app id from that argument
## (LibraryLaunchItem.get_app_id), so gamescope focuses the game's window, and runs its Steam
## handling (RunningApp.is_steam_app).
##
## A game that is not installed gets OGUI's Install, and an installed one Uninstall: both are handed
## to Steam (steam://install/<appid>, steam://uninstall/<appid>), whose own dialog opens in Big
## Picture, started as Main menu > Emulators > Steam Client starts it. The game's app manifest then
## says how the download goes (install_progressed) and when it is done. Steam downloads while it
## runs: closing Steam before the end ends the install here as failed, and Steam carries on with it
## at its next start.

const SteamApps := preload("steam_apps.gd")
const RomNames := preload("rom_names.gd")
const HELPER := "/usr/lib/retroforge/steam-library"
## s between two looks at an install's app manifest.
const POLL := 2.0
## s Steam has to come up after an install or uninstall is handed to it.
const STEAM_START := 90.0

var launch_manager := load("res://core/global/launch_manager.tres") as LaunchManager


# Set in _ready, not _init: overriding _init skips Library._init, which is what registers the
# library with the LibraryManager (on ready). Ready handlers run before ready is emitted.
func _ready() -> void:
	library_id = "retroforge-steam"
	store_id = "retroforge"
	supports_uninstall = true
	logger = Log.get_logger("RetroForgeSteam", Log.LEVEL.INFO)


func steam_root() -> String:
	return SteamApps.steam_root()


func get_library_launch_items() -> Array[LibraryLaunchItem]:
	var games := await _games()
	var items: Array[LibraryLaunchItem] = []
	var installed := 0
	for game in games:
		items.append(_launch_item(game))
		installed += 1 if game["installed"] else 0
	_drop_stale(items)
	logger.info("Found %d Steam game(s), %d installed" % [items.size(), installed])
	return items


## steam-library's games, run on a worker thread: on a large account it reads tens of MB.
func _games() -> Array:
	var out := []
	var task := WorkerThreadPool.add_task(func() -> void:
		var output: Array = []
		out.append(OS.execute(HELPER, [], output))
		out.append("".join(output)))
	while not WorkerThreadPool.is_task_completed(task):
		await get_tree().process_frame
	WorkerThreadPool.wait_for_task_completion(task)
	if out.size() < 2 or out[0] != 0:
		logger.warn("%s failed (exit %s)" % [HELPER, out[0] if out.size() > 0 else "?"])
		return []
	return SteamApps.parse_library(out[1])


## OGUI's load_library only ever adds: remove our cards whose game is gone (a refund, a license
## removed), or whose install state changed, before LibraryManager adds this scan's items (deferred).
func _drop_stale(items: Array[LibraryLaunchItem]) -> void:
	var wanted := {}
	for item in items:
		wanted[item.name] = "%s %s" % [item.provider_app_id, item.installed]
	var current := {}
	for app in library_manager.get_library_items([]):
		var launch := app.get_launch_item(library_id)
		if launch:
			current[app.name] = "%s %s" % [launch.provider_app_id, launch.installed]
	for name in RomNames.stale(current, wanted):
		logger.info("Steam game changed or gone: " + name)
		library_manager.remove_library_launch_item(library_id, name)


func _launch_item(game: Dictionary) -> LibraryLaunchItem:
	var item := LibraryLaunchItem.new()
	item.name = game["name"]
	item.provider_app_id = str(game["appid"])
	item.command = "steam"
	item.args = SteamApps.launch_args(game["appid"])
	item.tags = PackedStringArray(["retroforge", "steam"])
	item.categories = PackedStringArray(["game"])
	item.installed = game["installed"]
	item.metadata = {"steam_app": game["appid"], "dir": game["dir"]}
	return item


## OGUI's Install (Library.install_to calls this).
func install(item: LibraryLaunchItem) -> void:
	install_completed.emit(item, await _through_steam(item, "install"))


func uninstall(item: LibraryLaunchItem) -> void:
	uninstall_completed.emit(item, await _through_steam(item, "uninstall"))


## Hand an install or uninstall to Steam and follow the game's app manifest until it is done: true,
## or false once Steam has closed (or never came up) first.
func _through_steam(item: LibraryLaunchItem, verb: String) -> bool:
	var appid := item.provider_app_id.to_int()
	logger.info("%s: %s through Steam" % [item.name, verb])
	var steam := LibraryLaunchItem.new()
	steam.name = "Steam"
	steam.command = "steam"
	steam.args = SteamApps.ui_args("steam://%s/%d" % [verb, appid])
	steam.installed = true
	steam._provider_id = ""
	launch_manager.launch(steam)
	var root := SteamApps.steam_root()
	var waited := 0.0
	var steam_seen := false
	while true:
		await get_tree().create_timer(POLL).timeout
		waited += POLL
		var state := SteamApps.app_state(root, appid)
		if verb == "install" and not state.is_empty():
			if state["total"] > 0:
				install_progressed.emit(item, clampf(float(state["done"]) / state["total"], 0.0, 1.0))
			if SteamApps.install_complete(state["flags"]):
				return true
		elif verb == "uninstall" and state.is_empty():
			return true
		var running := _steam_running()
		steam_seen = steam_seen or running
		if (steam_seen and not running) or (not steam_seen and waited > STEAM_START):
			logger.info("%s: Steam closed before the %s was done" % [item.name, verb])
			return false
	return false


## True while Valve's client runs (a process named steam: /usr/bin/steam runs as bash).
func _steam_running() -> bool:
	return OS.execute("pgrep", ["-x", "steam"]) == 0
