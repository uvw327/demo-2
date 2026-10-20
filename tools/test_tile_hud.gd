# HUD 集成冒烟：生成星球 → 选中贴片 → HUD 显示且各行内容正确 →
# 取消选中 → HUD 隐藏；再选一次 → 重新显示（状态机回归）。
# 用法：godot --headless --path . --script res://tools/test_tile_hud.gd
extends SceneTree

var _done := false


func _initialize() -> void:
	_run.call_deferred()


func _process(_delta: float) -> bool:
	return _done


func _run() -> void:
	var planet: Node3D = load("res://planet.gd").new()
	root.add_child(planet)
	await process_frame

	planet._on_generate_requested({
		"seed": 4242, "coverage": 0.3, "rainfall": 1, "temperature": 1,
	})
	var tries := 0
	while tries < 60000 and (planet._mesh_instance == null or planet._menu != null):
		await process_frame
		tries += 1
	print("[1] 生成结束，HUD 隐藏? visible=", planet._hud.visible
			, "（生成期间不应显示）")

	# —— 选中一个已生成的陆地贴片：HUD 应出现且基本面非空 ——
	var hud_tile := -1
	for i in planet._topo_verts.size():
		if planet._generated[i] == 1 and planet._inland_water[i] == 0:
			hud_tile = i
			break
	planet.select_tile(hud_tile)
	await process_frame
	var shown: bool = planet._hud.visible
	var texts: Array[String] = []
	for c in planet._hud._rows.get_children():
		texts.append(c.text)
	var title: String = planet._hud._title.text
	var biome_expect: String = planet.BIOME_NAMES[planet._tile_biome[hud_tile]]
	var terrain_expect: String = planet.TERRAIN_NAMES[planet._terrain[hud_tile]]
	print("[2] 选中贴片 ", hud_tile, " → HUD visible=", shown,
			" 标题=", title)
	print("[3] 各行：", " | ".join(texts))
	var body := "/".join(texts)
	var ok: bool = shown \
			and title == "贴片 #%d" % hud_tile \
			and body.contains("地形：" + terrain_expect) \
			and body.contains("群系：" + biome_expect) \
			and body.contains("海拔：") \
			and body.contains("温度：") \
			and body.contains("经纬度：") \
			and body.contains("°")
	print(bin_if(ok, "PASS: HUD 显示内容齐全且与缓存数据一致"))

	# —— 取消选中：HUD 应隐藏 ——
	planet.deselect()
	await process_frame
	var hidden_ok: bool = not planet._hud.visible
	print("[4] 取消后 visible=", planet._hud.visible, " → ",
			bin_if(hidden_ok, "PASS: 取消选中 HUD 收起"))

	# —— 重新选中 + 选中内陆湖贴片（分组系“海洋”（内陆湖）标记）——
	var lake_tile := -1
	for i in planet._topo_verts.size():
		if planet._inland_water[i] == 1:
			lake_tile = i
			break
	if lake_tile >= 0:
		planet.select_tile(lake_tile)
		await process_frame
		var lake_texts: Array[String] = []
		for c in planet._hud._rows.get_children():
			lake_texts.append(c.text)
		var lake_body := "/".join(lake_texts)
		print("[5] 内陆湖贴片 ", lake_tile, " 文本：", " | ".join(lake_texts))
		print(bin_if(lake_body.contains("（内陆湖）"),
				"PASS: 内陆湖标记正确"))

	print("=== HUD 冒烟结束 ===")
	_done = true


func bin_if(ok: bool, msg: String) -> String:
	return ("PASS: " + msg) if ok else ("FAIL: " + msg)
