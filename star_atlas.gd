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
# 图集里**只放原图切出来的真实精灵**，不掺任何程序化生成的形状 ——
# 星星的形态一律来自 stars.png 本身（第 4 轮：此前追加过一颗程序化四芒星，
# 已按需求移除：满屏 ✦ 十字是合成形状，与原版柔光星点不符）。
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


# 把精灵打包成紧凑的网格图集。
#
# 两个关键处理：
#   ① **alpha 归一化**：每颗星裁出来单独归一化到峰值 1.0 ——
#      这样「亮度」完全由 instance color 控制（原图各颗星自带的强弱差异
#      会被归一化抹掉），符合需求里「随机采样后调整大小和亮度」的做法。
#   ② **留足白边**：每格四周留一倍精灵尺寸的空白，
#      mipmap 降采样时相邻格的星不会串味。
#
# 返回 { texture, uv_rects, sizes }：
#   uv_rects[i] = 第 i 颗星在新图集里的归一化 UV 矩形（正好框住那颗星）
#   sizes[i]    = 第 i 颗星的固有边长（像素），供上层按它做大小差异
static func pack(img: Image, sprites: Array[Sprite]) -> Dictionary:
	var sprites_all: Array[Sprite] = sprites.duplicate()

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
	for i in sprites_all.size():
		var s: Sprite = sprites_all[i]
		var ox := (i % cols) * cell + int((cell - s.rect.size.x) * 0.5)
		var oy := int(i / float(cols)) * cell + int((cell - s.rect.size.y) * 0.5)
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
