class_name StarDome
extends MultiMeshInstance3D
# 背景星空：RimWorld WorldLayer_Stars 的 Godot 对应形（规划见 docs/starfield_plan.md）。
#
# 做法：半径 DOME_RADIUS 的天球上按“三高斯归一化”撒 STAR_COUNT 个均匀方向，
# 每个方向放一个朝向球心的 quad（单 MultiMesh，1 个 draw call），
# quad 显示同一张 64×64「三颗四芒星」glyph 的完整 UV → 实际星点 ≈ 3×quad 数。
# 随机尺寸 + 随机绕法线旋转，让同一张贴图看起来像千星群而非复制粘贴。
#
# 星感三要素（对照 RimWorld 的调校要点）：
# · glyph 是“软”的：菱形核用 pow 平滑衰减（中心亮、边缘快速变暗），十字臂细到
#   几乎看不见；alpha 生成后再过一遍 3×3 盒式模糊 —— 边缘没有硬锯齿，
#   远看是噪点而不是硬编码的几何体。
# · 每颗星有独立亮度与色温：MultiMesh instance color（use_colors）承载，
#   shader 里与贴图 alpha 相乘 —— 九成暗星、一成亮星、偶尔冷蓝/暖黄。
#   亮度靠颜色而不是物理尺寸，所以星点可以画得很小而不刺眼。
# · 星球边缘的大气辉光（atmosphere.gdshader）压住背景相对亮度，
#   星空因此显得更深邃（对应原版 WorldLayer_Glow 的观感补偿）。
#
# 与原版的三处对应/差异：
#   原版顶点着色器加 _WorldSpaceCameraPos 实现相机相对天球 → 这里等价改为
#   _process 把天球中心贴到相机位置（只有方向、没有平移视差）；
#   原版 ZTest Off（双相机合成的一半）→ 这里深度测试照常开、只关深度写入，
#   星穹半径远大于最远视距，星球按深度自然遮挡星星；
#   原版星图随太阳旋转（昼夜系统）→ 本项目无时间/太阳概念，第 1 期静态。

# —— 参数表（全部集中在此调参，见规划文档 §4.2）——
const STAR_SHADER := preload("res://starfield.gdshader")
const DOME_RADIUS := 400.0  # 天球半径：最远视距 10 的 40 倍，远沉入 far(4000) 之内
const STAR_COUNT := 1500    # quad 数（= 原版 StarsCount；实际星点 ≈ 3×1500）
# quad 边长 / 天球半径 → 角尺寸 ≈ 该比值（弧度）：0.015→0.86°，0.08→4.6°。
# 比上一版（0.04~0.22）小一个数量级：星点从“大十字”缩成“细碎噪点”，
# 刺眼感主要靠 instance color 的亮度分布压住，而不是靠物理尺寸。
const STAR_SIZE_MIN := 0.015
const STAR_SIZE_MAX := 0.08
# 亮星可以略大、暗星一律偏小：亮度与尺寸弱相关，视觉上更自然
const DIM_SIZE_MAX := 0.045
const BRIGHT_SIZE_MIN := 0.03

# —— 亮度/色温分布（写进 MultiMesh instance color）——
# 90% 暗星（灰 0.2~0.6）、10% 亮星（灰 0.8~1.0）；
# 亮星里再取一小部分染成极淡的冷蓝/暖黄（“偶尔混入”，不做主导）。
const DIM_RATIO := 0.90
const DIM_GRAY_MIN := 0.2
const DIM_GRAY_MAX := 0.6
const BRIGHT_GRAY_MIN := 0.8
# 亮星中染成异色的比例
const TINTED_RATIO := 0.15

# —— 星点两分类（决定颜色与尺寸档位）——
enum Kind { DIM, BRIGHT }

# glyph 贴图参数（64×64，运行期生成；调“星多大/多尖/亮度”就改这里）
# —— 形态学（对照 RimWorld Stars.png 反推）：原版是「近乎不透明的实体星形 + 细窄
#    抗锯齿边」。但直接照搬「实心菱形核 + 实心十字臂」在屏幕上的观感是
#    “巨大的硬边白色十字”（首版实测，与原版截图差极远）——
#    根因不是形状错，而是**没有抗锯齿、没有亮度变化**，于是硬边被放大成刺眼几何体。
#    第 2 轮改成「pow 平滑衰减的软核 + 极细极暗的臂 + 3×3 模糊」：
#    形状保留 ✦ 的神韵，边缘化开，整体退成细碎噪点。
const TEX_SIZE := 64
# 菱形核半径 / 半箭长：核只占菱形内一小段（中央一小团亮斑），四周快速衰减
const GLYPH_CORE_R := 0.45
# 核心衰减指数：越大越锐（中心亮核收紧、边缘掉得快）
const GLYPH_FALLOFF := 3.0
# 十字臂：极细极暗 —— 远看几乎不可见，拉近才隐约是 ✦ 的四芒
const GLYPH_ARM_W := 0.09   # 臂宽 / 半箭长
const GLYPH_ARM_LEN := 1.6  # 臂长 / 半箭长
const GLYPH_ARM_BRIGHT := 0.10  # 臂亮度系数（远看几乎不发光）
# 三颗星：中心(px)、半箭长 s（菱形核尖端到中心的像素距离；臂再向外探 1.6s）
const GLYPHS := [
	[Vector2(32, 32), 11.0],  # 中央大星
	[Vector2(49, 15), 5.0],   # 右上小星
	[Vector2(15, 49), 4.5],   # 左下小星
]

var star_seed := -1  # 当前星空种子；-1 = 尚未构建

var _material: ShaderMaterial
# 最近一次 build 的全部 instance transform（GDScript 侧拷贝）。
# 用途：① headless 冒烟可在 dummy 渲染器下做确定性对比（dummy 的 MultiMesh
# 读不回 transform，恒返回 zero，见 tools/test_starfield.gd）；② 排查星穹布局时直接看数。
var _built: Array[Transform3D] = []
# 最近一次 build 的每颗星颜色（GDScript 侧拷贝，同上：dummy 渲染器读不回）
var _built_colors: Array[Color] = []


func _ready() -> void:
	_ensure_material()


# 材质惰性装配：_ready 在 --script 测试环境里触发时机不可靠，build() 亦兜底调用
func _ensure_material() -> void:
	if _material != null:
		return
	_material = ShaderMaterial.new()
	_material.shader = STAR_SHADER
	_material.set_shader_parameter("star_tex", _make_star_tex())
	material_override = _material


# 每帧把天球中心贴到相机位置（不做平移 ⇒ 星空无视差；旋转恒 identity ⇒ 静态星图）。
# 成本：一次 transform 赋值，忽略不计；网格从不因相机动而重建。
func _process(_delta: float) -> void:
	var vp := get_viewport()
	if vp == null:
		return
	var cam := vp.get_camera_3d()
	if cam != null:
		global_position = cam.global_position


# 按 seed 重建星穹。确定性保证：独立 RandomNumberGenerator（不碰星球噪声的随机流），
# 同一个 seed 永远得到同一片星空。触发语义参考原版 ShouldRegenerate：种子变了才重铺。
func build(seed_value: int) -> void:
	star_seed = seed_value
	_ensure_material()
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	_built.clear()
	_built_colors.clear()
	# —— 提交渲染：单 MultiMesh，1 个 draw call ——
	# use_colors 必须在 instance_count 之前打开（之后设会清空缓冲）。
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true        # 每颗星的亮度/色温 → 顶点色通道 COLOR
	mm.mesh = _make_quad_mesh()
	mm.instance_count = STAR_COUNT
	for i in STAR_COUNT:
		# 球面均匀方向：三个高斯分量归一化（不是 inside_unit_sphere——那个在角落偏密）
		var dir := Vector3(rng.randfn(), rng.randfn(), rng.randfn()).normalized()
		var z_axis := -dir  # 法线朝球心：相机在球心，正对 quad 正面
		# 切平面正交基：把参考轴投影到切面上，再叉乘补全
		var helper := Vector3.UP if absf(dir.y) < 0.9 else Vector3.RIGHT
		var x_axis := (helper - dir * helper.dot(dir)).normalized()
		var y_axis := z_axis.cross(x_axis)
		# 随机绕法线旋转（原版 randomizeRotation 对应物），消掉贴图复制感
		var angle := rng.randf() * TAU
		var xr := x_axis.rotated(z_axis, angle)
		var yr := y_axis.rotated(z_axis, angle)
		var xform_basis := Basis(xr, yr, z_axis)
		# 先抽星的“档位”，颜色与尺寸都跟着档位走（亮星更大更白，暗星更小更灰）
		var kind := _star_kind(rng)
		var col := _star_color(rng, kind)
		# QuadMesh 边长 2 → 缩放 s 得边长 2s；求边长 = rel×半径，故 scale = rel×半径/2
		var rel := _star_size(rng, kind)
		var edge := rel * DOME_RADIUS
		xform_basis = xform_basis.scaled(Vector3(edge * 0.5, edge * 0.5, edge * 0.5))
		_built.append(Transform3D(xform_basis, dir * DOME_RADIUS))
		_built_colors.append(col)
		mm.set_instance_transform(i, _built[i])
		mm.set_instance_color(i, col)
	multimesh = mm


# 抽一颗星的档位：九成暗星、一成亮星。
func _star_kind(rng: RandomNumberGenerator) -> Kind:
	if rng.randf() < DIM_RATIO:
		return Kind.DIM
	return Kind.BRIGHT


# 抽一颗星的颜色（亮度 + 色温）。
# alpha 恒为 1 —— 亮度只走 RGB，让 ALBEDO 携带亮度、ALPHA 只承载贴图形状
# （避免亮度被乘两次，暗星直接消失）。
func _star_color(rng: RandomNumberGenerator, kind: Kind) -> Color:
	if kind == Kind.DIM:
		var g := rng.randf_range(DIM_GRAY_MIN, DIM_GRAY_MAX)
		return Color(g, g, g, 1.0)
	# 亮星：偶尔染成极淡的冷蓝/暖黄（“偶尔混入”），其余是纯白系
	if rng.randf() < TINTED_RATIO:
		if rng.randf() < 0.5:
			return Color(0.7, 0.8, 1.0, 1.0)
		return Color(1.0, 0.9, 0.7, 1.0)
	var g2 := rng.randf_range(BRIGHT_GRAY_MIN, 1.0)
	return Color(g2, g2, g2, 1.0)


# 抽一颗星的尺寸（相对天球半径）。亮星允许更大、暗星一律偏小：
# 亮度与尺寸弱相关 → 画面里少数几颗“主角星”，其余是细碎噪点。
func _star_size(rng: RandomNumberGenerator, kind: Kind) -> float:
	if kind == Kind.BRIGHT:
		return rng.randf_range(BRIGHT_SIZE_MIN, STAR_SIZE_MAX)
	return rng.randf_range(STAR_SIZE_MIN, DIM_SIZE_MAX)


# 冒烟/排查看数用：返回最近一次 build 的全部 transform 快照（深拷贝，
# 防止调用方拿到与内部 _built 同引用的数组——那样后续 build 会把旧快照一并清掉）
func snapshot_transforms() -> Array[Transform3D]:
	return _built.duplicate()


# 冒烟/排查看数用：返回最近一次 build 的每颗星颜色快照（同上，深拷贝）
func snapshot_colors() -> Array[Color]:
	return _built_colors.duplicate()


# 星点 quad 网格（2×2、朝 +Z），显式带一份白色顶点色。
# 原因：MultiMesh 的 instance color 是「乘在网格顶点色上」的（见 set_instance_color
# 文档：*multiplying* the mesh's existing vertex colors），而引擎里
# `color_interp *= instance_color` 只在网格带顶点色时才有的乘。
# 没有顶点色 → COLOR 恒为白 → 每颗星亮度相同，正是要修掉的毛病。
func _make_quad_mesh() -> ArrayMesh:
	var verts := PackedVector3Array([
		Vector3(-1, -1, 0), Vector3(1, -1, 0),
		Vector3(1, 1, 0), Vector3(-1, 1, 0),
	])
	var uvs := PackedVector2Array([
		Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0),
	])
	var cols := PackedColorArray([
		Color(1, 1, 1, 1), Color(1, 1, 1, 1), Color(1, 1, 1, 1), Color(1, 1, 1, 1),
	])
	var idx := PackedInt32Array([0, 1, 2, 0, 2, 3])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


# 程序化烘焙 64×64 三颗四芒星 glyph：纯白 RGB，变化全在 alpha。
# 形态 = 曼哈顿距离场（(|dx|+|dy|)/s）的菱形核（pow 平滑衰减）
#      + 两条极细极暗的十字臂；
# 最后整体过一遍 3×3 盒式模糊（抹掉硬锯齿）并做峰值归一化（模糊会削峰，
# 归一化把中心亮度补回来 —— 不然整片星空会比预期更暗）。
func _make_star_tex() -> ImageTexture:
	var img := Image.create_empty(TEX_SIZE, TEX_SIZE, true, Image.FORMAT_RGBA8)
	# 先把 alpha 算进浮点缓冲（模糊需要比 8bit 更宽的中间精度）
	var buf := PackedFloat32Array()
	buf.resize(TEX_SIZE * TEX_SIZE)
	for y in TEX_SIZE:
		for x in TEX_SIZE:
			var a := 0.0
			for g in GLYPHS:
				a = maxf(a, _star_alpha(Vector2(x, y), g[0], g[1] as float))
			buf[y * TEX_SIZE + x] = a
	_blur_alpha(buf)
	_normalize_peak(buf)
	for y in TEX_SIZE:
		for x in TEX_SIZE:
			var a := clampf(buf[y * TEX_SIZE + x], 0.0, 1.0)
			# 纯白 RGB + alpha 衰减：blend 出来只有形状亮度差，无色调污染
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))
	img.generate_mipmaps()  # 缩小时按屏幕占比选层，避免星点闪烁
	return ImageTexture.create_from_image(img)


# 单颗星 alpha：菱形核（pow 平滑衰减，中心亮、边缘快速变暗）
# 叠两条极细极暗的十字臂（✦ 的尖芒，远看几乎不可见）。
# 两形取 max：中心是柔和亮斑，臂从核外探出。
func _star_alpha(p: Vector2, c: Vector2, s: float) -> float:
	var dx := absf(p.x - c.x)
	var dy := absf(p.y - c.y)
	# 菱形核：曼哈顿距离归一化到 1 = 菱形尖端，再按 GLYPH_CORE_R 截断
	var d_mm := (dx + dy) / s
	var core := pow(clampf(1.0 - d_mm / GLYPH_CORE_R, 0.0, 1.0), GLYPH_FALLOFF)
	# 十字臂：沿轴向衰减 × 横向窄缝（宽度取 0.5px 下限，保证再小也还剩一列）
	var arm_len := s * GLYPH_ARM_LEN
	var w := maxf(s * GLYPH_ARM_W, 0.5)
	var ax := pow(clampf(1.0 - dx / arm_len, 0.0, 1.0), 2.0) \
			* pow(clampf(1.0 - dy / w, 0.0, 1.0), 2.0)
	var ay := pow(clampf(1.0 - dy / arm_len, 0.0, 1.0), 2.0) \
			* pow(clampf(1.0 - dx / w, 0.0, 1.0), 2.0)
	var arms := maxf(ax, ay) * GLYPH_ARM_BRIGHT
	return maxf(core, arms)


# 3×3 盒式模糊（可分离：先横后纵），作用在 alpha 缓冲上。
# 目的只有一个：把解析衰减算出来的硬边抹成软边 —— 星星不再是硬编码几何体。
# 边界用钳位复制（边缘像素延拓），避免整幅图出现暗环。
func _blur_alpha(buf: PackedFloat32Array) -> void:
	var n := TEX_SIZE
	var tmp := buf.duplicate()
	# 横向
	for y in n:
		for x in n:
			var l := buf[y * n + maxi(x - 1, 0)]
			var c := buf[y * n + x]
			var r := buf[y * n + mini(x + 1, n - 1)]
			tmp[y * n + x] = (l + c + r) / 3.0
	# 纵向（读 tmp 写回 buf）
	for y in n:
		for x in n:
			var u := tmp[maxi(y - 1, 0) * n + x]
			var c := tmp[y * n + x]
			var d := tmp[mini(y + 1, n - 1) * n + x]
			buf[y * n + x] = (u + c + d) / 3.0


# 峰值归一化：模糊会把中心的 1.0 削到 0.4 上下，整片星空随之偏暗。
# 这里把最大值拉回 1.0 —— 只动整体亮度，不改变形状。
func _normalize_peak(buf: PackedFloat32Array) -> void:
	var peak := 0.0
	for v in buf:
		peak = maxf(peak, v)
	if peak <= 0.0001:
		return
	var k := 1.0 / peak
	for i in buf.size():
		buf[i] *= k
