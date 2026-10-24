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

	# —— 6) ribbon mesh：分支链采样数 / 半径 / 单位法线 / UV / 索引范围 ——
	var mesh: ArrayMesh = null
	if planet._river_instance != null:
		mesh = planet._river_instance.mesh
	var ok_mesh: bool = mesh != null and mesh.get_surface_count() == 1
	var vn := 0
	var actual_tris := 0
	var expect_samples := 0
	var expect_strips := 0
	var join_seg: int = PlanetScript.RIVER_JOIN_SEG
	var joins := 0
	var mouth_caps := 0
	var extras := 0
	if ok_mesh:
		var arr := mesh.surface_get_arrays(0)
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
		var uvs: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV]
		var uv2s: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV2]
		var cols: PackedColorArray = arr[Mesh.ARRAY_COLOR]
		var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
		vn = verts.size()
		actual_tris = int(idx.size() / 3)
		ok_mesh = vn > 0 and normals.size() == vn \
				and uvs.size() == vn and uv2s.size() == vn and cols.size() == vn \
				and idx.size() % 3 == 0
		# 期望采样数：按分支链重算。RIVER_SMOOTH_ITERS>0 时链先做 Chaikin，
		# 点数 = count × 2^iters，且平滑后单段 ≤0.55°（< RIVER_MAX_ARC_DEG）
		# 不会再细分，所以采样数就等于平滑后的点数。
		var iters: int = PlanetScript.RIVER_SMOOTH_ITERS
		for bi in planet._river_branch_n:
			var s0: int = planet._river_branch_offsets[bi]
			var cnt: int = planet._river_branch_offsets[bi + 1] - s0
			if cnt < 2:
				continue
			var pts := PackedVector3Array()
			pts.resize(cnt)
			for i in cnt:
				pts[i] = planet._tile_centers[planet._river_branch_nodes[s0 + i]]
			if planet._inland_water[planet._river_branch_nodes[s0 + cnt - 1]] == 1:
				pts[cnt - 1] = pts[cnt - 2].slerp(pts[cnt - 1],
						PlanetScript.RIVER_MOUTH_PAST).normalized()
			if iters > 0:
				var arc_sum0 := 0.0
				for i in cnt - 1:
					arc_sum0 += pts[i].angle_to(pts[i + 1])
				if arc_sum0 < 1e-9:
					continue
				# cnt<3 的链没法角切，原样输出（点数不变）
				expect_samples += cnt if cnt < 3 else cnt * (1 << iters)
				expect_strips += 1
				continue
			var nseg_sum := 0
			var arc_sum := 0.0
			for i in cnt - 1:
				var theta := pts[i].angle_to(pts[i + 1])
				arc_sum += theta
				nseg_sum += maxi(1, ceili(theta / deg_to_rad(
						PlanetScript.RIVER_MAX_ARC_DEG)))
			if arc_sum < 1e-9:
				continue
			expect_samples += nseg_sum + 1
			expect_strips += 1
		# 汇合点圆角接头：每个汇合点 = 1 个圆心 + SEG 个弧点、SEG 个三角形
		for vk in planet._river_junctions:
			if planet._river_half_width[vk] > 0.0:
				joins += 1
		# 河口端头：每条入海的链 1 个圆
		for bi2 in planet._river_branch_n:
			var s2: int = planet._river_branch_offsets[bi2]
			var c2: int = planet._river_branch_offsets[bi2 + 1] - s2
			if c2 >= 2 \
					and planet._inland_water[planet._river_branch_nodes[s2 + c2 - 1]] == 1:
				mouth_caps += 1
		extras = joins + mouth_caps
		ok_mesh = ok_mesh and vn == expect_samples * 2 + extras * (join_seg + 1) \
				and idx.size() == (expect_samples - expect_strips) * 6 \
						+ extras * join_seg * 3
		if ok_mesh:
			# UV2.x 上限：干流最粗 × 入海口喇叭口 × miter 伸出
			var half_lo: float = PlanetScript.RIVER_HALF_MIN \
					* PlanetScript.RIVER_TIP_TAPER - 1e-5
			var half_hi: float = PlanetScript.RIVER_HALF_MAX \
					* PlanetScript.RIVER_MOUTH_FLARE \
					* PlanetScript.RIVER_MITER_MAX_RATIO + 1e-5
			for i in vn:
				var p := verts[i]
				if not p.is_finite() or absf(p.length() - 1.0) > 1e-5:
					ok_mesh = false
					break
				if absf(normals[i].length() - 1.0) > 1e-3:
					ok_mesh = false
					break
				var uvx := uvs[i].x
				# 0/1 = ribbon 两侧；0.5 = 圆角接头圆心（偏移系数为 0）
				if absf(uvx) > 1e-6 and absf(uvx - 1.0) > 1e-6 \
						and absf(uvx - 0.5) > 1e-6:
					ok_mesh = false
					break
				# UV2.x = 烘焙半宽（miter 处可放大到 1/cos 倍）
				var hw := uv2s[i].x
				if hw < half_lo or hw > half_hi:
					ok_mesh = false
					break
				# COLOR.r = 端头 alpha（源头渐隐允许 < 1）
				if cols[i].r < 0.0 or cols[i].r > 1.0:
					ok_mesh = false
					break
			if ok_mesh:
				for j in idx.size():
					if idx[j] < 0 or idx[j] >= vn:
						ok_mesh = false
						break
	print(bin_if(ok_mesh, "河流 mesh：%d 顶点 / %d 三角形（期望 %d / %d，%d 条链 + %d 汇合点 + %d 河口），"
			% [vn, actual_tris, expect_samples * 2 + extras * (join_seg + 1),
			(expect_samples - expect_strips) * 2 + extras * join_seg,
			planet._river_branch_n, joins, mouth_caps])
			+ "半径 1.0、单位法线、UV/UV2/COLOR 合法")
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
		var mw: float = planet._river_material.get_shader_parameter("min_width_px")
		var col: Color = planet._river_material.get_shader_parameter("river_color")
		ok_mat = sh != null and sh.resource_path.ends_with("planet_rivers.gdshader") \
				and is_equal_approx(db, PlanetScript.RIVER_DEPTH_BIAS) \
				and is_equal_approx(mw, PlanetScript.RIVER_MIN_WIDTH_PX) \
				and col.is_equal_approx(PlanetScript.RIVER_COLOR) \
				and planet._river_instance.cast_shadow \
						== GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ok_mat = ok_mat and low_p == 0 and river_p == 1 and high_p == 2
	print(bin_if(ok_mat, "图层顺序 低丘 %d → 河流 %d → 高山 %d，shader 参数一致"
			% [low_p, river_p, high_p]))
	_ok = _ok and ok_mat

	# —— 8) 河宽分级：半宽单调、范围合法、干/支比明显；分支链覆盖每条河段一次 ——
	var ok_width: bool = planet._river_half_width.size() == total
	var bad_width := -1
	var half_lo_all := 1e9
	var half_hi_all := 0.0
	if ok_width:
		for e in edge_n:
			var a: int = planet._river_edges[e * 2]
			var b: int = planet._river_edges[e * 2 + 1]
			var ha: float = planet._river_half_width[a]
			if ha < PlanetScript.RIVER_HALF_MIN - 1e-6 \
					or ha > PlanetScript.RIVER_HALF_MAX + 1e-6:
				bad_width = a
				break
			half_lo_all = minf(half_lo_all, ha)
			half_hi_all = maxf(half_hi_all, ha)
			# 下游不能比上游细（Q 单调 → 宽度单调，不允许「粗—细—粗」）
			if planet._inland_water[b] == 0:
				var hb: float = planet._river_half_width[b]
				if hb < ha - 1e-6:
					bad_width = b
					break
	var ratio := 0.0
	if half_lo_all > 0.0:
		ratio = half_hi_all / half_lo_all
	# 对数映射的护栏：顶到上限的节点必须极少（线性+clamp 时实测 12%，
	# 等于把整个上游主干并成同一宽度 —— §21 P2）
	var sat := float(planet._river_render_stats.get("half_at_max", 1.0))
	# 干/支比：河宽尺度现在锚在「贴片」上（§23），干流全宽被压到 36% L，
	# 所以比值必然比之前（5.4×）小；3.4× 是设计值，护栏取 3.2× 防回退到"一样粗"。
	ok_width = ok_width and bad_width == -1 and ratio >= 3.2 and sat <= 0.02
	# 玩法护栏（§23）：河道全宽不得超过贴片对边宽的 40%，否则一个贴片里几乎没有
	# 陆地可发展（玩家要靠河发电，但也要有地）。L = 相邻贴片中心距的均值。
	var tile_len := 0.0
	var tile_len_n := 0
	for v in mini(total, 512):
		var cnt2: int = planet._tile_neighbor_count[v]
		if cnt2 <= 0:
			continue
		tile_len += planet._tile_centers[v].distance_to(
				planet._tile_centers[planet._tile_neighbors[v * 6]])
		tile_len_n += 1
	if tile_len_n > 0:
		tile_len /= float(tile_len_n)
	var width_frac: float = 2.0 * half_hi_all / maxf(tile_len, 1e-6)
	ok_width = ok_width and width_frac <= 0.40
	# 分支链覆盖：每条河段恰好被一条链走过（每个 from 节点的 cover 恰为 1）
	var cover := PackedInt32Array()
	cover.resize(total)
	cover.fill(0)
	for bi in planet._river_branch_n:
		var s0: int = planet._river_branch_offsets[bi]
		var cnt: int = planet._river_branch_offsets[bi + 1] - s0
		for i in cnt - 1:
			cover[planet._river_branch_nodes[s0 + i]] += 1
	var bad_cover := -1
	for e in edge_n:
		var a: int = planet._river_edges[e * 2]
		if cover[a] != 1:
			bad_cover = a
			break
	ok_width = ok_width and bad_cover == -1
	var half_p50 := float(planet._river_render_stats.get("half_p50", 0.0))
	var half_p90 := float(planet._river_render_stats.get("half_p90", 0.0))
	print(bin_if(ok_width, "河宽分级：半宽 %.4f–%.4f（干/支 %.1f×，全宽 %.0f%% 图块，p50 %.4f，p90 %.4f，顶上限 %.1f%%），%d 条链覆盖每条河段一次%s"
			% [half_lo_all, half_hi_all, ratio, 100.0 * width_frac, half_p50, half_p90, 100.0 * sat,
			planet._river_branch_n,
			"" if bad_width == -1 and bad_cover == -1
					else "，坏贴片 %d" % maxi(bad_width, bad_cover)]))
	_ok = _ok and ok_width

	# —— 9) 水文确定性：同一份地形/气候重算，河段/Q/宽度/分支链逐位一致 ——
	var first_edges: PackedInt32Array = planet._river_edges.duplicate()
	var first_half: PackedFloat32Array = planet._river_half_width.duplicate()
	var first_branch: PackedInt32Array = planet._river_branch_nodes.duplicate()
	var first_flow: PackedFloat32Array = planet._river_flow.duplicate()
	planet._compute_river_edges()
	var ok_det: bool = first_edges == planet._river_edges \
			and first_flow == planet._river_flow \
			and first_half == planet._river_half_width \
			and first_branch == planet._river_branch_nodes
	print(bin_if(ok_det, "水文确定性：重算河段/Q/半宽/分支链逐位一致"))
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
