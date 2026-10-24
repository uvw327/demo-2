extends Node
# 方案 B（海拔幂变换整形）的参数选型诊断。
#
# 目标：把钟形噪声压成"大片平原 + 少数尖峰"，且
#   · 海岸线逐点不变（陆地率/群系/内陆水零影响）
#   · 跨种子稳定（每颗星球都有山，但山都是少数）
#   · 尖峰/山区这些游戏性要素不被腰斩
#
# 变换（锚在海平面上，保证 f(SEA_LEVEL)=SEA_LEVEL → 海岸线是双射，不动）：
#     r      = e - SEA_LEVEL
#     f(e)   = SEA_LEVEL + sign(r) * |r|^p / A^(p-1)
#   A = 锚（|r|=A 处不变形），p>1 → 中低幅压平、高幅保留。
#
# 关键推导（f 严格单调 ⇒ 门限在原始空间的等效切点可解析求出）：
#     f⁻¹(T) = SEA_LEVEL + ((T - SEA_LEVEL) * A^(p-1))^(1/p)
#   令 A = PEAK_ELEV - SEA_LEVEL = 0.67，则 f⁻¹(PEAK_ELEV) = PEAK_ELEV
#   → **尖峰门槛在原始空间原地不动**（尖峰数量精确保留），
#     而中低幅被压向海平面（丘陵/山区被削减）。
#
# 本工具用 Fibonacci 球面采样（8192 点）+ 8 个种子做快速网格扫描；
# 真实管线（Goldberg 贴片 + priority-flood）复核见 terrain_calib.gd。

const SEA_LEVEL := -0.05
const HILL1_ELEV := 0.18
const HILL2_ELEV := 0.32
const MOUNT_ELEV := 0.48
const PEAK_ELEV := 0.62
const TILE_COUNT := 8192
const REAL_TILES := 40962 # 真实管线 100% 覆盖的 Goldberg 贴片数（用于换算绝对数量）
const SEEDS := [4242, 1, 7, 100, 2024, 31337, 555, 90210]

var _dirs: PackedVector3Array


func _ready() -> void:
	_build_dirs()
	print("========== 方案B：海拔幂变换整形 · 参数选型 ==========")
	print("采样点 ", _dirs.size(), "（Fibonacci 球）× ", SEEDS.size(), " 个种子")

	var raw := {}
	for seed in SEEDS:
		raw[seed] = _elevations(_mk(seed))

	# —— 1. 原始噪声分布（判断分位数口径）——
	print("")
	print("【1】原始噪声分布（8 种子合并）")
	var all := PackedFloat32Array()
	for seed in SEEDS:
		var v: PackedFloat32Array = raw[seed]
		all.append_array(v)
	all.sort()
	var q := func(p: float) -> float:
		return all[clampi(int(p * (all.size() - 1)), 0, all.size() - 1)]
	print("  n=%d  min=%.3f  p10=%.3f  p25=%.3f  p50=%.3f  p75=%.3f  p90=%.3f  p99=%.3f  max=%.3f" % [
		all.size(), all[0], q.call(0.10), q.call(0.25), q.call(0.50), q.call(0.75),
		q.call(0.90), q.call(0.99), all[all.size() - 1]])
	print("  当前门限在原始分布的分位：HILL1=%.1f%%  HILL2=%.1f%%  MOUNT=%.1f%%  PEAK=%.1f%%" % [
		_pct(all, HILL1_ELEV), _pct(all, HILL2_ELEV), _pct(all, MOUNT_ELEV),
		_pct(all, PEAK_ELEV)])

	# —— 2. (p × A) 网格扫描 ——
	print("")
	print("【2】(幂指数 p × 变形锚 A) 网格扫描")
	print("     列：丘+山/陆地% | 山区数 | 不可逾数 | 河段落差p95 | 建议 NORM")
	print("     （山区数/不可逾数按真实贴片数 %d 换算）" % REAL_TILES)
	print("  %-5s %-5s %9s %8s %8s %8s %8s %9s" % [
		"p", "A", "丘+山/陆%", "极差", "山区数", "不可逾数", "落差p95", "建议NORM"])

	var base_drop := _drop_p95(raw, 1.0, 0.85)
	for p in [1.0, 1.25, 1.5, 1.75, 2.0, 2.25]:
		for a in [0.55, 0.67, 0.75, 0.85, 1.0]:
			if p == 1.0 and a != 0.85:
				continue # 不整形时 A 无意义
			var rates := []
			var mount_sum := 0.0
			var imp_sum := 0.0
			var land_sum := 0.0
			for seed in SEEDS:
				var r := _eval_shape(raw[seed], p, a)
				rates.append(r["hill_of_land"])
				mount_sum += r["mount"]
				imp_sum += r["imp"]
				land_sum += r["land"]
			var n := float(SEEDS.size())
			var lo := 1e9
			var hi := -1e9
			var sm := 0.0
			for x in rates:
				lo = minf(lo, x)
				hi = maxf(hi, x)
				sm += x
			var mount_abs := mount_sum / n / 100.0 * REAL_TILES
			var imp_abs := imp_sum / n / 100.0 * REAL_TILES
			var drop := _drop_p95(raw, p, a)
			print("  %-5.2f %-5.2f %9.1f %8.1f %8.0f %8.0f %8.4f %9.4f" % [
				p, a, sm / n, hi - lo, mount_abs, imp_abs, drop,
				0.25 * drop / maxf(base_drop, 1e-6)])
			# 打印等效原始切点（对照现状 0.18/0.32/0.48/0.62）
			if a == 0.67 or (p == 1.0):
				var sc := pow(a, p - 1.0)
				var inv := []
				for t in [HILL1_ELEV, HILL2_ELEV, MOUNT_ELEV, PEAK_ELEV]:
					inv.append(SEA_LEVEL + pow((t - SEA_LEVEL) * sc, 1.0 / p))
				print("        └ 等效原始切点 = %.3f / %.3f / %.3f / %.3f" % [
					inv[0], inv[1], inv[2], inv[3]])

	# —— 3. 逐种子明细（选定配置用）——
	print("")
	print("【3】候选 p=1.75 / A=0.67 逐种子明细")
	print("  %-8s %8s %8s %8s %8s %8s %8s %8s" % [
		"seed", "陆地%", "平原%", "小丘%", "大丘%", "山区%", "不可逾%", "丘+山/陆"])
	for seed in SEEDS:
		var r := _eval_shape(raw[seed], 1.75, 0.67)
		print("  %-8d %8.1f %8.1f %8.1f %8.1f %8.1f %8.1f %8.1f" % [
			seed, r["land"], r["flat"], r["small"], r["large"], r["mount"], r["imp"],
			r["hill_of_land"]])

	print("")
	print("【4】现状基线（不整形）逐种子明细")
	print("  %-8s %8s %8s %8s %8s %8s %8s %8s" % [
		"seed", "陆地%", "平原%", "小丘%", "大丘%", "山区%", "不可逾%", "丘+山/陆"])
	for seed in SEEDS:
		var r := _eval_vals(raw[seed])
		print("  %-8d %8.1f %8.1f %8.1f %8.1f %8.1f %8.1f %8.1f" % [
			seed, r["land"], r["flat"], r["small"], r["large"], r["mount"], r["imp"],
			r["hill_of_land"]])

	get_tree().quit()


# ============ 基础设施 ============

func _pct(sorted: PackedFloat32Array, v: float) -> float:
	# v 在排序数组中的分位（%）——用二分找第一个 >= v
	var lo := 0
	var hi := sorted.size() - 1
	while lo < hi:
		var mid := (lo + hi) / 2
		if sorted[mid] < v:
			lo = mid + 1
		else:
			hi = mid
	return float(lo) / float(sorted.size() - 1) * 100.0


func _mk(seed_value: int) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.seed = seed_value
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX
	n.frequency = 1.2
	n.fractal_octaves = 4
	n.fractal_type = FastNoiseLite.FRACTAL_FBM
	return n


func _build_dirs() -> void:
	var ga := PI * (3.0 - sqrt(5.0))
	_dirs = PackedVector3Array()
	for i in TILE_COUNT:
		var y := 1.0 - 2.0 * (float(i) + 0.5) / float(TILE_COUNT)
		var rr := sqrt(maxf(0.0, 1.0 - y * y))
		var th := ga * float(i)
		_dirs.append(Vector3(cos(th) * rr, y, sin(th) * rr))


func _elevations(n: FastNoiseLite) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for d in _dirs:
		out.append(n.get_noise_3dv(d))
	return out


func _shape(vals: PackedFloat32Array, p: float, a: float) -> PackedFloat32Array:
	var scale := pow(a, p - 1.0)
	var out := PackedFloat32Array()
	for e in vals:
		var r := e - SEA_LEVEL
		out.append(SEA_LEVEL + signf(r) * pow(absf(r), p) / scale)
	return out


func _eval_shape(vals: PackedFloat32Array, p: float, a: float) -> Dictionary:
	return _eval_vals(_shape(vals, p, a))


func _eval_vals(vals: PackedFloat32Array) -> Dictionary:
	var flat := 0
	var small := 0
	var large := 0
	var mount := 0
	var imp := 0
	var land := 0
	for e in vals:
		if e < SEA_LEVEL:
			flat += 1
			continue
		land += 1
		if e < HILL1_ELEV:
			flat += 1
		elif e < HILL2_ELEV:
			small += 1
		elif e < MOUNT_ELEV:
			large += 1
		elif e < PEAK_ELEV:
			mount += 1
		else:
			imp += 1
	var n := float(vals.size())
	var hills := small + large + mount + imp
	return {
		"land": land / n * 100.0,
		"flat": flat / n * 100.0,
		"small": small / n * 100.0,
		"large": large / n * 100.0,
		"mount": mount / n * 100.0,
		"imp": imp / n * 100.0,
		"hill": hills / n * 100.0,
		"hill_of_land": hills / maxf(float(land), 1.0) * 100.0,
	}


# 相邻采样点的高差（球面网格近似：与下一环的横向邻居比）→ 河流产流的坡度信号
func _drop_p95(raw: Dictionary, p: float, a: float) -> float:
	var ds := PackedFloat32Array()
	for seed in SEEDS:
		var vals: PackedFloat32Array = raw[seed]
		var shaped := vals if p == 1.0 else _shape(vals, p, a)
		for i in shaped.size():
			var j := i + 1
			if j >= shaped.size():
				j = i - 1
			var d: float = shaped[i] - shaped[j]
			if d > 0.0:
				ds.append(d)
	if ds.size() == 0:
		return 0.0
	ds.sort()
	return ds[int(0.95 * (ds.size() - 1))]
