extends Library
## The player's GOG or Epic games (.claude/plans/stores.plan.md): every game the account owns,
## installed or not, from `store <gog|epic> games`. One instance per store, `store` set before it is
## added. An installed game launches as `store <s> launch <id>`, which syncs its cloud saves around the
## game and runs it through our Proton. Install and Uninstall run the store's tool through `store`,
## with its progress on the card (install_progressed). Signed out, the library is empty.

const Runner := preload("store_runner.gd")
const Spawn := preload("spawn.gd")
const TOOL := "/usr/lib/retroforge/store"
const TITLES := {"gog": "GOG", "epic": "Epic Games"}
## `store games`' art keys, by OGUI BoxArtProvider.LAYOUT (as steam_apps.gd ART).
const ART_KEYS := ["portrait", "landscape", "hero", "logo"]
## s before art that could not be fetched is tried again.
const ART_RETRY := 86400

var store := "gog"
var tool := TOOL
var launch_manager := load("res://core/global/launch_manager.tres") as LaunchManager
var notification_manager := load("res://core/global/notification_manager.tres")
var _installs := {}  # provider_app_id -> Runner


# Set in _ready, not _init: overriding _init skips Library._init, which is what registers the
# library with the LibraryManager (on ready). Ready handlers run before ready is emitted.
func _ready() -> void:
	library_id = "retroforge-" + store
	store_id = "retroforge"
	supports_uninstall = true
	logger = Log.get_logger("RetroForge" + store.capitalize(), Log.LEVEL.INFO)
	launch_manager.app_stopped.connect(_on_app_stopped)


## What `store launch` left for the player (a cloud save that did not sync), shown once its game has
## stopped: the launch's process ends after the upload, so this comes after it.
func _on_app_stopped(app: RunningApp) -> void:
	if not app.launch_item or app.launch_item._provider_id != library_id:
		return
	var data := OS.get_environment("XDG_DATA_HOME")
	if data == "":
		data = OS.get_environment("HOME").path_join(".local/share")
	var path := data.path_join("retroforge/stores/notices-" + store)
	if not FileAccess.file_exists(path):
		return
	for line in FileAccess.get_file_as_string(path).split("\n", false):
		notification_manager.show(Notification.new("%s: %s" % [app.launch_item.name, line]))
	DirAccess.remove_absolute(path)


func get_library_launch_items() -> Array[LibraryLaunchItem]:
	var items: Array[LibraryLaunchItem] = []
	if not FileAccess.file_exists(tool):
		return items
	var games := await _games()
	var installed := 0
	for game in games:
		if game is Dictionary and str(game.get("id", "")) != "" and str(game.get("title", "")) != "":
			items.append(launch_item(store, tool, game))
			installed += 1 if game.get("installed", false) else 0
	_drop_stale(items)
	logger.info("Found %d %s game(s), %d installed" % [items.size(), TITLES[store], installed])
	if not items.is_empty():
		Spawn.run(tool, [store, "art"])  # the covers into the cache before the cards ask (store's ART)
	return items


## `store <s> games` on a worker thread: it may ask the store's servers.
func _games() -> Array:
	var out := []
	var args := [store, "games"]
	var task := WorkerThreadPool.add_task(func() -> void:
		var output: Array = []
		out.append(OS.execute(tool, args, output))
		out.append("".join(output)))
	while not WorkerThreadPool.is_task_completed(task):
		await get_tree().process_frame
	WorkerThreadPool.wait_for_task_completion(task)
	if out.size() < 2 or out[0] != 0:
		if out.size() > 0 and out[0] != 3:  # 3: not signed in, an empty library
			logger.warn("store %s games failed (exit %s)" % [store, out[0] if out.size() > 0 else "?"])
		return []
	var data = JSON.parse_string(out[1])
	return data if data is Array else []


## OGUI's load_library only ever adds: remove our cards whose game is gone (signed out, a license
## removed), or whose install state changed, before LibraryManager adds this scan's items (deferred).
func _drop_stale(items: Array[LibraryLaunchItem]) -> void:
	var wanted := {}
	for item in items:
		wanted[item.name] = "%s %s" % [item.provider_app_id, item.installed]
	for app in library_manager.get_library_items([]):
		var launch := app.get_launch_item(library_id)
		if launch and wanted.get(app.name, "") != "%s %s" % [launch.provider_app_id, launch.installed]:
			logger.info("%s game changed or gone: %s" % [TITLES[store], app.name])
			library_manager.remove_library_launch_item(library_id, app.name)


static func launch_item(store_name: String, tool_path: String, game: Dictionary) -> LibraryLaunchItem:
	var item := LibraryLaunchItem.new()
	item.name = str(game["title"])
	item.provider_app_id = str(game["id"])
	item.command = tool_path
	item.args = PackedStringArray([store_name, "launch", str(game["id"])])
	item.tags = PackedStringArray(["retroforge", store_name])
	item.categories = PackedStringArray(["game"])
	item.installed = bool(game.get("installed", false))
	item.metadata = {"store": store_name, "art": game.get("art", {}), "dir": str(game.get("dir", ""))}
	return item


## OGUI's Install (Library.install_to calls this).
func install(item: LibraryLaunchItem) -> void:
	install_completed.emit(item, await _run(item, "install"))


func uninstall(item: LibraryLaunchItem) -> void:
	uninstall_completed.emit(item, await _run(item, "uninstall"))


## `store <s> <verb> <id>`, its progress on the card: true once it is done.
func _run(item: LibraryLaunchItem, verb: String) -> bool:
	if _installs.has(item.provider_app_id):
		return false
	var runner := Runner.new()
	runner.tool = tool
	_installs[item.provider_app_id] = runner
	runner.progressed.connect(func(pct: int) -> void: install_progressed.emit(item, pct / 100.0))
	logger.info("%s: %s from %s" % [item.name, verb, TITLES[store]])
	runner.start([store, verb, item.provider_app_id])
	var result: Array = await runner.finished
	_installs.erase(item.provider_app_id)
	var code: int = result[0]
	if code != 0:
		logger.warn("store %s %s %s exited %d: %s" % [store, verb, item.provider_app_id, code, result[1]])
		notification_manager.show(Notification.new("%s: %s" % [item.name, Runner.failure_text(TITLES[store], code, result[1])]))
	else:
		library_manager.load_library.call_deferred(library_id)  # the card's installed state
	return code == 0


## Where fetched art is kept: $XDG_CACHE_HOME/retroforge/store-art, else ~/.cache/...
static func art_cache_dir() -> String:
	var cache := OS.get_environment("XDG_CACHE_HOME")
	if cache == "":
		cache = OS.get_environment("HOME").path_join(".cache")
	return cache.path_join("retroforge/store-art")


## A store game's art for a layout, from the URL `store games` gave (already sized for it), kept in
## cache_dir/<store>/<id>/<key>-<url hash>, so a new URL is fetched anew: its path, or "" when there is
## none or it could not be fetched. Only an HTTP error (curl exit 22: the store has no such file) is
## not tried again for ART_RETRY; a timeout or a dropped connection is tried at the card's next ask.
## curl runs at a low priority, behind OGUI. Blocks for the download: call it off the main thread.
static func fetch_art(cache_dir: String, launch: LibraryLaunchItem, kind: int) -> String:
	if kind < 0 or kind >= ART_KEYS.size():
		return ""
	var url := str((launch.metadata.get("art", {}) as Dictionary).get(ART_KEYS[kind], ""))
	if not url.begins_with("https://"):
		return ""
	var dest := cache_dir.path_join(str(launch.metadata.get("store", ""))).path_join(launch.provider_app_id.validate_filename()).path_join(
		"%s-%s" % [ART_KEYS[kind], url.sha1_text().left(12)])
	if FileAccess.file_exists(dest):
		return dest
	var missing := dest + ".missing"
	if FileAccess.file_exists(missing) and Time.get_unix_time_from_system() - FileAccess.get_modified_time(missing) < ART_RETRY:
		return ""
	DirAccess.make_dir_recursive_absolute(dest.get_base_dir())
	var part := dest + ".part"
	var code := OS.execute("nice", ["-n", "10", "curl", "-fsSL", "--max-time", "20", "-o", part, url])
	if code == 0 and FileAccess.file_exists(part) and FileAccess.get_size(part) > 0:
		DirAccess.rename_absolute(part, dest)
		DirAccess.remove_absolute(missing)
		return dest
	DirAccess.remove_absolute(part)
	if code == 22:
		var mark := FileAccess.open(missing, FileAccess.WRITE)
		if mark:
			mark.close()
	return ""
