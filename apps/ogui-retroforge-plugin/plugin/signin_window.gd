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
var logger := Log.get_logger("RetroForgeSignin", Log.LEVEL.INFO)
var tree: SceneTree
var _app: RunningApp


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


## The sign-in ended: the app stops if Chromium has not already, as OGUI stops one (state, then
## app_killed): OGUI drops it and its in-game state, and its running-game card and launch screen go.
func release() -> void:
	if _app == null:
		return
	var app := _app
	_app = null
	app.on_exit = Callable()
	if app.state != RunningApp.STATE.STOPPED:
		app.state = RunningApp.STATE.STOPPED
		app.app_killed.emit()
