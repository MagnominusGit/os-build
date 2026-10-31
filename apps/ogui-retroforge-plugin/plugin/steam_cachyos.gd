extends RefCounted
## Apps > Steam Client > "CachyOS Proton arm64": Proton-CachyOS's arm64 build, downloaded when the player
## presses Download (Update once installed). /usr/bin/retroforge-steam-cachyos installs it as a user unit
## and waits for it, so the download goes on if OGUI restarts. Its progress is the percentage
## steam-compat-tools writes to ~/.local/share/retroforge/steam-compat-tools.progress, read here while
## the command runs (looked up on every tick: Apps > Steam Client builds new rows at each visit).
## Nothing selects the tool and DXVK-Sarek is not turned on in it: the player picks it per game in
## Steam (Properties > Compatibility). Not shown on ARMv8.0 CPUs (the command answers armv8): those
## take our ARMv8.0 Proton, the Proton row.

const TOOL := "/usr/bin/retroforge-steam-cachyos"
const TITLE := "CachyOS Proton arm64"
const POLL := 0.5  # s between progress samples

var notification_manager := load("res://core/global/notification_manager.tres")
var row_scene := load("res://core/ui/components/card_button_setting.tscn") as PackedScene
var logger := Log.get_logger("RetroForgeCachyOS", Log.LEVEL.INFO)
var tree: SceneTree
var _row: Control  # OGUI CardButtonSetting
var _running := false
var _shown := ""  # the row's text while a download runs


func setup(scene_tree: SceneTree) -> RefCounted:
	tree = scene_tree
	return self


## Add the row at the end of box (Apps > Steam Client's rows). False on an ARMv8.0 CPU, or when the
## command is missing.
func attach(box: Node) -> bool:
	if not box or not FileAccess.file_exists(TOOL):
		return false
	var now := status()
	if now == "" or now == "armv8":
		return false
	_row = row_scene.instantiate()
	_row.name = "RetroForgeSteamCachyOS"
	_row.text = TITLE
	_row.separator_visible = false
	_label(now)
	box.add_child(_row)
	_row.disabled = _running
	_row.button_up.connect(_install)
	return true


func detach() -> void:
	if is_instance_valid(_row):
		_row.queue_free()


## What retroforge-steam-cachyos reports: armv8, missing or "installed <tag>" ("" when it cannot run).
func status() -> String:
	var output: Array = []
	if OS.execute(TOOL, ["status"], output) != 0 or output.is_empty():
		return ""
	return str(output[0]).strip_edges()


## The row's description and button for `now` (status()), or the download's progress while it runs.
func _label(now: String) -> void:
	if not is_instance_valid(_row):
		return
	if _running:
		_row.description = _shown
		return
	if now.begins_with("installed "):
		_row.description = "Installed: %s. Select it for a game in Steam: Properties > Compatibility." % now.trim_prefix("installed ")
		_row.button_text = "Update"
	else:
		_row.description = "Proton-CachyOS for Windows games, a 356 MB download. Once installed, select it for a game in Steam: Properties > Compatibility."
		_row.button_text = "Download"


func _progress(text: String) -> void:
	_shown = text
	_label("")


func _progress_file() -> String:
	var data := OS.get_environment("XDG_DATA_HOME")
	if data.is_empty():
		data = OS.get_environment("HOME").path_join(".local/share")
	return data.path_join("retroforge/steam-compat-tools.progress")


## steam-compat-tools' progress file: a percentage while it downloads, `unpacking` after.
func _poll() -> void:
	var f := FileAccess.open(_progress_file(), FileAccess.READ)
	if not f:
		return
	var text := f.get_as_text().strip_edges()
	if text == "unpacking":
		_progress("Installing...")
	elif text.is_valid_int():
		_progress("Downloading %d%%" % clampi(int(text), 0, 99))


func _poll_while_running() -> void:
	while _running:
		await tree.create_timer(POLL).timeout
		if _running:
			_poll()


## Download / Update: `retroforge-steam-cachyos install`, polled for its progress until it ends. An
## Update that found nothing newer leaves the same release installed.
func _install() -> void:
	if _running:
		return
	var before := status()
	_running = true
	if is_instance_valid(_row):
		_row.disabled = true
	_progress("Checking for the newest release...")
	var code := -1
	var cmd := Command.create(TOOL, ["install"])
	if cmd.execute() == OK:
		_poll_while_running()  # not awaited: runs beside the command
		code = await cmd.finished as int
	_running = false
	var now := status()
	if code == 0 and now.begins_with("installed ") and now == before:
		_notify(TITLE + " is up to date")
	elif code == 0 and now.begins_with("installed "):
		_notify(TITLE + " installed. Restart Steam, then select it for a game: Properties > Compatibility.")
	else:
		logger.warn("retroforge-steam-cachyos install exited %d (now %s): %s" % [code, now, cmd.stderr])
		_notify("Could not download %s. Check the network connection." % TITLE)
	if is_instance_valid(_row):
		_row.disabled = false
	_label(now)


func _notify(text: String) -> void:
	notification_manager.show(Notification.new(text))
