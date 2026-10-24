extends RefCounted
## Settings > Stores: GOG and Epic, each with Sign in or Sign out (.claude/plans/stores.plan.md).
##
## Sign-in is on the player's phone (D6). Sign in sets the store's tool up first (`store <s> setup`,
## its progress in the row), then `store <s> sign-in` serves a one-time page and prints its link with
## a QR code, which shows under the row with Cancel. When the phone sends the store's code back, the
## panel asks before it is used: only the player's OK on the device signs in. Then the store's library
## reloads (`changed`). Leaving the page keeps a sign-in going until Cancel or its 15 minutes.

signal changed(store: String)

const Runner := preload("store_runner.gd")
const TOOL := "/usr/lib/retroforge/store"
const STORES := {"gog": "GOG", "epic": "Epic Games"}
## Pixels per QR module on screen, and the light border around it, in modules.
const QR_SCALE := 6
const QR_QUIET := 4

var notification_manager := load("res://core/global/notification_manager.tres")
var section_scene := load("res://core/ui/components/section_label.tscn") as PackedScene
var setting_scene := load("res://core/ui/components/card_button_setting.tscn") as PackedScene
var button_scene := load("res://core/ui/components/card_button.tscn") as PackedScene
var logger := Log.get_logger("RetroForgeStores", Log.LEVEL.INFO)
var tree: SceneTree
var tool := TOOL
var _box: Node
## store -> {"row", "qr", "text", "confirm", "cancel", "runner", "account", "step"}
var _stores := {}
var _nodes: Array[Node] = []


func setup(scene_tree: SceneTree) -> RefCounted:
	tree = scene_tree
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
		var qr := TextureRect.new()
		qr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		qr.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
		qr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var text := Label.new()
		text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		var confirm = button_scene.instantiate()
		confirm.text = "Sign in with it"
		var cancel = button_scene.instantiate()
		cancel.text = "Cancel"
		# In the tree FIRST: a component's @onready children only exist once it is ready.
		for node in [label, row, qr, text, confirm, cancel]:
			box.add_child(node)
			_nodes.append(node)
		var runner := Runner.new()
		runner.tool = tool
		_stores[store] = {"row": row, "qr": qr, "text": text, "confirm": confirm, "cancel": cancel,
			"runner": runner, "account": "", "step": ""}
		row.pressed.connect(_on_row_pressed.bind(store))
		confirm.pressed.connect(_on_confirm.bind(store))
		cancel.pressed.connect(_on_cancel.bind(store))
		runner.progressed.connect(_on_progress.bind(store))
		runner.event.connect(_on_event.bind(store))
		runner.finished.connect(_on_finished.bind(store))
		_show_panel(store, false)
	refresh()
	return true


func detach() -> void:
	for store in _stores:
		_stores[store]["runner"].cancel()
	for node in _nodes:
		if is_instance_valid(node):
			node.queue_free()
	_nodes.clear()
	_stores.clear()


## Each store's row from `store <s> status`.
func refresh() -> void:
	for store in _stores:
		_refresh_row(store)


func _refresh_row(store: String) -> void:
	var status := await _status(store)
	var s: Dictionary = _stores.get(store, {})
	if s.is_empty() or s["runner"].running:
		return
	s["account"] = str(status.get("account", "")) if status.get("signed_in", false) else ""
	var row = s["row"]
	row.disabled = false
	if s["account"] != "":
		row.description = "Signed in as %s." % s["account"]
		row.button_text = "Sign out"
	else:
		row.description = "Sign in with your phone: RetroForge never sees your password."
		row.button_text = "Sign in"


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
	if s["runner"].running:
		return
	if s["account"] != "":
		_sign_out(store)
		return
	s["step"] = "setup"
	s["row"].disabled = true
	s["row"].description = "Getting %s ready..." % STORES[store]
	s["runner"].start([store, "setup"])


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
	if _stores[store]["step"] == "setup":
		_stores[store]["row"].description = "Getting %s ready... %d%%" % [STORES[store], percent]


func _on_event(data: Dictionary, store: String) -> void:
	var s: Dictionary = _stores[store]
	var title: String = STORES[store]
	match str(data.get("event", "")):
		"page":
			s["qr"].texture = qr_texture(data.get("qr", []))
			s["text"].text = ("Scan this with your phone's camera. Sign in to %s there, then send what %s shows "
				+ "at the end back to this device.\n%s") % [title, title, data.get("url", "")]
			s["row"].description = "Waiting for your phone..."
			_show_panel(store, true)
			s["confirm"].visible = false
			s["cancel"].grab_focus.call_deferred()
		"code":
			s["text"].text = "A sign-in arrived from %s. Use it to sign in to %s?" % [data.get("sender", "your phone"), title]
			s["qr"].visible = false
			s["confirm"].visible = true
			_recalculate_focus()
			s["confirm"].grab_focus.call_deferred()
		"rejected":
			s["qr"].visible = true
			s["confirm"].visible = false
			s["text"].text = "Not used. Send it again from your phone, or Cancel."
			_recalculate_focus()
		"error":
			s["qr"].visible = true
			s["confirm"].visible = false
			s["text"].text = "%s did not take it (%s). Sign in on your phone again." % [title, data.get("message", "")]
			_recalculate_focus()
		"signed_in":
			_notify("Signed in to %s as %s." % [title, data.get("account", "")])
			changed.emit(store)


func _on_confirm(store: String) -> void:
	var s: Dictionary = _stores[store]
	s["confirm"].visible = false
	s["text"].text = "Signing in..."
	s["runner"].say("accept")


func _on_cancel(store: String) -> void:
	var s: Dictionary = _stores[store]
	if s["confirm"].visible:
		s["runner"].say("reject")
		return
	s["step"] = "cancelled"
	s["runner"].cancel()


func _on_finished(code: int, error: String, store: String) -> void:
	var s: Dictionary = _stores.get(store, {})
	if s.is_empty():
		return
	var step: String = s["step"]
	if step == "setup" and code == 0:
		s["step"] = "sign-in"
		s["row"].description = "Opening the sign-in page..."
		s["runner"].start([store, "sign-in"])
		return
	s["step"] = ""
	_show_panel(store, false)
	if code != 0 and step != "cancelled":
		logger.warn("store %s %s exited %d: %s" % [store, step, code, error])
		_notify(Runner.failure_text(STORES[store], code, error))
	_refresh_row(store)
	s["row"].grab_focus.call_deferred()


func _show_panel(store: String, on: bool) -> void:
	var s: Dictionary = _stores[store]
	for key in ["qr", "text", "cancel"]:
		s[key].visible = on
	s["confirm"].visible = false
	_recalculate_focus()


func _recalculate_focus() -> void:
	var focus: Node = _box.find_child("FocusGroup", false, false) if is_instance_valid(_box) else null
	if focus and focus.has_method("recalculate_focus"):
		focus.recalculate_focus()


## The QR code `store sign-in` printed (rows of 0/1) as a texture, with its light border.
static func qr_texture(rows: Array) -> ImageTexture:
	if rows.is_empty():
		return null
	var n: int = str(rows[0]).length() + 2 * QR_QUIET
	var image := Image.create(n, n, false, Image.FORMAT_L8)
	image.fill(Color.WHITE)
	for y in rows.size():
		var row := str(rows[y])
		for x in row.length():
			if row[x] == "1":
				image.set_pixel(x + QR_QUIET, y + QR_QUIET, Color.BLACK)
	image.resize(n * QR_SCALE, n * QR_SCALE, Image.INTERPOLATE_NEAREST)
	return ImageTexture.create_from_image(image)


func _notify(text: String) -> void:
	notification_manager.show(Notification.new(text))
