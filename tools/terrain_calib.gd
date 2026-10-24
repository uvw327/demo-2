extends Node
# 方案 B 的真实管线标定：扫描 (幂指数 p × 变形锚 A × 坡度归一化 norm)。
#
# 走真实 planet.tscn 生成（真实 Goldberg 贴片邻接 + 真实 priority-flood），
# 因此结果可直接作为生产配置的选型依据。标定通过 planet.gd 的
# _elev_shape_pow_override / _elev_shape_anchor_override / _river_slope_norm_override
# 钩子注入参数。
#
# 分母口径：**真实陆地**（生成且海拔 > 海平面），不含海洋"平原"。
# 早期版本用"平原(含海洋)"当分母，会把比例算低近 1 倍。
#
# 环境变量：
#   CALIB_SEEDS  逗号分隔种子，默认 4242
#   CALIB_COV    覆盖率，默认 1.0
#   CALIB_P      逗号分隔的 p 候选，默认 "1.0,1.5,2.0"
#   CALIB_A      逗号分隔的 anchor 候选，默认 "0.85"
#   CALIB_NORM   逗号分隔的 slope_norm 候选，默认 "0.25"

var _planet: Node3D
var _scene: PackedScene


func _ready() -> void:
	var seeds := _csv("CALIB_SEEDS", "4242")
	var cov_s := OS.get_environment("CALIB_COV")
	var cov := float(cov_s) if cov_s != "" else 1.0
	var ps := _csv("CALIB_P", "1.0,1.5,2.0")
	var anchors := _csv("CALIB_A", "0.85")
	var norms := _csv("CALIB_NORM", "0.25")

	_scene = load("res://planet.tscn")
	print("===== 方案B 真实管线标定（覆盖率 %.2f）=====" % cov)
	print("  %-5s %-5s %-5s %8s %7s %7s %7s %7s %7s %7s %7s" % [
		"p", "A", "norm", "陆地", "丘+山%", "小丘", "大丘", "山区", "不可逾", "河段", "跨高山"])

	for ps_line in ps:
		for a_line in anchors:
			for n_line in norms:
				await _run(float(ps_line), float(a_line), float(n_line), seeds, cov)


func _run(p_val: float, a_val: float, n_val: float, seeds: PackedStringArray,
		cov: float) -> void:
	var agg := {"land": 0.0, "hills": 0.0, "small": 0.0, "large": 0.0, "mount": 0.0,
			"imp": 0.0, "edges": 0.0, "cross": 0.0, "n": 0.0}
	for s in seeds:
		if _planet != null:
			_planet.queue_free()
			await get_tree().process_frame
		_planet = _scene.instantiate()
		add_child(_planet)
		await get_tree().process_frame
		await get_tree().process_frame
		_planet.set("_elev_shape_pow_override", p_val)
		_planet.set("_elev_shape_anchor_override", a_val)
		_planet.set("_river_slope_norm_override", n_val)
		_planet.call("_on_generate_requested", {"seed": int(s), "coverage": cov,
				"rainfall": 1.0, "temperature": 1.0})
		await _wait_gen()
		var terr: PackedByteArray = _planet.get("_terrain")
		var elev: PackedFloat32Array = _planet.get("_tile_elev")
		# 真实陆地 = 已生成 且 海拔高于海平面（_terrain 里海洋也算"平原"，要剔掉）
		var land := 0
		var small := 0
		var large := 0
		var mount := 0
		var imp := 0
		for i in terr.size():
			var lv: int = terr[i]
			if lv <= 0:
				continue
			if elev[i] <= -0.05: # SEA_LEVEL
				continue # 海洋
			land += 1
			match lv:
				2: small += 1
				3: large += 1
				4: mount += 1
				5: imp += 1
		agg["land"] += land
		agg["small"] += small
		agg["large"] += large
		agg["mount"] += mount
		agg["imp"] += imp
		agg["hills"] += (small + large + mount + imp) * 100.0 / maxf(float(land), 1.0)
		agg["edges"] += _planet.get("_river_edge_count")
		agg["cross"] += _cross_mountain()
		agg["n"] += 1.0
	var n: float = agg["n"]
	print("  %-5.2f %-5.2f %-5.2f %8.0f %7.1f %7.0f %7.0f %7.0f %7.0f %7.0f %7.0f" % [
		p_val, a_val, n_val, agg["land"] / n, agg["hills"] / n, agg["small"] / n,
		agg["large"] / n, agg["mount"] / n, agg["imp"] / n, agg["edges"] / n,
		agg["cross"] / n])


func _cross_mountain() -> int:
	# 跨高山河段数是局部变量，这里按 _terrain 与 _river_edges 复算
	var terr: PackedByteArray = _planet.get("_terrain")
	var edges: PackedInt32Array = _planet.get("_river_edges")
	var cnt: int = _planet.get("_river_edge_count")
	var hi := 0
	for e in cnt:
		var ha: int = terr[edges[e * 2]]
		var hb: int = terr[edges[e * 2 + 1]]
		if ha >= 4 or hb >= 4:
			hi += 1
	return hi


func _wait_gen() -> void:
	var limit := Time.get_ticks_msec() + 180000
	while Time.get_ticks_msec() < limit:
		await get_tree().process_frame
		var pct: float = _planet.get("_gen_pct")
		if pct >= 99.9:
			for i in 3:
				await get_tree().process_frame
			return
	push_warning("等待生成超时")


func _csv(key: String, def: String) -> PackedStringArray:
	var v := OS.get_environment(key)
	if v == "":
		v = def
	return v.split(",")
