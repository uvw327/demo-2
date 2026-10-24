extends Node
# 地形参数扫描：定位"丘陵/山区为什么这么多"，并给出可验证的调参方向。
#
# 方法：复刻 planet.gd 的地形判定链路（噪声 → 海平面 → 阈值分档），
# 但脱离场景直接在内存里跑，这样能一次性扫几十组配置。
# 每组输出：陆地率 / 各地形档占比 / 丘+山占陆地比 / 丘陵 quad 覆盖面积比。

# —— 复刻自 planet.gd 的常量 ——
const HILL1_ELEV := 0.18
const HILL2_ELEV := 0.32
const MOUNT_ELEV := 0.48
const PEAK_ELEV := 0.62
const SEA_LEVEL := -0.05
const TILE_COUNT := 8192
const QUAD_SIZE_MID := 1.0

# 星球表面的等面积单位球采样点（复用 Goldberg 顶点的近似：Fibonacci 球面）
var _dirs: PackedVector3Array


func _ready() -> void:
	print("")
	print("========== 地形参数扫描 ==========")
	print("")
	print("【枚举核对】FastNoiseLite.FractalType:")
	print("  FRACTAL_FBM      = ", FastNoiseLite.FRACTAL_FBM)
	print("  FRACTAL_RIDGED   = ", FastNoiseLite.FRACTAL_RIDGED)
	print("  FRACTAL_PING_PONG= ", FastNoiseLite.FRACTAL_PING_PONG)
	var probe := FastNoiseLite.new()
	print("  新建实例 fractal_type = ", probe.fractal_type, "（Godot 默认）")
	print("  新建实例 noise_type = ", probe.noise_type, "（0=TYPE_SIMPLEX）")
	print("  → planet.gd 只显式设了 noise_type/frequency/octaves，fractal_type 用的是默认值")
	print("")

	_build_dirs()
	print("【采样】", _dirs.size(), " 个球面等面积采样点（Fibonacci 球）")

	# —— 基准：复现 planet.gd 当前配置 ——
	var base := _eval(_mk(4242, 1.2, 4, FastNoiseLite.FRACTAL_FBM),
			SEA_LEVEL, HILL1_ELEV, HILL2_ELEV, MOUNT_ELEV, PEAK_ELEV)
	print("")
	print("【基准 = planet.gd 现状】")
	_print_row("现状 (freq1.2 oct4 FBM sea-0.05)", base)

	# —— 扫描 1：噪声 fractal_type ——
	print("")
	print("【扫描 1】fractal_type：RIDGED 能否造出山脉而非噪点丘陵")
	for ft in [FastNoiseLite.FRACTAL_FBM, FastNoiseLite.FRACTAL_RIDGED]:
		var nm := "FBM" if ft == FastNoiseLite.FRACTAL_FBM else "RIDGED"
		var r := _eval(_mk(4242, 1.2, 4, ft), SEA_LEVEL, HILL1_ELEV, HILL2_ELEV, MOUNT_ELEV, PEAK_ELEV)
		_print_row("fractal_type=" + nm, r)

	# —— 扫描 2：fractal_octaves（高频层数）——
	print("")
	print("【扫描 2】fractal_octaves：高频层越多 → 丘陵越碎、越多")
	for oc in [1, 2, 3, 4, 6, 8]:
		var r := _eval(_mk(4242, 1.2, oc, FastNoiseLite.FRACTAL_FBM),
				SEA_LEVEL, HILL1_ELEV, HILL2_ELEV, MOUNT_ELEV, PEAK_ELEV)
		_print_row("octaves=%d" % oc, r)

	# —— 扫描 3：frequency ——
	print("")
	print("【扫描 3】frequency：越低 → 陆块越大、海拔场越平坦（丘越少）")
	for f in [0.4, 0.6, 0.8, 1.0, 1.2, 1.6, 2.0]:
		var r := _eval(_mk(4242, f, 4, FastNoiseLite.FRACTAL_FBM),
				SEA_LEVEL, HILL1_ELEV, HILL2_ELEV, MOUNT_ELEV, PEAK_ELEV)
		_print_row("frequency=%.1f" % f, r)

	# —— 扫描 4：海平面 ——
	print("")
	print("【扫描 4】SEA_LEVEL：噪声均值≈0、σ≈0.27 → 海平面定在哪决定陆地率")
	for s in [-0.35, -0.25, -0.15, -0.05, 0.0, 0.05, 0.10]:
		var r := _eval(_mk(4242, 1.2, 4, FastNoiseLite.FRACTAL_FBM),
				s, HILL1_ELEV, HILL2_ELEV, MOUNT_ELEV, PEAK_ELEV)
		_print_row("sea=%+.2f" % s, r)

	# —— 扫描 5：阈值整体抬高 ——
	print("")
	print("【扫描 5】阈值整体抬高（海平面不动，丘/山门限上移）")
	var ths := [
		["现状", 0.18, 0.32, 0.48, 0.62],
		["+0.06", 0.24, 0.38, 0.54, 0.68],
		["+0.12", 0.30, 0.44, 0.60, 0.74],
		["+0.20", 0.38, 0.52, 0.68, 0.82],
		["+0.30", 0.48, 0.62, 0.78, 0.92],
	]
	for t in ths:
		var r := _eval(_mk(4242, 1.2, 4, FastNoiseLite.FRACTAL_FBM),
				SEA_LEVEL, t[1], t[2], t[3], t[4])
		_print_row("阈值" + str(t[0]) + " (%.2f/%.2f/%.2f/%.2f)" % [t[1], t[2], t[3], t[4]], r)

	# —— 扫描 6：海平面 + 阈值联动（模拟"重标定到分位"）——
	print("")
	print("【扫描 6】分位重标定：把门限钉在海拔分布的固定分位上（跨种子稳定）")
	var qspec := [
		["陆地 35% / 丘 8/18/25/24", 0.35, 0.08, 0.18, 0.25, 0.24],
		["陆地 35% / 丘 5/12/18/25", 0.35, 0.05, 0.12, 0.18, 0.25],
		["陆地 45% / 丘 8/15/20/25", 0.45, 0.08, 0.15, 0.20, 0.25],
	]
	for q in qspec:
		var seed_land: float = q[1]
		var fracs := [q[2], q[3], q[4], q[5]]
		var vals := _elevations(_mk(4242, 1.2, 4, FastNoiseLite.FRACTAL_FBM))
		vals.sort()
		# 陆地：取 (1-sea_land) 分位以上的都算陆地
		var sea_cut := _quantile(vals, seed_land)
		var cuts := PackedFloat32Array()
		var acc := seed_land
		for fr in fracs:
			acc += fr
			cuts.append(_quantile(vals, minf(acc, 0.999)))
		var r := _eval_vals(vals, sea_cut, cuts[0], cuts[1], cuts[2], cuts[3])
		_print_row("%s → 海平面%.3f 门限%.3f/%.3f/%.3f/%.3f" % [q[0], sea_cut, cuts[0], cuts[1], cuts[2], cuts[3]], r)

	# —— 扫描 7：海拔整形曲线（把钟形噪声压成"高原+孤峰"）——
	print("")
	print("【扫描 7】海拔整形：对噪声做幂变换（低幅压平、高幅保留）→ 造出平原+少量尖峰")
	print("     曲线 f(e) = sign(e)*|e|^p 归一化到 [-1,1]，p>1 压低中低幅、放大高幅")
	for p in [1.0, 1.5, 2.0, 2.5, 3.0]:
		var r := _eval_pow(_mk(4242, 1.2, 4, FastNoiseLite.FRACTAL_FBM),
				SEA_LEVEL, HILL1_ELEV, HILL2_ELEV, MOUNT_ELEV, PEAK_ELEV, p)
		_print_row("幂变换 p=%.1f" % p, r)

	# —— 扫描 8：8 种子稳定性（对最优候选做交叉验证）——
	print("")
	print("【扫描 8】跨种子稳定性：候选配置在 8 个种子下的表现")
	print("  %-38s %8s %8s %10s %10s" % ["配置", "陆地%", "丘+山%", "丘/陆地%", "覆盖%"])
	for seed in [4242, 1, 7, 100, 2024, 31337, 555, 90210]:
		var r := _eval(_mk(seed, 1.2, 4, FastNoiseLite.FRACTAL_FBM),
				SEA_LEVEL, HILL1_ELEV, HILL2_ELEV, MOUNT_ELEV, PEAK_ELEV)
		print("  %-38s %8.1f %8.1f %9.1f%% %9.1f%%" % [
			"现状 seed=%d" % seed, r["land"], r["hill"] * 100.0, r["hill_of_land"], r["cover"]])

	get_tree().quit()


# ============ 基础设施 ============

func _mk(seed_value: int, freq: float, oct: int, ft: int) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.seed = seed_value
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX
	n.frequency = freq
	n.fractal_octaves = oct
	n.fractal_type = ft
	return n


func _build_dirs() -> void:
	# Fibonacci 球面：等面积均匀采样
	var ga := PI * (3.0 - sqrt(5.0))
	_dirs = PackedVector3Array()
	for i in TILE_COUNT:
		var y := 1.0 - 2.0 * (float(i) + 0.5) / float(TILE_COUNT)
		var r := sqrt(maxf(0.0, 1.0 - y * y))
		var th := ga * float(i)
		_dirs.append(Vector3(cos(th) * r, y, sin(th) * r))


func _elevations(n: FastNoiseLite) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for d in _dirs:
		out.append(n.get_noise_3dv(d))
	return out


func _quantile(sorted_vals: PackedFloat32Array, p: float) -> float:
	var idx := int(p * (sorted_vals.size() - 1))
	return sorted_vals[clampi(idx, 0, sorted_vals.size() - 1)]


func _eval(n: FastNoiseLite, sea: float, t1: float, t2: float, t3: float, t4: float) -> Dictionary:
	return _eval_vals(_elevations(n), sea, t1, t2, t3, t4)


func _eval_vals(vals: PackedFloat32Array, sea: float, t1: float, t2: float, t3: float, t4: float) -> Dictionary:
	var sea_cut := sea
	var flat := 0
	var small := 0
	var large := 0
	var mount := 0
	var imp := 0
	var land := 0
	for e in vals:
		if e < sea_cut:
			flat += 1
			continue
		land += 1
		if e < t1:
			flat += 1
		elif e < t2:
			small += 1
		elif e < t3:
			large += 1
		elif e < t4:
			mount += 1
		else:
			imp += 1
	var n := float(vals.size())
	var hills := small + large + mount + imp
	# 丘陵 quad 覆盖面积比：quad 边长 ≈ 平均贴片宽 → 覆盖 ≈ 丘+山 贴片数 / 总贴片数
	return {
		"land": land / n * 100.0,
		"flat": flat / n * 100.0,
		"small": small / n * 100.0,
		"large": large / n * 100.0,
		"mount": mount / n * 100.0,
		"imp": imp / n * 100.0,
		"hill": hills / n * 100.0,
		"hill_of_land": hills / maxf(float(land), 1.0) * 100.0,
		"cover": hills / n * 100.0 * QUAD_SIZE_MID,
	}


func _eval_pow(n: FastNoiseLite, sea: float, t1: float, t2: float, t3: float, t4: float, p: float) -> Dictionary:
	var raw := _elevations(n)
	# f(e) = sign(e) * |e|^p，再线性映射回 [-1,1]（保持原始量级）
	var mx := 0.0
	for e in raw:
		mx = maxf(mx, absf(e))
	var vals := PackedFloat32Array()
	for e in raw:
		var s := signf(e) * pow(absf(e), p) / pow(maxf(mx, 0.001), p - 1.0)
		vals.append(s)
	return _eval_vals(vals, sea, t1, t2, t3, t4)


func _print_row(label: String, r: Dictionary) -> void:
	print("  %-44s 陆%5.1f%%  平%5.1f%% 小丘%5.1f%% 大丘%4.1f%% 山区%4.1f%% 丘+山/陆%5.1f%%" % [
		label, r["land"], r["flat"], r["small"], r["large"], r["mount"], r["hill_of_land"]])
