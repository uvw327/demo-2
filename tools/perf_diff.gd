extends Node
# 差分探针：区分「场景本身的开销」与「渲染循环空转」两项贡献。
#
#   PROBE_MODE = menu      只建菜单+星空+太阳，不生成星球（背景音乐也不播）
#   PROBE_MODE = planet    生成星球（= 用户场景）
#   PROBE_MODE = nomusic   生成星球但静音（隔离 OGG 解码的 CPU 贡献）
#   PROBE_SECONDS = 采样秒数
#   PROBE_VSYNC / PROBE_MAXFPS / PROBE_WINSIZE 同 perf_idle.gd

var _planet: Node3D
var _frames0 := 0


func _ready() -> void:
	var mode := OS.get_environment("PROBE_MODE")
	if mode == "":
		mode = "planet"
	var secs := float(OS.get_environment("PROBE_SECONDS")) if OS.get_environment("PROBE_SECONDS") != "" else 10.0
	var vsync := float(OS.get_environment("PROBE_VSYNC")) if OS.get_environment("PROBE_VSYNC") != "" else 0.0
	var maxfps := int(float(OS.get_environment("PROBE_MAXFPS")) if OS.get_environment("PROBE_MAXFPS") != "" else 0.0)
	var winsize := OS.get_environment("PROBE_WINSIZE")

	if winsize != "":
		var parts := winsize.split("x")
		if parts.size() == 2:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			DisplayServer.window_set_size(Vector2i(int(parts[0]), int(parts[1])))

	var scene: PackedScene = load("res://planet.tscn")
	_planet = scene.instantiate()
	add_child(_planet)
	await get_tree().process_frame
	await get_tree().process_frame

	if mode != "menu":
		_planet.call("_on_generate_requested", {"seed": 4242, "coverage": 1.0,
				"rainfall": 1.0, "temperature": 1.0})
		await _wait_gen()

	if mode == "nomusic":
		var m := _planet.get_node_or_null("StartMusic") as AudioStreamPlayer
		if m != null:
			m.stop()
			m.stream = null

	if vsync > 0.5:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
	else:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = maxfps

	for i in 60:
		await get_tree().process_frame

	print("[DIFF] MODE=", mode, " vsync=", int(vsync), " maxfps=", maxfps,
			" window=", DisplayServer.window_get_size())
	print("[DIFF] MARK_BEGIN")
	_frames0 = Engine.get_process_frames()
	var t0 := Time.get_ticks_usec()
	while (Time.get_ticks_usec() - t0) < int(secs * 1000000):
		await get_tree().process_frame
	var wall := (Time.get_ticks_usec() - t0) / 1000000.0
	print("[DIFF] frames=", Engine.get_process_frames() - _frames0,
			" wall=%.2f" % wall, " real_fps=%.1f" % ((Engine.get_process_frames() - _frames0) / wall))
	print("[DIFF] tris=", Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
			" draws=", Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	print("[DIFF] MARK_END")
	get_tree().quit()


func _wait_gen() -> void:
	var t := 0
	while t < 3000:
		await get_tree().process_frame
		t += 1
		var mesh_ok := false
		for c in _planet.get_children():
			if c is MeshInstance3D and c.mesh != null:
				mesh_ok = true
		if mesh_ok and t > 30:
			for i in 20:
				await get_tree().process_frame
			return
