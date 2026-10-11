extends ScrollContainer

## Settings > Emulators: the QForge emulator store (plan Phase 4, part 3).
##
## One block per catalog emulator: its name, who made it (author, homepage, licence and its link:
## the attribution every emulator's licence asks for), installed vs pinned version and size, and
## a button that is Download, Update or Open (the emulator's own UI, `qforge-launch --gui`), plus
## Delete once installed (a nightly entry -- catalog "channel": "nightly", Cemu -- adds an Update
## row instead: whether a newer build exists is only known online, so the button asks), and the player's "Run on fast cores" default for that emulator (every
## launch of it, Open included, unless a game overrides it). Everything else goes through /usr/bin/qforge-emu (list / install / remove);
## the page never downloads or verifies anything itself.
##
## Built in code on the pattern of OGUI's own settings pages (library_settings_menu.tscn): a
## StateWatcher on this page's State hands focus to the page's FocusGroup, and Back pops the
## settings state machine to return to the button list.

const EMU_TOOL := "/usr/bin/qforge-emu"
const LAUNCHER := "/usr/bin/qforge-launch"
const LaunchArgs := preload("launch_args.gd")
const Credits := preload("credits.gd")
const PROGRESS_POLL := 0.5  # s between download progress samples
const BLOCK_GAP := 24  # px between two emulators' blocks
const EXIT_TEXT := {
	3: "Download failed: check the network connection.",
	4: "The download did not match the version QForge tested; nothing was changed.",
	5: "Not enough free space, or the emulators folder is not writable.",
}

var settings_state_machine := load("res://assets/state/state_machines/settings_state_machine.tres") as StateMachine
var launch_manager := load("res://core/global/launch_manager.tres") as LaunchManager
var notification_manager := load("res://core/global/notification_manager.tres")
var section_scene := load("res://core/ui/components/section_label.tscn") as PackedScene
var row_scene := load("res://core/ui/components/card_button_setting.tscn") as PackedScene
var toggle_scene := load("res://core/ui/components/toggle.tscn") as PackedScene
var focus_group_scene := load("res://core/systems/input/focus_group.tscn") as PackedScene
var input_watcher_scene := load("res://core/systems/input/input_watcher.tscn") as PackedScene
var state_updater_scene := load("res://core/systems/state/state_updater.tscn") as PackedScene
var state_watcher_scene := load("res://core/systems/state/state_watcher.tscn") as PackedScene
var focus_group_setter_script := load("res://core/systems/input/focus_group_setter.gd") as GDScript

## The settings state this page owns; the plugin's Emulators button pushes it.
var state: State
var logger := Log.get_logger("QForgeEmulators", Log.LEVEL.INFO)
var _rows: VBoxContainer
var _focus_group: FocusGroup
var _busy := {}  # emulator id -> true while an install or remove runs
var _inside := false  # this page's state is the current one (it has the focus)


func setup(page_state: State) -> void:
	state = page_state
	name = "QForgeEmulatorsMenu"
	follow_focus = true
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL

	# Back returns to the settings button list.
	var back = input_watcher_scene.instantiate()
	back.stop_propagation = true
	back.action = "ogui_east"
	var pop = state_updater_scene.instantiate()
	pop.state_machine = settings_state_machine
	pop.action = 2  # StateUpdater.ACTION.POP
	pop.on_signal = "input_released"
	back.add_child(pop)
	add_child(back)

	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 5)
	add_child(margin)
	_rows = VBoxContainer.new()
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_child(_rows)
	_focus_group = focus_group_scene.instantiate() as FocusGroup
	_rows.add_child(_focus_group)

	# Entering this page's state gives it the focus.
	var watcher = state_watcher_scene.instantiate()
	watcher.state = state
	var setter: Node = focus_group_setter_script.new()
	setter.target = _focus_group
	setter.on_signal = "state_entered"
	watcher.add_child(setter)
	add_child(watcher)
	# Rows are rebuilt after every install / delete, which frees the focused one; while the page
	# is entered, refresh() hands the focus back.
	watcher.state_entered.connect(func(): _inside = true)
	watcher.state_exited.connect(func(): _inside = false)
	watcher.state_removed.connect(func(): _inside = false)
	# Fill the page whenever it is shown (focusing the Emulators button shows it).
	visibility_changed.connect(func():
		if is_visible_in_tree():
			refresh())


## Rebuild the rows from `qforge-emu list`.
func refresh() -> void:
	for child in _rows.get_children():
		if child != _focus_group:
			child.queue_free()
	await get_tree().process_frame
	var emus := _list()
	if emus.is_empty():
		_add_label("No emulator catalog found")
	var ids := emus.keys()
	ids.sort()
	for id in ids:
		_add_emulator(id, emus[id])
	_focus_group.current_focus = null
	_focus_group.recalculate_focus()
	if _inside:
		_focus_group.grab_focus()
	logger.info("Emulators page: %d emulator(s)" % emus.size())


func _list() -> Dictionary:
	var output: Array = []
	if OS.execute(EMU_TOOL, ["list"], output) != 0 or output.is_empty():
		logger.warn("qforge-emu list failed")
		return {}
	var parsed = JSON.parse_string(str(output[0]))
	if not parsed is Dictionary:
		return {}
	return parsed.get("emulators", {})


func _add_label(text: String) -> void:
	var label = section_scene.instantiate()
	label.text = text
	_rows.add_child(label)


func _add_credit(emu: Dictionary) -> void:
	var text := Credits.credit_text(emu)
	if text == "":
		return
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.modulate = Color(1, 1, 1, 0.7)
	_rows.add_child(label)


## One block per emulator: its name once (heading), who made it, then three rows -- the version
## with Download / Update / Open, the fast-cores default, and Delete once installed. Only the last
## row draws a separator, so a line marks where one emulator ends (OGUI's toggle draws one by
## default, which used to split a block in two), and a gap opens before the next heading.
func _add_emulator(id: String, emu: Dictionary) -> void:
	var name_text := str(emu.get("name", id))
	if _rows.get_child_count() > 1:  # the FocusGroup is always there
		var gap := Control.new()
		gap.custom_minimum_size = Vector2(0, BLOCK_GAP)
		_rows.add_child(gap)
	_add_label(name_text)
	_add_credit(emu)
	var size := int(emu.get("size", 0))
	var pinned := Credits.version_text(str(emu.get("pinned", "?")))
	var installed = emu.get("installed")
	var nightly: bool = emu.get("channel") == "nightly"
	var mb := size / 1048576

	var main = row_scene.instantiate()
	if installed == null:
		main.text = "Not installed"
		if nightly:
			main.description = "Latest nightly build, about %d MB. Not tested by QForge." % mb
		else:
			main.description = "Version %s, %d MB." % [pinned, mb]
		main.button_text = "Download"
		main.button_up.connect(_install.bind(id, name_text, str(emu.get("pinned", "")), size, main, null))
	elif nightly:
		main.text = Credits.version_text(str(installed))
		main.description = "Installed. Nightly builds come straight from upstream, untested by QForge."
		main.button_text = "Open"
		main.button_up.connect(_open.bind(id, name_text))
	elif emu.get("update", false):
		main.text = "Version " + Credits.version_text(str(installed))
		main.description = "Update to %s available, %d MB." % [pinned, mb]
		main.button_text = "Update"
		main.button_up.connect(_install.bind(id, name_text, str(emu.get("pinned", "")), size, main, installed))
	else:
		main.text = "Version " + Credits.version_text(str(installed))
		# PortMaster (catalog "self_update"): it offers its own updates when opened.
		main.description = "Installed. Updates itself: open it to check." if emu.get("self_update", false) else "Installed."
		main.button_text = "Open"
		main.button_up.connect(_open.bind(id, name_text))
	main.separator_visible = false
	_rows.add_child(main)
	if _busy.has(id):
		main.disabled = true

	var fast = toggle_scene.instantiate()
	fast.text = "Run on fast cores"
	fast.description = "Games can override this in their own settings."
	fast.button_pressed = LaunchArgs.emulator_fast_cores(id)
	fast.separator_visible = installed == null  # the block's last row when there is no Delete
	fast.toggled.connect(_set_fast_cores.bind(id, name_text, fast))
	_rows.add_child(fast)

	if installed != null and nightly:
		var update = row_scene.instantiate()
		update.text = "Newer nightly"
		update.description = "Looks for a newer nightly build and installs it (about %d MB)." % mb
		update.button_text = "Update"
		update.separator_visible = false
		update.button_up.connect(_install.bind(id, name_text, str(emu.get("pinned", "")), size, update, installed))
		_rows.add_child(update)
		if _busy.has(id):
			update.disabled = true

	if installed != null:
		var remove = row_scene.instantiate()
		remove.text = "Delete"
		remove.description = "Removes the emulator. Its settings, saves and states are kept."
		remove.button_text = "Delete"
		remove.separator_visible = true
		remove.button_up.connect(_remove.bind(id, name_text, remove))
		_rows.add_child(remove)


## `previous` is the installed build (null for a first download): a nightly Update that finds the
## same build changes nothing, and says so.
func _install(id: String, name_text: String, tag: String, size: int, row: Control, previous: Variant) -> void:
	if _busy.has(id):
		return
	_busy[id] = true
	row.disabled = true
	row.description = "Downloading..."
	var cmd := Command.create(EMU_TOOL, ["install", id])
	if cmd.execute() != OK:
		_busy.erase(id)
		_notify("Could not start the download of " + name_text)
		refresh()
		return
	# Progress from the size of qforge-emu's hidden .part file.
	var part := OS.get_environment("HOME").path_join("emulators/%s/.%s.AppImage.part" % [id, tag])
	var poll := Timer.new()
	poll.wait_time = PROGRESS_POLL
	add_child(poll)
	poll.timeout.connect(_show_progress.bind(part, size, row))
	poll.start()
	var code := await cmd.finished as int
	poll.queue_free()
	_busy.erase(id)
	if code == 0 and previous != null and _installed(id) == previous:
		_notify(name_text + " is up to date")
	elif code == 0:
		_notify(name_text + " installed")
	else:
		logger.warn("qforge-emu install %s exited %d: %s" % [id, code, cmd.stderr])
		_notify(EXIT_TEXT.get(code, "Installing %s failed." % name_text))
	refresh()


## The build `qforge-emu list` reports as installed for `id`, or null.
func _installed(id: String) -> Variant:
	return _list().get(id, {}).get("installed")


func _show_progress(part: String, size: int, row: Control) -> void:
	if size <= 0 or not is_instance_valid(row):
		return
	var f := FileAccess.open(part, FileAccess.READ)
	if f:
		row.description = "Downloading %d%%" % mini(99, f.get_length() * 100 / size)


func _remove(id: String, name_text: String, row: Control) -> void:
	if _busy.has(id):
		return
	var dialog := get_tree().get_first_node_in_group("dialog") as Dialog
	if dialog:
		dialog.open(row, "Delete %s?\nIts settings, saves and states are kept." % name_text, "Delete", "Cancel")
		if not await dialog.choice_selected:
			return
	_busy[id] = true
	var cmd := Command.create(EMU_TOOL, ["remove", id])
	var code := -1
	if cmd.execute() == OK:
		code = await cmd.finished as int
	_busy.erase(id)
	_notify(name_text + (" deleted" if code == 0 else " could not be deleted"))
	refresh()


## The Toggle only emits on the player's input: this never fires while the rows are built.
func _set_fast_cores(on: bool, id: String, name_text: String, toggle: Control) -> void:
	if LaunchArgs.set_emulator_fast_cores(id, on):
		logger.info("%s: fast cores by default %s" % [id, "on" if on else "off"])
		return
	logger.warn("could not write " + LaunchArgs.player_conf_path(id))
	_notify("Could not save the fast cores setting of " + name_text)
	toggle.button_pressed = not on  # back to what is saved (the setter does not emit toggled)


## The emulator's own UI, launched like a game so OGUI's overlay and Exit work.
func _open(id: String, name_text: String) -> void:
	var item := LibraryLaunchItem.new()
	item.name = name_text
	item.command = LAUNCHER
	item.args = PackedStringArray(["--gui", id])
	item.installed = true
	item._provider_id = "qforge-roms"  # its EXIT hook reports a missing emulator
	launch_manager.launch(item)


func _notify(text: String) -> void:
	var note := Notification.new(text)
	notification_manager.show(note)
