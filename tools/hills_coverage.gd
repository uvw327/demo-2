extends Node
# 视觉放大效应验证：丘陵 quad 覆盖的**实际表面积** vs 地形等级贴片数占比。
#
# 关键点：玩家看到的是"地图上铺了多少山"，那是 quad 的几何覆盖，
# 而不是"多少贴片被判为丘陵"。后者只决定"在哪些位置放 quad"，
# 前者才决定"眼睛看到多少山"。
#
# 公式：每个 quad 是贴在球面上的切平面方块，边长 = QUAD_SIZE × avg_tile。
# 球面上一块 quad 的实际覆盖面积 ≈ (边长)²（切平面近似球面，误差 O(边长²/R²) 可忽略）。
# 总覆盖比 = quad数 × (QUAD_SIZE × avg_tile)² / (4πR²)

const R := 1.0
const TILE_COUNT := 40962
const QUAD_SIZE_MIN := 0.9
const QUAD_SIZE_MAX := 1.1


func _ready() -> void:
	print("")
	print("========== 丘陵视觉覆盖放大效应 ==========")
	print("")

	# 平均贴片宽：等面积球面 N 个贴片 → 平均面积 4πR²/N → 等效圆直径 4/√N（R=1）
	var avg_tile := 4.0 / sqrt(float(TILE_COUNT))
	print("【几何参数】")
	print("  贴片总数 = ", TILE_COUNT)
	print("  平均贴片宽 avg_tile = 4/√N = %.6f 弧度 (%.2f°)" % [avg_tile, rad_to_deg(avg_tile)])
	print("  quad 边长 = QUAD_SIZE(%.1f~%.1f) × avg_tile = %.6f ~ %.6f 弧度" % [
			QUAD_SIZE_MIN, QUAD_SIZE_MAX, QUAD_SIZE_MIN * avg_tile, QUAD_SIZE_MAX * avg_tile])
	print("  → 换一个角度看：一个 quad 的边长 ≈ %.1f 个贴片宽" % (QUAD_SIZE_MIN * avg_tile / avg_tile))
	print("")

	# 实测各等级占比（seed 4242，来自 terrain_diag）
	var levels := {"小丘陵": 6375, "大丘陵": 3782, "山区": 1265, "不可逾越": 381}
	var land := 24512
	var total := 40962

	print("【贴片计数 vs 视觉覆盖】")
	print("  %-12s %8s %12s %12s" % ["等级", "贴片数", "占陆地%", "quad几何覆盖%"])

	var quad_area_mid := pow(1.0 * avg_tile, 2.0)  # QUAD_SIZE 中值 1.0
	var sphere_area := 4.0 * PI * R * R

	for lv in ["小丘陵", "大丘陵", "山区", "不可逾越"]:
		var n: int = levels[lv]
		var cover := float(n) * quad_area_mid / sphere_area * 100.0
		print("  %-12s %8d %11.1f%% %11.1f%%" % [lv, n, float(n) / land * 100.0, cover])

	var hills_total := 0
	for lv in levels:
		hills_total += levels[lv]
	var cover_total := float(hills_total) * quad_area_mid / sphere_area * 100.0
	print("")
	print("  丘+山合计贴片 = %d (占陆地 %.1f%%)" % [hills_total, float(hills_total) / land * 100.0])
	print("  丘+山 quad 几何覆盖 = %.1f%% 的星球表面积" % cover_total)
	print("")

	# 抖动导致的扩散：JITTER_SMALL_HILLS = 0.37 → 小丘陵 quad 中心可偏离贴片中心 0.37×avg_tile
	print("【抖动扩散效应】")
	print("  JITTER_SMALL_HILLS = 0.37 → 小丘陵 quad 中心位置抖动 ±0.37×avg_tile")
	print("  JITTER_LARGE_HILLS = 0.20 → 大丘陵")
	print("  JITTER_HIGH        = 0.08 → 山区/不可逾越")
	print("  → 小丘陵抖得最远（0.37），所以视觉上「小山包」散布得最开、看起来最多")
	print("")

	# 关键：低海拔区也会长山
	print("【关键机制：小丘陵的高度视觉】")
	print("  小丘陵 quad 贴在 1.005R 处（离球面 0.5% 半径 = 贴片宽的 %.1f 倍）" % (0.005 / avg_tile))
	print("  → quad 略微悬浮在球面上方，边缘不贴地 →")
	print("    即使贴片本身海拔只比平原高一点点（0.18~0.32），")
	print("    贴图轮廓也让它在视觉上「鼓」成一个山包")
	print("    → 平地上撒 15.6% 的小丘陵 = 平地被切成碎块 = 观感「到处是山」")
	print("")

	# 顶点数
	print("【渲染负担印证】")
	print("  低丘 quad = 10157，高山 quad = 1646（seed 4242, 覆盖率 100%）")
	print("  合计 11803 个 alpha 混合 quad 覆盖 %.1f%% 的星球表面" % cover_total)
	print("  → 30.1 万三角形中 27948 个是河流，丘陵占 11803 quad = 23606 三角形")

	get_tree().quit()
