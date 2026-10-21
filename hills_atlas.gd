class_name HillsAtlas
extends RefCounted
# 丘陵贴片图集（第 2 期，见 docs/planet_textures_plan.md §4 步骤 5）：
# 4 张原版丘陵贴图（各 128²，内部 2×2 = 4 个 64² 变体）打包成 2×2 图集，
# 让「每个 ≥小丘陵 的贴片头顶贴一个切线 quad」的丘陵层仍然只有 1 次 draw call。
#
# 与 biome_atlas.gd 同款防串味手段：gutter 用**边缘像素延展填充**（对带 alpha 的
# 图片天然正确：边缘是透明就延展透明、是山色就延展山色）+ generate_mipmaps()
# 在延展之后做 —— mip 链上每个 texel 都是本格内容，远景降采样不会从邻格渗色
# （地表图集在 §7.1 实证过的教训，这里照搬）。
#
# 与 biome_atlas 的两点差异（贴图性质不同）：
#   · 色卡不透明近纯色 → 缩半无损；丘陵图是 64² 小变体 + alpha 轮廓 → 原生打包
#     不缩放（再缩变体就糊了）；
#   · 地表采样是盒式投影 + fract 平铺（有导数突跳，需手算 LOD）；丘陵是每个
#     quad 自带 UV、点采图集格 → UV 在 quad 内连续、恒在变体内，直接 texture()。
#
# 全部运行期打包（与项目「全代码动态构建」的风格一致），不产生新的资产文件。

const SPRITE := 128  # 每格有效边长（原生尺寸：内部 2×2 = 4 个 64² 变体）
const GUTTER := 16    # 格边延展宽：quad 点采无 fract 突跳，mip 过渡只需 16px 兜底
const COLS := 2
const ROWS := 2

# 与 planet.gd TerrainLevel（小丘/大丘/山地/不可逾越）顺序一一对应的 4 张原版贴图：
const HILL_TEXTURES: Array = [
	preload("res://assets/SmallHills.png"),
	preload("res://assets/LargeHills.png"),
	preload("res://assets/Mountains.png"),
	preload("res://assets/Impassable.png"),
]


# 打包图集。只做一次（调用方缓存结果），换种子重建星球不重做。
# 返回：
#   texture      → 图集纹理（含 mipmap；quad 远景靠它自然淡出）
#   cell_origins → Array[Vector2]，4 个格子有效区左上角的 UV（quad UV 的格原点）
#   sprite_uv    → Vector2，单格有效区 UV 尺寸；变体尺寸 = sprite_uv / 2
static func build() -> Dictionary:
	var cell := SPRITE + GUTTER * 2
	var aw := COLS * cell
	var ah := ROWS * cell
	var atlas := Image.create_empty(aw, ah, false, Image.FORMAT_RGBA8)
	atlas.fill(Color(0, 0, 0, 0))
	var cell_origins: Array[Vector2] = []
	for i in HILL_TEXTURES.size():
		var src: Image = HILL_TEXTURES[i].get_image()
		if src.get_format() != Image.FORMAT_RGBA8:
			src.convert(Image.FORMAT_RGBA8)
		# 正常应为原生 128²；尺寸对不上才缩（兜底，避免打包出错位的图集）
		if src.get_width() != SPRITE or src.get_height() != SPRITE:
			src.resize(SPRITE, SPRITE, Image.INTERPOLATE_LANCZOS)
		var ox := (i % COLS) * cell + GUTTER
		var oy := int(i / float(COLS)) * cell + GUTTER
		atlas.blit_rect(src, Rect2i(0, 0, SPRITE, SPRITE), Vector2i(ox, oy))
		_pad_gutter(atlas, src, ox, oy)
		cell_origins.append(Vector2(float(ox) / float(aw), float(oy) / float(ah)))
	# mipmap：远景 quad 缩到 1-2px 必须走 mip，否则颗粒闪烁；alpha 也随之降采样 →
	# 山体在远距离平滑淡出（而不是像素化硬边）
	atlas.generate_mipmaps()
	return {
		"texture": ImageTexture.create_from_image(atlas),
		"cell_origins": cell_origins,
		"sprite_uv": Vector2(float(SPRITE) / float(aw), float(SPRITE) / float(ah)),
	}


# gutter 四边用对应边缘行/列延展、四角用角像素填满（标准 atlas padding）。
# 必须在 generate_mipmaps() 之前做完：降采样链上的每个 texel 才都是本格内容，
# 格边永远混不到格子外的透明黑/邻格色（与 biome_atlas._pad_gutter 同构，
# 各自绑定本类的 SPRITE/GUTTER 常量，故独立实现）。
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
