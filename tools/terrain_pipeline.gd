extends Node
# 真实管线基线/复测：跑完整 planet.tscn 生成流程，输出地形与河流统计。
#
# 与 terrain_shape.gd（内存合成）的区别：这里走真实管线（真实 Goldberg
# 贴片邻接、真实 priority-flood 产流、真实湖泊剔除），所以数字可直接对比
# "改之前 vs 改之后" 的真实产出。
#
# 环境变量：
#   SHAPE_SEEDS   逗号分隔的种子列表，默认 4242
#   SHAPE_COV     覆盖率，默认 1.0

var _planet: Node3D


func _ready() -> void:
	var seed_str := OS.get_environment("SHAPE_SEEDS")
	if seed_str == "":
		seed_str = "4242"
	var cov := float(OS.get_environment("SHAPE_COV")) if OS.get_environment("SHAPE_COV") != "" else 1.0
	var seeds := seed_str.split(",")
	var scene: PackedScene = load("res://planet.tscn")

	print("===== 真实管线地形统计（覆盖率 %.2f）=====" % cov)
	for s in seeds:
		var sv := int(s)
		if _planet != null:
			_planet.queue_free()
			await get_tree().process_frame
		_planet = scene.instantiate()
		add_child(_planet)
		await get_tree().process_frame
		await get_tree().process_frame
		print("---------- seed=%d ----------" % sv)
		_planet.call("_on_generate_requested", {"seed": sv, "coverage": cov,
				"rainfall": 1.0, "temperature": 1.0})
		await _wait_gen()
		# 直接从场景对象读真实产出的统计
		var terr: Array = _planet.get("_terrain")
		var elev: PackedFloat32Array = _planet.get("_tile_elev")
		_report(sv, terr, elev)

	get_tree().quit()


func _report(sv: int, terr: Array, elev: PackedFloat32Array) -> void:
	var counts := {}
	for lv in terr:
		counts[lv] = counts.get(lv, 0) + 1
	var names := ["未生成", "平原", "小丘陵", "大丘陵", "山区", "不可逾越"]
	var flat: int = counts.get(1, 0)
	var small: int = counts.get(2, 0)
	var large: int = counts.get(3, 0)
	var mount: int = counts.get(4, 0)
	var imp: int = counts.get(5, 0)
	var land := small + large + mount + imp
	var land_total := flat + land
	# 陆地中丘+山占比：把"海洋(平原)"从分母剔除
	print("【地形】seed=%d  已生成=%d  平原(含海)=%d  小丘=%d  大丘=%d  山区=%d  不可逾=%d" % [
		sv, flat + land, flat, small, large, mount, imp])
	print("【地形】陆地中丘+山占比 = %.1f%%  (小丘 %.1f%% / 大丘 %.1f%% / 山区 %.1f%% / 不可逾 %.1f%%)" % [
		land * 100.0 / maxf(float(land_total), 1.0),
		small * 100.0 / maxf(float(land), 1.0),
		large * 100.0 / maxf(float(land), 1.0),
		mount * 100.0 / maxf(float(land), 1.0),
		imp * 100.0 / maxf(float(land), 1.0)])
	# 海拔分布（真实贴片的最终海拔）
	var vals := PackedFloat32Array()
	for e in elev:
		if e > -900.0:
			vals.append(e)
	vals.sort()
	if vals.size() > 0:
		var q := func(p: float) -> float:
			return vals[clampi(int(p * (vals.size() - 1)), 0, vals.size() - 1)]
		print("【海拔】n=%d  min=%.3f  p10=%.3f  p50=%.3f  p90=%.3f  p99=%.3f  max=%.3f" % [
			vals.size(), vals[0], q.call(0.10), q.call(0.50), q.call(0.90), q.call(0.99),
			vals[vals.size() - 1]])


func _wait_gen() -> void:
	# 生成完成标记：_progress(100.0) 在组装 ArrayMesh 后调用
	var limit := Time.get_ticks_msec() + 180000
	while Time.get_ticks_msec() < limit:
		await get_tree().process_frame
		var pct: float = _planet.get("_gen_pct")
		if pct >= 99.9:
			# 再等几帧，确保 _terrain / _tile_elev 都已填好
			for i in 3:
				await get_tree().process_frame
			return
	push_warning("等待生成超时")
