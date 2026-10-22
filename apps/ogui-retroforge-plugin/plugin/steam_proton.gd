extends RefCounted
## Settings > Steam > "Proton": the default Proton on ARMv8.0 CPUs (no LSE atomics, e.g. the SM6115), our
## ARMv8.0 build's stable or experimental channel, kept by /usr/bin/retroforge-steam-proton. Shown only on
## those CPUs: elsewhere the command answers "steam" and Steam's own default stays.

const TOOL := "/usr/bin/retroforge-steam-proton"
const CHANNELS := ["stable", "experimental"]

var notification_manager := load("res://core/global/notification_manager.tres")
var dropdown_scene := load("res://core/ui/components/dropdown.tscn") as PackedScene
var logger := Log.get_logger("RetroForgeSteamProton", Log.LEVEL.INFO)
var tree: SceneTree
var _dropdown: Control


func setup(scene_tree: SceneTree) -> RefCounted:
	tree = scene_tree
	return self


## Add the row at the top of box. False on a CPU with LSE atomics, or when the command is missing.
func attach(box: Node) -> bool:
	if not box or not FileAccess.file_exists(TOOL):
		return false
	var now := status()
	if not now in CHANNELS:
		return false
	_dropdown = dropdown_scene.instantiate()
	_dropdown.name = "RetroForgeSteamProton"
	_dropdown.title = "Proton"
	_dropdown.description = "Built for this CPU. Steam uses it for every game not set to another tool. Experimental follows Valve's Proton Experimental."
	box.add_child(_dropdown)
	box.move_child(_dropdown, 1)  # after the page's FocusGroup
	_dropdown.add_item("ARMv8.0 stable")
	_dropdown.add_item("ARMv8.0 experimental")
	_dropdown.select(CHANNELS.find(now))  # select() does not emit item_selected
	_dropdown.item_selected.connect(_on_selected)
	return true


func detach() -> void:
	if is_instance_valid(_dropdown):
		_dropdown.queue_free()


## What retroforge-steam-proton reports: stable, experimental or steam ("" when it cannot run).
func status() -> String:
	var output: Array = []
	if OS.execute(TOOL, ["status"], output) != 0 or output.is_empty():
		return ""
	return str(output[0]).strip_edges()


func _on_selected(index: int) -> void:
	var want: String = CHANNELS[index]
	var cmd := Command.create(TOOL, ["set", want])
	var code := -1
	if cmd.execute() == OK:
		code = await cmd.finished as int
	var now := status()
	if code == 0 and now == want:
		logger.info("Steam's Proton: " + want)
		return
	logger.warn("retroforge-steam-proton set %s exited %d (now %s): %s" % [want, code, now, cmd.stderr])
	notification_manager.show(Notification.new("Could not switch Steam's Proton to " + want))
	if is_instance_valid(_dropdown) and now in CHANNELS:
		_dropdown.select(CHANNELS.find(now))
