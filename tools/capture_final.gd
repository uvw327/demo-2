extends Node
# 临时验证脚本：生成星球 → 逐档拉近/拉远 → 截图存盘。
# 湿润种子（4242 / rain 1 / temp 1）河网更密，另加一张对准主河的近景。

var _planet: Node3D
var _shots := 0
var _dists := [1.15, 2.33, 10.0]


func _ready() -> void:
	var scene: PackedScene = load("res://planet.tscn")
	_planet = scene.instantiate()
	add_child(_planet)
	await get_tree().process_frame
	await get_tree().process_frame
	_planet.call("_on_generate_requested", {"seed": 4242, "coverage": 0.3,
			"rainfall": 1.0, "temperature": 1.0})
	await _wait_gen()
	for dist in _dists:
		var cam := _camera()
		if cam != null:
			cam.dist = dist
			cam.call("_update_cam")
		await _capture("final_%d.png" % _shots)
		print("SHOT final_%d.png dist=%s" % [_shots, dist])
		_shots += 1
	# 对准流量最大的河段拍近景：检查真实颜色/宽度与低丘叠加。
	var mid := _best_river_mid()
	if mid != Vector3.ZERO:
		var cam := _camera()
		if cam != null:
			cam.dist = 1.15
			cam.call("focus_on", mid)
		await _capture("final_river.png")
		print("SHOT final_river.png river close-up")
	get_tree().quit()


func _camera() -> OrbitCamera:
	for c in _planet.get_children():
		if c is OrbitCamera:
			return c
	return null


func _capture(name: String) -> void:
	for i in 5:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.resize(2000, 1125, Image.INTERPOLATE_LANCZOS)
	img.save_png("user://%s" % name)


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
