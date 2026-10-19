# 临时诊断：真实生成一颗星球，再合成"鼠标左键按下/抬起"事件，
# 验证 相机输入层 → view_tapped → planet 拾取 → 选中环 的整条链路在哪一环断掉。
# 用法：godot --headless --path . --script res://tools/test_selection_chain.gd
extends SceneTree

var _done := false


func _initialize() -> void:
	_run.call_deferred()


func _process(_delta: float) -> bool:
	return _done


func _run() -> void:
	var planet: Node3D = load("res://planet.gd").new()
	root.add_child(planet)
	await process_frame

	# —— 真跑生成（分帧流水线在 headless 主循环里也会逐帧推进）——
	planet._on_generate_requested({
		"seed": 4242, "coverage": 0.5, "rainfall": 1, "temperature": 1,
	})
	var tries := 0
	while tries < 60000 and (planet._mesh_instance == null or planet._menu != null):
		await process_frame
		tries += 1
	print("[1] 生成结束? tries=", tries,
		" mesh=", planet._mesh_instance != null,
		" menu清算=", planet._menu == null,
		" polys=", planet._tile_polys.size(),
		" generated=", planet._generated.size())

	# —— 链路 A：直接调 planet._on_view_tapped（跳过输入层）——
	var vp := root.get_visible_rect().size
	print("[2] viewport=", vp)
	if planet._orbit == null or planet._orbit.cam == null:
		print("FAIL: 相机引用为空 orbit=", planet._orbit != null, " cam=", planet._orbit != null and planet._orbit.cam != null)
		_done = true
		return
	var from: Vector3 = planet._orbit.cam.project_ray_origin(vp * 0.5)
	var dir: Vector3 = planet._orbit.cam.project_ray_normal(vp * 0.5)
	var b := from.dot(dir)
	var c := from.length_squared() - 1.0
	print("[3] 射线 look=", dir, " from=", from, " b=", b, " c=", c, " 判断 disc=", b * b - c)
	planet._on_view_tapped(vp * 0.5)
	print("[4] 直接拾取结果 selected=", planet._selected_tile,
		" ring_visible=", planet._selection_ring != null and planet._selection_ring.visible,
		" ring_mesh=", planet._selection_ring != null and planet._selection_ring.mesh != null)
	await process_frame
	await process_frame

	# —— 渲染实证：选中状态下等 2 帧让 GPU 渲染，截屏 + 环中心亮度采样 ——
	if planet._selected_tile >= 0 and planet._selection_ring != null:
		var world_center: Vector3 = planet._selection_ring.get_aabb().get_center()
		var screen_pos: Vector2 = planet._orbit.cam.unproject_position(world_center)
		await process_frame
		await process_frame
		var img := root.get_texture().get_image()
		if img != null:
			var png_path := OS.get_environment("TEMP").path_join("ring_render.png")
			img.save_png(png_path)
			print("[7] 截屏已存 ", png_path, " 尺寸=", img.get_size())
			# 帧缓冲可能带内容缩放（4K 屏 3×）：视口坐标 → 帧缓冲像素坐标
			var scale := Vector2(img.get_size()) / root.get_visible_rect().size
			var buffer_pos := Vector2i((screen_pos * scale).floor())
			print("[7b] 视口坐标=", screen_pos, " 缩放=", scale, " 帧缓冲坐标=", buffer_pos)
			var max_lum := 0.0
			var bright_px := 0
			var half := 40  # 环中心 ±40px 邻域
			for dx in range(-half, half + 1, 2):
				for dy in range(-half, half + 1, 2):
					var px := img.get_pixelv(buffer_pos + Vector2i(dx, dy))
					var lum := maxf(px.r, maxf(px.g, px.b))
					max_lum = maxf(max_lum, lum)
					if lum > 0.75:
						bright_px += 1
			print("[8] 邻域最大亮度=", max_lum, " 亮像素数(>0.75)=", bright_px,
				"（若接近 0 → 环在真实渲染中不可见）")
			# 裁剪环中心 160×160 区域放大 4 倍保存，供肉眼检查
			var crop := img.get_region(Rect2i(buffer_pos - Vector2i(80, 80), Vector2i(160, 160)))
			crop.resize(640, 640, Image.INTERPOLATE_NEAREST)
			crop.save_png(OS.get_environment("TEMP").path_join("ring_crop.png"))
			print("[9] 环中心裁剪图已存 ring_crop.png")

	# —— 链路 B：合成真实鼠标按下+抬起（走相机的 _unhandled_input）——
	# 探针 1：另一个自由节点的 _unhandled_input 是否收到事件（判定派发层）
	var probe := Node3D.new()
	probe.set_script(preload("res://tools/test_input_probe_node.gd"))
	root.add_child(probe)
	# 探针 2：相机 view_tapped 信号是否真的发出
	planet._orbit.view_tapped.connect(func(p): print("[sig] view_tapped ", p))
	planet.deselect()
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = vp * 0.5
	press.button_mask = MOUSE_BUTTON_MASK_LEFT
	Input.parse_input_event(press)
	await process_frame
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = vp * 0.5
	Input.parse_input_event(release)
	await process_frame
	await process_frame
	print("[5] 合成鼠标事件后 selected=", planet._selected_tile,
		" ring_visible=", planet._selection_ring != null and planet._selection_ring.visible,
		"（若与[4]不同 → 断点在相机的 _unhandled_input/事件被吃）")

	# —— 选中环的包围盒（确认几何位置合理）——
	if planet._selection_ring != null and planet._selection_ring.mesh != null:
		var aabb: AABB = planet._selection_ring.get_aabb()
		print("[6] 环 AABB 中心=", aabb.get_center(), " 半径参考=", aabb.get_longest_axis_size())

	print("=== 链路诊断结束 ===")
	_done = true
