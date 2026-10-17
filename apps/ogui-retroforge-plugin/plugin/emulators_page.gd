extends ScrollContainer

## The right side of the Emulators screen (emulators_screen.gd): ONE catalog emulator at a time,
## the one focused in the screen's list (show_emulator).
##
## Its block: who made it (author, homepage, licence and its link:
## the attribution every emulator's licence asks for), installed vs tested version and size, and
## a button that is Download, Update or Open (the emulator's own UI, `retroforge-launch --gui`)
## -- emu_state.gd decides which, and the Revert / Install tested rows (plan emulator-latest) --, the
## player's choice for each of the emulator's options (options.json: renderer, resolution, aspect...;
## see emu_options.gd), the player's "Run on fast cores" default for that emulator (every launch of
## it, Open included, unless a game overrides it), and Delete once installed. Whether upstream has a
## newer build is only known online: `retroforge-emu check` runs in the background when an emulator
## is shown, and the rows are rebuilt when it answers (offline: no Update, no error). Everything
## else goes through /usr/bin/retroforge-emu (list / check / install / rollback / remove); the page
## never downloads or verifies anything itself.
##
## Built in code on the pattern of OGUI's own settings pages (library_settings_menu.tscn): a
## StateWatcher on this page's State hands focus to the page's FocusGroup, and Back pops the
## screen's state machine to return to the list.

const EMU_TOOL := "/usr/bin/retroforge-emu"
const LAUNCHER := "/usr/bin/retroforge-launch"
const LaunchArgs := preload("launch_args.gd")
const Credits := preload("credits.gd")
const EmuOptions := preload("emu_options.gd")
const EmuState := preload("emu_state.gd")
const PROGRESS_POLL := 0.5  # s between download progress samples
const CHECK_TIMEOUT := 60.0  # s a background `check` may take (two GitHub calls)
const EXIT_TEXT := {
	3: "Download failed: check the network connection.",
	4: "The download could not be verified; nothing was changed.",
	5: "Not enough free space, or the emulators folder is not writable.",
}

var launch_manager := load("res://core/global/launch_manager.tres") as LaunchManager
var notification_manager := load("res://core/global/notification_manager.tres")
var section_scene := load("res://core/ui/components/section_label.tscn") as PackedScene
var row_scene := load("res://core/ui/components/card_button_setting.tscn") as PackedScene
var toggle_scene := load("res://core/ui/components/toggle.tscn") as PackedScene
var dropdown_scene := load("res://core/ui/components/dropdown.tscn") as PackedScene
var focus_group_scene := load("res://core/systems/input/focus_group.tscn") as PackedScene
var input_watcher_scene := load("res://core/systems/input/input_watcher.tscn") as PackedScene
var state_updater_scene := load("res://core/systems/state/state_updater.tscn") as PackedScene
var state_watcher_scene := load("res://core/systems/state/state_watcher.tscn") as PackedScene
var focus_group_setter_script := load("res://core/systems/input/focus_group_setter.gd") as GDScript

## The state this page owns on the screen's state machine; A on a list entry pushes it.
var state: State
## `retroforge-emu list`'s emulators (id -> entry), read by load_catalog().
var catalog := {}
## The emulator shown ("" = none yet).
var emulator_id := ""
var logger := Log.get_logger("RetroForgeEmulators", Log.LEVEL.INFO)
var _rows: VBoxContainer
var _focus_group: FocusGroup
var _busy := {}  # emulator id -> true while an install or remove runs
var _inside := false  # this page's state is the current one (it has the focus)
var _generation := 0  # refresh() calls: only the latest one builds rows
var _checks := {}  # emulator id -> its `retroforge-emu check` answer ({"latest", "error"})
var _checking := {}  # emulator id -> true while its check runs


func setup(page_state: State, state_machine: StateMachine) -> void:
	state = page_state
	name = "RetroForgeEmulatorsMenu"
	follow_focus = true
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL

	# Back returns to the list, unless the screen handles Back itself (state_machine null).
	if state_machine:
		_add_back(state_machine)
	_build_rows()


func _add_back(state_machine: StateMachine) -> void:
	var back = input_watcher_scene.instantiate()
	back.stop_propagation = true
	back.action = "ogui_east"
	var pop = state_updater_scene.instantiate()
	pop.state_machine = state_machine
	pop.action = 2  # StateUpdater.ACTION.POP
	pop.on_signal = "input_released"
	back.add_child(pop)
	add_child(back)


func _build_rows() -> void:
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


## Read the catalog again (`retroforge-emu list`): installed versions, updates.
func load_catalog() -> void:
	catalog = _list()


## Show one emulator (focusing its entry in the list).
func show_emulator(id: String) -> void:
	emulator_id = id
	refresh()
	_check(id)


## Ask upstream for the emulator's newest build in the background (retroforge-emu caches the
## answer for an hour); the rows are rebuilt if it is still the one shown.
func _check(id: String) -> void:
	if _checking.has(id) or not catalog.get(id, {}).get("follows_latest", false):
		return
	_checking[id] = true
	var cmd := Command.create(EMU_TOOL, ["check", id])
	cmd.timeout = CHECK_TIMEOUT
	var code := -1
	if cmd.execute() == OK:
		code = await cmd.finished as int
	_checking.erase(id)
	var parsed = JSON.parse_string(cmd.stdout) if code == 0 else null
	var answer = parsed.get("emulators", {}).get(id) if parsed is Dictionary else null
	if not answer is Dictionary:
		logger.warn("retroforge-emu check %s exited %d: %s" % [id, code, cmd.stderr])
		return
	if answer.get("error") != null:
		logger.info("%s: no newest build known: %s" % [id, answer["error"]])
	_checks[id] = answer
	if id == emulator_id and not _busy.has(id):
		refresh()


## Rebuild the rows of the shown emulator from the catalog last read.
func refresh() -> void:
	_generation += 1
	var generation := _generation
	for child in _rows.get_children():
		if child != _focus_group:
			child.queue_free()
	await get_tree().process_frame
	if generation != _generation:  # a newer refresh (the list moved on) builds the rows
		return
	if catalog.is_empty():
		_add_label("No emulator catalog found")
	elif catalog.has(emulator_id):
		_add_emulator(emulator_id, catalog[emulator_id])
	_focus_group.current_focus = null
	_focus_group.recalculate_focus()
	_confine_focus()
	if _inside:
		_focus_group.grab_focus()


## CardButtonSetting hands its focus to an inner button that has none of the neighbours FocusGroup
## set on the row, so Up from the first row (or Left) went to the nearest control on screen: an
## entry of the Emulators list, which swaps the page. Give the inner button the row's neighbours.
## (Dropdown forwards them itself.)
func _confine_focus() -> void:
	for row in _rows.get_children():
		var inner = row.get("card_button")
		if not (row is Control and inner is Control):
			continue
		for side in ["focus_neighbor_top", "focus_neighbor_bottom", "focus_neighbor_left",
				"focus_neighbor_right", "focus_next", "focus_previous"]:
			var path: NodePath = row.get(side)
			var target := row.get_node_or_null(path) if not path.is_empty() else null
			inner.set(side, target.get_path() if target else inner.get_path())


func _list() -> Dictionary:
	var output: Array = []
	if OS.execute(EMU_TOOL, ["list"], output) != 0 or output.is_empty():
		logger.warn("retroforge-emu list failed")
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


## The emulator's block (its name is the screen's title): who made it, then its rows -- the version
## with Download / Update / Open, one dropdown per option, the fast-cores default, and Delete once
## installed. Options show before the download too: a choice made then applies from the first
## launch. Only the last row draws a separator (OGUI's toggle draws one by default).
func _add_emulator(id: String, emu: Dictionary) -> void:
	var name_text := str(emu.get("name", id))
	_add_credit(emu)
	var installed = emu.get("installed")
	var state := EmuState.rows(id, emu, _checks.get(id, {}))
	_add_action_row(id, name_text, emu, state.main)

	for option in EmuOptions.options_for(id):
		_add_option(id, name_text, option)

	var fast = toggle_scene.instantiate()
	fast.text = "Run on fast cores"
	fast.description = "Games can override this in their own settings."
	fast.button_pressed = LaunchArgs.emulator_fast_cores(id)
	fast.separator_visible = installed == null and state.extra.is_empty()  # the block's last row
	fast.toggled.connect(_set_fast_cores.bind(id, name_text, fast))
	_rows.add_child(fast)

	for row in state.extra:
		_add_action_row(id, name_text, emu, row)
	if installed == null and not state.extra.is_empty():
		_rows.get_child(_rows.get_child_count() - 1).separator_visible = true

	if installed != null:
		var remove = row_scene.instantiate()
		remove.text = "Delete"
		remove.description = "Removes the emulator. Its settings, saves and states are kept."
		remove.button_text = "Delete"
		remove.separator_visible = true
		remove.button_up.connect(_remove.bind(id, name_text, remove))
		_rows.add_child(remove)


## One row of emu_state.gd: its button runs retroforge-emu with the row's args, or Open without.
func _add_action_row(id: String, name_text: String, emu: Dictionary, spec: Dictionary) -> Control:
	var row = row_scene.instantiate()
	row.text = spec.text
	row.description = spec.description
	row.button_text = spec.button
	row.separator_visible = false
	var args: Array = spec.args
	if args.is_empty():
		row.button_up.connect(_open.bind(id, name_text))
	elif args[0] == "rollback":
		row.button_up.connect(_rollback.bind(id, name_text, row))
	else:
		row.button_up.connect(_install.bind(id, name_text, args, emu, row))
	_rows.add_child(row)
	if _busy.has(id):
		row.disabled = true
	return row


## Download / Update / Install tested: `retroforge-emu <args>`. The installed build before (null for a
## first download) tells an Update that found nothing newer from one that installed.
func _install(id: String, name_text: String, args: Array, emu: Dictionary, row: Control) -> void:
	if _busy.has(id):
		return
	_busy[id] = true
	row.disabled = true
	row.description = "Downloading..."
	var before = emu.get("installed")
	var argv: Array[String] = []
	argv.assign(args)  # Command.create takes Array[String]
	var cmd := Command.create(EMU_TOOL, argv)
	if cmd.execute() != OK:
		_busy.erase(id)
		_notify("Could not start the download of " + name_text)
		_reload()
		return
	# Progress from the size of retroforge-emu's hidden .part file, named after the catalog's tag;
	# the size is the tested build's, close enough for a newer one.
	var part := OS.get_environment("HOME").path_join("emulators/%s/.%s.AppImage.part" % [id, str(emu.get("pinned", ""))])
	var poll := Timer.new()
	poll.wait_time = PROGRESS_POLL
	add_child(poll)
	poll.timeout.connect(_show_progress.bind(part, int(emu.get("size", 0)), row))
	poll.start()
	var code := await cmd.finished as int
	poll.queue_free()
	_busy.erase(id)
	if code == 0 and before != null and _installed(id) == before:
		_notify(name_text + " is up to date")
	elif code == 0:
		_notify(name_text + " installed")
	else:
		logger.warn("retroforge-emu %s exited %d: %s" % [" ".join(args), code, cmd.stderr])
		_notify(EXIT_TEXT.get(code, "Installing %s failed." % name_text))
	_reload()


## Revert: back to the build kept from before the last switch (offline, instant).
func _rollback(id: String, name_text: String, row: Control) -> void:
	if _busy.has(id):
		return
	_busy[id] = true
	row.disabled = true
	var cmd := Command.create(EMU_TOOL, ["rollback", id])
	var code := -1
	if cmd.execute() == OK:
		code = await cmd.finished as int
	_busy.erase(id)
	if code == 0:
		_notify("%s is back to %s" % [name_text, Credits.version_text(str(_installed(id)))])
	else:
		logger.warn("retroforge-emu rollback %s exited %d: %s" % [id, code, cmd.stderr])
		_notify(name_text + " could not be reverted")
	_reload()


## The build `retroforge-emu list` reports as installed for `id`, or null.
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
	_reload()


func _reload() -> void:
	load_catalog()
	refresh()


## One option's dropdown: "Emulator's setting" (RetroForge leaves it alone), then each choice.
## Items are added once it is in the tree (the Dropdown's OptionButton is @onready); select() does
## not emit item_selected, so building the rows never saves.
func _add_option(id: String, name_text: String, option: Dictionary) -> void:
	var dropdown = dropdown_scene.instantiate()
	dropdown.title = option["label"]
	dropdown.description = option["description"]
	_rows.add_child(dropdown)
	dropdown.clear()  # dropdown.tscn ships one placeholder item, which would shift every index
	for text in EmuOptions.emulator_items(option):
		dropdown.add_item(text)
	dropdown.select(EmuOptions.index_of(option, EmuOptions.emulator_choice(id, option)))
	dropdown.item_selected.connect(_set_option.bind(id, name_text, option, dropdown))


func _set_option(index: int, id: String, name_text: String, option: Dictionary, dropdown: Control) -> void:
	var values := EmuOptions.values(option)
	if index < 0 or index >= values.size():
		logger.warn("%s: %s: no choice at item %d" % [id, option["id"], index])
		return
	if EmuOptions.set_emulator_choice(id, option, values[index]):
		logger.info("%s: %s = %s" % [id, option["id"], values[index] if values[index] != "" else "(emulator's setting)"])
		return
	logger.warn("could not write " + LaunchArgs.player_conf_path(id))
	_notify("Could not save the %s setting of %s" % [option["label"], name_text])
	dropdown.select(EmuOptions.index_of(option, EmuOptions.emulator_choice(id, option)))  # what is saved


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
	item._provider_id = "retroforge-roms"  # its EXIT hook reports a missing emulator
	launch_manager.launch(item)


func _notify(text: String) -> void:
	var note := Notification.new(text)
	notification_manager.show(note)
