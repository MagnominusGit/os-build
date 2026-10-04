extends Plugin

## QForge: ROM library with one library tab per system (plan Phase 4). Prototype: the PSX tab.
##
## OpenGamepadUI's library menu only fills its own two grids (Installed, All Games); a tab added
## through library_tabs_state gets placed in the TabContainer but its grid is ours to fill. Plugins
## are initialised BEFORE the library menu is ready (PluginManager comes first in card_ui.tscn), so
## tabs are added from library_loaded, which fires after the UI's first reload_library().

const LIBRARY_ID := "qforge-roms"

var library_manager := load("res://core/global/library_manager.tres") as LibraryManager
var tabs_state := load("res://core/ui/card_ui/library/library_tabs_state.tres") as TabContainerState
var menu_state_machine := load("res://assets/state/state_machines/menu_state_machine.tres") as StateMachine
var launcher_state := load("res://assets/state/states/game_launcher.tres") as State
var card_scene := load("res://core/ui/components/card.tscn") as PackedScene
var scroller_scene := load("res://core/systems/input/scroller_joystick.tscn") as PackedScene

var roms  # our Library subclass; untyped so roms.SYSTEMS resolves at runtime
## system -> {"tab": ScrollContainer, "grid": HFlowContainer}
var _tabs := {}


# No _init override: Plugin._init adds the node to the "plugin" group.
func _ready() -> void:
	logger = Log.get_logger("QForge", Log.LEVEL.INFO)
	roms = load(plugin_base.path_join("library_roms.gd")).new()
	add_library(roms)
	library_manager.library_loaded.connect(_on_library_loaded)
	logger.info("ROM library registered: %s" % library_manager.has_library(LIBRARY_ID))


func unload() -> void:
	for system in _tabs.keys():
		tabs_state.remove_tab(_tab_text(system))
	_tabs.clear()


func _on_library_loaded(library_id: String) -> void:
	if library_id != LIBRARY_ID:
		return
	for system in roms.SYSTEMS:
		_refresh_system(system)


## Library items whose qforge-roms launch item belongs to the given system, sorted by name.
func _items_for(system: String) -> Array[LibraryItem]:
	var items: Array[LibraryItem] = []
	for item in library_manager.get_library_items():
		var launch := item.get_launch_item(LIBRARY_ID)
		if launch and system in launch.tags:
			items.append(item)
	return items


func _refresh_system(system: String) -> void:
	var items := _items_for(system)
	if items.is_empty():
		if system in _tabs:
			tabs_state.remove_tab(_tab_text(system))
			_tabs.erase(system)
		return
	if not system in _tabs:
		_tabs[system] = _make_tab()
		tabs_state.add_tab(_tab_text(system), _tabs[system]["tab"])
	var grid: HFlowContainer = _tabs[system]["grid"]
	for child in grid.get_children():
		child.queue_free()
	for item in items:
		grid.add_child(await _build_card(item))
	logger.info("%s tab: %d game(s)" % [_tab_text(system), items.size()])


func _tab_text(system: String) -> String:
	return roms.SYSTEMS[system]["name"]


## Same node layout as the library menu's AllGamesTab: library_menu.gd focuses the first card of a
## tab through get_child(1).get_child(0), so ScrollerJoystick first, then MarginContainer > grid.
func _make_tab() -> Dictionary:
	var tab := ScrollContainer.new()
	tab.visible = false
	tab.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tab.add_child(scroller_scene.instantiate())
	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_left", 15)
	margin.add_theme_constant_override("margin_top", 100)
	margin.add_theme_constant_override("margin_right", 15)
	tab.add_child(margin)
	var grid := HFlowContainer.new()
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 26)
	grid.add_theme_constant_override("v_separation", 16)
	grid.alignment = FlowContainer.ALIGNMENT_CENTER
	margin.add_child(grid)
	return {"tab": tab, "grid": grid}


## As library_menu.gd's _build_card: pressing the card opens OGUI's game launch menu.
func _build_card(item: LibraryItem) -> Control:
	var card := card_scene.instantiate()
	await card.set_library_item(item)
	var on_button_up := func():
		launcher_state.data = {"item": item}
		menu_state_machine.push_state(launcher_state)
	card.button_up.connect(on_button_up)
	return card
