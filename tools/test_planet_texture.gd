# 星球纹理化回归护栏（headless 冒烟）：图集打包 / UV2 格子映射 / 顶点色调制器 /
# 材质 uniform 装配。对应 docs/planet_textures_plan.md §5 验证方案。
# 运行：godot --headless --path . --script res://tools/test_planet_texture.gd
extends SceneTree

# 图集脚本走 preload 而非 class_name：headless/--script 下全局类名缓存不稳
#（与 star_dome.gd 的依赖风格一致）
const BiomeAtlasScript := preload("res://biome_atlas.gd")

var _done := false


func _initialize() -> void:
	_run.call_deferred()


func _process(_delta: float) -> bool:
	return _done


func _run() -> void:
	var planet: Node3D = load("res://planet.gd").new()
	root.add_child(planet)
	await process_frame

	# —— 1) 图集打包：尺寸、格子数、cell_uv ——
	var atlas: Dictionary = planet._ensure_biome_atlas()
	var tex: Texture2D = atlas["texture"]
	var origins: Array[Vector2] = atlas["cell_origins"]
	var aw: int = tex.get_width()
	var ah: int = tex.get_height()
	var cell_px := float(aw) / 4.0
	var sp: int = BiomeAtlasScript.SPRITE
	var gut: int = BiomeAtlasScript.GUTTER
	# mipmap 断言走 Image 层，不用 Texture2D.has_mipmaps()：本环境后者对所有贴图
	# 恒返回 false（连随工程导入的 stars.png 也 false，实测），不是打包 bug；
	# 而打包 Image 经 generate_mipmaps() 后 get_image() roundtrip 为 true ——
	# ImageTexture 正是从这个 Image 上传 mip 链的（标准 idiom）。
	var atlas_img: Image = tex.get_image() if tex != null else null
	var has_mips: bool = atlas_img != null and atlas_img.has_mipmaps()
	var ok_grid: bool = tex != null and origins.size() == 8 \
			and aw == sp + 2 * gut + 3 * int(cell_px) \
			and ah == 2 * (sp + 2 * gut) \
			and has_mips
	print(bin_if(ok_grid, "图集 4×2 打包正确（%d×%d，8 格，mipmap=%s）" \
			% [aw, ah, str(has_mips)]))

	# —— 1b) gutter 边缘延展填充：格边 gutter 必须是内容色而非透明黑。
	# 透明黑 gutter + fract 边界 mip 突跳 = 截图实证的细暗线（§7 接缝修复）。
	var ok_pad: bool = atlas_img != null
	if ok_pad:
		for i in origins.size():
			# round() 而非 int()：UV 往返 float 可能得 63.99999…，截断会偏 1px
			var px := int(round(origins[i].x * float(aw)))
			var py := int(round(origins[i].y * float(ah)))
			var edge := atlas_img.get_pixel(px, py + sp / 2) # 格左缘内容
			var g1 := atlas_img.get_pixel(px - 1, py + sp / 2) # 左 gutter 紧贴缘
			var g2 := atlas_img.get_pixel(px - 1, py - 1) # 左上角 gutter
			# 最远端（px-GUTTER，紧贴邻格 territory）—— 高 LOD 越界亮弧的回归点：
			# 必须仍是本格延展色，不是邻格色/透明黑
			var gf := atlas_img.get_pixel(px - gut, py + sp / 2)
			ok_pad = ok_pad and g1.a > 0.99 and g1.is_equal_approx(edge) \
					and g2.a > 0.99 and gf.a > 0.99 and gf.is_equal_approx(edge)
	print(bin_if(ok_pad, "gutter 边缘延展正确（8 格 g0/gfar/角 = 内容色，无透明黑）"))

	# —— 1c) 第 8 格 = Ocean 卡备份：未生成贴片与已生成海域逐像素同观感的前提 ——
	var ok_cell8: bool = atlas_img != null
	if ok_cell8:
		var p0 := Vector2i(int(round(origins[0].x * float(aw))),
				int(round(origins[0].y * float(ah))))
		var p8 := Vector2i(int(round(origins[7].x * float(aw))),
				int(round(origins[7].y * float(ah))))
		# 内容区 3 个抽查点：两格必须一致且不透明（同一张 Ocean 缩放图的两次 blit）
		for q in [Vector2i(17, 240), Vector2i(128, 128), Vector2i(240, 17)]:
			var c0: Color = atlas_img.get_pixel(p0.x + q.x, p0.y + q.y)
			var c8: Color = atlas_img.get_pixel(p8.x + q.x, p8.y + q.y)
			ok_cell8 = ok_cell8 and c0.a > 0.99 and c0.is_equal_approx(c8)
	print(bin_if(ok_cell8, "第 8 格 = Ocean 卡备份（与第 0 格内容一致）"))

	# —— 2) 生成星球 ——
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

	# —— 3) 网格 UV2 通道存在 ——
	var mesh: ArrayMesh = planet._mesh_instance.mesh
	var arrays := mesh.surface_get_arrays(0)
	var uv2: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2]
	var cols: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	if uv2.is_empty() or uv2.size() != verts.size() or cols.size() != verts.size():
		print("FAIL: UV2/顶点色通道缺失 uv2=", uv2.size(),
				" verts=", verts.size(), " colors=", cols.size())
		_quit(1)
		return
	print("PASS: UV2 与顶点色通道齐全（", verts.size(), " 顶点）")

	# —— 4) 逐片核对 UV2 格子原点（按 _tile_polys 累计顶点基址 → 片 → 顶点段）——
	# 未生成片必须指向第 8 格；已生成片必须指向其 biome 的格子。
	var base := 0
	var bad_cell := -1
	var checked_ungenerated := 0
	var checked_generated := 0
	var n_tiles: int = planet._tile_polys.size()
	for t in n_tiles:
		var n: int = planet._tile_polys[t].size()
		var expect: Vector2
		if planet._generated[t] == 1:
			var b: int = planet._tile_biome[t]
			if b == planet.BIOME_NONE:
				bad_cell = t # 已生成却没写 biome id → 数据不一致
				break
			expect = origins[b]
			checked_generated += 1
		else:
			expect = origins[7]
			checked_ungenerated += 1
		if uv2[base] != expect:
			bad_cell = t
			break
		base += n
	if bad_cell >= 0:
		print("FAIL: 贴片 ", bad_cell, " 的 UV2 格子原点不匹配")
		_quit(1)
		return
	print("PASS: UV2 格子映射全对（已生成 ", checked_generated,
			" + 未生成 ", checked_ungenerated, " 片抽查）")

	# —— 5) 顶点色调制器语义：rgb = 明暗（平原 1.0），a = 岩石量 ∈ {0,0.4,0.8} ——
	var bad_col := -1
	for i in cols.size():
		var c: Color = cols[i]
		var alpha_ok: bool = is_equal_approx(c.a, 0.0) \
				or is_equal_approx(c.a, 0.4) or is_equal_approx(c.a, 0.8)
		# 调制器是乘数/混合量，不该出现 >1 或负值
		if not alpha_ok or c.r < 0.0 or c.r > 1.0 \
				or not is_equal_approx(c.r, c.g) or not is_equal_approx(c.g, c.b):
			bad_col = i
			break
	if bad_col >= 0:
		print("FAIL: 顶点色调制器异常 @", bad_col, " = ", cols[bad_col])
		_quit(1)
		return
	print("PASS: 顶点色调制器语义正确（灰阶乘数 + a∈{0,0.4,0.8} 岩石量）")

	# —— 5b) 水格判定：UV2 → 格号反推（与 shader 的 vertex() 同一套公式）——
	# shader 靠它决定该贴片要不要摊平 WorldMacro；判据错位 = 海面/陆地摊反了，
	# 而且是**静默**的视觉 bug（不报错、只是海面出现斑块）。这里把公式原样复刻一遍：
	#   格原点 = (GUTTER + (i%COLS)*cell)/aw → (origin - gutter_uv)/格距 = 格号
	var cell_uv_v: Vector2 = atlas["cell_uv"]
	var gutter_uv_v: Vector2 = atlas["gutter_uv"]
	var pitch_v: Vector2 = cell_uv_v + 2.0 * gutter_uv_v
	var bad_water := -1
	for i in origins.size():
		var ij := Vector2(round((origins[i].x - gutter_uv_v.x) / pitch_v.x),
				round((origins[i].y - gutter_uv_v.y) / pitch_v.y))
		# 反推格号必须等于图集布局的格号（4 列 × 2 行）
		if ij != Vector2(float(i % 4), float(floori(float(i) / 4.0))):
			bad_water = i
			break
		# 只有格 0（Ocean）与格 7（未生成深洋备份）判为水
		var is_water: bool = (ij - Vector2(0.0, 0.0)).length() < 0.5 \
				or (ij - Vector2(3.0, 1.0)).length() < 0.5
		if is_water != (i == 0 or i == 7):
			bad_water = i
			break
	if bad_water >= 0:
		print("FAIL: 格 ", bad_water, " 的水格判定/格号反推与布局不符")
		_quit(1)
		return
	print("PASS: 水格判定正确（格号反推 = 布局格号；仅格0 Ocean 与格7 未生成深洋判为水）")

	# —— 6) 材质 uniform 装配 ——
	var mat: ShaderMaterial = planet._mesh_instance.material_override
	var ok_mat: bool = false
	var cv := Vector2.ZERO
	var gv := Vector2.ZERO
	if mat != null:
		var t0 = mat.get_shader_parameter("biome_atlas")
		var t1 = mat.get_shader_parameter("macro_tex")
		cv = mat.get_shader_parameter("cell_uv")
		gv = mat.get_shader_parameter("gutter_uv")
		ok_mat = t0 is Texture2D and t1 is Texture2D and cv.x > 0.0 and cv.y > 0.0 \
				and gv.x > 0.0 and gv.y > 0.0
	print(bin_if(ok_mat, "材质 uniform 装配齐全（atlas/macro/cell_uv=%s/gutter_uv=%s）" \
			% [str(cv), str(gv)]))
	_quit(0 if (ok_grid and ok_mat) else 1)


func _quit(code: int) -> void:
	print("=== 星球纹理化冒烟结束 ===")
	_done = true
	quit(code)


func bin_if(ok: bool, msg: String) -> String:
	return ("PASS: " + msg) if ok else ("FAIL: " + msg)
