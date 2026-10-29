extends RefCounted
## Runs /usr/bin/retroforge-launch --psn-install for the PSN packages row (plan psn-pkg Phase 3).
##
## The verb installs everything the player dropped into ~/roms/ps3/psn (one headless RPCS3 run),
## writes a .psn stub per base game, consumes what succeeded, and prints one TAB-separated result
## line per file: `ok|failed <TAB> <file> <TAB> <title id or -> <TAB> <stub or ->`, or
## `nothing-to-do` for an empty folder. A multi-GB install takes minutes, so the tool runs on a
## worker thread (scrape_runner.gd's shape); stderr is drained on a second task so a chatty RPCS3
## cannot stall it. No cancel: a SIGTERM would kill RPCS3 mid-extract. No OGUI types: tested on a
## stock headless Godot (tests/test-plugin.sh) against a fake tool.

## The tool ended: its exit code (-1 when it could not start), its result lines as
## [{"status", "file", "title_id", "stub"}], and its last stderr line ("" on success).
signal finished(code: int, results: Array, error: String)

const TOOL := "/usr/bin/retroforge-launch"

var tool := TOOL
var running := false


## Start the install. False when a run is already going.
func start() -> bool:
	if running:
		return false
	running = true
	WorkerThreadPool.add_task(_run)
	return true


# Worker thread.
func _run() -> void:
	# Godot forks before it tries the program: a missing one still "runs" with a bogus exit code.
	var pipe := OS.execute_with_pipe(tool, ["--psn-install"], true) if FileAccess.file_exists(tool) else {}
	if pipe.is_empty():
		_end.call_deferred(-1, [], "")
		return
	var io: FileAccess = pipe["stdio"]
	var errors: Array[String] = []
	var err_task := WorkerThreadPool.add_task(_drain.bind(pipe["stderr"], errors))
	var results := []
	while true:
		var line := io.get_line()
		if line == "" and io.get_error() != OK:
			break
		var parsed := parse_line(line)
		if not parsed.is_empty():
			results.append(parsed)
	WorkerThreadPool.wait_for_task_completion(err_task)
	while OS.is_process_running(pipe["pid"]):
		OS.delay_msec(10)
	var code := OS.get_process_exit_code(pipe["pid"])
	_end.call_deferred(code, results, "" if code == 0 or errors.is_empty() else errors[-1])


# Worker thread: read stderr to its end, keeping its lines.
static func _drain(err: FileAccess, lines: Array[String]) -> void:
	while true:
		var line := err.get_line()
		if line == "" and err.get_error() != OK:
			return
		if line != "":
			lines.append(line)


func _end(code: int, results: Array, error: String) -> void:
	running = false
	finished.emit(code, results, error)


## A result line as {"status", "file", "title_id", "stub"}; {} for anything else (the tool's
## `nothing-to-do` included: no results is that).
static func parse_line(line: String) -> Dictionary:
	var parts := line.split("\t")
	if parts.size() != 4 or not parts[0] in ["ok", "failed"]:
		return {}
	return {"status": parts[0], "file": parts[1], "title_id": parts[2], "stub": parts[3]}


## Whether a run gave any game a new card (its stub): the ROM library should reload.
static func any_stub(results: Array) -> bool:
	for r in results:
		if r.get("status") == "ok" and r.get("stub", "-") != "-":
			return true
	return false


## What a finished run achieved, for a notification.
static func results_text(results: Array) -> String:
	var games := 0
	var licences := 0
	var failed := 0
	for r in results:
		if r.get("status") != "ok":
			failed += 1
		elif str(r.get("file", "")).to_lower().ends_with(".pkg"):
			games += 1
		else:
			licences += 1
	if games == 0 and licences == 0 and failed == 0:
		return "Nothing to install: the PSN folder is empty."
	var parts := PackedStringArray()
	if games:
		parts.append("Installed %d package%s." % [games, "" if games == 1 else "s"])
	if licences:
		parts.append("%d licence%s." % [licences, "" if licences == 1 else "s"])
	if failed:
		parts.append("%d failed and stay%s in roms/ps3/psn." % [failed, "s" if failed == 1 else ""])
	return " ".join(parts)


## What a failed run tells the player, from the verb's exit code and last stderr line.
static func failure_text(code: int, error: String) -> String:
	if "already running" in error:
		return "A PSN install or a PlayStation 3 game is already running."
	if "not installed" in error:
		return "RPCS3 is not installed. Download it from Apps in the main menu first."
	return "The PSN install could not run (%d)." % code
