# 临时回归：「扰动球冠」选区（第 4 轮性能手术重写）的核心不变量验证。
# 用法：godot --headless --path . --script res://tools/test_region_cap.gd
# 验证项：
#   [1] 30%/50% 档：region 面积逐位精确 = round(total × coverage)
#   [2] 100% 档：短路 fill(1)，整球可交互
#   [3] 确定性：同种子同覆盖率同中心，两次生成 region 逐位一致
#   [4] 单块连通：区域贴片在对偶网格上构成 1 个连通块
#       （邻接从 _tile_polys 的共享对偶顶点反推，等价于细分网格棱）
#   [5] 水域派生一致性：_inland_water=1 ⇔ 区内海拔<海平面，
#       且这些贴片的地形恒为平原（海底平原语义）
extends SceneTree

var _done := false


func _initialize() -> void:
	_run.call_deferred()


func _process(_delta: float) -> bool:
	return _done # 返回 true 结束主循环


func _are_equal(a: PackedByteArray, b: PackedByteArray) -> bool:
	var n := a.size()
	for i in n:
		if a[i] != b[i]:
			return false
	return true


func _pair_key(a: Vector3i, b: Vector3i) -> String:
	# 棱两端点按字典序规范化，保证两块贴片算出同一个 key
	var flip := false
	if a.x > b.x:
		flip = true
	elif a.x == b.x and a.y > b.y:
		flip = true
	elif a.x == b.x and a.y == b.y and a.z > b.z:
		flip = true
	var p := b if flip else a
	var q := a if flip else b
	return "%d,%d,%d|%d,%d,%d" % [p.x, p.y, p.z, q.x, q.y, q.z]


func _region_components(planet: Node3D) -> int:
	# 从每贴片独占的对偶多边形反推邻接：相邻贴片的对偶顶点（三角形重心）
	# 是同一批浮点值，量化到 1e-5 格点后逐位相等；每条棱由且只由相邻
	# 两块贴片共享。返回区域连接块个数。
	var polys = planet._tile_polys
	var edges := {}
	var adj: Array = []
	adj.resize(polys.size())
	for i in polys.size():
		adj[i] = PackedInt32Array()
	for ti in polys.size():
		var poly: PackedVector3Array = polys[ti]
		var n := poly.size()
		for k in n:
			var ka := Vector3i((poly[k] * 1e5).round())
			var kb := Vector3i((poly[(k + 1) % n] * 1e5).round())
			var key := _pair_key(ka, kb)
			if edges.has(key):
				var other: int = edges[key]
				if other != ti:
					adj[ti].append(other)
					adj[other].append(ti)
			else:
				edges[key] = ti
	var seen := PackedByteArray()
	seen.resize(polys.size())
	var comps := 0
	for t in polys.size():
		if planet._generated[t] != 1 or seen[t] == 1:
			continue
		comps += 1
		var stack: Array = [t]
		seen[t] = 1
		while stack.size() > 0:
			var w: int = stack.pop_back()
			for nb in adj[w]:
				if planet._generated[nb] == 1 and seen[nb] == 0:
					seen[nb] = 1
					stack.append(nb)
	return comps


func _run() -> void:
	var planet: Node3D = load("res://planet.gd").new()
	root.add_child(planet) # _ready 挂相机与菜单（headless 下也能建）
	await process_frame

	var center := Vector3(0, 0, 1) # 测试固定球冠中心（镜头方向的替身）
	var fails := 0

	# —— [1] 面积逐位精确（30% / 50%）+ [4] 单块连通 + [5] 水域派生 ——
	for cov in [0.3, 0.5]:
		planet._init_noise(4242)
		planet._rain_shift = 0.0
		planet._temp_shift = 0.0
		await planet._build_goldberg_mesh_async(cov, center)
		var total: int = planet._topo_verts.size()
		var target := roundi(total * cov)
		var n_gen := 0
		for i in total:
			if planet._generated[i] == 1:
				n_gen += 1
		if n_gen == target:
			print("PASS[%s]: 面积精确 %d / %d（目标 %d）"
					% [str(int(cov * 100)) + "%", n_gen, total, target])
		else:
			print("FAIL: 面积 %d ≠ 目标 %d（覆盖率 %.0f%%）" % [n_gen, target, cov * 100])
			fails += 1
		var comps: int = _region_components(planet)
		if comps == 1:
			print("PASS: 区域单块连通")
		else:
			print("FAIL: 区域连通块个数 = ", comps)
			fails += 1
		# 水域派生：_inland_water == (区内 elev < SEA_LEVEL)，恒平原
		var n_water := 0
		var bad_water := 0
		for i in total:
			var expect: int = planet._inland_water[i]
			var derived := 1 if (planet._generated[i] == 1
					and planet._tile_elev[i] < planet.SEA_LEVEL) else 0
			if expect != derived:
				bad_water += 1
			if expect == 1:
				n_water += 1
				if planet._terrain[i] != planet.TerrainLevel.FLAT:
					bad_water += 1
		if bad_water == 0 and n_water > 0:
			print("PASS: 水域派生一致（%d 贴片，含大陆架收边）" % n_water)
		else:
			print("FAIL: 水域派生不一致 bad=", bad_water, " count=", n_water)
			fails += 1

	# —— [2] 100% 短路整球 ——
	await planet._build_goldberg_mesh_async(1.0, center)
	var total2: int = planet._topo_verts.size()
	var n_all := 0
	for i in total2:
		if planet._generated[i] == 1:
			n_all += 1
	if n_all == total2:
		print("PASS: 100% 档整球可交互")
	else:
		print("FAIL: 100% 档只生成 ", n_all, "/", total2)
		fails += 1

	# —— [3] 确定性：同种子同参两次生成 region 逐位一致 ——
	planet._init_noise(4242)
	await planet._build_goldberg_mesh_async(0.3, center)
	var r1: PackedByteArray = planet._generated.duplicate()
	await planet._build_goldberg_mesh_async(0.3, center)
	var r2: PackedByteArray = planet._generated
	if _are_equal(r1, r2):
		print("PASS: 同种子同参两次生成逐位一致")
	else:
		print("FAIL: 两次生成结果不一致")
		fails += 1

	print("=== 冒烟结束：", "全通过" if fails == 0 else str(fails) + " 项失败", " ===")
	_done = true
