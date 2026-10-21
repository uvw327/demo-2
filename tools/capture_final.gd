extends Node
# 临时验证脚本：生成星球 → 逐档拉近/拉远 → 截图存盘。

var _planet: Node3D
var _shots := 0
var _dists := [1.15, 2.33, 10.0]


func _ready() -> void:
	var scene: PackedScene = load("res://planet.tscn")
	_planet = scene.instantiate()
	add_child(_planet)
	await get_tree().process_frame
	await get_tree().process_frame
	_planet.call("_on_generate_requested", {"seed": 20261021, "coverage": 0.3,
			"rainfall": 0.0, "temperature": 0.0})
	await _wait_gen()
	for dist in _dists:
		for c in _planet.get_children():
			if c is OrbitCamera:
				c.dist = dist
				c.call("_update_cam")
		for i in 5:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		img.resize(2000, 1125, Image.INTERPOLATE_LANCZOS)
		img.save_png("user://final_%d.png" % _shots)
		print("SHOT final_%d.png dist=%s" % [_shots, dist])
		_shots += 1
	get_tree().quit()


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
