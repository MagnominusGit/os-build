extends RefCounted
## The store sign-in's window in front of OGUI, as OGUI puts a game there
## (.claude/plans/store-signin-window.plan.md, D3).
##
## `store <s> sign-in --display <game display>` starts Chromium where OGUI starts games. Chromium
## overwrites its own environment (process titles), so OGUI cannot tie its windows to an app by
## OGUI_ID: they were orphans, left behind OGUI (plan F5). adopt() makes Chromium one of OGUI's running
## apps (signin_app.gd): its windows, found by their _NET_WM_PID, get that app's id, and OGUI goes to
## its in-game state and focuses them as a game's. The Guide menu and the on-screen keyboard then work
## over it as over a game (the prototype ran as a launched game, HW-OK on the Pocket FIT), and the
## menu's Exit cancels the sign-in. When Chromium exits, OGUI sees the app stop and leaves the in-game
## state, back to Settings > Stores; release() does the same when the sign-in ends first.

const SigninApp := preload("signin_app.gd")
const NAME := "RetroForge store sign-in"
## Seconds between looks for Chromium's new windows (a popup, Google's sign-in).
const POLL := 0.5

var gamescope := load("res://core/systems/gamescope/gamescope.tres") as GamescopeInstance
var launch_manager := load("res://core/global/launch_manager.tres") as LaunchManager
var state_machine := load("res://assets/state/state_machines/global_state_machine.tres") as StateMachine
var in_game_state := load("res://assets/state/states/in_game.tres") as State
var osk := load("res://core/global/keyboard_instance.tres") as KeyboardInstance
var popup_state_machine := load("res://assets/state/state_machines/popup_state_machine.tres") as StateMachine
var osk_state := load("res://assets/state/states/osk.tres") as State
var popup_state := load("res://assets/state/states/popup.tres") as State
var logger := Log.get_logger("RetroForgeSignin", Log.LEVEL.INFO)
var tree: SceneTree
var _app: RunningApp
var _osk_ours := false  # the keyboard is up because a page's text field took the focus (typing)
var _field: TextEdit  # what the keyboard types into: its edits go to the page's field (typing)
var _sent := ""  # _field's text as the page's field last heard of it
var _say := Callable()  # a line to the sign-in's helper


func setup(scene_tree: SceneTree) -> RefCounted:
	tree = scene_tree
	return self


## The X display OGUI starts games on (":1"), "" when there is none.
func display() -> String:
	var xwayland := gamescope.get_xwayland(gamescope.XWAYLAND_TYPE_GAME)
	return str(xwayland.name) if xwayland else ""


## Chromium (pid) in front, as a running app whose Exit calls on_exit.
func adopt(pid: int, on_exit: Callable) -> void:
	release()
	var xwayland := gamescope.get_xwayland(gamescope.XWAYLAND_TYPE_GAME)
	if not xwayland:
		logger.warn("no game display: the sign-in window stays behind OGUI")
		return
	var item := LibraryLaunchItem.new()
	item.name = NAME
	var app := SigninApp.new(item, str(xwayland.name))
	app.pid = pid
	app.app_id = item.get_app_id()
	app.on_exit = on_exit
	app.window_ids_changed.connect(_on_windows_changed.bind(app))
	_app = app
	launch_manager._add_running(app)
	state_machine.push_state(in_game_state)
	logger.info("sign-in window: Chromium pid %d as app %d on %s" % [pid, app.app_id, xwayland.name])
	_claim_windows(app, xwayland)


## As launch_manager.launch() does for a game: a new window (the sign-in's own popups) gets the
## focus; when the focused one goes (a popup closed), the window left does.
func _on_windows_changed(before: PackedInt64Array, after: PackedInt64Array, app: RunningApp) -> void:
	for window in after:
		if not window in before:
			app.switch_window(window)
			return
	var primary := gamescope.get_xwayland(gamescope.XWAYLAND_TYPE_PRIMARY)
	if not primary or not primary.baselayer_window in before or primary.baselayer_window in after:
		return
	if after.is_empty():
		primary.remove_baselayer_window()
	else:
		app.switch_window(after[0])


## Chromium's windows get the app's id as they appear, until it stops: OGUI finds them by it.
func _claim_windows(app: RunningApp, xwayland) -> void:
	while _app == app and app.state != RunningApp.STATE.STOPPED:
		for window in xwayland.get_windows_for_pid(app.pid):
			if not xwayland.has_app_id(window) or xwayland.get_app_id(window) != app.app_id:
				xwayland.set_app_id(window, app.app_id)
		await tree.create_timer(POLL).timeout


## A text field in the window took (on) or lost the focus (`typing` events, chromium_signin.py THE
## KEYBOARD): OGUI's keyboard comes up over the window, as Guide+X brings it up over a game (OGUI's
## input_manager.gd _osk_input), and goes once no field has the focus. Never over another popup (the
## Guide menu), and a keyboard the player brought up is theirs to close.
##
## It types into _field, not into the window (X11): OGUI sends X11 keys through InputPlumber's
## virtual keyboard, which it does not find after a fresh boot (its proxy keeps InputPlumber's target
## list from before that keyboard existed; Air X, 2026-11-01). say(line) carries each edit to the
## helper, which types it into the page's field.
func typing(on: bool, say: Callable) -> void:
	if _app == null:
		return
	if on and popup_state_machine.current_state() == null:
		_say = say
		_open_field()
		popup_state_machine.push_state(osk_state)
		state_machine.push_state(popup_state)
		var context := KeyboardContext.new(KeyboardContext.TYPE.GODOT, _field)
		context.submitted.connect(_on_submitted)
		# OGUI gives the target the focus back when the keyboard closes: not this hidden one.
		context.exited.connect(func() -> void: _field.focus_mode = Control.FOCUS_NONE)
		osk.open(context)
		_osk_takes_touch()
		_osk_ours = true
	elif not on and _osk_ours:
		_close_osk()


## OGUI's keyboard gives gamescope's input focus to OGUI's own window only for an X11 context
## (on_screen_keyboard.gd open()), and this one is GODOT. Without it gamescope kept sending touches to
## Chromium: a tap on a key blurred the page's field, the helper said `typing` off, and the keyboard
## closed (issue #34; the D-pad, through InputPlumber, worked). 2 is what OGUI sets for its X11
## keyboard: OGUI's window takes the touches. The keyboard's close() puts the focus back.
func _osk_takes_touch() -> void:
	var xwayland := gamescope.get_xwayland(gamescope.XWAYLAND_TYPE_OGUI)
	if not xwayland:
		return
	var windows := xwayland.get_windows_for_pid(OS.get_process_id())
	if windows.is_empty():
		logger.warn("no OGUI window: touches on the keyboard go to the sign-in window")
		return
	xwayland.set_input_focus(windows[0], 2)


## An empty _field, in the tree (the keyboard looks for the target's scroll containers) and hidden.
func _open_field() -> void:
	if _field == null or not is_instance_valid(_field):
		_field = TextEdit.new()
		_field.visible = false
		_field.focus_mode = Control.FOCUS_NONE
		_field.text_changed.connect(_on_field_changed)
		tree.root.add_child(_field)
	_sent = ""
	_field.text = ""


## The keyboard changed _field: the page's field gets a backspace per character past what both
## share, then the rest.
func _on_field_changed() -> void:
	var now := _field.text
	var same := 0
	while same < mini(now.length(), _sent.length()) and now[same] == _sent[same]:
		same += 1
	var line := JSON.stringify({"type": "text", "delete": _sent.length() - same, "insert": now.substr(same)})
	_sent = now
	if _say.is_valid():
		_say.call(line)


## The keyboard's Enter (it closes itself after): the page's field gets an Enter.
func _on_submitted() -> void:
	if _say.is_valid():
		_say.call(JSON.stringify({"type": "key", "key": "Enter"}))


func _close_osk() -> void:
	_osk_ours = false
	if popup_state_machine.current_state() == osk_state:
		osk.close()
		popup_state_machine.pop_state()


## The sign-in ended: the app stops if Chromium has not already, as OGUI stops one (state, then
## app_killed): OGUI drops it and its in-game state, and its running-game card and launch screen go.
func release() -> void:
	if _app == null:
		return
	if _osk_ours:
		_close_osk()
	_say = Callable()
	if _field != null and is_instance_valid(_field):
		_field.queue_free()
	_field = null
	var app := _app
	_app = null
	app.on_exit = Callable()
	if app.state != RunningApp.STATE.STOPPED:
		app.state = RunningApp.STATE.STOPPED
		app.app_killed.emit()
