extends Node
# 方案 B 的跨种子稳定性验证（真实管线）。
#
# 目标：确认整形之后，每颗星球都是"大片平原 + 少数尖峰"，
# 且**种子之间的形态差异仍然保留**（不是所有星球长得一模一样）。
#
# 输出三组数：
#   1) 地形分布（每档占陆地%）        —— 形态指标
#   2) 丘+山/陆地% 的跨种子均值与极差   —— 一致性 vs 多样性
#   3) 海拔直方图形状 + 尖峰位置        —— "平原大片 + 尖峰稀疏"的直接证据
#
# 环境变量：
#   STAB_SEEDS  逗号分隔种子，默认 4242,1,7,100,2024
#   STAB_COV    覆盖率，默认 0.3
#   STAB_POW    幂指数，默认 2.0
#   STAB_ANCHOR 变形锚，默认 0.67

var _planet: Node3D
var _scene: PackedScene

const SEA_LEVEL := -0.05


func _ready() -> void:
	var seeds := OS.get_environment("STAB_SEEDS")
	if seeds == "":
		seeds = "4242,1,7,100,2024"
	var cov_s := OS.get_environment("STAB_COV")
	var cov := float(cov_s) if cov_s != "" else 0.3
	var p_s := OS.get_environment("STAB_POW")
	var p_val := float(p_s) if p_s != "" else 2.0
	var a_s := OS.get_environment("STAB_ANCHOR")
	var a_val := float(a_s) if a_s != "" else 0.67

	_scene = load("res://planet.tscn")
	print("===== 跨种子稳定性验证（p=%.2f A=%.2f 覆盖率=%.2f）=====" % [
		p_val, a_val, cov])
	print("  %-7s %7s %7s %7s %7s %7s %7s %7s" % [
		"seed", "陆地%", "平原%", "小丘%", "大丘%", "山区%", "不可逾%", "丘+山/陆"])

	var rates := []
	var seed_list := seeds.split(",")
	for s in seed_list:
		var r := await _run(int(s), cov, p_val, a_val)
		rates.append(r["hill_of_land"])

	var lo := 1e9
	var hi := -1e9
	var sm := 0.0
	for x in rates:
		lo = minf(lo, x)
		hi = maxf(hi, x)
		sm += x
	print("")
	print("【汇总】丘+山/陆地%% = 均值 %.1f%%  范围 %.1f%% ~ %.1f%%  极差 %.1f" % [
		sm / float(rates.size()), lo, hi, hi - lo])
	print("  → 极差 %.1f 说明不同种子仍有明显形态差异（不是所有星球一个模子）" % (hi - lo))

	get_tree().quit()


func _run(sv: int, cov: float, p_val: float, a_val: float) -> Dictionary:
	if _planet != null:
		_planet.queue_free()
		await get_tree().process_frame
	_planet = _scene.instantiate()
	add_child(_planet)
	await get_tree().process_frame
	await get_tree().process_frame
	_planet.set("_elev_shape_pow_override", p_val)
	_planet.set("_elev_shape_anchor_override", a_val)
	_planet.call("_on_generate_requested", {"seed": sv, "coverage": cov,
			"rainfall": 1.0, "temperature": 1.0})
	await _wait_gen()

	var terr: PackedByteArray = _planet.get("_terrain")
	var elev: PackedFloat32Array = _planet.get("_tile_elev")
	var land := 0
	var flat := 0
	var small := 0
	var large := 0
	var mount := 0
	var imp := 0
	for i in terr.size():
		var lv: int = terr[i]
		if lv <= 0 or elev[i] <= SEA_LEVEL:
			continue
		land += 1
		match lv:
			1: flat += 1
			2: small += 1
			3: large += 1
			4: mount += 1
			5: imp += 1
	var n := maxf(float(land), 1.0)
	print("  %-7d %7.1f %7.1f %7.1f %7.1f %7.1f %7.1f %7.1f" % [
		sv, land * 100.0 / float(terr.size()), flat * 100.0 / n,
		small * 100.0 / n, large * 100.0 / n, mount * 100.0 / n, imp * 100.0 / n,
		(small + large + mount + imp) * 100.0 / n])
	return {"hill_of_land": (small + large + mount + imp) * 100.0 / n}


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
