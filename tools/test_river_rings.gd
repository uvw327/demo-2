extends Node
# 河岸圆环像素自检（docs/planet_rivers_plan.md §25–§26）。
#
# 验收判据（不靠肉眼）：把「河岸色 #565860 的像素、且上下左右 N px 处全都是水」
# 判为「落在水体内部的孤岛河岸像素」。正常河道里河岸带外侧必然是陆地，
# 只有 §25 那种「河岸被画在图元自身边界上」的圆环才会整圈落在水里。
#
# 运行（需要真实渲染，不能 --headless）：
#   godot --path . tools/test_river_rings.tscn

const WATER := Color(73.0 / 255.0, 82.0 / 255.0, 100.0 / 255.0)
const BANK := Color(86.0 / 255.0, 88.0 / 255.0, 96.0 / 255.0)
# 判色容差（每通道）：河岸与水只差 (13,6,-4)/255，所以必须用窄容差精确匹配，
# 不能靠"偏蓝/偏亮"这种粗略规则。
const TOL := 5.0 / 255.0
# 检查半径：视口高的 0.8%（1125 高时 ≈ 9 px，与 §25.1 的实测口径一致）
const RING_PROBE_RATIO := 0.008

var _planet: Node3D
var _fails := 0


func _ready() -> void:
	var scene: PackedScene = load("res://planet.tscn")
	_planet = scene.instantiate()
	add_child(_planet)
	await get_tree().process_frame
	await get_tree().process_frame
	_planet.call("_on_generate_requested", {"seed": 4242, "coverage": 0.3,
			"rainfall": 1.0, "temperature": 1.0})
	await _wait_gen()

	var targets := _junction_targets(6)
	print("汇合点取样：", targets.size(), " 处")
	if targets.is_empty():
		print("SKIP: 没有可见汇合点")
		get_tree().quit(0)
		return
	var idx := 0
	for p in targets:
		for dist in [1.10, 1.30]:
			var cam := _camera()
			if cam != null:
				cam.dist = dist
				cam.call("focus_on", p)
			var img := await _grab()
			if img == null:
				print("SKIP: 拿不到渲染结果（是否用了 --headless？）")
				get_tree().quit(0)
				return
			var bad := _count_islands(img)
			var ok := bad == 0
			if not ok:
				_fails += 1
			print("%s 汇合点 %d @dist=%s：水体内部孤岛河岸像素 %d"
					% ["PASS" if ok else "FAIL", idx, str(dist), bad])
			if not ok:
				img.save_png("user://ring_fail_%d_%s.png" % [idx, str(dist).replace(".", "")])
		idx += 1
	print("RESULT: %s" % ("PASS" if _fails == 0 else "FAIL"))
	get_tree().quit(0 if _fails == 0 else 1)


# 河岸色像素，且 4 个正方向 probe 距离处全都是水 → 候选孤岛。
# 单点会误报：斜向河岸带上总有几个像素，沿正方向走出 probe 后已经越过薄河岸带
# 落进水里。所以再按 8 邻接聚成连通块，只统计 ≥ MIN_BLOB 的块 ——
# 真正的圆环是「一圈」，孤岛必然是几十~几百像素的连续块。
const MIN_BLOB := 12
# 只检查画面中心区域：汇合点由 focus_on 对到屏幕中心，边缘的河道没意义。
# 全画面 3840×2158 逐像素在 GDScript 里要几十秒，裁到 1200×900 快一个数量级。
const SCAN_HALF_W := 600
const SCAN_HALF_H := 450


func _count_islands(img: Image) -> int:
	var w := img.get_width()
	var h := img.get_height()
	var x0 := maxi(0, w / 2 - SCAN_HALF_W)
	var y0 := maxi(0, h / 2 - SCAN_HALF_H)
	var cw := mini(w, w / 2 + SCAN_HALF_W) - x0
	var ch := mini(h, h / 2 + SCAN_HALF_H) - y0
	var probe := maxi(3, int(round(float(h) * RING_PROBE_RATIO)))
	if cw <= probe * 2 or ch <= probe * 2:
		return 0
	# 直接读原始字节：get_pixel() 每次都走一遍 Variant 转换，全图扫描会慢一个数量级。
	img.convert(Image.FORMAT_RGB8)
	var data := img.get_data()
	var cand := PackedByteArray()
	cand.resize(cw * ch)
	for y in range(probe, ch - probe):
		var row := ((y + y0) * w + x0) * 3
		for x in range(probe, cw - probe):
			var i := row + x * 3
			if absi(data[i] - 86) > 5 or absi(data[i + 1] - 88) > 5 \
					or absi(data[i + 2] - 96) > 5:
				continue
			var all_water := true
			for k in 4:
				var px := x + (probe if k == 0 else (-probe if k == 1 else 0))
				var py := y + (probe if k == 2 else (-probe if k == 3 else 0))
				var j := ((py + y0) * w + (px + x0)) * 3
				if absi(data[j] - 73) > 5 or absi(data[j + 1] - 82) > 5 \
						or absi(data[j + 2] - 100) > 5:
					all_water = false
					break
			if all_water:
				cand[y * cw + x] = 1
	# 8 邻接连通块，只累加够大的块（单点误报来自斜向河岸带）
	var seen := PackedByteArray()
	seen.resize(cw * ch)
	var stack := PackedInt32Array()
	var bad := 0
	for yy in range(probe, ch - probe):
		for xx in range(probe, cw - probe):
			var start := yy * cw + xx
			if cand[start] == 0 or seen[start] == 1:
				continue
			stack.clear()
			stack.append(start)
			seen[start] = 1
			var size := 0
			while not stack.is_empty():
				var i := stack[stack.size() - 1]
				stack.remove_at(stack.size() - 1)
				size += 1
				var cx := i % cw
				var cy := i / cw
				for dy in [-1, 0, 1]:
					var ny: int = cy + int(dy)
					if ny < 0 or ny >= ch:
						continue
					for dx in [-1, 0, 1]:
						if dx == 0 and dy == 0:
							continue
						var nx: int = cx + int(dx)
						if nx < 0 or nx >= cw:
							continue
						var j: int = ny * cw + nx
						if cand[j] == 1 and seen[j] == 0:
							seen[j] = 1
							stack.append(j)
			if size >= MIN_BLOB:
				bad += size
	return bad


func _near(c: Color, target: Color) -> bool:
	return absf(c.r - target.r) <= TOL and absf(c.g - target.g) <= TOL \
			and absf(c.b - target.b) <= TOL


func _grab() -> Image:
	for i in 6:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var tex := get_viewport().get_texture()
	if tex == null:
		return null
	var img := tex.get_image()
	if img == null or img.get_width() < 64:
		return null
	return img


func _camera() -> OrbitCamera:
	for c in _planet.get_children():
		if c is OrbitCamera:
			return c
	return null


# 可见半球上（dot(区域中心) > 0.75）半径最大的汇合点，按方位散开
func _junction_targets(limit: int) -> Array:
	var centers: PackedVector3Array = _planet._tile_centers
	var halves: PackedFloat32Array = _planet._river_half_width
	var region: Vector3 = _planet._region_center
	var cand: Array = []
	for v in _planet._river_junctions:
		var p: Vector3 = centers[v]
		if p.dot(region) < 0.75 or halves[v] <= 0.0:
			continue
		cand.append([halves[v], p])
	cand.sort_custom(func(a, b): return a[0] > b[0])
	var out: Array = []
	for item in cand:
		var p: Vector3 = item[1]
		var too_close := false
		for q in out:
			if p.angle_to(q) < 0.012:
				too_close = true
				break
		if not too_close:
			out.append(p)
		if out.size() >= limit:
			break
	return out


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
