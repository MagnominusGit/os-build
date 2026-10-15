extends ScrollContainer

## Game settings > RetroForge: per-ROM options, in the screen the gear on OGUI's launch menu opens.
## "Run on fast cores": the emulator's default (Settings > Emulators), On or Off for this game
## (CPUS=big / all in the game's conf, which retroforge-launch reads; launch_args.gd). Then one
## dropdown per option of the game's emulator (options.json, emu_options.gd): "Emulator default
## (<its choice>)" or a value for this game only, rebuilt at each visit (another game may run in
## another emulator).
##
## Wired like that screen's own sections (game_settings.tscn): the button replaces the
## game-settings state with this page's State on focus and hands the focus to the page when
## pressed; the page fades in and out with its State (as game_settings_library.tscn) and Back
## returns through the screen's shared focus stack. The button only shows for RetroForge ROMs.

const LIBRARY_ID := "retroforge-roms"
const EmuOptions := preload("emu_options.gd")
const LaunchArgs := preload("launch_args.gd")
const TITLE := "RetroForge"

var game_settings_state := load("res://assets/state/states/game_settings.tres") as State
var settings_state_machine := load("res://assets/state/state_machines/game_settings_state_machine.tres") as StateMachine
var focus_stack := load("res://core/ui/card_ui/launch/game_settings_focus.tres")
var dropdown_scene := load("res://core/ui/components/dropdown.tscn") as PackedScene
var button_scene := load("res://core/ui/components/card_button.tscn") as PackedScene
var focus_group_scene := load("res://core/systems/input/focus_group.tscn") as PackedScene
var state_updater_scene := load("res://core/systems/state/state_updater.tscn") as PackedScene
var state_watcher_scene := load("res://core/systems/state/state_watcher.tscn") as PackedScene

var logger := Log.get_logger("RetroForgeGameSettings", Log.LEVEL.INFO)
var roms  # the plugin's ROM library (library_roms.gd)
var button: Control
var _state := State.new()
var _focus_group: FocusGroup
## Dropdown entries, in order: the game override each one saves.
const CPUS_CHOICES := ["", "big", "all"]

var _fast_cores: Control  # OGUI Dropdown
var _rows: VBoxContainer
var _option_rows: Array = []  # this game's option dropdowns, rebuilt at each visit
var _section_label: Label
var _item: LibraryLaunchItem  # the RetroForge launch item of the game being configured


## Add the page and its button to OGUI's game settings screen. False when its layout is not
## the one this was written against (then nothing is added).
func attach(menu: Node, rom_library) -> bool:
	var buttons: Node = menu.find_child("ButtonsContainer", true, false)
	var library_page: Node = menu.find_child("LibrarySettings", true, false)
	_section_label = menu.find_child("SectionLabel", true, false) as Label
	if not (buttons and library_page and _section_label):
		return false
	roms = rom_library
	_state.name = "retroforge_game_settings"
	_build_page()
	library_page.get_parent().add_child(self)
	_build_button(buttons)
	game_settings_state.state_entered.connect(_on_game_settings_entered)
	# Connected after game_settings.gd's own handler, which titles a section from its state's
	# name ("Retroforge"): ours runs second and sets the real name.
	settings_state_machine.state_changed.connect(_on_section_changed)
	return true


func detach() -> void:
	if game_settings_state.state_entered.is_connected(_on_game_settings_entered):
		game_settings_state.state_entered.disconnect(_on_game_settings_entered)
	if settings_state_machine.state_changed.is_connected(_on_section_changed):
		settings_state_machine.state_changed.disconnect(_on_section_changed)
	if is_instance_valid(button):
		button.queue_free()
	queue_free()


func _build_page() -> void:
	name = "RetroForgeGameSettings"
	visible = false
	follow_focus = true
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL

	var watcher = state_watcher_scene.instantiate()
	watcher.state = _state
	var fade := FadeEffect.new()
	fade.target = self
	fade.on_signal = "state_entered"
	fade.fade_out_signal = "state_exited"
	watcher.add_child(fade)
	add_child(watcher)

	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 4)
	add_child(margin)
	var rows := VBoxContainer.new()
	margin.add_child(rows)
	_rows = rows

	_fast_cores = dropdown_scene.instantiate()
	_fast_cores.title = "Run on fast cores"
	_fast_cores.description = "Keep the emulator on the fast CPU cores. Helps demanding systems (PS2, PS3, Wii U); PS1 does not need it. The default is set per emulator in Settings > Emulators."
	_fast_cores.item_selected.connect(_on_fast_cores_selected)
	_focus_group = focus_group_scene.instantiate() as FocusGroup
	_focus_group.focus_stack = focus_stack
	rows.add_child(_focus_group)
	rows.add_child(_fast_cores)
	_focus_group.current_focus = _fast_cores


func _build_button(buttons: Node) -> void:
	button = button_scene.instantiate()
	button.name = "RetroForgeButton"
	button.text = TITLE
	var show_page = state_updater_scene.instantiate()
	show_page.state_machine = settings_state_machine
	show_page.state = _state
	show_page.action = 3  # StateUpdater.ACTION.REPLACE, as the screen's own buttons
	show_page.on_signal = "focus_entered"
	button.add_child(show_page)
	var enter := FocusGroupSetter.new()
	enter.target = _focus_group
	enter.on_signal = "pressed"
	button.add_child(enter)

	var library_button := buttons.find_child("LibraryButton", false, false)
	buttons.add_child(button)
	if library_button:
		buttons.move_child(button, library_button.get_index() + 1)
	_recalculate(buttons)


## Show the button for RetroForge ROMs only, and load this game's saved choice.
func _on_game_settings_entered(_from: State) -> void:
	# Same lookup order as game_settings.gd, so the page always configures the titled game.
	var item = game_settings_state.get_meta("item") if game_settings_state.has_meta("item") \
		else game_settings_state.data.get("item")
	_item = item.get_launch_item(LIBRARY_ID) if item is LibraryItem else null
	var show := _item != null
	if button.visible != show:
		button.visible = show
		_recalculate(button.get_parent())
	if not show:
		_build_options("")  # no RetroForge game: no rows of the last one left behind
	if show:
		# Filled on each visit: the default's label follows the emulator's current setting.
		# select() does not emit item_selected, so loading never saves.
		_fast_cores.clear()
		_fast_cores.add_item("Emulator default (%s)" % ("On" if roms.emulator_fast_cores(_item) else "Off"))
		_fast_cores.add_item("On")
		_fast_cores.add_item("Off")
		_fast_cores.select(CPUS_CHOICES.find(roms.get_cpus(_item)))
		_build_options(roms.emulator_of(_item))


## The game's emulator options, after the fast-cores row. Removed from the tree before they are
## freed, so the FocusGroup never walks a dying row.
func _build_options(emulator: String) -> void:
	if _focus_group.current_focus in _option_rows:
		_focus_group.current_focus = _fast_cores
	for row in _option_rows:
		_rows.remove_child(row)
		row.queue_free()
	_option_rows.clear()
	if emulator != "":
		for option in EmuOptions.options_for(emulator):
			_add_option(emulator, option)
	_focus_group.recalculate_focus()


func _add_option(emulator: String, option: Dictionary) -> void:
	var dropdown = dropdown_scene.instantiate()
	dropdown.title = option["label"]
	dropdown.description = option["description"]
	_rows.add_child(dropdown)
	_option_rows.append(dropdown)
	for text in EmuOptions.game_items(option, EmuOptions.emulator_choice(emulator, option)):
		dropdown.add_item(text)
	var system: String = _item.metadata["system"]
	var rom: String = _item.metadata["rom"]
	dropdown.select(EmuOptions.index_of(option, EmuOptions.game_choice(system, rom, option)))
	dropdown.item_selected.connect(_on_option_selected.bind(option, dropdown))


func _on_option_selected(index: int, option: Dictionary, dropdown: Control) -> void:
	var values := EmuOptions.values(option)
	if not _item or index < 0 or index >= values.size():
		return
	var system: String = _item.metadata["system"]
	var rom: String = _item.metadata["rom"]
	if EmuOptions.set_game_choice(system, rom, option, values[index]):
		logger.info("%s: %s = %s" % [_item.name, option["id"], values[index] if values[index] != "" else "(emulator default)"])
		return
	logger.warn("could not write " + LaunchArgs.game_conf_path(system, rom))
	dropdown.select(EmuOptions.index_of(option, EmuOptions.game_choice(system, rom, option)))  # what is saved


func _on_fast_cores_selected(index: int) -> void:
	if _item and index >= 0 and index < CPUS_CHOICES.size():
		roms.set_cpus(_item, CPUS_CHOICES[index])


func _on_section_changed(_from: State, to: State) -> void:
	if to == _state:
		_section_label.text = TITLE


func _recalculate(buttons: Node) -> void:
	var group := buttons.find_child("FocusGroup", false, false)
	if group:
		group.recalculate_focus()
