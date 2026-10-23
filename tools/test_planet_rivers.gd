# 河流层回归护栏（headless 冒烟）：贴片邻接 / 水文 parent 链 / 河段阈值 /
# ribbon mesh 几何 / 图层 priority 与 shader 参数。
# 对应 docs/planet_rivers_plan.md（第 3 期一期）。
# 运行：godot --headless --path . --script res://tools/test_planet_rivers.gd
extends SceneTree

const PlanetScript := preload("res://planet.gd")

var _done := false
var _ok := true


func _initialize() -> void:
	_run.call_deferred()


func _process(_delta: float) -> bool:
	return _done


func _run() -> void:
	var planet: Node3D = PlanetScript.new()
	root.add_child(planet)
	await process_frame

	# —— 1) 生成星球（湿润种子，保证有河；与丘陵测试同种子便于对照）——
	planet._on_generate_requested({
		"seed": 4242, "coverage": 0.3, "rainfall": 1, "temperature": 1,
	})
	var tries := 0
	while tries < 60000 and (planet._mesh_instance == null or planet._menu != null):
		await process_frame
		tries += 1
	if planet._mesh_instance == null:
		print("FAIL: 星球未生成")
		_quit(1)
		return
	var total: int = planet._tile_centers.size()

	# —— 2) 邻接：N×6，5/6 邻居，恰好 12 个五边形，且严格对称 ——
	var ok_adj: bool = planet._tile_neighbors.size() == total * 6 \
			and planet._tile_neighbor_count.size() == total
	var five_n := 0
	var bad_adj := -1
	if ok_adj:
		for v in total:
			var cnt: int = planet._tile_neighbor_count[v]
			if cnt != 5 and cnt != 6:
				bad_adj = v
				break
			if cnt == 5:
				five_n += 1
			var seen := PackedInt32Array()
			for k in cnt:
				var u: int = planet._tile_neighbors[v * 6 + k]
				if u < 0 or u >= total or u == v:
					bad_adj = v
					break
				for k2 in seen.size():
					if seen[k2] == u:
						bad_adj = v
						break
				if bad_adj != -1:
					break
				seen.append(u)
				# 邻接必须严格对称：u 的邻居表里也要有 v
				var back := false
				for k2 in planet._tile_neighbor_count[u]:
					if planet._tile_neighbors[u * 6 + k2] == v:
						back = true
						break
				if not back:
					bad_adj = v
					break
			if bad_adj != -1:
				break
	ok_adj = ok_adj and bad_adj == -1 and five_n == 12
	print(bin_if(ok_adj, "贴片邻接 N×6：5/6 邻居且五边形恰 12 个%s"
			% ["" if bad_adj == -1 else "，坏贴片 %d" % bad_adj]))
	_ok = _ok and ok_adj

	# —— 3) 河段：非空、端点合法、from 是陆地、to 是 from 的邻居 ——
	var edge_n: int = planet._river_edges.size() >> 1
	var ok_edges: bool = edge_n > 0 and edge_n == planet._river_edge_count
	var bad_edge := -1
	if ok_edges:
		for e in edge_n:
			var a: int = planet._river_edges[e * 2]
			var b: int = planet._river_edges[e * 2 + 1]
			if a < 0 or a >= total or b < 0 or b >= total or a == b \
					or planet._generated[a] != 1 or planet._generated[b] != 1 \
					or planet._inland_water[a] == 1:
				bad_edge = e
				break
			if not _is_neighbor(planet, a, b):
				bad_edge = e
				break
	ok_edges = ok_edges and bad_edge == -1
	print(bin_if(ok_edges, "河段 %d 条：端点合法、from 为陆地、to 为邻接贴片%s"
			% [edge_n, "" if bad_edge == -1 else "，坏河段 %d" % bad_edge]))
	_ok = _ok and ok_edges

	# —— 4) parent 链：每条河段 to == parent[from]；沿 parent 必达水面且无环 ——
	var ok_chain: bool = planet._river_parent.size() == total \
			and planet._river_flow.size() == total \
			and planet._river_filled.size() == total
	var bad_chain := -1
	var max_steps := 0
	var reached_mouths := 0
	if ok_chain:
		for e in edge_n:
			var a: int = planet._river_edges[e * 2]
			var b: int = planet._river_edges[e * 2 + 1]
			if planet._river_parent[a] != b:
				bad_chain = a
				break
			if planet._river_filled[b] >= planet._river_filled[a]:
				bad_chain = a
				break
		if bad_chain == -1:
			for e in edge_n:
				var v: int = planet._river_edges[e * 2]
				var steps := 0
				while steps < total:
					if planet._inland_water[v] == 1:
						reached_mouths += 1
						break
					var p: int = planet._river_parent[v]
					if p < 0:
						break
					v = p
					steps += 1
				max_steps = maxi(max_steps, steps)
				if steps >= total:
					bad_chain = planet._river_edges[e * 2]
					break
	ok_chain = ok_chain and bad_chain == -1 and reached_mouths == edge_n
	print(bin_if(ok_chain, "parent 链：%d 条河段全部入水、无环（最长 %d 跳）%s"
			% [reached_mouths, max_steps,
			"" if bad_chain == -1 else "，坏贴片 %d" % bad_chain]))
	_ok = _ok and ok_chain

	# —— 5) A 方案：Qc 候选 → 整树/短枝过滤，最终边是候选的子集 ——
	var threshold: float = float(planet._river_stats["threshold"])
	var candidate_tiles: int = int(planet._river_stats["candidate_tiles"])
	var expected_candidates := 0
	var candidate_mask := PackedByteArray()
	candidate_mask.resize(total)
	for v in total:
		if planet._generated[v] == 1 and planet._inland_water[v] == 0 \
				and planet._river_parent[v] >= 0 \
				and planet._river_flow[v] >= threshold:
			expected_candidates += 1
			candidate_mask[v] = 1
	var bad_final := -1
	var actual_mouths := 0
	for e in edge_n:
		var a: int = planet._river_edges[e * 2]
		var b: int = planet._river_edges[e * 2 + 1]
		if candidate_mask[a] == 0:
			bad_final = a
			break
		if planet._inland_water[b] == 1:
			actual_mouths += 1
	var density: float = float(planet._river_stats["density"])
	var tree_pruned: int = int(planet._river_stats["tree_pruned_tiles"])
	var branch_pruned: int = int(planet._river_stats["branch_pruned_tiles"])
	var tree_min: int = int(planet._river_stats["tree_min"])
	var branch_min: int = int(planet._river_stats["branch_min"])
	var branch_p50: float = float(planet._river_stats["branch_p50"])
	var trunk_p50: float = float(planet._river_stats["trunk_p50"])
	var mouths: int = int(planet._river_stats["mouths"])
	var ok_stats: bool = candidate_tiles == expected_candidates \
			and edge_n > 0 and edge_n < candidate_tiles \
			and tree_pruned + branch_pruned == candidate_tiles - edge_n \
			and bad_final == -1 \
			and tree_min >= PlanetScript.RIVER_TREE_MIN_EDGES \
			and branch_min >= PlanetScript.RIVER_BRANCH_MIN_EDGES \
			and density >= 0.105 and density <= 0.120 \
			and mouths >= 25 and mouths <= 30 and mouths == actual_mouths \
			and branch_p50 >= 7.0 and trunk_p50 >= 12.0 \
			and int(planet._river_stats["land"]) > 0
	var stats_msg := "A 方案：候选 %d → 整树 -%d / 短枝 -%d → %d 条" \
			% [candidate_tiles, tree_pruned, branch_pruned, edge_n]
	stats_msg += "（密度 %.1f%%，入海口 %d，枝长 p50 %.1f，干流 p50 %.1f，最短枝 %d，树最小 %d）" \
			% [density * 100.0, mouths, branch_p50, trunk_p50, branch_min, tree_min]
	print(bin_if(ok_stats, stats_msg))
	_ok = _ok and ok_stats

	# —— 6) ribbon mesh：采样数 / 半径 / 单位法线 / UV.x=0/1 / 索引范围 ——
	var mesh: ArrayMesh = null
	if planet._river_instance != null:
		mesh = planet._river_instance.mesh
	var ok_mesh: bool = mesh != null and mesh.get_surface_count() == 1
	var vn := 0
	var expect_samples := 0
	var expect_indices := 0
	if ok_mesh:
		var arr := mesh.surface_get_arrays(0)
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
		var uvs: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV]
		var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
		vn = verts.size()
		ok_mesh = vn > 0 and vn % 2 == 0 and normals.size() == vn \
				and uvs.size() == vn and idx.size() % 3 == 0
		# 期望采样/索引数：与 _build_river_mesh_from_edges 同规则重算
		for e in edge_n:
			var a: int = planet._river_edges[e * 2]
			var b: int = planet._river_edges[e * 2 + 1]
			var pa: Vector3 = planet._tile_centers[a]
			var pb: Vector3 = planet._tile_centers[b]
			if planet._inland_water[b] == 1:
				pb = (pa + pb).normalized()
			var theta := pa.angle_to(pb)
			if theta < 1e-6:
				continue
			var n: int = maxi(2, ceili(theta / deg_to_rad(
					PlanetScript.RIVER_MAX_ARC_DEG)))
			expect_samples += n + 1
			expect_indices += n * 6
		ok_mesh = ok_mesh and vn == expect_samples * 2 \
				and idx.size() == expect_indices
		if ok_mesh:
			for i in vn:
				var p := verts[i]
				if not p.is_finite() or absf(p.length() - 1.0) > 1e-5:
					ok_mesh = false
					break
				if absf(normals[i].length() - 1.0) > 1e-3:
					ok_mesh = false
					break
				var uvx := uvs[i].x
				if absf(uvx) > 1e-6 and absf(uvx - 1.0) > 1e-6:
					ok_mesh = false
					break
			if ok_mesh:
				for j in idx.size():
					if idx[j] < 0 or idx[j] >= vn:
						ok_mesh = false
						break
	print(bin_if(ok_mesh, "河流 mesh：%d 采样点 / %d 三角形（期望 %d / %d），"
			% [vn >> 1, int(expect_indices / 3), expect_samples,
			int(expect_indices / 3)])
			+ "半径 1.0、单位法线、UV.x=0/1")
	_ok = _ok and ok_mesh

	# —— 7) 图层顺序与 shader 参数：低丘 0 → 河流 1 → 高山 2 ——
	var low_p := -1
	var high_p := -1
	if planet._hills_low_instance != null \
			and planet._hills_low_instance.material_override != null:
		low_p = planet._hills_low_instance.material_override.render_priority
	if planet._hills_high_instance != null \
			and planet._hills_high_instance.material_override != null:
		high_p = planet._hills_high_instance.material_override.render_priority
	var river_p := -1
	var ok_mat := false
	if planet._river_material != null:
		river_p = planet._river_material.render_priority
		var sh: Shader = planet._river_material.shader
		var db: float = planet._river_material.get_shader_parameter("depth_bias")
		var bw: float = planet._river_material.get_shader_parameter("base_half_width")
		var mw: float = planet._river_material.get_shader_parameter("min_width_px")
		var col: Color = planet._river_material.get_shader_parameter("river_color")
		ok_mat = sh != null and sh.resource_path.ends_with("planet_rivers.gdshader") \
				and is_equal_approx(db, PlanetScript.RIVER_DEPTH_BIAS) \
				and is_equal_approx(bw, PlanetScript.RIVER_BASE_HALF_WIDTH) \
				and is_equal_approx(mw, PlanetScript.RIVER_MIN_WIDTH_PX) \
				and col.is_equal_approx(PlanetScript.RIVER_COLOR) \
				and planet._river_instance.cast_shadow \
						== GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ok_mat = ok_mat and low_p == 0 and river_p == 1 and high_p == 2
	print(bin_if(ok_mat, "图层顺序 低丘 %d → 河流 %d → 高山 %d，shader 参数一致"
			% [low_p, river_p, high_p]))
	_ok = _ok and ok_mat

	# —— 8) custom_aabb 覆盖整球（零面积 ribbons 不被视锥裁掉）——
	var ok_aabb := false
	if planet._river_instance != null:
		var bb: AABB = planet._river_instance.custom_aabb
		var lo := bb.position
		var hi := bb.position + bb.size
		ok_aabb = lo.x <= -1.0 and lo.y <= -1.0 and lo.z <= -1.0 \
				and hi.x >= 1.0 and hi.y >= 1.0 and hi.z >= 1.0
	print(bin_if(ok_aabb, "custom_aabb 覆盖单位球"))
	_ok = _ok and ok_aabb

	# —— 9) 水文确定性：同一份地形/气候重算，河段与 Q 逐位一致 ——
	var first_edges: PackedInt32Array = planet._river_edges.duplicate()
	var first_flow: PackedFloat32Array = planet._river_flow.duplicate()
	planet._compute_river_edges()
	var ok_det: bool = first_edges == planet._river_edges \
			and first_flow == planet._river_flow
	print(bin_if(ok_det, "水文确定性：重算河段/Q 逐位一致"))
	_ok = _ok and ok_det

	# —— 10) 气候响应：干/温密度必须低于湿/热，且过滤后仍有河 ——
	planet.queue_free()
	await process_frame
	var dry: Node3D = PlanetScript.new()
	root.add_child(dry)
	await process_frame
	dry._on_generate_requested({
		"seed": 4242, "coverage": 0.3, "rainfall": 0, "temperature": 0,
	})
	tries = 0
	while tries < 60000 and (dry._mesh_instance == null or dry._menu != null):
		await process_frame
		tries += 1
	var dry_ok := false
	var dry_density := -1.0
	if dry._mesh_instance != null:
		dry_density = float(dry._river_stats.get("density", -1.0))
		var dry_tree_min: int = int(dry._river_stats.get("tree_min", 0))
		var dry_branch_min: int = int(dry._river_stats.get("branch_min", 0))
		dry_ok = dry_density >= 0.075 and dry_density <= 0.095 \
				and dry_density < density - 0.015 \
				and dry_tree_min >= PlanetScript.RIVER_TREE_MIN_EDGES \
				and dry_branch_min >= PlanetScript.RIVER_BRANCH_MIN_EDGES
	print(bin_if(dry_ok, "气候响应：干/温密度 %.1f%% < 湿/热 %.1f%%（过滤后仍有河）"
			% [dry_density * 100.0, density * 100.0]))
	_ok = _ok and dry_ok
	dry.queue_free()

	print("RESULT: ", "PASS" if _ok else "FAIL")
	print("=== 河流层冒烟结束 ===")
	_quit(0 if _ok else 1)


func _is_neighbor(planet: Node3D, a: int, b: int) -> bool:
	var cnt: int = planet._tile_neighbor_count[a]
	for k in cnt:
		if planet._tile_neighbors[a * 6 + k] == b:
			return true
	return false


func _quit(code: int) -> void:
	_done = true
	quit(code)


func bin_if(ok: bool, msg: String) -> String:
	return ("PASS: " + msg) if ok else ("FAIL: " + msg)
