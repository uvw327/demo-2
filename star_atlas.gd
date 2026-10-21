class_name StarAtlas
extends RefCounted
# 星点图集：把 RimWorld 原版 Stars.png（1024×1024，散布 22 颗柔光星点）
# 切成一颗颗独立的精灵，再打包成紧凑的网格图集，供星穹逐颗随机采样。
#
# 为什么要这一层（而不是直接拿原图当贴图）：
#   ① 原图 1024×1024 里只有 22 个小星点、其余全是透明像素 —— 直接当贴图用，
#      每个 quad 只能采到一小块，且 mipmap 会在大片空白里取样（颜色发灰、边界串味）。
#   ② 切成精灵再紧凑打包后：每颗星能独立采样、mipmap 干净、显存占用极小。
#   ③ 每颗星原本的**固有大小**（8×8 ~ 20×20 px）与柔和的 alpha 衰减被完整保留 ——
#      随机采样时天然就有「大小不一、软硬不一」的星，不用额外去造。
#
# 另外补一颗**程序化生成的柔光四芒星**：原版 RimWorld 的 64×64 星图是三颗四芒星，
# 参考截图里最亮的那几颗正是这种带四道光芒的 ✦。这里现算一颗（软边，非硬边几何体），
# 混进图集里，只给最亮的少数星用 —— 对应参考图「满屏细碎暗点 + 零星几颗带光芒的亮星」。
#
# 全部在运行期做（与项目「全代码动态构建」一致），不产生任何新资产文件。

# 图集里每颗星的信息
class Sprite:
	var rect: Rect2i     # 在原图里的包围盒
	var peak: float      # 原始峰值 alpha（打包时会被归一化掉，这里留作亮度参考）
	var size: int        # 包围盒边长（固有大小的代表）


# 找出图集里所有独立星点（连通域）
#
# 性能：原图 1024×1024 = 1M 像素，在 GDScript 里逐像素扫一遍要 20ms+（启动卡顿）。
# 两处优化：
#   ① 直接读原始字节缓冲（RGBA8，alpha 在每像素第 4 字节），避开 get_pixel() 的调用开销；
#   ② 外层「找种子」用步长 2 的粗扫（1/4 的读取量）—— 图集里的星最小 8×8，
#      粗扫不可能漏掉；找到种子后再做**全分辨率**泛洪，精度不打折。
# 结果与逐像素扫描完全一致，启动开销降到几毫秒。
static func extract_sprites(img: Image) -> Array[Sprite]:
	var w := img.get_width()
	var h := img.get_height()
	# 亮度阈值：滤掉极淡的噪点（峰值 < 0.04 基本不可见）
	const ALPHA_MIN := 0.04
	var threshold := 255 * ALPHA_MIN
	var rgba := img
	if rgba.get_format() != Image.FORMAT_RGBA8:
		rgba = img.duplicate()
		rgba.convert(Image.FORMAT_RGBA8)
	var data := rgba.get_data()
	var visited := PackedByteArray()
	visited.resize(w * h)
	var out: Array[Sprite] = []
	var stack: Array[Vector2i] = []
	# 种子粗扫：直接按字节偏移步进（每 2 个像素 = 8 字节），
	# 避开逐像素的索引乘法 —— GDScript 里这个差别很大（1M 次 vs 250K 次）。
	const SEED_STEP := 2
	var row_stride := w * 4
	for y in range(0, h, SEED_STEP):
		var row_off := y * row_stride
		for x in range(0, w, SEED_STEP):
			var boff := row_off + x * 4
			if data[boff + 3] < threshold:
				continue
			var idx := y * w + x
			if visited[idx] == 1:
				continue
			visited[idx] = 1
			stack.clear()
			stack.append(Vector2i(x, y))
			var minx := x
			var maxx := x
			var miny := y
			var maxy := y
			var peak := 0.0
			while not stack.is_empty():
				var p: Vector2i = stack.pop_back()
				var a := data[(p.y * w + p.x) * 4 + 3] / 255.0
				peak = maxf(peak, a)
				minx = mini(minx, p.x)
				maxx = maxi(maxx, p.x)
				miny = mini(miny, p.y)
				maxy = maxi(maxy, p.y)
				# 8 邻域
				for dy in range(-1, 2):
					for dx in range(-1, 2):
						var nx := p.x + dx
						var ny := p.y + dy
						if nx < 0 or ny < 0 or nx >= w or ny >= h:
							continue
						var ni := ny * w + nx
						if visited[ni] == 1:
							continue
						if data[ni * 4 + 3] < threshold:
							continue
						visited[ni] = 1
						stack.append(Vector2i(nx, ny))
			var sp := Sprite.new()
			sp.rect = Rect2i(minx, miny, maxx - minx + 1, maxy - miny + 1)
			sp.peak = peak
			sp.size = maxi(sp.rect.size.x, sp.rect.size.y)
			out.append(sp)
	# 峰值亮度降序（亮的在前，方便按亮度分段取样）
	out.sort_custom(func(a: Sprite, b: Sprite) -> bool: return a.peak > b.peak)
	return out


# 程序化生成一颗**柔光四芒星**（RGBA8，白色 + alpha 衰减）。
# 与原版 RimWorld 星图同形：中心亮核 + 四道光芒。
# 关键是"柔"：全程 smoothstep 衰减，没有硬边 —— 硬边十字正是上一版被否掉的效果。
#
# 注意亮度配比：光芒必须**明显**弱于核心（这里 0.55 : 1.0），
# 否则缩小后整颗星糊成一个白团，四芒的形状就消失了。
static func make_four_point_star(size: int) -> Image:
	var img := Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
	var c := float(size) * 0.5
	for y in size:
		for x in size:
			var dx := (float(x) + 0.5 - c) / c
			var dy := (float(y) + 0.5 - c) / c
			var r := sqrt(dx * dx + dy * dy)
			# 中心核：紧实的一小团，边缘快速收
			var core := 1.0 - smoothstep(0.05, 0.30, r)
			core = core * core
			# 四道光芒：沿 ±x / ±y 轴的窄条，越远越弱。
			# across = 到最近那条轴的**垂直**距离（= min），沿 = 沿轴的距离（= max）。
			# （min/max 弄反的话光芒会塌成核心外一圈极窄的环，等于看不见。）
			var across := minf(absf(dx), absf(dy))
			var ray := 0.0
			if across < 0.24 and r > 0.16:
				ray = (1.0 - smoothstep(0.0, 0.24, across)) \
						* (1.0 - smoothstep(0.16, 0.95, r))
			var a := clampf(maxf(core, ray * 0.55), 0.0, 1.0)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))
	return img


# 把精灵打包成紧凑的网格图集。
#
# 三个关键处理：
#   ① **alpha 归一化**：每颗星裁出来单独归一化到峰值 1.0 ——
#      这样「亮度」完全由 instance color 控制（原图各颗星自带的强弱差异
#      会被归一化抹掉），符合需求里「随机采样后调整大小和亮度」的做法。
#   ② **留足白边**：每格四周留一倍精灵尺寸的空白，
#      mipmap 降采样时相邻格的星不会串味。
#   ③ **追加一颗程序化四芒星**（见 make_four_point_star），
#      排在最后，供最亮的星使用。
#
# 返回 { texture, uv_rects, sizes }：
#   uv_rects[i] = 第 i 颗星在新图集里的归一化 UV 矩形（正好框住那颗星）
#   sizes[i]    = 第 i 颗星的固有边长（像素），供上层按它做大小差异
static func pack(img: Image, sprites: Array[Sprite]) -> Dictionary:
	var sprites_all: Array[Sprite] = sprites.duplicate()
	# 程序化四芒星：作为最后一位（最亮的星专用）
	var four_size := 32
	var four := Sprite.new()
	four.rect = Rect2i(0, 0, four_size, four_size)
	four.peak = 1.0
	four.size = four_size
	sprites_all.append(four)

	var cols := int(ceil(sqrt(float(sprites_all.size()))))
	var rows := int(ceil(float(sprites_all.size()) / float(cols)))
	# 格子边长 = 最大精灵边长的 2 倍（上下左右各留一倍白边，防 mipmap 串味）
	var max_size := 8
	for s in sprites_all:
		max_size = maxi(max_size, s.size)
	var cell := max_size * 2
	var aw := cols * cell
	var ah := rows * cell
	var atlas := Image.create_empty(aw, ah, true, Image.FORMAT_RGBA8)
	atlas.fill(Color(0, 0, 0, 0))
	var uv_rects: Array[Rect2] = []
	var sizes: Array[int] = []
	var four_index := sprites_all.size() - 1
	for i in sprites_all.size():
		var s: Sprite = sprites_all[i]
		var ox := (i % cols) * cell + int((cell - s.rect.size.x) * 0.5)
		var oy := int(i / float(cols)) * cell + int((cell - s.rect.size.y) * 0.5)
		if i == four_index:
			# 程序化四芒星：直接贴整张（它本身就是一张完整贴图）
			var four_img := make_four_point_star(four_size)
			for y in four_size:
				for x in four_size:
					atlas.set_pixel(ox + x, oy + y, four_img.get_pixel(x, y))
		else:
			# 原图里的星：拷贝并按峰值归一化 alpha
			var inv_peak := 1.0 / maxf(s.peak, 0.0001)
			for y in s.rect.size.y:
				for x in s.rect.size.x:
					var c := img.get_pixel(s.rect.position.x + x, s.rect.position.y + y)
					c.a = clampf(c.a * inv_peak, 0.0, 1.0)
					atlas.set_pixel(ox + x, oy + y, c)
		uv_rects.append(Rect2(
			float(ox) / float(aw),
			float(oy) / float(ah),
			float(s.rect.size.x) / float(aw),
			float(s.rect.size.y) / float(ah)))
		sizes.append(s.size)
	atlas.generate_mipmaps()
	return {
		"texture": ImageTexture.create_from_image(atlas),
		"uv_rects": uv_rects,
		"sizes": sizes,
	}
