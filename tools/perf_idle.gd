extends Node
# 稳态空闲探针：生成星球 → 静置在固定配置下 N 秒 → 输出真实 FPS。
# 通过环境变量切换配置，便于逐项对照（每个配置单独起一个进程跑）。
#
#   PROBE_COVERAGE   覆盖率 0.3 / 1.0            默认 1.0
#   PROBE_SECONDS    采样时长（秒）              默认 8
#   PROBE_VSYNC      0=off 1=on                 默认 0（复现项目现状）
#   PROBE_MAXFPS     0=不限                      默认 0
#   PROBE_3DSCALE    3D 渲染缩放                 默认 1.0
#   PROBE_WINSIZE    窗口宽x高，空=保持项目设置   默认空（项目=全屏 4K）

var _planet: Node3D
var _frames0 := 0


func _ready() -> void:
	var coverage := _env_f("PROBE_COVERAGE", 1.0)
	var secs := _env_f("PROBE_SECONDS", 8.0)
	var vsync := _env_f("PROBE_VSYNC", -1.0)
	var maxfps := int(_env_f("PROBE_MAXFPS", 0.0))
	var scale3d := _env_f("PROBE_3DSCALE", 1.0)
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

	_planet.call("_on_generate_requested", {"seed": 4242, "coverage": coverage,
			"rainfall": 1.0, "temperature": 1.0})
	await _wait_gen()

	# 应用配置（vsync < 0 表示沿用项目设置，不覆盖）
	if vsync >= 0.0:
		if vsync > 0.5:
			DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
		else:
			DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = maxfps
	if absf(scale3d - 1.0) > 0.001:
		get_viewport().scaling_3d_scale = scale3d

	# 预热 60 帧（着色器编译、贴图上传、驱动缓存）
	for i in 60:
		await get_tree().process_frame

	print("[IDLE] CONFIG vsync=", int(vsync), " max_fps=", maxfps,
			" 3d_scale=", scale3d, " window=", DisplayServer.window_get_size(),
			" viewport=", get_viewport().get_visible_rect().size)
	print("[IDLE] MARK_BEGIN")
	_frames0 = Engine.get_process_frames()
	var t0 := Time.get_ticks_usec()
	await _idle(secs)
	var wall := (Time.get_ticks_usec() - t0) / 1000000.0
	var frames := Engine.get_process_frames() - _frames0
	print("[IDLE] frames=", frames, " wall=%.2f" % wall, " real_fps=%.1f" % (frames / wall))
	print("[IDLE] draw_calls=", Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
			" tris=", Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	print("[IDLE] MARK_END")
	get_tree().quit()


func _idle(secs: float) -> void:
	var t := Time.get_ticks_msec()
	while (Time.get_ticks_msec() - t) < int(secs * 1000.0):
		await get_tree().process_frame


func _env_f(key: String, def: float) -> float:
	var v := OS.get_environment(key)
	return float(v) if v != "" else def


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
