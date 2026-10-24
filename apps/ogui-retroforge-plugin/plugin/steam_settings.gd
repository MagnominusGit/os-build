extends RefCounted
## Settings > Steam: an entry after General in OGUI's Settings menu, and its page. Built as
## settings_menu.tscn builds General: the button replaces the settings state and, on focus, sets the
## TabContainer's tab and the section title; the page focuses its FocusGroup when the state is entered,
## and Back pops it. The Steam rows (steam_proton.gd, steam_sarek.gd, steam_keep.gd, steam_direct.gd)
## attach to `box`. Settings > Stores (store_settings.gd) is a second one, set up with its own title
## and placed after Steam's entry.

var title := "Steam"

var settings_state_machine := load("res://assets/state/state_machines/settings_state_machine.tres") as StateMachine
var card_button_scene := load("res://core/ui/components/card_button.tscn") as PackedScene
var state_updater_scene := load("res://core/systems/state/state_updater.tscn") as PackedScene
var focus_group_scene := load("res://core/systems/input/focus_group.tscn") as PackedScene
var input_watcher_scene := load("res://core/systems/input/input_watcher.tscn") as PackedScene
var state_watcher_script := load("res://core/systems/state/state_watcher.gd") as GDScript
var focus_group_setter_script := load("res://core/systems/input/focus_group_setter.gd") as GDScript
var tab_setter_script := load("res://core/systems/user_interface/tab_setter.gd") as GDScript
var text_setter_script := load("res://core/systems/user_interface/text_setter.gd") as GDScript

var tree: SceneTree
var box: VBoxContainer  # the page's rows
var _button: Control
var _page: ScrollContainer
var _state := State.new()


func setup(scene_tree: SceneTree, page_title := "Steam") -> RefCounted:
	tree = scene_tree
	title = page_title
	return self


## False when OGUI's Settings layout differs: the rows then stay in Settings > General. The entry goes
## after the button named `after` when there is one, else after General's.
func attach(after := "") -> bool:
	var menu: Node = tree.get_first_node_in_group("settings_menu")
	var general: Node = menu.find_child("GeneralSettings", true, false) if menu else null
	var tabs := general.get_parent() as TabContainer if general else null
	var general_button: Node = menu.find_child("GeneralButton", true, false) if menu else null
	var title_label: Node = menu.find_child("SectionLabel", true, false) if menu else null
	if not (tabs and general_button and title_label):
		return false
	_state.name = "settings_retroforge_" + title.to_lower()

	_page = ScrollContainer.new()
	_page.name = "RetroForge%sSettings" % title
	_page.follow_focus = true
	_page.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_page.visible = false
	var back = input_watcher_scene.instantiate()
	back.stop_propagation = true
	back.action = "ogui_east"
	var pop = state_updater_scene.instantiate()
	pop.state_machine = settings_state_machine
	pop.action = 2  # POP
	pop.on_signal = "input_released"
	back.add_child(pop)
	_page.add_child(back)
	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 5)
	var outer := VBoxContainer.new()
	outer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box = VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var focus = focus_group_scene.instantiate()
	box.add_child(focus)
	outer.add_child(box)
	margin.add_child(outer)
	_page.add_child(margin)
	var watcher: Node = state_watcher_script.new()
	watcher.state = _state
	var setter: Node = focus_group_setter_script.new()
	setter.target = focus
	setter.on_signal = "state_entered"
	watcher.add_child(setter)
	_page.add_child(watcher)
	tabs.add_child(_page)

	_button = card_button_scene.instantiate()
	_button.name = "RetroForge%sButton" % title
	_button.text = title
	var open = state_updater_scene.instantiate()
	open.state_machine = settings_state_machine
	open.state = _state
	open.action = 3  # as General's button
	open.on_signal = "button_up"
	_button.add_child(open)
	var tab: Node = tab_setter_script.new()
	tab.target = tabs
	tab.tab_number = tabs.get_tab_idx_from_control(_page)
	tab.on_signal = "focus_entered"
	_button.add_child(tab)
	var text: Node = text_setter_script.new()
	text.target = title_label
	text.text = title
	text.on_signal = "focus_entered"
	_button.add_child(text)
	var buttons := general_button.get_parent()
	var before: Node = buttons.get_node_or_null(after) if after != "" else null
	buttons.add_child(_button)
	buttons.move_child(_button, (before if before else general_button).get_index() + 1)
	var buttons_focus := buttons.find_child("FocusGroup", false, false)
	if buttons_focus:
		buttons_focus.recalculate_focus()
	return true


func detach() -> void:
	for node in [_button, _page]:
		if is_instance_valid(node):
			node.queue_free()
