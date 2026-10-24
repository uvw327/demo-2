extends Node
# 性能探针：真实生成一颗星球，然后分阶段采样帧率 / CPU 时间 / draw call / 三角形数。
#
# 用法：
#   godot.exe --path <项目根> --script res://tools/perf_probe.gd  (不行，--script 需要 MainLoop)
#   实际用：godot.exe --path <项目根> res://tools/perf_probe.tscn
#
# 环境变量：
#   PROBE_COVERAGE  0.3 / 1.0   默认 0.3
#   PROBE_SECONDS    采样时长（秒），默认 5
#   PROBE_FRAMES     额外启动后等待帧数

var _planet: Node3D
var _phase := ""
var _acc := {}
var _samples := 0


func _ready() -> void:
	var coverage := float(OS.get_environment("PROBE_COVERAGE")) if OS.get_environment("PROBE_COVERAGE") != "" else 0.3
	var secs := float(OS.get_environment("PROBE_SECONDS")) if OS.get_environment("PROBE_SECONDS") != "" else 5.0

	var scene: PackedScene = load("res://planet.tscn")
	_planet = scene.instantiate()
	add_child(_planet)
	await get_tree().process_frame
	await get_tree().process_frame

	print("[PROBE] ==== 环境 ====")
	print("[PROBE] renderer = ", ProjectSettings.get_setting("rendering/renderer/rendering_method"))
	print("[PROBE] vsync_mode(project) = ", ProjectSettings.get_setting("display/window/vsync/vsync_mode"))
	print("[PROBE] window size = ", DisplayServer.window_get_size())
	print("[PROBE] viewport size = ", get_viewport().get_visible_rect().size)
	print("[PROBE] render size = ", get_viewport().get_screen_transform())
	print("[PROBE] screen = ", DisplayServer.screen_get_size())

	var t_gen0 := Time.get_ticks_msec()
	_planet.call("_on_generate_requested", {"seed": 4242, "coverage": coverage,
			"rainfall": 1.0, "temperature": 1.0})
	await _wait_gen()
	print("[PROBE] 生成完毕，耗时 ", Time.get_ticks_msec() - t_gen0, " ms")

	# 预热：让 shader 编译 / 贴图上传 / 驱动缓存稳定下来
	for i in 30:
		await get_tree().process_frame

	# ---- 阶段 A：基线（项目当前配置：vsync 关、无 max_fps）----
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	await _sample("A 基线 (vsync=OFF, max_fps=0)", secs)

	# ---- 阶段 B：仅开 vsync ----
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
	await _sample("B vsync=ON, max_fps=0", secs)

	# ---- 阶段 C：vsync 关 + max_fps=60 ----
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 60
	await _sample("C vsync=OFF, max_fps=60", secs)

	# ---- 阶段 D：vsync 开 + max_fps=60 ----
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
	Engine.max_fps = 60
	await _sample("D vsync=ON, max_fps=60", secs)

	# ---- 阶段 E：回到基线，再把 3D 渲染分辨率压到 1/4，隔离「像素量」的贡献 ----
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	get_viewport().scaling_3d_scale = 0.5
	await get_tree().process_frame
	await _sample("E 基线 + 3D 渲染缩放 0.5x", secs)

	print("[PROBE] ==== 结束 ====")
	get_tree().quit()


func _sample(label: String, secs: float) -> void:
	_acc = {"fps": 0.0, "proc": 0.0, "draw": 0.0, "prim": 0.0, "vram": 0.0, "n": 0.0}
	_samples = 0
	var frames0 := Engine.get_process_frames()
	var t0 := Time.get_ticks_msec()
	var wall0 := Time.get_ticks_usec()
	while (Time.get_ticks_msec() - t0) < int(secs * 1000.0):
		await get_tree().process_frame
		_acc["fps"] += Performance.get_monitor(Performance.TIME_FPS)
		_acc["proc"] += Performance.get_monitor(Performance.TIME_PROCESS)
		_acc["draw"] += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		_acc["prim"] += Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
		_acc["vram"] += Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)
		_samples += 1
	var wall := (Time.get_ticks_usec() - wall0) / 1000000.0
	var frames := Engine.get_process_frames() - frames0
	print("[PROBE] -------- ", label, " --------")
	print("[PROBE]   实际帧数 = ", frames, " / 墙钟 ", "%.2f" % wall, " s  => 真实 FPS = %.1f" % (frames / wall))
	print("[PROBE]   Performance.TIME_FPS(引擎自报) = %.1f" % (_acc["fps"] / maxf(_samples, 1)))
	print("[PROBE]   每帧主线程 process 时间 = %.2f ms  (占墙钟 %.1f%%)" % [
			_acc["proc"] / maxf(_samples, 1) * 1000.0,
			(_acc["proc"] / maxf(wall, 0.001)) * 100.0])
	print("[PROBE]   draw calls/帧 = %.0f   三角形/帧 = %.0f   显存 = %.1f MB" % [
			_acc["draw"] / maxf(_samples, 1),
			_acc["prim"] / maxf(_samples, 1),
			_acc["vram"] / maxf(_samples, 1) / 1048576.0])
	print("[PROBE]   节点数 = ", Performance.get_monitor(Performance.OBJECT_NODE_COUNT))


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
