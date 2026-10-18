extends OSPlatform
## RetroForge's OS platform: Settings > General > Updates drives /usr/bin/retroforge-update (plan
## ota-ui Phase 2), in place of OGUI's own updater, which only knows OGUI's x86 update.zip.
##
## OGUI picks its OS platform from a fixed list of os-release IDs (core/global/platform.gd) that
## has no `retroforge`, and calls ready(root) from card_ui's _ready, before plugins load. So
## plugin.gd installs this as platform.os and calls ready() itself, as Platform.load() would have
## (core/platform/os/nixos.gd is the model).
##
## The section: one button walking Check for updates -> Install <version> (progress in its
## description) -> Restart now, and a Stable / Beta dropdown; switching never asks (plan ota-ui D3)
## and checks the new channel straight away. Nothing installs or restarts without a press (D2). An
## update already installed and waiting for a reboot shows Restart now from the start.

const UpdateStates := preload("update_states.gd")
const ScrapeRunner := preload("scrape_runner.gd")
const TOOL := "/usr/bin/retroforge-update"
const CHECK_TIMEOUT := 60.0  # s: the manifest fetch retries for at most ~30 s

var notification_manager := load("res://core/global/notification_manager.tres") as NotificationManager
var button_scene := load("res://core/ui/components/card_button_setting.tscn") as PackedScene
var dropdown_scene := load("res://core/ui/components/dropdown.tscn") as PackedScene
var section_scene := load("res://core/ui/components/section_label.tscn") as PackedScene

## Test seams (tests/test-plugin.sh runs this against OGUI's own settings scene and a fake client).
var tool := TOOL
var reboot_command: Array[String] = ["systemctl", "reboot"]

var _apply := ScrapeRunner.new()  # runs the install: `N%` lines on a worker thread
var _step := UpdateStates.Step.IDLE
var _running := ""  # this image's version
var _offered := ""  # the version check found, or the one staged
var _channels: Array[String] = []
var _button: Control  # card_button_setting
var _channel: Control  # dropdown
var _nodes: Array[Node] = []


## Called by plugin.gd once the settings menus exist. (No _init override: tests/test-plugin.sh
## forbids one in every plugin script.)
func ready(root: Window) -> void:
	logger = Log.get_logger("PlatformRetroForge", Log.LEVEL.INFO)
	name = "RetroForge"
	_apply.tool = tool
	_apply.progressed.connect(_on_install_progress)
	_apply.finished.connect(_on_install_finished)
	var menu: Node = root.find_child("GeneralSettings", true, false)
	var box: Node = menu.get_node_or_null("MarginContainer/VBoxContainer/VBoxContainer") if menu else null
	if not box:
		logger.warn("OGUI general settings layout not found; no Updates section")
		return
	_remove_ogui_updater(menu, box)
	if FileAccess.file_exists(tool):
		_add_updater(box)


func detach() -> void:
	for node in _nodes:
		if is_instance_valid(node):
			node.queue_free()
	_nodes.clear()


## OGUI's updater fetches OGUI's x86 update.zip (the session runs it with --skip-update-pack): its
## auto-update toggle, buttons, timer and SoftwareUpdater go, as nixos.gd removes them. The menu's
## script keeps references to them, so those are cleared too.
func _remove_ogui_updater(menu: Node, box: Node) -> void:
	for path in ["SoftwareUpdater", "UpdateTimer"]:
		var node := menu.get_node_or_null(path)
		if node:
			node.queue_free()
	for path in ["AutoUpdateToggle", "CheckUpdateButton", "UpdateButton"]:
		var node := box.get_node_or_null(path)
		if node:
			node.queue_free()
	for property in ["updater", "update_timer", "auto_update_toggle", "check_update_button", "update_button"]:
		if property in menu:
			menu.set(property, null)


func _add_updater(box: Node) -> void:
	var label: Node = box.get_node_or_null("UpdatesLabel")
	if not label:
		label = section_scene.instantiate()
		label.text = "Updates"
		box.add_child(label)
		box.move_child(label, 0)
		_nodes.append(label)
	_button = button_scene.instantiate()
	_button.name = "RetroForgeUpdateButton"
	_button.text = "System update"
	_button.button_up.connect(_on_button)
	_channel = dropdown_scene.instantiate()
	_channel.name = "RetroForgeUpdateChannel"
	_channel.title = "Update channel"
	# In the tree FIRST: a component's @onready children only exist once it is ready, and OGUI is a
	# release export, where calling a method on such a null child segfaults instead of erroring
	# (see scraper_settings.gd).
	var at := label.get_index() + 1
	for node in [_button, _channel]:
		box.add_child(node)
		box.move_child(node, at)
		at += 1
		_nodes.append(node)
	var focus_group = box.get_node_or_null("FocusGroup")
	if focus_group:
		focus_group.current_focus = _button  # was OGUI's auto-update toggle, now freed
	_running = _run(["version"]).strip_edges()
	_fill_channels()
	_channel.item_selected.connect(_on_channel_selected)
	_show()
	_restore_staged()


## Run a local subcommand synchronously (no network); its stdout, "" on failure.
func _run(args: Array) -> String:
	var out := []
	return str(out[0]) if OS.execute(tool, args, out) == 0 and not out.is_empty() else ""


func _fill_channels() -> void:
	var listed := UpdateStates.parse_channels(_run(["channels"]))
	var current := UpdateStates.parse_channel(_run(["channel"]))
	_channels = listed["channels"]
	_channel.clear()  # dropdown.tscn ships one placeholder item
	for i in _channels.size():
		_channel.add_item(UpdateStates.channel_name(_channels[i]))
		if _channels[i] == current:
			_channel.select(i)
	_channel.description = UpdateStates.channel_description(listed["pinned"])
	_channel.set_meta("pinned", listed["pinned"] != "")


func _show(percent := 0) -> void:
	if not is_instance_valid(_button):
		return
	var shown := UpdateStates.button_for(_step, _running, _offered, percent)
	_button.button_text = shown["button"]
	_button.description = shown["description"]
	_button.disabled = shown["disabled"]
	var busy := _step in [UpdateStates.Step.CHECKING, UpdateStates.Step.INSTALLING]
	_channel.disabled = busy or bool(_channel.get_meta("pinned", false))


## A session restarted after an install (OGUI crash, logout) still has the update waiting.
func _restore_staged() -> void:
	var cmd := Command.create(tool, ["staged"])
	if cmd.execute() != OK or (await cmd.finished) != 0:
		return
	if _step == UpdateStates.Step.IDLE:
		_offered = cmd.stdout.strip_edges()
		_step = UpdateStates.Step.STAGED
		_show()


func _on_button() -> void:
	match _step:
		UpdateStates.Step.IDLE:
			check()
		UpdateStates.Step.AVAILABLE:
			_install()
		UpdateStates.Step.STAGED:
			_restart()


## Ask the channel's server for a newer version. True when one is available (or already staged).
func check() -> bool:
	if _step in [UpdateStates.Step.CHECKING, UpdateStates.Step.INSTALLING]:
		return false
	if _step == UpdateStates.Step.STAGED:
		return true
	_step = UpdateStates.Step.CHECKING
	_show()
	var cmd := Command.create(tool, ["check"])
	cmd.timeout = CHECK_TIMEOUT
	var code := -1
	if cmd.execute() == OK:
		code = await cmd.finished as int
	var offered := cmd.stdout.strip_edges()
	if code == 0 and offered != "":
		_offered = offered
		# check reprints an update that is already installed: Restart, not Install again.
		var staged := Command.create(tool, ["staged"])
		var is_staged: bool = staged.execute() == OK and (await staged.finished) == 0
		_step = UpdateStates.Step.STAGED if is_staged else UpdateStates.Step.AVAILABLE
	else:
		# Exit 7 is also how every failure ends (no network, a bad manifest): the client fails closed.
		_step = UpdateStates.Step.IDLE
		if code != 7:
			logger.warn("retroforge-update check exited %d: %s" % [code, cmd.stderr])
	_show()
	if _step == UpdateStates.Step.IDLE:
		_button.description = "No update found on the %s channel." % UpdateStates.channel_name(_current_channel())
	return _step != UpdateStates.Step.IDLE


func _install() -> void:
	if not _apply.start([]):
		return
	_step = UpdateStates.Step.INSTALLING
	_show()


func _on_install_progress(percent: int) -> void:
	if _step == UpdateStates.Step.INSTALLING:
		_show(percent)


func _on_install_finished(code: int, _summary: Dictionary, error: String) -> void:
	if code == 0:
		_step = UpdateStates.Step.STAGED
		_show()
		_notify("RetroForge %s is installed. Restart to use it." % _offered)
		return
	logger.warn("retroforge-update exited %d: %s" % [code, error])
	_step = UpdateStates.Step.IDLE
	_show()
	_button.description = "The update could not be installed. Check the network and try again."
	_notify("The RetroForge update could not be installed")


func _on_channel_selected(index: int) -> void:
	if index < 0 or index >= _channels.size():
		return
	var cmd := Command.create(tool, ["set-channel", _channels[index]])
	if cmd.execute() != OK or (await cmd.finished) != 0:
		logger.warn("retroforge-update set-channel %s failed: %s" % [_channels[index], cmd.stderr])
		_notify("Could not change the update channel")
		_fill_channels()
		return
	logger.info("update channel: " + _channels[index])
	if _step == UpdateStates.Step.AVAILABLE:
		_step = UpdateStates.Step.IDLE  # that offer was the other channel's
	check()


## As OGUI's power menu reboots (power_menu.gd): systemctl as the session user.
func _restart() -> void:
	logger.info("restarting into RetroForge " + _offered)
	var output := []
	if OS.execute(reboot_command[0], PackedStringArray(reboot_command.slice(1)), output, true) != OK:
		logger.warn("%s failed: %s" % [" ".join(reboot_command), output])
		_notify("Could not restart. Use the power menu to restart.")


func _current_channel() -> String:
	return UpdateStates.parse_channel(_run(["channel"]))


func _notify(text: String) -> void:
	notification_manager.show(Notification.new(text))
