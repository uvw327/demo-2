extends Node
# 验证方案 B 的关键不变式：整形前后，各地形档占据的**海拔区间**是否一致。
#
# 为什么要验这个：整形 f 改变了海拔数值，如果每档的海拔区间变了，那么
# 温度制冷（ELEV_COOL×海拔）、山地增雨（RIVER_OROGRAPHIC×海拔）这些
# 依赖海拔绝对值的参数就会被悄悄改变 → 气候表现漂移。
# 若区间一致 → 气候参数零影响，整形是纯粹的"地形分档"改动。
#
# 跑真实管线，分别在整形开/关下采集每档海拔的 min/max/均值。

var _planet: Node3D
var _scene: PackedScene


func _ready() -> void:
	var seeds := OS.get_environment("CALIB_SEEDS")
	if seeds == "":
		seeds = "4242"
	var cov_s := OS.get_environment("CALIB_COV")
	var cov := float(cov_s) if cov_s != "" else 1.0
	_scene = load("res://planet.tscn")
	print("===== 地形档海拔区间 不变式验证（覆盖率 %.2f）=====" % cov)
	for s in seeds.split(","):
		await _run(int(s), cov)
	get_tree().quit()


func _run(sv: int, cov: float) -> void:
	# —— 关整形（现状）——
	await _gen(sv, cov, 1.0)
	var off := _collect()
	# —— 开整形（p=2 / A=0.67，生产配置）——
	await _gen(sv, cov, 2.0)
	var on := _collect()

	print("---------- seed=%d ----------" % sv)
	var names := ["小丘陵", "大丘陵", "山区", "不可逾越"]
	for i in 4:
		var lv := i + 2
		var o: Dictionary = off[lv]
		var n: Dictionary = on[lv]
		if o["n"] == 0:
			continue
		print("  %-6s 关: n=%-6d 海拔 %.3f~%.3f 均值%.3f   |  开: n=%-6d 海拔 %.3f~%.3f 均值%.3f" % [
			names[i], o["n"], o["min"], o["max"], o["avg"],
			n["n"], n["min"], n["max"], n["avg"]])


func _gen(sv: int, cov: float, p_val: float) -> void:
	if _planet != null:
		_planet.queue_free()
		await get_tree().process_frame
	_planet = _scene.instantiate()
	add_child(_planet)
	await get_tree().process_frame
	await get_tree().process_frame
	_planet.set("_elev_shape_pow_override", p_val)
	_planet.call("_on_generate_requested", {"seed": sv, "coverage": cov,
			"rainfall": 1.0, "temperature": 1.0})
	var limit := Time.get_ticks_msec() + 180000
	while Time.get_ticks_msec() < limit:
		await get_tree().process_frame
		var pct: float = _planet.get("_gen_pct")
		if pct >= 99.9:
			for i in 3:
				await get_tree().process_frame
			return
	push_warning("等待生成超时")


func _collect() -> Dictionary:
	var terr: Array = _planet.get("_terrain")
	var elev: PackedFloat32Array = _planet.get("_tile_elev")
	var out := {}
	for lv in range(0, 6):
		out[lv] = {"n": 0, "min": 9e9, "max": -9e9, "sum": 0.0}
	for i in terr.size():
		var lv: int = terr[i]
		if lv <= 0:
			continue
		var e: float = elev[i]
		var d: Dictionary = out[lv]
		d["n"] += 1
		d["sum"] += e
		if e < d["min"]:
			d["min"] = e
		if e > d["max"]:
			d["max"] = e
	for lv in range(0, 6):
		var d: Dictionary = out[lv]
		if d["n"] > 0:
			d["avg"] = d["sum"] / float(d["n"])
		else:
			d["avg"] = 0.0
	return out
