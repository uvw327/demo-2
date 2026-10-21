class_name BiomeAtlas
extends RefCounted
# 生态色卡图集：把 7 张原版生态色卡（512²，见 docs/planet_textures_plan.md §2）
# 各缩到 256²，打包成 4×2 网格图集，供 planet_surface.gdshader 逐贴片按 UV2 采样。
# 第 8 格 = 未生成区域的纯色格（死海蓝），于是「已生成 + 未生成」仍是 1 次 draw call。
#
# 为什么打包成一张图集（而不是照抄原版「一个 biome 一个材质」）：
#   原版 7+ 个 biome 各一个 subMesh/材质 → 7+ 次 draw call；
#   我们把「格子原点」写进网格 UV2，fragment 按 UV2 定位格子 —— 全 biome 仍只 1 次 draw call。
#
# 两个防串味手段：
#   ① 格边 gutter 用**边缘像素延展填充**（不是留白/透明黑）：双线性在格边采样、
#      以及高层 mip 降采样都会混进 gutter —— 若是透明黑就渲出细暗线（实证：
#      fract() 整数边界处 UV 突跳 → 屏幕导数爆炸 → 采最高 mip → 混黑 gutter）；
#      延展成同色后，任何层级混到 gutter 都拿回相邻内容色，暗线根源掐掉；
#   ② fragment 里 fract() 把平铺坐标折回 [0,1] 再加格子原点 —— 采样永不越出本格，
#      主贴图连 repeat 都不依赖（macro 是整图平铺，才需要 repeat_enable）。
#
# 全部在运行期做（与项目「全代码动态构建」一致），不产生新的资产文件。

const SPRITE := 256  # 每格有效边长（原图 512 缩一半：低对比度色卡缩半无损观感）
# 格边 gutter（全部填**本格**边缘延展色）。64px = 放到最大距离（dist 10，LOD≈4-5）
# 时采样足迹 ≤ ±64px，仍只踩进本格延展区 —— 否则会伸进**邻格**延展区，把邻格颜色
# 染进 fract 边界渲成亮弧（实证：Ocean 右邻 IceSheetOcean 浅色 → 海洋上浅色弧线）。
# 换算：LOD L 的足迹约 ±2^L px，16px 只够 LOD 3（远景观测到 LOD 4-5 才翻车）。
const GUTTER := 64
const COLS := 4
const ROWS := 2

# 与 planet.gd BIOME_NAMES 顺序一一对应的 7 张原版色卡：
# [海洋, 海冰, 冰盖, 苔原, 寒带, 沙漠, 温带森林]
const BIOME_TEXTURES: Array = [
	preload("res://assets/Ocean.png"),
	preload("res://assets/IceSheetOcean.png"),
	preload("res://assets/IceSheet.png"),
	preload("res://assets/Tundra.png"),
	preload("res://assets/BorealForest.png"),
	preload("res://assets/Desert.png"),
	preload("res://assets/TemperateForest.png"),
]
# 全局宏观噪声：大陆尺度明暗斑块，所有生态共享（原版 WorldMacro 同款思路）
const MACRO_TEXTURE := preload("res://assets/WorldMacro.png")


# 打包图集。只做一次（调用方缓存结果），换种子重建星球不重做。
# ungenerated_color：第 8 格的纯色（planet.gd 传 C_UNGENERATED）。
# 返回：
#   texture      → 紧凑图集纹理（含 mipmap）
#   macro        → WorldMacro 纹理
#   cell_origins → Array[Vector2]，8 个格子有效区左上角的 UV（写进网格 UV2）
#   cell_uv      → Vector2，单格有效区的 UV 尺寸（shader 里乘 fract 平铺坐标）
static func build(ungenerated_color: Color) -> Dictionary:
	var cell := SPRITE + GUTTER * 2
	var aw := COLS * cell
	var ah := ROWS * cell
	var atlas := Image.create_empty(aw, ah, false, Image.FORMAT_RGBA8)
	atlas.fill(Color(0, 0, 0, 0))
	var cell_origins: Array[Vector2] = []
	for i in BIOME_TEXTURES.size():
		var src: Image = BIOME_TEXTURES[i].get_image()
		if src.get_format() != Image.FORMAT_RGBA8:
			src.convert(Image.FORMAT_RGBA8)
		# 512 → 256：色卡是近纯色低对比噪声，缩半后颗粒感不变
		src.resize(SPRITE, SPRITE, Image.INTERPOLATE_LANCZOS)
		var ox := (i % COLS) * cell + GUTTER
		var oy := int(i / float(COLS)) * cell + GUTTER
		atlas.blit_rect(src, Rect2i(0, 0, SPRITE, SPRITE), Vector2i(ox, oy))
		_pad_gutter(atlas, src, ox, oy)
		cell_origins.append(Vector2(float(ox) / float(aw), float(oy) / float(ah)))
	# 第 8 格：未生成区域纯色（与海洋同色，视觉上是「没贴图的平坦海面」），
	# 连同 gutter 一起填满 —— 纯色格边缘延展 = 纯色本身。
	var ox8 := (7 % COLS) * cell + GUTTER
	var oy8 := int(7 / float(COLS)) * cell + GUTTER
	atlas.fill_rect(Rect2i(ox8 - GUTTER, oy8 - GUTTER, SPRITE + GUTTER * 2,
			SPRITE + GUTTER * 2), ungenerated_color)
	cell_origins.append(Vector2(float(ox8) / float(aw), float(oy8) / float(ah)))
	# mipmap：远景整颗星球缩小后必须走 mipmap，否则星点/颗粒会闪
	atlas.generate_mipmaps()
	return {
		"texture": ImageTexture.create_from_image(atlas),
		"macro": MACRO_TEXTURE,
		"cell_origins": cell_origins,
		"cell_uv": Vector2(float(SPRITE) / float(aw), float(SPRITE) / float(ah)),
	}


# gutter 四边用对应边缘行/列延展、四角用角像素填满（标准 atlas padding）。
# 必须在 generate_mipmaps() 之前做完：降采样链上的每个 texel 才都是内容色，
# 格边永远混不到透明黑 —— 这是 fract 边界细暗线的根源（见文件头注释①）。
static func _pad_gutter(atlas: Image, src: Image, ox: int, oy: int) -> void:
	for g in GUTTER:
		# 上/下：源行 0 与 SPRITE-1 各延展 GUTTER 行
		atlas.blit_rect(src, Rect2i(0, 0, SPRITE, 1), Vector2i(ox, oy - GUTTER + g))
		atlas.blit_rect(src, Rect2i(0, SPRITE - 1, SPRITE, 1),
				Vector2i(ox, oy + SPRITE + g))
		# 左/右：源列 0 与 SPRITE-1 各延展 GUTTER 列
		atlas.blit_rect(src, Rect2i(0, 0, 1, SPRITE), Vector2i(ox - GUTTER + g, oy))
		atlas.blit_rect(src, Rect2i(SPRITE - 1, 0, 1, SPRITE),
				Vector2i(ox + SPRITE + g, oy))
	# 四个 GUTTER² 角块（行列延展都不覆盖的区域）用对应角像素填满
	atlas.fill_rect(Rect2i(ox - GUTTER, oy - GUTTER, GUTTER, GUTTER),
			src.get_pixel(0, 0))
	atlas.fill_rect(Rect2i(ox + SPRITE, oy - GUTTER, GUTTER, GUTTER),
			src.get_pixel(SPRITE - 1, 0))
	atlas.fill_rect(Rect2i(ox - GUTTER, oy + SPRITE, GUTTER, GUTTER),
			src.get_pixel(0, SPRITE - 1))
	atlas.fill_rect(Rect2i(ox + SPRITE, oy + SPRITE, GUTTER, GUTTER),
			src.get_pixel(SPRITE - 1, SPRITE - 1))
