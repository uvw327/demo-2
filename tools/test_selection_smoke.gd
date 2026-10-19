# 临时冒烟：不渲染地验证“点击选区”核心逻辑（选中环几何 + 射线拾取数学）。
# 用法：godot --headless --path . --script res://tools/test_selection_smoke.gd
extends SceneTree

var _done := false


func _initialize() -> void:
	_smoke.call_deferred()


func _process(_delta: float) -> bool:
	return _done  # 返回 true 结束主循环


func _smoke() -> void:
	var planet: Node3D = load("res://planet.gd").new()
	root.add_child(planet)  # _ready 挂相机与菜单（headless 下也能建）
	# 伪造两块贴片的拓扑（单位球面），绕过重量级生成流程
	var axis_a := Vector3(0, 0, 1)
	var axis_b := Vector3(1, 0, 0)
	var topo: Array[Vector3] = [axis_a, axis_b]
	planet._topo_verts = topo
	var poly := PackedVector3Array()
	for i in 6:
		var ang := TAU * i / 6.0
		poly.append((axis_a + axis_a.cross(Vector3(1, 0, 0)) * cos(ang) + Vector3(0, 1, 0) * sin(ang) * 0.5).normalized())
	planet._tile_polys = [poly, PackedVector3Array()] as Array[PackedVector3Array]
	planet._generated = PackedByteArray([1, 1])

	# 等一帧让相机就位后再测拾取
	await process_frame

	var fails := 0
	# —— 选中 → 环 mesh 存在、可见、顶点数为边界数×2 ——
	planet.select_tile(0)
	var ring: MeshInstance3D = planet._selection_ring
	if ring == null:
		print("FAIL: 环实例未创建")
		fails += 1
	else:
		var m: ArrayMesh = ring.mesh
		var vcount: int = m.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size()
		if ring.visible and vcount == poly.size() * 2:
			print("PASS: 选中环已生成，顶点数 ", vcount)
		else:
			print("FAIL: 环状态异常 visible=", ring.visible, " 顶点=", vcount)
			fails += 1
	# —— 取消 → 隐藏 ——
	planet.deselect()
	if not ring.visible and planet._selected_tile == -1:
		print("PASS: 取消选中后环隐藏")
	else:
		print("FAIL: 取消选中语义异常")
		fails += 1
	# —— 点按拾取：屏幕中心应命中 axis_a 方向 → tile 0 ——
	var vp_size := root.get_visible_rect().size
	planet._on_view_tapped(vp_size * 0.5)
	if planet._selected_tile == 0:
		print("PASS: 屏幕中心点按拾取到贴片 0")
	else:
		print("FAIL: 中心拾取错 (selected=", planet._selected_tile, ")")
		fails += 1
	# —— 点到星空（屏幕角部）→ 取消 ——
	planet.select_tile(0)
	planet._on_view_tapped(Vector2(vp_size.x * 0.02, vp_size.y * 0.02))
	if planet._selected_tile == -1:
		print("PASS: 点到星空取消选中")
	else:
		print("FAIL: 星空拾取语义异常 (selected=", planet._selected_tile, ")")
		fails += 1
	# —— 点到不可交互（未生成）贴片 → 取消 ——
	planet._generated = PackedByteArray([0, 1])
	planet.select_tile(0)
	planet._on_view_tapped(vp_size * 0.5)
	if planet._selected_tile == -1:
		print("PASS: 不可交互贴片取消选中")
	else:
		print("FAIL: 不可交互语义异常 (selected=", planet._selected_tile, ")")
		fails += 1

	print("=== 冒烟结束：", "全通过" if fails == 0 else str(fails) + " 项失败", " ===")
	_done = true
