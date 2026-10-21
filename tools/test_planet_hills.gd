# 丘陵贴片层回归护栏（headless 冒烟）：图集打包 / quad 数量与几何 / UV 落格 /
# alpha 覆盖率分档 / 构建确定性。对应 docs/planet_textures_plan.md §5（第 2 期）。
# 运行：godot --headless --path . --script res://tools/test_planet_hills.gd
extends SceneTree

# 图集/星球脚本走 preload 而非 class_name：headless/--script 下全局类名缓存不稳
#（与 test_planet_texture.gd 的依赖风格一致）
const HillsAtlasScript := preload("res://hills_atlas.gd")
const PlanetScript := preload("res://planet.gd")

var _done := false
var _ok := true # 全部断言的汇总（最终退出码）


func _initialize() -> void:
	_run.call_deferred()


func _process(_delta: float) -> bool:
	return _done


func _run() -> void:
	var planet: Node3D = PlanetScript.new()
	root.add_child(planet)
	await process_frame

	# —— 1) 丘陵图集：尺寸 / 4 格 / mipmap / sprite_uv ——
	var atlas: Dictionary = planet._ensure_hills_atlas()
	var tex: Texture2D = atlas["texture"]
	var origins: Array[Vector2] = atlas["cell_origins"]
	var sprite_uv: Vector2 = atlas["sprite_uv"]
	var img: Image = tex.get_image() if tex != null else null
	var sp: int = HillsAtlasScript.SPRITE
	var gut: int = HillsAtlasScript.GUTTER
	var aw: int = tex.get_width() if tex != null else 0
	var has_mips: bool = img != null and img.has_mipmaps()
	var ok_grid: bool = tex != null and origins.size() == 4 \
			and aw == 2 * (sp + 2 * gut) \
			and sprite_uv.is_equal_approx(Vector2(float(sp) / float(aw),
			float(sp) / float(aw))) and has_mips
	print(bin_if(ok_grid, "丘陵图集 2×2 打包正确（%d×%d，4 格，mipmap=%s）"
			% [aw, aw, str(has_mips)]))
	_ok = _ok and ok_grid

	# —— 1b) gutter 延展：最远端 == 内容缘（防邻格渗色，biome 图集同款断言）——
	var ok_pad: bool = img != null
	if ok_pad:
		for ci in 4:
			var px := int(round(origins[ci].x * float(aw)))
			var py := int(round(origins[ci].y * float(aw)))
			var edge := img.get_pixel(px, py + sp / 2)
			var gf := img.get_pixel(px - gut, py + sp / 2)
			ok_pad = ok_pad and gf.is_equal_approx(edge)
	print(bin_if(ok_pad, "gutter 边缘延展正确（4 格 gfar = 内容缘）"))
	_ok = _ok and ok_pad

	# —— 1c) alpha 覆盖率分档（全像素 a>0 口径：与原版提取实测 4.8/14.3/23.7/45.8%
	# 精确对齐；四档必须保持「小丘稀 → 逾越满」的严格递增，带宽留约 ±50% 容差）——
	# 注：4 图 alpha 上限 ~0.69–0.81（原图本就半透明，丘陵叠色在地表色上），故按
	# a>0（有笔迹）计而非 a>0.5（实心），0.5 口径会把软边全漏掉（实测 1.9/3.6/9.4/32.6）。
	var cover := [0.0, 0.0, 0.0, 0.0]
	if img != null:
		for ci2 in 4:
			var px2 := int(round(origins[ci2].x * float(aw)))
			var py2 := int(round(origins[ci2].y * float(aw)))
			var hit := 0
			for sy in sp:
				for sx in sp:
					if img.get_pixel(px2 + sx, py2 + sy).a > 0.0:
						hit += 1
			cover[ci2] = hit / float(sp * sp)
	var ok_cover: bool = cover[0] > 0.02 and cover[0] < 0.10 \
			and cover[1] > 0.08 and cover[1] < 0.22 \
			and cover[2] > 0.15 and cover[2] < 0.35 \
			and cover[3] > 0.35 and cover[3] < 0.60
	print(bin_if(ok_cover, "四格 alpha 覆盖率分档正确（小丘%.1f%% 大丘%.1f%% 山%.1f%% 逾越%.1f%%）"
			% [cover[0] * 100.0, cover[1] * 100.0, cover[2] * 100.0, cover[3] * 100.0]))
	_ok = _ok and ok_cover

	# —— 2) 生成星球（30% 档，种子与 test_planet_texture 一致便于对照）——
	planet._on_generate_requested({
		"seed": 4242, "coverage": 0.3, "rainfall": 1, "temperature": 1,
	})
	var tries := 0
	while tries < 60000 and (planet._mesh_instance == null or planet._menu != null):
		await process_frame
		tries += 1
	if planet._mesh_instance == null:
		print("FAIL: 星球未生成")
		_quit(1)
		return
	print("PASS: 星球生成完毕")

	# —— 3) quad 数量 = 地形 ≥ 小丘 的贴片数（精确相等 → 平原/水域/未生成无 quad）——
	var hills_count := 0
	for lv in planet._terrain:
		if lv >= PlanetScript.TerrainLevel.SMALL_HILLS:
			hills_count += 1
	var hm: ArrayMesh = null
	if planet._hills_instance != null:
		hm = planet._hills_instance.mesh
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	var ok_count: bool = hm != null and hills_count > 0
	if ok_count:
		var ha := hm.surface_get_arrays(0)
		verts = ha[Mesh.ARRAY_VERTEX]
		uvs = ha[Mesh.ARRAY_TEX_UV]
		idx = ha[Mesh.ARRAY_INDEX]
		ok_count = verts.size() == hills_count * 4 and idx.size() == hills_count * 6 \
				and uvs.size() == verts.size()
	print(bin_if(ok_count, "quad 数与地形匹配（%d quad × 4 顶点，%d 片 ≥小丘）"
			% [verts.size(), hills_count]))
	_ok = _ok and ok_count

	# —— 4) 几何：顶点半径全部在 1.005×R ± 0.001（离球面防 z-fighting、贴而不浮）——
	var rmin := INF
	var rmax := 0.0
	for vv in verts:
		var r := vv.length()
		rmin = minf(rmin, r)
		rmax = maxf(rmax, r)
	var expect_r: float = 1.0 + PlanetScript.HILLS_OFFSET
	var ok_geo: bool = ok_count and rmin > expect_r - 0.001 and rmax < expect_r + 0.001
	print(bin_if(ok_geo, "quad 顶点半径 = 1.005±0.001（min %.4f max %.4f）"
			% [rmin, rmax]))
	_ok = _ok and ok_geo

	# —— 5) UV 落格：第 i 个 quad 的 UV 全在「第 i 个 ≥小丘 贴片」等级格的 2×2 变体内 ——
	var lvl_list: Array[int] = []
	for lv2 in planet._terrain:
		if lv2 >= PlanetScript.TerrainLevel.SMALL_HILLS:
			lvl_list.append(lv2)
	var bad_uv := -1
	if ok_count and lvl_list.size() == hills_count:
		for qi in lvl_list.size():
			var cell: Vector2 = origins[lvl_list[qi] - PlanetScript.TerrainLevel.SMALL_HILLS]
			for k in 4:
				var uv: Vector2 = uvs[qi * 4 + k]
				# 变体格范围 = [cell, cell + sprite_uv]（容差 1e-4 吃 float32 舍入）
				if uv.x < cell.x - 0.0001 or uv.x > cell.x + sprite_uv.x + 0.0001 \
						or uv.y < cell.y - 0.0001 or uv.y > cell.y + sprite_uv.y + 0.0001:
					bad_uv = qi
					break
	elif ok_count:
		bad_uv = -2 # 贴片序与 quad 序对不上（数量断言已过的前提下不该发生）
	var ok_uv: bool = ok_count and bad_uv == -1
	print(bin_if(ok_uv, "UV 全部落在对应等级格内（%d quad 逐个核对%s）"
			% [lvl_list.size(), "" if bad_uv == -1 else "，坏 quad %d" % bad_uv]))
	_ok = _ok and ok_uv

	# —— 6) 确定性：同 seed 重建逐位一致（独立随机流）；换 seed 必须有差异 ——
	var v1 := PackedVector3Array()
	var ok_det: bool = hm != null
	if ok_det:
		var hm2: ArrayMesh = planet._build_hills_mesh(4242)
		if hm2 != null:
			var a1 := hm.surface_get_arrays(0)
			var a2 := hm2.surface_get_arrays(0)
			v1 = a1[Mesh.ARRAY_VERTEX]
			var v2: PackedVector3Array = a2[Mesh.ARRAY_VERTEX]
			var u1: PackedVector2Array = a1[Mesh.ARRAY_TEX_UV]
			var u2: PackedVector2Array = a2[Mesh.ARRAY_TEX_UV]
			ok_det = not v1.is_empty() and v1 == v2 and u1 == u2
		else:
			ok_det = false
		var hm3: ArrayMesh = planet._build_hills_mesh(9999)
		if ok_det and hm3 != null:
			var v3: PackedVector3Array = hm3.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
			ok_det = v3 != v1
		else:
			ok_det = false
	print(bin_if(ok_det, "确定性：同种子 quad 逐位一致、换种子有差异"))
	_ok = _ok and ok_det

	_quit(0 if _ok else 1)


func _quit(code: int) -> void:
	print("=== 丘陵贴片层冒烟结束 ===")
	_done = true
	quit(code)


func bin_if(ok: bool, msg: String) -> String:
	return ("PASS: " + msg) if ok else ("FAIL: " + msg)
