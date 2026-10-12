extends ScrollContainer

## Game settings > RetroForge: per-ROM options, in the screen the gear on OGUI's launch menu opens.
## For now "Run on fast cores": the emulator's default (Settings > Emulators), On or Off for this
## game (retroforge-launch --cpus big / all on its command line).
##
## Wired like that screen's own sections (game_settings.tscn): the button replaces the
## game-settings state with this page's State on focus and hands the focus to the page when
## pressed; the page fades in and out with its State (as game_settings_library.tscn) and Back
## returns through the screen's shared focus stack. The button only shows for RetroForge ROMs.

const LIBRARY_ID := "retroforge-roms"
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
	if show:
		# Filled on each visit: the default's label follows the emulator's current setting.
		# select() does not emit item_selected, so loading never saves.
		_fast_cores.clear()
		_fast_cores.add_item("Emulator default (%s)" % ("On" if roms.emulator_fast_cores(_item) else "Off"))
		_fast_cores.add_item("On")
		_fast_cores.add_item("Off")
		_fast_cores.select(CPUS_CHOICES.find(roms.get_cpus(_item)))


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
