## paint_shop.gd - turns a recorded paint job (render/livery.gd) into
## textures.
##
## The painting is 2D drawing, so it is done by the graphics card: each
## display list is drawn once inside an offscreen viewport and read back as a
## texture with mipmaps. That takes a frame or two, so a robot shows in its
## plain base colour for an instant and its paint then pops in.
##
## One job at a time, in the order asked. Finished jobs are remembered by key
## (the robot's id and build), so the menus can show the same robot again and
## again for free.
class_name PaintShop
extends Node

const KEEP := 28                  # finished paint jobs remembered

static var _inst: PaintShop = null

var _queue := []                  # [{ key, plan: Callable, done: [Callable] }]
var _busy := false
var _cache := {}                  # key -> { color, normal, finish }
var _order := []
var _views := {}                  # size -> [SubViewport, CanvasPlay]

## The shop, made the first time it is asked for.
static func shared() -> PaintShop:
	if _inst == null or not is_instance_valid(_inst):
		_inst = PaintShop.new()
		_inst.name = "PaintShop"
		(Engine.get_main_loop() as SceneTree).root.add_child.call_deferred(_inst)
	return _inst

## Ask for a paint job. `plan` returns Livery.paint()'s result when called
## (so nothing is planned for a job that is already in the cache); `done` is
## called with { color, normal, finish } textures (the last two may be null).
func request(key: String, plan: Callable, done: Callable) -> void:
	if _cache.has(key):
		done.call(_cache[key])
		return
	for job in _queue:
		if job.key == key:
			job.done.append(done)
			return
	_queue.append({"key": key, "plan": plan, "done": [done]})

func _process(_dt: float) -> void:
	if _busy or _queue.is_empty(): return
	_run(_queue.pop_front())

func _stage(px: int) -> Array:
	if not _views.has(px):
		var vp := SubViewport.new()
		vp.size = Vector2i(px, px)
		vp.disable_3d = true
		vp.transparent_bg = false
		vp.msaa_2d = Viewport.MSAA_4X
		vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
		vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
		var play := CanvasPlay.new()
		play.size = Vector2(px, px)
		vp.add_child(play)
		add_child(vp)
		_views[px] = [vp, play]
	return _views[px]

func _run(job: Dictionary) -> void:
	if not (job.plan as Callable).is_valid(): return     # whoever asked is gone
	_busy = true
	var plan: Dictionary = job.plan.call()
	var maps := {"color": null, "normal": null, "finish": null}
	if DisplayServer.get_name() != "headless":
		for kind in ["color", "height", "finish"]:
			var rec: CanvasRec = plan.get(kind)
			if rec == null: continue
			var stage := _stage(int(rec.size.x))
			var vp: SubViewport = stage[0]
			var play: CanvasPlay = stage[1]
			play.show_list(rec.list)
			vp.render_target_update_mode = SubViewport.UPDATE_ONCE
			await RenderingServer.frame_post_draw
			await RenderingServer.frame_post_draw
			var img := vp.get_texture().get_image()
			play.show_list([])
			if img == null or img.is_empty(): continue
			if img.get_format() != Image.FORMAT_RGBA8: img.convert(Image.FORMAT_RGBA8)
			if kind == "height":
				img.bump_map_to_normal_map(5.0)
				img.generate_mipmaps(true)
				maps.normal = ImageTexture.create_from_image(img)
			else:
				img.generate_mipmaps()
				maps[kind] = ImageTexture.create_from_image(img)
	_cache[job.key] = maps
	_order.append(job.key)
	while _order.size() > KEEP: _cache.erase(_order.pop_front())
	for fn in job.done:
		if fn.is_valid(): fn.call(maps)
	_busy = false
