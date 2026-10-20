class_name StarDome
extends MultiMeshInstance3D
# 背景星空：RimWorld WorldLayer_Stars 的 Godot 对应形（规划见 docs/starfield_plan.md）。
#
# 做法：半径 DOME_RADIUS 的天球上按“三高斯归一化”撒 STAR_COUNT 个均匀方向，
# 每个方向放一个朝向球心的 quad（单 MultiMesh，1 个 draw call），
# quad 显示同一张 64×64「三颗四芒星」glyph 的完整 UV → 实际星点 ≈ 3×quad 数。
# 随机尺寸 + 随机绕法线旋转，让同一张贴图看起来像千变星群而非复制粘贴。
#
# 星感三要素（对照 RimWorld 的调校要点）：
# · glyph 大半透明、亮核极小 —— 星 quad 的角尺寸其实不小（5~22°），不透明亮核必须只占
#   贴图中央很小一块，否则整屏变白雾；指数 sharp 保证“亮核尖锐 + 快速衰减”。
# · 贴图运行期程序化生成（与本项目全代码构建风格一致）：64×64 一次 Image，
#   确定性公式 → 同代码同像素；免去重烘 png + 重导 import 的往返。
# · 与原版的三处对应/差异：
#   原版顶点着色器加 _WorldSpaceCameraPos 实现相机相对天球 → 这里等价改为
#   _process 把天球中心贴到相机位置（只有方向、没有平移视差）；
#   原版 ZTest Off（双相机合成的一半）→ 这里深度测试照常开、只关深度写入，
#   星穹半径远大于最远视距，星球按深度自然遮挡星星；
#   原版星图随太阳旋转（昼夜系统）→ 本项目无时间/太阳概念，第 1 期静态。

# —— 参数表（全部集中在此调参，见规划文档 §4.2）——
const STAR_SHADER := preload("res://starfield.gdshader")
const DOME_RADIUS := 400.0  # 天球半径：最远视距 10 的 40 倍，远沉入 far(4000) 之内
const STAR_COUNT := 1500    # quad 数（= 原版 StarsCount；实际星点 ≈ 3×1500）
# quad 边长 / 天球半径。目标角尺寸：实体亮核 ≈ 1~3°（小点星到大星），据此反推：
# 实体对角 ≈ 0.39×quad 角尺寸（glyph 实体占贴图 ~20%）→ quad 取 4.6~11.5°。
# 首版的 0.10~0.38（照抄原版 1~3.8/10）会让实体亮核大到 4~10°，星星连成白雾。
const STAR_SIZE_MIN := 0.04
const STAR_SIZE_MAX := 0.22

# glyph 贴图参数（64×64，运行期生成；调“星多大/多尖/亮度”就改这里）
# —— 形态学（对照 RimWorld Stars.png 反推）：星星不是柔和的幂坡渐变，而是
#    「近乎不透明的实体星形 + 细窄抗锯齿边」。实体核心占比对应原文档
#    “521/4096 像素 alpha>250（12.7%）” 的量级；幂坡渐变会叠出棉团白雾（首版实测）。
const TEX_SIZE := 64
const GLYPH_RIM := 0.5   # AA 边带 / 半箭长：0.5 = 实体核只占菱形内半段（更小的亮斑）
const GLYPH_ARM_W := 0.12  # 十字臂宽 / 半箭长：细臂，构成 4 芒星的横向/纵向长芒
const GLYPH_ARM_LEN := 1.8  # 十字臂长 / 半箭长：臂探出菱形核，构成 ✦ 的尖芒
# 三颗星：中心(px)、半箭长 s（菱形核尖端到中心的像素距离；臂再向外探 1.8s）
const GLYPHS := [
	[Vector2(32, 32), 8.0],   # 中央大星
	[Vector2(47, 17), 3.5],   # 右上小星
	[Vector2(17, 47), 3.0],   # 左下小星
]

var star_seed := -1  # 当前星空种子；-1 = 尚未构建

var _material: ShaderMaterial
# 最近一次 build 的全部 instance transform（GDScript 侧拷贝）。
# 用途：① headless 冒烟可在 dummy 渲染器下做确定性对比（dummy 的 MultiMesh
# 读不回 transform，恒返回 zero，见 tools/test_starfield.gd）；② 排查星穹布局时直接看数。
var _built: Array[Transform3D] = []


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
		var basis := Basis(xr, yr, z_axis)
		# QuadMesh 边长 2 → 缩放 s 得边长 2s；求边长 = rel×半径，故 scale = rel×半径/2
		var edge := rng.randf_range(STAR_SIZE_MIN, STAR_SIZE_MAX) * DOME_RADIUS
		basis = basis.scaled(Vector3(edge * 0.5, edge * 0.5, edge * 0.5))
		_built.append(Transform3D(basis, dir * DOME_RADIUS))
	# 提交渲染：单 MultiMesh，1 个 draw call
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = QuadMesh.new()          # 默认 2×2 面向 +Z；朝向/尺寸全由 instance basis 决定
	mm.instance_count = STAR_COUNT
	for i in STAR_COUNT:
		mm.set_instance_transform(i, _built[i])
	multimesh = mm


# 冒烟/排查看数用：返回最近一次 build 的全部 transform 快照（深拷贝，
# 防止调用方拿到与内部 _built 同引用的数组——那样后续 build 会把旧快照一并清掉）
func snapshot_transforms() -> Array[Transform3D]:
	return _built.duplicate()


# 程序化烘焙 64×64 三颗四芒星 glyph：纯白 RGB，变化全在 alpha。
# 四芒星形 = 曼哈顿距离场（(|dx|+|dy|)/s）压到 0..1 后上幂 —— 菱形骨架自带轴向尖芒。
func _make_star_tex() -> ImageTexture:
	var img := Image.create_empty(TEX_SIZE, TEX_SIZE, false, Image.FORMAT_RGBA8)
	for y in TEX_SIZE:
		for x in TEX_SIZE:
			var a := 0.0
			for g in GLYPHS:
				a = maxf(a, _star_alpha(Vector2(x, y), g[0], g[1] as float))
			# 纯白 RGB + alpha 衰减：blend 出来只有形状亮度差，无色调污染
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))
	return ImageTexture.create_from_image(img)


# 单颗星 alpha：菱形核（✦ 的实体部分，全亮 + AA 边带）叠两条细十字臂（✚ 的长芒）。
# 两形取 max：中心是实体菱形，臂从核外探出 —— 标准四芒星剪影。
func _star_alpha(p: Vector2, c: Vector2, s: float) -> float:
	var dx := absf(p.x - c.x)
	var dy := absf(p.y - c.y)
	var d_mm: float = (dx + dy) / s
	var a_diamond := clampf((0.5 - d_mm) / GLYPH_RIM, 0.0, 1.0)
	var arm_len := s * GLYPH_ARM_LEN
	var w := s * GLYPH_ARM_W
	var a_cross_x := clampf(1.0 - dx / arm_len, 0.0, 1.0) * clampf(1.0 - dy / w, 0.0, 1.0)
	var a_cross_y := clampf(1.0 - dy / arm_len, 0.0, 1.0) * clampf(1.0 - dx / w, 0.0, 1.0)
	return maxf(a_diamond, maxf(a_cross_x, a_cross_y))
