extends SceneTree
# 重新烘焙 assets/font/glyphs.tres：ASCII + CJK_SYMBOLS（全角标点）字符集
# + assets/chinese.txt（tools/extract_chinese.py 从游戏源码字符串提取的汉字清单）
# → font_baker 的 MSDF 图集。与上次烘焙（菜单字体）同一套参数。
# 用法：解压源字体 zip（Alibaba PuHuiTi 3.0，仓库不入库）后设置 BAKE_FONT
# 环境变量指向 .ttf，然后：
#   godot --headless --path . --script res://tools/bake_glyphs.gd

const OUT_PATH := "res://assets/font/glyphs.tres"
const CHARSET_KEYS := ["ASCII", "CJK_SYMBOLS"]
const CUSTOM_TEXT := "res://assets/chinese.txt"


func _initialize() -> void:
	var src_font := OS.get_environment("BAKE_FONT")
	if src_font.is_empty() or not FileAccess.file_exists(src_font):
		push_error("缺少源字体：请解压 Alibaba PuHuiTi 3.0 zip 并设置 BAKE_FONT 指向 .ttf")
		quit(1)
		return

	# 收集码点：字符集 ranges/points + 自定义文本（字符串清单）
	var ranges: Array = []
	var points := PackedInt32Array()
	for key in CHARSET_KEYS:
		var data: Dictionary = Charsets.get_charset(key)
		if data.has("ranges"):
			ranges.append_array(data["ranges"])
		if data.has("points"):
			points.append_array(data["points"])
	var custom := FontBakerCore.extract_chars_from_file(CUSTOM_TEXT)
	points.append_array(custom)
	print("[bake] 字符集 ASCII+CJK_SYMBOLS + 自定义清单 %d 个码点" % custom.size())

	var options := FontBakerCore.BakeOptions.new() # msdf_size=48 / pixel_range=14（与上次一致）
	var baker := FontBakerCore.new()
	baker.progress_updated.connect(func(msg: String) -> void: print("[bake] ", msg))
	var result: FontFile = baker.bake(src_font, ranges, points, options)
	if result == null:
		push_error("烘焙失败")
		quit(1)
		return

	# 元数据：与旧文件的 metadata 风格一致，便于日后核查烘焙来源
	result.set_meta("charsets", PackedStringArray(CHARSET_KEYS))
	var cust_file := FileAccess.open(CUSTOM_TEXT, FileAccess.READ)
	result.set_meta("custom_text", cust_file.get_as_text())
	result.set_meta("source_font_path", src_font.get_file())

	var err := ResourceSaver.save(result, OUT_PATH)
	if err != OK:
		push_error("保存失败 err=%d" % err)
		quit(1)
		return
	print("[bake] 已保存 ", OUT_PATH)
	quit(0)
