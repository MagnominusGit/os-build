extends RefCounted
## Apps > Steam Client > "Steam: DXVK-Sarek (low-end GPUs)": the player's DXVK-Sarek setting, kept by
## /usr/bin/retroforge-steam-sarek (DXVK_SAREK=on|off in ~/.config/retroforge/steam.conf), which /usr/bin/steam
## applies at every start. On: Proton-CachyOS's arm64 build is installed or updated in the background
## (a 356 MB download the first time) with its DXVK-Sarek turned on, the DXVK that still runs on the
## Adreno 610 once upstream DXVK stops. Off: nothing is downloaded, and Sarek is turned off in an
## installed one. Never set, it is on for the SM6115 only. The command decides all of that, so the
## toggle only shows what `retroforge-steam-sarek status` says and runs `on` / `off`.

const TOOL := "/usr/bin/retroforge-steam-sarek"

var notification_manager := load("res://core/global/notification_manager.tres")
var toggle_scene := load("res://core/ui/components/toggle.tscn") as PackedScene
var logger := Log.get_logger("RetroForgeSarek", Log.LEVEL.INFO)
var tree: SceneTree
var _toggle: Control  # OGUI Toggle


func setup(scene_tree: SceneTree) -> RefCounted:
	tree = scene_tree
	return self


## Add the toggle to target (Apps > Steam Client), else under Settings > General after "Pause game in
## menus". False when the layout differs or the command is missing.
func attach(target: Node = null) -> bool:  # target: Apps > Steam Client's rows (apps_page.gd)
	var menu: Node = tree.root.find_child("GeneralSettings", true, false)
	var box: Node = target if target else (menu.get_node_or_null("MarginContainer/VBoxContainer/VBoxContainer") if menu else null)
	if not box or not FileAccess.file_exists(TOOL):
		return false
	var after: Node = box.get_node_or_null("RetroForgePauseInMenus")
	if not after:
		after = box.get_node_or_null("AnimatedEffectsToggle")
	_toggle = toggle_scene.instantiate()
	_toggle.name = "RetroForgeSteamSarek"
	_toggle.text = "Steam: DXVK-Sarek (low-end GPUs)"
	_toggle.description = "Installs Proton-CachyOS (356 MB) with DXVK-Sarek for Windows games. Select it for a game in Steam."
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


## What retroforge-steam-sarek reports: "on" or "off" ("" when it cannot run).
func status() -> String:
	var output: Array = []
	if OS.execute(TOOL, ["status"], output) != 0 or output.is_empty():
		return ""
	return str(output[0]).strip_edges()


## The Toggle only emits on the player's input: this never fires while it is built. The command
## runs without blocking the UI; a failure puts the toggle back to what is saved and says so.
func _on_toggled(on: bool) -> void:
	var want := "on" if on else "off"
	var cmd := Command.create(TOOL, [want])
	var code := -1
	if cmd.execute() == OK:
		code = await cmd.finished as int
	var now := status()
	if code == 0 and now == want:
		logger.info("DXVK-Sarek " + want)
		if on:
			_notify("DXVK-Sarek on: Proton-CachyOS installs in the background. Restart Steam, then select it for a game.")
		return
	logger.warn("retroforge-steam-sarek %s exited %d (now %s): %s" % [want, code, now, cmd.stderr])
	_notify("Could not turn DXVK-Sarek " + want)
	if is_instance_valid(_toggle):
		_toggle.button_pressed = now == "on"  # the setter does not emit toggled


func _notify(text: String) -> void:
	notification_manager.show(Notification.new(text))
