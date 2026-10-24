extends RefCounted
## One texture per art file, shared by every card that shows it: a game has a card in its own tab,
## in the library's other tabs and on the home screen, and each card asks for its art. Held by weak
## reference, so a texture lives exactly as long as some card holds it: nothing outlives the cards
## showing it (a 2,000-ROM library keeps no textures once its cards are gone). A newer art file
## (its mtime) is decoded again. No OGUI types, so tests/test-plugin.sh runs it on a stock Godot.

## Signals the cards that asked for a key while its one decode ran.
class Loading:
	signal done(texture: Texture2D)

var _shared := {}  # key -> {"ref": WeakRef to the texture, "mtime": the art file's when decoded}
var _loading := {}  # key -> Loading, while that key's decode runs


## The texture for `key`, made from the art file `src`: the one a card still holds, else `job`'s
## Image (run on a worker thread) uploaded once however many cards ask meanwhile; null without one.
func texture(key: String, src: String, job: Callable) -> Texture2D:
	var mtime := FileAccess.get_modified_time(src)
	var entry: Dictionary = _shared.get(key, {})
	if not entry.is_empty() and entry["mtime"] == mtime:
		var held: Texture2D = entry["ref"].get_ref()
		if held:
			return held
	if key in _loading:
		return await (_loading[key] as Loading).done
	var loading := Loading.new()
	_loading[key] = loading
	var image: Image = await run(job)
	var made: Texture2D = ImageTexture.create_from_image(image) if image else null
	_loading.erase(key)
	if made:
		_shared[key] = {"ref": weakref(made), "mtime": mtime}
	else:
		_shared.erase(key)
	loading.done.emit(made)
	return made


## `job`'s result, computed on a WorkerThreadPool task while frames keep drawing.
func run(job: Callable) -> Variant:
	var out := []
	var task := WorkerThreadPool.add_task(func() -> void: out.append(job.call()))
	var tree := Engine.get_main_loop() as SceneTree
	while not WorkerThreadPool.is_task_completed(task):
		await tree.process_frame
	WorkerThreadPool.wait_for_task_completion(task)
	return out[0] if not out.is_empty() else null
