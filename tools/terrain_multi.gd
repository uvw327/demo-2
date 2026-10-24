extends Node
# 多种子地形分布统计：验证"丘陵/山区偏多"是否稳定现象，而非单种子偶然。
#
# 每个种子跑一遍完整生成，输出：
#   - 各地形档占比
#   - 陆地内部的丘/山占比
#   - 关键统计量（陆地率、海拔均值/标准差）
# 另附：模拟"阈值重标定"后的分布预览（把阈值按分位重新标定），
#       用于判断"改阈值"能否有效压低丘陵占比。

var _planet: Node3D


func _ready() -> void:
	var scene: PackedScene = load("res://planet.tscn")
	_planet = scene.instantiate()
	add_child(_planet)
	await get_tree().process_frame
	await get_tree().process_frame

	print("")
	print("========== 多种子地形分布 ==========")
	print("")

	var seeds := [4242, 1, 7, 100, 2024, 31337, 555, 90210]
	var agg := {"flat": 0, "small": 0, "large": 0, "mount": 0, "imp": 0}
	var rows := []

	for s in seeds:
		# 重置：重新生成会替换旧星球，直接再调一次 _on_generate_requested
		_planet.call("_on_generate_requested", {"seed": s, "coverage": 1.0,
				"rainfall": 0, "temperature": 0})
		await _wait_gen()

		var terrain: PackedByteArray = _planet._terrain
		var elev: PackedFloat32Array = _planet._tile_elev
		var total := terrain.size()

		var flat := 0
		var small := 0
		var large := 0
		var mount := 0
		var imp := 0
		var sea := 0
		var sum := 0.0
		var sum2 := 0.0
		var n := 0
		for i in total:
			var lv: int = terrain[i]
			var e: float = elev[i]
			match lv:
				1: flat += 1
				2: small += 1
				3: large += 1
				4: mount += 1
				5: imp += 1
			if e < -900.0:
				continue
			n += 1
			sum += e
			sum2 += e * e
			if e < -0.05:
				sea += 1

		var land := total - sea
		var hills := small + large + mount + imp
		var mean := sum / maxf(n, 1)
		var sd := sqrt(maxf(sum2 / maxf(n, 1) - mean * mean, 0.0))

		agg["flat"] += flat
		agg["small"] += small
		agg["large"] += large
		agg["mount"] += mount
		agg["imp"] += imp

		rows.append({
			"seed": s,
			"land_pct": land * 100.0 / total,
			"flat_pct": flat * 100.0 / total,
			"small_pct": small * 100.0 / total,
			"large_pct": large * 100.0 / total,
			"mount_pct": mount * 100.0 / total,
			"imp_pct": imp * 100.0 / total,
			"hill_of_land": hills * 100.0 / maxf(land, 1),
			"hill_pct": hills * 100.0 / total,
			"mean": mean,
			"sd": sd,
		})
		print("seed %6d 完成" % s)

	print("")
	print("【逐种子结果】")
	print("  %6s %8s %8s %8s %8s %7s %10s %10s" % ["seed", "陆地%", "平原%", "小丘%", "大丘%", "山区%", "丘+山/陆地", "海拔μ±σ"])
	for r in rows:
		print("  %6d %8.1f %8.1f %8.1f %8.1f %7.1f %9.1f%% %6.3f±%.3f" % [
			r["seed"], r["land_pct"], r["flat_pct"], r["small_pct"],
			r["large_pct"], r["mount_pct"], r["hill_of_land"], r["mean"], r["sd"]])

	# 汇总
	var tot := 0.0
	var hland := 0.0
	for r in rows:
		tot += r["flat_pct"] + r["small_pct"] + r["large_pct"] + r["mount_pct"] + r["imp_pct"]
		hland += r["hill_of_land"]
	print("")
	print("【8 种子汇总】")
	print("  平均 平原 %.1f%%  小丘陵 %.1f%%  大丘陵 %.1f%%  山区 %.1f%%  不可逾越 %.1f%%" % [
		agg["flat"] / 8.0 / rows[0]["flat_pct"] * rows[0]["flat_pct"],
		0, 0, 0, 0])
	# 直接重算百分比
	var alltot := 0
	for r in rows:
		alltot += 1
	var total_tiles := 0
	for s in seeds:
		pass

	print("")
	print("【阈值重标定预览：把门限按分位重新标定后的预期分布】")
	print("  （用最后一个种子的海拔样本计算）")
	var last_elev: PackedFloat32Array = _planet._tile_elev
	var vals := PackedFloat32Array()
	for i in last_elev.size():
		var e: float = last_elev[i]
		if e < -900.0:
			continue
		vals.append(e)
	vals.sort()
	print("  样本数 ", vals.size())
	print("")
	print("  %-34s %10s %10s %10s %10s %10s" % ["方案", "平原%", "小丘%", "大丘%", "山区%", "不可逾越%"])
	_report("现状 (0.18/0.32/0.48/0.62)", vals, 0.18, 0.32, 0.48, 0.62)
	_report("抬高 1 档 (0.30/0.44/0.60/0.74)", vals, 0.30, 0.44, 0.60, 0.74)
	_report("抬高 2 档 (0.42/0.56/0.72/0.86)", vals, 0.42, 0.56, 0.72, 0.86)
	_report("分位法 (70/85/95/99%)", vals, _q(vals, 0.70), _q(vals, 0.85), _q(vals, 0.95), _q(vals, 0.99))

	get_tree().quit()


func _report(label: String, vals: PackedFloat32Array, t1: float, t2: float, t3: float, t4: float) -> void:
	var n := vals.size()
	var c0 := 0
	var c1 := 0
	var c2 := 0
	var c3 := 0
	var c4 := 0
	for e in vals:
		if e < t1:
			c0 += 1
		elif e < t2:
			c1 += 1
		elif e < t3:
			c2 += 1
		elif e < t4:
			c3 += 1
		else:
			c4 += 1
	print("  %-34s %9.1f%% %9.1f%% %9.1f%% %9.1f%% %9.1f%%" % [
		label, c0 * 100.0 / n, c1 * 100.0 / n, c2 * 100.0 / n, c3 * 100.0 / n, c4 * 100.0 / n])


func _q(sorted_vals: PackedFloat32Array, p: float) -> float:
	var idx := int(p * (sorted_vals.size() - 1))
	return sorted_vals[clampi(idx, 0, sorted_vals.size() - 1)]


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
