extends Node
# 地形分布诊断：统计海拔直方图与各阈值档占比，回答"为什么丘陵/山区这么多"。
#
# 关键：地形等级判定 _terrain_level(elev) 只看海拔，阈值固定：
#   HILL1_ELEV = 0.18  (小丘陵起点)
#   HILL2_ELEV = 0.32  (大丘陵起点)
#   MOUNT_ELEV  = 0.48  (山区起点)
#   PEAK_ELEV   = 0.62  (不可逾越起点)
#   SEA_LEVEL   = -0.05
#
# 所以要回答的问题是：海拔噪声 get_noise_3dv() 的分布，与这组固定阈值
# 匹配得有多差？特别是噪声的输出范围 vs 阈值门限的关系。

const PlanetScript := preload("res://planet.gd")

var _planet: Node3D


func _ready() -> void:
	var scene: PackedScene = load("res://planet.tscn")
	_planet = scene.instantiate()
	add_child(_planet)
	await get_tree().process_frame
	await get_tree().process_frame

	var seed_value := 4242
	var coverage := 1.0
	_planet.call("_on_generate_requested", {"seed": seed_value, "coverage": coverage,
			"rainfall": 1.0, "temperature": 1.0})
	await _wait_gen()

	print("")
	print("========== 海拔分布诊断 (seed=", seed_value, ", 覆盖率 100%) ==========")

	var terrain: PackedByteArray = _planet._terrain
	var elev: PackedFloat32Array = _planet._tile_elev
	var total := terrain.size()

	# —— 1. 地形等级分布 ——
	var counts := {}
	for lv in terrain:
		counts[lv] = counts.get(lv, 0) + 1
	print("")
	print("【地形等级分布】")
	var names := ["未生成", "平原", "小丘陵", "大丘陵", "山区", "不可逾越"]
	for lv in names.size():
		var c: int = counts.get(lv, 0)
		print("  %-10s %6d  (%5.1f%%)" % [names[lv], c, float(c) / total * 100.0])

	# —— 2. 已生成陆地 vs 海洋 ——
	var land := 0
	var ocean := 0
	for lv in terrain:
		if lv == 1 or lv == 2 or lv == 3 or lv == 4 or lv == 5:
			land += 1
		elif lv == 0:
			ocean += 1
	print("")
	print("【海陆】陆地(含水下平原外的全部) = ", land, " / ", total)

	# —— 3. 海拔直方图（只看已生成区域）——
	var bins := 40
	var hist := PackedInt32Array()
	hist.resize(bins)
	var lo := -1.0
	var hi := 1.0
	var valid := 0
	var sum := 0.0
	var mn := 999.0
	var mx := -999.0
	for i in total:
		var e: float = elev[i]
		if e < -900.0:
			continue
		valid += 1
		sum += e
		mn = minf(mn, e)
		mx = maxf(mx, e)
		var b := int((e - lo) / (hi - lo) * bins)
		b = clampi(b, 0, bins - 1)
		hist[b] += 1
	print("")
	print("【海拔统计】已生成 ", valid, " 贴片")
	print("  范围 [", "%.4f" % mn, ", ", "%.4f" % mx, "]  均值 = %.4f" % (sum / maxf(valid, 1)))
	print("")
	print("  直方图 (bin=0.05):")
	var maxh := 1
	for h in hist:
		maxh = maxi(maxh, h)
	for b in bins:
		var e0 := lo + (hi - lo) * b / bins
		var e1 := lo + (hi - lo) * (b + 1) / bins
		var bar := "#".repeat(int(round(float(hist[b]) / maxh * 46.0)))
		print("   %+.2f..%+.2f %6d %5.1f%%  %s" % [e0, e1, hist[b],
				float(hist[b]) / maxf(valid, 1) * 100.0, bar])

	# —— 4. 关键：阈值门限 vs 实际分布 ——
	print("")
	print("【阈值门限 vs 实际占比】")
	print("  %-14s %10s %10s %10s" % ["档位", "海拔区间", "贴片数", "占比"])
	var prev := -INF
	var thresholds := [
		["平原/海洋", -INF, 0.18],
		["小丘陵", 0.18, 0.32],
		["大丘陵", 0.32, 0.48],
		["山区", 0.48, 0.62],
		["不可逾越", 0.62, INF],
	]
	for t in thresholds:
		var name: String = t[0]
		var a: float = t[1]
		var b2: float = t[2]
		var c := 0
		for i in total:
			var e: float = elev[i]
			if e < -900.0:
				continue
			if e >= a and e < b2:
				c += 1
		var range_str := ("%+.2f..%+.2f" % [a, b2]) if is_finite(a) and is_finite(b2) else ("%+.2f..∞" % a if is_finite(a) else "-∞..%+.2f" % b2)
		print("  %-14s %10s %10d %9.1f%%" % [name, range_str, c, float(c) / maxf(valid, 1) * 100.0])

	# —— 5. 关键诊断：噪声输出范围 ——
	print("")
	print("【诊断：海拔噪声的原始输出范围】")
	print("  FastNoiseLite.get_noise_3dv() 理论范围 [-1, 1]")
	var elev_noise: FastNoiseLite = _planet._elev_noise
	print("  frequency = ", elev_noise.frequency,
			"  fractal_octaves = ", elev_noise.fractal_octaves,
			"  fractal_type = ", elev_noise.fractal_type,
			"  fractal_gain = ", elev_noise.fractal_gain,
			"  fractal_lacunarity = ", elev_noise.fractal_lacunarity)
	print("  阈值门限落在这把尺子上的位置：")
	print("    HILL1=0.18 → 噪声的 %.1f%% 分位" % (_pct(elev, valid, 0.18)))
	print("    HILL2=0.32 → 噪声的 %.1f%% 分位" % (_pct(elev, valid, 0.32)))
	print("    MOUNT =0.48 → 噪声的 %.1f%% 分位" % (_pct(elev, valid, 0.48)))
	print("    PEAK  =0.62 → 噪声的 %.1f%% 分位" % (_pct(elev, valid, 0.62)))
	print("    SEA   =-0.05 → 噪声的 %.1f%% 分位" % (_pct(elev, valid, -0.05)))

	# —— 6. 采样原始噪声（未经收边）看真实分布形态 ——
	print("")
	print("【诊断：原始海拔噪声采样分布（4000 点，球面均匀采样）】")
	var raw := PackedFloat32Array()
	var rng := RandomNumberGenerator.new()
	rng.seed = 999
	for i in 4000:
		var z := rng.randf_range(-1.0, 1.0)
		var a2 := rng.randf_range(0.0, TAU)
		var rr := sqrt(maxf(0.0, 1.0 - z * z))
		var dir := Vector3(rr * cos(a2), z, rr * sin(a2))
		raw.append(elev_noise.get_noise_3dv(dir))
	var rsum := 0.0
	var rmn := 999.0
	var rmx := -999.0
	for r in raw:
		rsum += r
		rmn = minf(rmn, r)
		rmx = maxf(rmx, r)
	print("  范围 [%.4f, %.4f]  均值 %.4f" % [rmn, rmx, rsum / raw.size()])
	var rhist := PackedInt32Array()
	rhist.resize(20)
	for r in raw:
		var b3 := int((r + 1.0) * 10.0)
		rhist[clampi(b3, 0, 19)] += 1
	var rmaxh := 1
	for h in rhist:
		rmaxh = maxi(rmaxh, h)
	for b in rhist.size():
		var e0 := -1.0 + b * 0.1
		print("   %+.2f..%+.2f %5d  %s" % [e0, e0 + 0.1, rhist[b],
				"#".repeat(int(round(float(rhist[b]) / rmaxh * 46.0)))])
	print("  （阈值标尺：SEA=-0.05 在第 9.5 格, HILL1=0.18 在第 11.8 格,")
	print("    HILL2=0.32 在第 13.2 格, MOUNT=0.48 在第 14.8 格, PEAK=0.62 在第 16.2 格）")

	get_tree().quit()


func _pct(elev: PackedFloat32Array, valid: int, threshold: float) -> float:
	var below := 0
	for i in elev.size():
		var e: float = elev[i]
		if e < -900.0:
			continue
		if e < threshold:
			below += 1
	return float(below) / maxf(valid, 1) * 100.0


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
