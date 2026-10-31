extends RefCounted
## Apps > Proton > "Channel": on ARMv8.0 CPUs (no LSE atomics, e.g. the SM6115), our ARMv8.0 build's stable
## or experimental channel, kept by /usr/bin/retroforge-steam-proton: Steam's default Proton and each
## Windows game's, and the one GOG and Epic games run with (steam-compat-tools reads the channel). Shown
## only on those CPUs: elsewhere the command answers "steam" and there is no channel to pick.

## The channel was switched: the tool row below installs the other build (proton_tool.gd install()).
signal changed

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


## Add the row at the end of box. False on a CPU with LSE atomics, or when the command is missing.
func attach(box: Node) -> bool:
	if not box or not FileAccess.file_exists(TOOL):
		return false
	var now := status()
	if not now in CHANNELS:
		return false
	_dropdown = dropdown_scene.instantiate()
	_dropdown.name = "RetroForgeSteamProton"
	_dropdown.title = "Channel"
	_dropdown.description = "Stable follows Valve's Proton releases, Experimental its Proton Experimental, rebuilt for this CPU."
	box.add_child(_dropdown)
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
		logger.info("Proton channel: " + want)
		changed.emit()
		return
	logger.warn("retroforge-steam-proton set %s exited %d (now %s): %s" % [want, code, now, cmd.stderr])
	notification_manager.show(Notification.new("Could not switch Proton to " + want))
	if is_instance_valid(_dropdown) and now in CHANNELS:
		_dropdown.select(CHANNELS.find(now))
