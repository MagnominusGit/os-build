extends RefCounted
## Settings > Stores: GOG and Epic, each with Sign in or Sign out (.claude/plans/stores.plan.md).
##
## Sign in opens the store's own sign-in page in a window on the device
## (.claude/plans/store-signin-window.plan.md): `store <s> sign-in` runs Chromium on OGUI's game
## display, which signin_window.gd puts in front as OGUI puts a game; the player signs in there by
## touch or the gamepad (the helper declares stores/signin-gamepad.yaml), and the on-screen keyboard
## comes up when a page's text field takes the focus (`typing`). The window closes by itself once the
## store gives its code, the code signs in, the row says whom it signed in and the store's library
## reloads (`changed`). The first sign-in downloads Chromium first (~190 MB, plan D1), its progress in
## the row, with Cancel under it; the Guide menu's Exit closes the window and cancels. Each store's tool is set up in the
## background when the page first shows (`store <s> setup`); a store whose tool is not set up yet sets
## it up first, its progress in the row.

signal changed(store: String)

const Runner := preload("store_runner.gd")
const SigninWindow := preload("signin_window.gd")
const TOOL := "/usr/lib/retroforge/store"
const STORES := {"gog": "GOG", "epic": "Epic Games"}

var notification_manager := load("res://core/global/notification_manager.tres")
var launch_manager := load("res://core/global/launch_manager.tres") as LaunchManager
var section_scene := load("res://core/ui/components/section_label.tscn") as PackedScene
var setting_scene := load("res://core/ui/components/card_button_setting.tscn") as PackedScene
var button_scene := load("res://core/ui/components/card_button.tscn") as PackedScene
var logger := Log.get_logger("RetroForgeStores", Log.LEVEL.INFO)
var tree: SceneTree
var tool := TOOL
var _box: Node
## store -> {"row", "cancel", "runner", "status", "step"}
var _stores := {}
var _window: SigninWindow
var _nodes: Array[Node] = []
var _prepared := false


func setup(scene_tree: SceneTree) -> RefCounted:
	tree = scene_tree
	_window = SigninWindow.new()
	_window.setup(scene_tree)
	return self


## The rows on `box` (the Stores page). False when there is no page or the build has no store tool.
func attach(box: Node) -> bool:
	if not box or not FileAccess.file_exists(tool):
		return false
	_box = box
	for store in STORES:
		var title: String = STORES[store]
		var label = section_scene.instantiate()
		label.text = title
		var row = setting_scene.instantiate()
		row.name = "RetroForgeStore" + title.replace(" ", "")
		row.text = title
		row.button_text = "Sign in"
		var cancel = button_scene.instantiate()
		cancel.text = "Cancel"
		# In the tree FIRST: a component's @onready children only exist once it is ready.
		for node in [label, row, cancel]:
			box.add_child(node)
			_nodes.append(node)
		var runner := Runner.new()
		runner.tool = tool
		_stores[store] = {"row": row, "cancel": cancel, "runner": runner, "status": {}, "step": ""}
		row.pressed.connect(_on_row_pressed.bind(store))
		cancel.pressed.connect(_on_cancel.bind(store))
		runner.progressed.connect(_on_progress.bind(store))
		runner.event.connect(_on_event.bind(store))
		runner.finished.connect(_on_finished.bind(store))
		_show_panel(store, false)
	# The page (a ScrollContainer, steam_settings.gd) shows: the rows' state, and the tools set up.
	var page: Node = box
	while page and not page is ScrollContainer:
		page = page.get_parent()
	if page:
		page.visibility_changed.connect(_on_page_shown.bind(page))
	refresh()
	return true


func detach() -> void:
	if _window:
		_window.release()
	for store in _stores:
		_stores[store]["runner"].cancel()
	for node in _nodes:
		if is_instance_valid(node):
			node.queue_free()
	_nodes.clear()
	_stores.clear()


func _on_page_shown(page: Control) -> void:
	if page.is_visible_in_tree():
		_prepared = true
		refresh()


## Each store's row from `store <s> status`; a store whose tool is not set up yet sets it up now,
## once the page has been shown (not at OGUI's start, before the network is up).
func refresh() -> void:
	for store in _stores:
		_refresh_row(store)


func _refresh_row(store: String) -> void:
	var status := await _status(store)
	var s: Dictionary = _stores.get(store, {})
	if s.is_empty() or s["runner"].running:
		return
	s["status"] = status
	var row = s["row"]
	row.disabled = false
	var account := str(status.get("account", "")) if status.get("signed_in", false) else ""
	if account != "":
		row.description = "Signed in as %s." % account
		row.button_text = "Sign out"
	else:
		row.description = "Sign in on %s's own page: RetroForge never sees your password." % STORES[store]
		row.button_text = "Sign in"
	if _prepared and not status.get("ready", true):
		s["step"] = "prepare"
		s["runner"].start([store, "setup"])


## `store <s> status` on a worker thread: {} when it fails.
func _status(store: String) -> Dictionary:
	var out := []
	var task := WorkerThreadPool.add_task(func() -> void:
		var output: Array = []
		out.append(OS.execute(tool, [store, "status"], output))
		out.append("".join(output)))
	while not WorkerThreadPool.is_task_completed(task):
		await tree.process_frame
	WorkerThreadPool.wait_for_task_completion(task)
	if out.size() < 2 or out[0] != 0:
		return {}
	var data = JSON.parse_string(out[1])
	return data if data is Dictionary else {}


func _on_row_pressed(store: String) -> void:
	var s: Dictionary = _stores[store]
	if s["status"].get("signed_in", false):
		if not s["runner"].running:
			_sign_out(store)
		return
	if s["runner"].running:
		if s["step"] == "prepare":
			s["step"] = "setup"  # the background set-up becomes this sign-in's first step
			s["row"].disabled = true
			s["row"].description = "Getting %s ready..." % STORES[store]
		return
	# The window would take the game's place, and nothing gives the game its focus back after.
	if not launch_manager.get_running().is_empty():
		_notify("Close the running game first: the sign-in opens in its place.")
		return
	s["row"].disabled = true
	if s["status"].get("ready", false):
		_start_sign_in(store)
	else:
		s["step"] = "setup"
		s["row"].description = "Getting %s ready..." % STORES[store]
		s["runner"].start([store, "setup"])


func _start_sign_in(store: String) -> void:
	var s: Dictionary = _stores[store]
	s["step"] = "sign-in"
	s["row"].description = "Opening the sign-in page..."
	var args := [store, "sign-in"]
	var display: String = _window.display()
	if display != "":
		args.append_array(["--display", display])
	s["runner"].start(args)
	_show_panel(store, true)


func _sign_out(store: String) -> void:
	var s: Dictionary = _stores[store]
	s["row"].disabled = true
	var out := []
	var task := WorkerThreadPool.add_task(func() -> void: out.append(OS.execute(tool, [store, "sign-out"], [])))
	while not WorkerThreadPool.is_task_completed(task):
		await tree.process_frame
	WorkerThreadPool.wait_for_task_completion(task)
	if out.is_empty() or out[0] != 0:
		_notify("Could not sign out of %s." % STORES[store])
	else:
		_notify("Signed out of %s." % STORES[store])
		changed.emit(store)
	_refresh_row(store)


func _on_progress(percent: int, store: String) -> void:
	if _stores.has(store) and _stores[store]["step"] == "setup":
		_stores[store]["row"].description = "Getting %s ready... %d%%" % [STORES[store], percent]


func _on_event(data: Dictionary, store: String) -> void:
	if not _stores.has(store):
		return  # detached while it ran
	var s: Dictionary = _stores[store]
	var title: String = STORES[store]
	match str(data.get("event", "")):
		"browser":
			match str(data.get("state", "")):
				"setup":
					s["row"].description = "Getting the sign-in window ready... %d%%" % int(data.get("percent", 0))
				"open":
					s["row"].description = "Sign in to %s in its window." % title
					_window.adopt(int(data.get("pid", 0)), _on_cancel.bind(store))
				"closed":
					_window.release()
					_show_panel(store, false)
					s["row"].description = "Signing in to %s..." % title
					s["row"].grab_focus.call_deferred()
		"typing":
			_window.typing(bool(data.get("on", false)))
		"signed_in":
			_notify("Signed in to %s as %s." % [title, data.get("account", "")])
			changed.emit(store)


func _on_cancel(store: String) -> void:
	if not _stores.has(store):
		return
	var s: Dictionary = _stores[store]
	s["step"] = "cancelled"
	s["runner"].cancel()


func _on_finished(code: int, error: String, store: String) -> void:
	var s: Dictionary = _stores.get(store, {})
	if s.is_empty():
		return
	var step: String = s["step"]
	s["step"] = ""
	if step == "setup" and code == 0:
		_start_sign_in(store)
		return
	var was_open := step in ["sign-in", "cancelled"]
	if was_open:
		_window.release()
	_show_panel(store, false)
	if code != 0 and step not in ["cancelled", "prepare"]:
		logger.warn("store %s %s exited %d: %s" % [store, step, code, error])
		_notify(Runner.failure_text(STORES[store], code, error))
	elif code != 0:
		logger.info("store %s %s exited %d: %s" % [store, step, code, error])
	_refresh_row(store)
	if was_open:
		s["row"].grab_focus.call_deferred()


func _show_panel(store: String, on: bool) -> void:
	var s: Dictionary = _stores[store]
	s["cancel"].visible = on
	_recalculate_focus()
	if on:
		s["cancel"].grab_focus.call_deferred()


func _recalculate_focus() -> void:
	var focus: Node = _box.find_child("FocusGroup", false, false) if is_instance_valid(_box) else null
	if focus and focus.has_method("recalculate_focus"):
		focus.recalculate_focus()


func _notify(text: String) -> void:
	notification_manager.show(Notification.new(text))
