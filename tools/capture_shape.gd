extends Node
# 方案 B 的视觉对照：同一颗星球、同一机位，拍摄"整形关闭"与"整形开启"
# 两组截图，直观对比"丘陵铺满地图"与"大片平原 + 少数尖峰"。
#
# 覆盖 3 个距离：全球（看整体形态）、半球（看地貌分布）、近景（看平原质感）。
# 每组都拍一张正对主河道的近景，检查河网是否仍正常。

var _planet: Node3D
var _shots := 0
var _out_dir := "user://"


func _ready() -> void:
	var scene: PackedScene = load("res://planet.tscn")
	# 关整形基线
	await _capture_group(scene, 1.0, 0.85, "base")
	# 方案 B 生产配置
	await _capture_group(scene, 2.0, 0.67, "shaped")
	get_tree().quit()


func _capture_group(scene: PackedScene, p_val: float, a_val: float,
		tag: String) -> void:
	if _planet != null:
		_planet.queue_free()
		await get_tree().process_frame
	_planet = scene.instantiate()
	add_child(_planet)
	await get_tree().process_frame
	await get_tree().process_frame
	_planet.set("_elev_shape_pow_override", p_val)
	_planet.set("_elev_shape_anchor_override", a_val)
	_planet.call("_on_generate_requested", {"seed": 4242, "coverage": 0.3,
			"rainfall": 1.0, "temperature": 1.0})
	await _wait_gen()
	_report(tag)

	for dist in [1.35, 2.2, 5.0]:
		var cam := _camera()
		if cam != null:
			cam.dist = dist
			cam.call("_update_cam")
		await _capture("%s_dist_%s.png" % [tag, str(dist)])
		print("SHOT %s_dist_%s.png" % [tag, str(dist)])

	# 主河近景
	var mid := _best_river_mid()
	if mid != Vector3.ZERO:
		var cam := _camera()
		if cam != null:
			cam.dist = 1.35
			cam.call("focus_on", mid)
		await _capture("%s_river.png" % tag)
		print("SHOT %s_river.png" % tag)


func _report(tag: String) -> void:
	var terr: PackedByteArray = _planet.get("_terrain")
	var elev: PackedFloat32Array = _planet.get("_tile_elev")
	var land := 0
	var hills := 0
	for i in terr.size():
		var lv: int = terr[i]
		if lv <= 0 or elev[i] <= -0.05:
			continue
		land += 1
		if lv >= 2:
			hills += 1
	print("[%s] 陆地=%d  丘+山=%d  占比=%.1f%%  河段=%d" % [
		tag, land, hills, hills * 100.0 / maxf(float(land), 1.0),
		_planet.get("_river_edge_count")])


func _camera() -> OrbitCamera:
	for c in _planet.get_children():
		if c is OrbitCamera:
			return c
	return null


func _capture(name: String) -> void:
	for i in 8:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.resize(2000, 1125, Image.INTERPOLATE_LANCZOS)
	img.save_png("%s%s" % [_out_dir, name])


func _best_river_mid() -> Vector3:
	var edges: PackedInt32Array = _planet._river_edges
	var centers: PackedVector3Array = _planet._tile_centers
	var flows: PackedFloat32Array = _planet._river_flow
	var center: Vector3 = _planet._region_center
	var best_mid := Vector3.ZERO
	var best_score := -INF
	for e in edges.size() >> 1:
		var a: int = edges[e * 2]
		var b: int = edges[e * 2 + 1]
		var mid: Vector3 = (centers[a] + centers[b]).normalized()
		var d := mid.dot(center)
		if d < 0.7:
			continue
		var score: float = flows[a] + d * 10.0
		if score > best_score:
			best_score = score
			best_mid = mid
	return best_mid


func _wait_gen() -> void:
	var t := 0
	while t < 2000:
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
