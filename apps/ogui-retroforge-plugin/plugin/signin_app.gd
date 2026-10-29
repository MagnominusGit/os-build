extends RunningApp
## The store sign-in's Chromium as one of OGUI's running apps (signin_window.gd). OGUI did not start
## it, so it runs while /proc/<pid> exists (OS.is_process_running only knows Godot's own children),
## and OGUI's Exit (the Guide menu) calls `on_exit`, the plugin's Cancel, instead of OGUI's Reaper,
## which spares the pid it is given (it takes it for its reaper process).

## The plugin's Cancel of the sign-in.
var on_exit := Callable()


func is_running() -> bool:
	return pid > 0 and DirAccess.dir_exists_absolute("/proc/%d" % pid)


func kill(_sig: Reaper.SIG = Reaper.SIG.TERM) -> void:
	if state == STATE.STOPPED:
		return
	state = STATE.STOPPING
	app_stopped.emit()
	if on_exit.is_valid():
		on_exit.call()
