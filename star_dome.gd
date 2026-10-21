class_name StarDome
extends MultiMeshInstance3D
# 背景星空：RimWorld WorldLayer_Stars 的 Godot 对应形（规划见 docs/starfield_plan.md）。
#
# 做法：半径 DOME_RADIUS 的天球上按“三高斯归一化”撒 STAR_COUNT 个均匀方向，
# 每个方向放一个朝向球心的 quad（单 MultiMesh，1 个 draw call）。
#
# **贴图来自 RimWorld 原版**：assets/stars.png 就是原版 Stars.png（SHA256 一致），
# 1024×1024 里散布着 22 颗独立的柔光星点精灵。启动时用 StarAtlas 把它们
# 切成精灵、紧凑打包成小图集；每颗星随机采样其中一块 → 天然就有
# 「不同形状 / 不同大小」的星，既不用自己造贴图，也不会出现硬边几何体的十字。
#
# 每颗星的三个随机维度：
#   ① 采样哪一颗精灵   → INSTANCE_CUSTOM 携带 UV 矩形（vertex 阶段改写 UV）
#   ② 多大             → quad 的缩放
#   ③ 多亮 / 什么色温   → instance color（乘在白色顶点色上）
#
# 与原版的三处对应/差异：
#   原版顶点着色器加 _WorldSpaceCameraPos 实现相机相对天球 → 这里等价改为
#   _process 把天球中心贴到相机位置（只有方向、没有平移视差）；
#   原版 ZTest Off（双相机合成的一部分）→ 这里深度测试照常开、只关深度写入，
#   星穹半径远大于最远视距，星球按深度自然遮挡星星；
#   原版星图随太阳旋转（昼夜系统）→ 本项目无时间/太阳概念，第 1 期静态。

# —— 参数表（全部集中在此调参，见规划文档 §4.2）——
const STAR_SHADER := preload("res://starfield.gdshader")
# 图集分析器（用 preload 而非 class_name：跟 planet.gd 的依赖风格一致，
# 且不依赖编辑器的全局类名注册缓存 —— headless 冒烟与 CI 下更稳）
const StarAtlasScript := preload("res://star_atlas.gd")
# 从 RimWorld 原版提取的星点图集（assets/stars.png，1024×1024）：
# 里面散布着 22 颗独立的柔光星点精灵（8×8 ~ 20×20 px 不等）。
const STAR_ATLAS := preload("res://assets/stars.png")
const DOME_RADIUS := 400.0  # 天球半径：最远视距 10 的 40 倍，远沉入 far(4000) 之内
# 星点数（= quad 数，1 quad = 1 颗星）。
# 原版 1500 个 quad × 每张 3 颗星 = 4500 个星点；这里一颗一 quad，
# 数量取 8000 以补回星点密度（实测屏幕密度 ~480 个/百万像素，与原版一致）。
const STAR_COUNT := 16000
# —— quad 尺寸 ——
# quad 边长 / 天球半径 = 星的角尺寸（弧度）。
# 注意与旧版的区别：旧版贴图里星只占 64×64 的一小角，quad 尺寸 ≠ 星尺寸；
# 现在**图集里的精灵恰好铺满整个 quad**（UV 矩形正好框住那颗星），
# 所以 quad 尺寸就是星的屏幕尺寸 —— 数值必须很小，否则会糊成大光斑。
# 换算：2000px 宽的画面 ≈ 26.7px/度，1px ≈ 0.0375° ≈ 0.00065 弧度。
# 原版截图的目标：普通星点 1~3px（≈0.0007~0.0020），最亮的带芒星 8~14px（≈0.005~0.009）。
const STAR_SIZE_MIN := 0.0018
const STAR_SIZE_MAX := 0.0070
# 暗星一律偏小、亮星允许更大：亮度与尺寸弱相关，视觉上更自然
const DIM_SIZE_MAX := 0.0032
const BRIGHT_SIZE_MIN := 0.0032
# 四芒星（程序化生成）单独给尺寸：它是画面里唯一的「大而带芒」的星，
# 要明显比普通星点大，原版截图里约 12~20px。
const FOUR_POINT_SIZE := 0.0130
# —— 图集取样 ——
# 每颗星随机取图集里的一颗精灵（按面积加权 → 大星更容易被抽到），
# 再乘一个随机大小系数 —— 于是「采样哪颗 + 抽到后多大」两层随机。
const SAMPLE_JITTER_MIN := 0.75
const SAMPLE_JITTER_MAX := 1.35
# 四芒星（程序化，图集最后一位）的使用比例：只给最亮的少数星，
# 对应原版截图「满屏细碎暗点 + 零星几颗带四芒光芒的亮星」。
const FOUR_POINT_RATIO := 1.0

# —— 亮度/色温分布（写进 MultiMesh instance color）——
# 90% 暗星（灰 0.2~0.6）、10% 亮星（灰 0.8~1.0）；
# 亮星里再取一小部分染成极淡的冷蓝/暖黄（“偶尔混入”，不做主导）。
# 注：原版截图里绝大多数星是“暗到几乎看不见的灰点”，只有零星几颗明显更亮，
# 所以暗星区间的上限压到 0.55、亮星比例压到 8% —— 亮星更少、更集中。
const DIM_RATIO := 0.92
const DIM_GRAY_MIN := 0.18
const DIM_GRAY_MAX := 0.55
const BRIGHT_GRAY_MIN := 0.8
# 亮星中染成异色的比例
const TINTED_RATIO := 0.15

# —— 星点两分类（决定颜色与尺寸档位）——
enum Kind { DIM, BRIGHT }

var star_seed := -1  # 当前星空种子；-1 = 尚未构建

var _material: ShaderMaterial
# 最近一次 build 的全部 instance transform（GDScript 侧拷贝）。
# 用途：① headless 冒烟可在 dummy 渲染器下做确定性对比（dummy 的 MultiMesh
# 读不回 transform，恒返回 zero，见 tools/test_starfield.gd）；② 排查星穹布局时直接看数。
var _built: Array[Transform3D] = []
# 最近一次 build 的每颗星颜色（GDScript 侧拷贝，同上：dummy 渲染器读不回）
var _built_colors: Array[Color] = []
# 图集分析结果（启动时做一次）：紧凑图集 + 每颗精灵的 UV 矩形 + 固有大小 + 抽样权重
var _atlas_uv_rects: Array[Rect2] = []
var _atlas_sizes: Array[int] = []
var _atlas_weights: PackedFloat32Array = PackedFloat32Array()
var _atlas_ready := false
# 图集里所有精灵的「平均固有边长」—— 采样时用它把精灵的原生大小差异
# 换算成屏幕上的大小差异（8×8 的小星比 20×20 的大星小 2.5 倍）。
var _atlas_mean_size := 12.0


func _ready() -> void:
	_ensure_material()


# 材质惰性装配：_ready 在 --script 测试环境里触发时机不可靠，build() 亦兜底调用
func _ensure_material() -> void:
	if _material != null:
		return
	_material = ShaderMaterial.new()
	_material.shader = STAR_SHADER
	_ensure_atlas()
	_material.set_shader_parameter("star_tex", _atlas_texture)
	material_override = _material


# 图集准备：把 RimWorld 原版 Stars.png 切成精灵、紧凑打包。
# 只做一次（结果缓存），之后所有 build() 复用 —— 换种子重建星穹不该重做这件事。
var _atlas_texture: Texture2D
var _atlas_total_weight := 0.0


func _ensure_atlas() -> void:
	if _atlas_ready:
		return
	_atlas_ready = true
	var img: Image = STAR_ATLAS.get_image()
	var sprites: Array = StarAtlasScript.extract_sprites(img)
	var packed: Dictionary = StarAtlasScript.pack(img, sprites)
	_atlas_texture = packed["texture"]
	_atlas_uv_rects = packed["uv_rects"]
	_atlas_sizes = packed["sizes"]
	# 抽样权重按精灵面积（大的星更容易被抽到 —— 与原版「大小随机」的观感一致）。
	# 权重按累积值存成前缀和，抽样时二分查找。
	_atlas_weights = PackedFloat32Array()
	var total := 0.0
	for s: StarAtlasScript.Sprite in sprites:
		total += float(s.rect.size.x * s.rect.size.y)
		_atlas_weights.append(total)
	_atlas_total_weight = total
	# 精灵的平均固有边长（用于把「原生大小差异」换算成「屏幕大小差异」）
	var size_sum := 0
	for s2: StarAtlasScript.Sprite in sprites:
		size_sum += s2.size
	_atlas_mean_size = maxf(1.0, float(size_sum) / maxf(1.0, float(sprites.size())))


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
	_ensure_atlas()
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	_built.clear()
	_built_colors.clear()
	# —— 提交渲染：单 MultiMesh，1 个 draw call ——
	# use_colors / use_custom_data 必须在 instance_count 之前打开（之后设会清空缓冲）。
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true        # 每颗星的亮度/色温 → 顶点色通道 COLOR
	mm.use_custom_data = true   # 每颗星采样图集的哪一块 → UV 矩形
	mm.mesh = _make_quad_mesh()
	mm.instance_count = STAR_COUNT
	var n_sprites := _atlas_uv_rects.size()
	# 四芒星在图集里的位置（最后一位），只给最亮的少数星用
	var four_index := n_sprites - 1
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
		# 采样图集里的哪一颗星（按面积加权）
		var si := _sample_sprite(rng)
		# 最亮的少数星改用四芒星（程序化，图集最后一位）—— 原版截图里
		# 「零星几颗带光芒的亮星」就是这种形态
		var is_four := false
		if kind == Kind.BRIGHT and rng.randf() < FOUR_POINT_RATIO:
			si = four_index
			is_four = true
		# 抽到之后再乘一个随机大小系数 —— 「采样哪颗」+「抽到后多大」两层随机
		var jitter := rng.randf_range(SAMPLE_JITTER_MIN, SAMPLE_JITTER_MAX)
		# 精灵的**原生大小**也换算进屏幕尺寸：图集里 8×8 的小星就该比 20×20 的大星小。
		# （四芒星是程序化生成的固定尺寸，单独给尺寸）
		var rel := 0.0
		if is_four:
			rel = FOUR_POINT_SIZE * jitter
		else:
			var size_factor := 1.0
			if si < _atlas_sizes.size():
				size_factor = float(_atlas_sizes[si]) / _atlas_mean_size
			rel = _star_size(rng, kind) * jitter * size_factor
		# QuadMesh 边长 2 → 缩放 s 得边长 2s；求边长 = rel×半径，故 scale = rel×半径/2
		var edge := rel * DOME_RADIUS
		xform_basis = xform_basis.scaled(Vector3(edge * 0.5, edge * 0.5, edge * 0.5))
		_built.append(Transform3D(xform_basis, dir * DOME_RADIUS))
		_built_colors.append(col)
		mm.set_instance_transform(i, _built[i])
		mm.set_instance_color(i, col)
		# UV 矩形（u0, v0, du, dv）经 INSTANCE_CUSTOM 传给 vertex()
		var uv: Rect2 = _atlas_uv_rects[si] if n_sprites > 0 else Rect2(0, 0, 1, 1)
		mm.set_instance_custom_data(i, Color(uv.position.x, uv.position.y, uv.size.x, uv.size.y))
	multimesh = mm


# 按面积加权抽一颗精灵（权重前缀和 + 二分）。
# 面积大的星（20×20）比小星（8×8）更容易被抽到 —— 与原版「星有大小之分」的观感一致。
func _sample_sprite(rng: RandomNumberGenerator) -> int:
	var n := _atlas_uv_rects.size()
	if n <= 1:
		return 0
	var r := rng.randf() * _atlas_total_weight
	var lo := 0
	var hi := _atlas_weights.size() - 1
	while lo < hi:
		# 二分下标：>> 1 是整除（用 / 会被 GDScript 报整除警告）
		var mid := (lo + hi) >> 1
		if r <= _atlas_weights[mid]:
			hi = mid
		else:
			lo = mid + 1
	return lo


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


# 冒烟/排查看数用：返回图集里切出来的精灵数量（应 > 1，否则说明贴图没被正确解析）
func sprite_count() -> int:
	return _atlas_uv_rects.size()


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
