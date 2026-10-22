extends RefCounted
## Settings > General > "Steam: keep running between games": the player's setting, kept by
## /usr/bin/retroforge-steam-keep (KEEP_RUNNING=on|off in ~/.config/retroforge/steam.conf), which
## /usr/bin/steam reads at every launch. Off (the default), Steam starts with each game and OGUI stops
## it when the game ends. On, the first launch leaves Steam running as a user unit and later games are
## handed to it, so they start without Steam's cold start (~18 s of a ~30 s launch). Turning it off
## stops a kept Steam that runs no game; one that does stops when the game ends. The command decides
## all of that, so the toggle only shows what `retroforge-steam-keep status` says and runs `on` / `off`.

const TOOL := "/usr/bin/retroforge-steam-keep"

var notification_manager := load("res://core/global/notification_manager.tres")
var toggle_scene := load("res://core/ui/components/toggle.tscn") as PackedScene
var logger := Log.get_logger("RetroForgeSteamKeep", Log.LEVEL.INFO)
var tree: SceneTree
var _toggle: Control  # OGUI Toggle


func setup(scene_tree: SceneTree) -> RefCounted:
	tree = scene_tree
	return self


## Add the toggle under Settings > General, after the DXVK-Sarek one. False when the layout differs or
## the command is missing.
func attach(target: Node = null) -> bool:  # target: the Settings > Steam page (steam_settings.gd)
	var menu: Node = tree.root.find_child("GeneralSettings", true, false)
	var box: Node = target if target else (menu.get_node_or_null("MarginContainer/VBoxContainer/VBoxContainer") if menu else null)
	if not box or not FileAccess.file_exists(TOOL):
		return false
	var after: Node = null
	for name in ["RetroForgeSteamSarek", "RetroForgePauseInMenus", "AnimatedEffectsToggle"]:
		after = box.get_node_or_null(name)
		if after:
			break
	_toggle = toggle_scene.instantiate()
	_toggle.name = "RetroForgeSteamKeep"
	_toggle.text = "Steam: keep running between games"
	_toggle.description = "Steam games start faster after the first one. Steam stays in memory between games."
	_toggle.separator_visible = false  # as the rows above it; read in _ready, so before add_child
	box.add_child(_toggle)
	if after:
		box.move_child(_toggle, after.get_index() + 1)
	_toggle.button_pressed = status() == "on"
	_toggle.toggled.connect(_on_toggled)
	return true


func detach() -> void:
	if is_instance_valid(_toggle):
		_toggle.queue_free()


## What retroforge-steam-keep reports: "on" or "off" ("" when it cannot run).
func status() -> String:
	var output: Array = []
	if OS.execute(TOOL, ["status"], output) != 0 or output.is_empty():
		return ""
	return str(output[0]).strip_edges()


## The Toggle only emits on the player's input: this never fires while it is built. The command
## runs without blocking the UI (`off` may stop Steam); a failure puts the toggle back to what is
## saved and says so.
func _on_toggled(on: bool) -> void:
	var want := "on" if on else "off"
	var cmd := Command.create(TOOL, [want])
	var code := -1
	if cmd.execute() == OK:
		code = await cmd.finished as int
	var now := status()
	if code == 0 and now == want:
		logger.info("keep Steam running " + want)
		return
	logger.warn("retroforge-steam-keep %s exited %d (now %s): %s" % [want, code, now, cmd.stderr])
	_notify("Could not turn keeping Steam running " + want)
	if is_instance_valid(_toggle):
		_toggle.button_pressed = now == "on"  # the setter does not emit toggled


func _notify(text: String) -> void:
	notification_manager.show(Notification.new(text))
