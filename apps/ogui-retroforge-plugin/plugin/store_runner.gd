extends RefCounted
## Runs /usr/lib/retroforge/store for the Stores page and the GOG and Epic libraries
## (.claude/plans/stores.plan.md), as scrape_runner.gd runs retroforge-scrape: on a worker thread
## through OS.execute_with_pipe, stdout read line by line (`N%` progress, JSON events), stderr drained
## on a second task, results back on the main thread as signals. `say` writes a line to the tool's
## stdin. Cancel is SIGTERM (the store helper closes its sign-in window first). No OGUI types: tested
## on a stock Godot (tests/test-plugin.sh) against a fake tool.

## A `N%` line of the running tool.
signal progressed(percent: int)
## A JSON line of the running tool (the sign-in's events).
signal event(data: Dictionary)
## The tool ended: its exit code (-1 when it could not start) and its last stderr line without the
## `store: ` prefix ("" on success).
signal finished(code: int, error: String)

const TOOL := "/usr/lib/retroforge/store"
const PREFIX := "store: "

var tool := TOOL
var running := false
var _pid := -1
var _io: FileAccess


## Start the tool with `args`. False when a run is already going.
func start(args: Array) -> bool:
	if running:
		return false
	running = true
	_pid = -1
	WorkerThreadPool.add_task(_run.bind(PackedStringArray(args)))
	return true


## One line to the running tool's stdin.
func say(line: String) -> void:
	if running and _io:
		_io.store_string(line + "\n")
		_io.flush()


## Ask the running tool to stop (SIGTERM).
func cancel() -> void:
	if running and _pid > 0:
		OS.execute("kill", ["-TERM", str(_pid)])


# Worker thread.
func _run(args: PackedStringArray) -> void:
	# Godot forks before it tries the program: a missing one still "runs", so it must exist first.
	var pipe := OS.execute_with_pipe(tool, args, true) if FileAccess.file_exists(tool) else {}
	if pipe.is_empty():
		_end.call_deferred(-1, "")
		return
	_pid = pipe["pid"]
	_io = pipe["stdio"]
	var errors: Array[String] = []
	var err_task := WorkerThreadPool.add_task(_drain.bind(pipe["stderr"], errors))
	while true:
		var line := _io.get_line()
		if line == "" and _io.get_error() != OK:
			break
		var parsed := parse_line(line)
		if parsed.has("percent"):
			progressed.emit.call_deferred(parsed["percent"])
		elif parsed.has("event"):
			event.emit.call_deferred(parsed["event"])
	WorkerThreadPool.wait_for_task_completion(err_task)
	while OS.is_process_running(_pid):
		OS.delay_msec(10)
	var code := OS.get_process_exit_code(_pid)
	_end.call_deferred(code, "" if code == 0 or errors.is_empty() else errors[-1].trim_prefix(PREFIX))


# Worker thread: read stderr to its end, keeping its lines.
static func _drain(err: FileAccess, lines: Array[String]) -> void:
	while true:
		var line := err.get_line()
		if line == "" and err.get_error() != OK:
			return
		if line != "":
			lines.append(line)


func _end(code: int, error: String) -> void:
	running = false
	_pid = -1
	_io = null
	finished.emit(code, error)


## {"percent": N} for a `N%` line, {"event": {...}} for a JSON object line, {} for anything else.
static func parse_line(line: String) -> Dictionary:
	var text := line.strip_edges()
	if text.ends_with("%") and text.trim_suffix("%").is_valid_int():
		var pct := text.trim_suffix("%").to_int()
		return {"percent": pct} if pct >= 0 and pct <= 100 else {}
	if text.begins_with("{"):
		var data = JSON.parse_string(text)
		if data is Dictionary:
			return {"event": data}
	return {}


## What a failed run tells the player, from the tool's exit code (store's header) and its reason.
static func failure_text(store: String, code: int, error: String) -> String:
	match code:
		-1:
			return "This RetroForge build has no %s support." % store
		3:
			return "Sign in to %s first: Settings > Stores." % store
		4:
			return "%s could not be reached. Check the network and try again." % store
	return error if error != "" else "%s failed (%d)." % [store, code]
