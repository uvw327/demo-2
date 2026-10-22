class_name SunQuad
extends MeshInstance3D
# 太阳：相机相对的加法 quad（RimWorld WorldLayer_Sun / Custom_Sun 的 Godot 对应形，
# 规划见 docs/sun_plan.md）。
#
# 做法与原版同构（三件事）：
#   ① 一个 quad，平面 ⟂ 太阳方向，中心恒在「相机位置 + 方向 × SUN_DIST」——
#      于是屏幕角尺寸恒定、永远正对相机（视线与 quad 法线重合，不透视变形），
#      且贴着相机走 → 没有视差，像钉在天上。
#      （原版是顶点着色器加 _WorldSpaceCameraPos + 图层级 LookRotation(sunPos)，
#      这里等价改成 CPU 每帧一次位置赋值，与 star_dome 的做法同款。）
#   ② 材质是**零贴图**的加法 shader（sun.gdshader）：白色核心 + 暖黄光晕全是
#      片元着色器按 UV 算出来的。原版世界太阳同样没有贴图（参考文档 §0/§4.6）。
#   ③ 深度测试保留、深度写入关闭：星球按深度自然遮住太阳。原版靠「双相机
#      合成」达成同一效果（ZTest Off + 天空相机先行），本项目单相机更省。
#
# 与原版的差异：原版太阳方向随游戏时间变化（昼夜），本项目无时间系统，
# 方向由 planet.gd 的单一数据源（种子派生）写入，局内恒定。
#
# 依赖风格：本脚本刻意**不写 class_name**（与 star_atlas.gd 同款）——
# 引用方一律 preload 脚本常量，这样 headless 冒烟与 CI 不依赖编辑器的
# 全局类名注册缓存（.godot/global_script_class_cache.cfg）。

const SUN_SHADER := preload("res://sun.gdshader")

# —— 参数表（全部集中在此调参，见规划文档 §4.2）——
# 相机前方距离：必须大于「最远视距(10) + 星球半径(1)」= 11，
# 否则太阳所在的平面会插进星球内部、被星球整个吃掉。取 15：稳稳在星球之外
# （最坏情况——太阳背着星球、镜头拉远到 10——平面离球心仍有 5 个单位），
# 又远小于远平面 4000（星穹在 400，更远）。
const SUN_DIST := 15.0
# quad 边长 / 相机前方距离 = 角尺寸（弧度量级）。
# 原版 15/10 = 1.5（配 60° 垂直 FOV 的天空相机，光晕铺满全屏）。
# 本项目星球在默认距离 2.05 下就占屏高 58.4°，1.5 太压画面 → 收到 0.8：
# 可见柔光直径约 44°、白色亮核约 12°，既够醒目又不会盖住半个天空。
const SUN_SIZE_RATIO := 0.8
const SUN_QUAD_SIZE := SUN_DIST * SUN_SIZE_RATIO
# 透明绘制顺序：原版靠材质队列（太阳 1001 > 星空 1000）让光晕叠在星点之上。
# Godot 靠距离排序做不到（星穹节点原点贴着相机，会被排到最后）→
# 用 render_priority 显式压住星穹。数值越大越晚绘制（= 越靠上）。
const SUN_RENDER_PRIORITY := 10

# —— 取景参数：太阳相对「首屏视线」的偏角 ——
# 方位角：±33°~45°（左右由种子随机）。下限必须大于星球圆面的视角半径
# （默认距离 2.05 下约 29°），否则白色亮核会被星球整个挡住；上限受
# 16:9 水平半视场（约 54°）约束，再远就出画。
const AZIM_MIN := 33.0
const AZIM_MAX := 45.0
# 仰角：8°~22°——把太阳抬到画面上方，别贴着星球轮廓。
const ELEV_MIN := 8.0
const ELEV_MAX := 22.0
# 种子异或常量："SUN1" → 独立随机流（不碰星球噪声/星穹的随机流）
const SEED_XOR := 0x53554e31
# 菜单相位（还没生成星球）的默认方向：相对默认镜头（前视 -Z）右偏 40°、上抬 15°。
# 也就是「菜单背后那片天空里有一颗太阳」，生成世界后再按种子换成新方向。
const DEFAULT_DIRECTION := Vector3(0.621, 0.259, -0.740)

# —— 期 2：光晕圆盘内的星星缩小（原版 WorldLayer_Stars.cs:63-68）——
# 原版判据：dot(starDir, sunDir) > 0.8 → size *= LerpDouble(0.8,1,1,0.35,dot)
# 那个 0.8 **不是魔数**：它恰好等于原版太阳「光晕可见圆盘」的边缘 ——
# 方片半宽 7.5 @ 距离 10 → atan(7.5/10) = 36.87° → cos = 0.8。
# 语义是「落在光晕里的星星缩小」（被光晕淹没 → 缩小以免抢戏）。
#
# 我们的光晕比原版小（比例 0.8 而非 1.5 → 半宽 6 @ 距离 15 → 21.8°，
# cos ≈ 0.928），所以**不能照抄 0.8**：那会让光晕外一圈星星无故变小。
# 阈值必须由我们自己的光晕几何导出 —— 见 glow_disc_cos()。
const STAR_SHRINK_MIN := 0.35  # 正对太阳时缩到原尺寸的 0.35 倍（原版常量）


# 太阳「光晕可见圆盘」的边缘余弦 —— 判据的**唯一来源**。
# 光晕亮度包络 a = max(0, 1-2d) 在 UV 半径 0.5 处归零，即方片半宽处；
# 该半径相对相机的张角 = atan(半宽 / 距离)，故 cos 即阈值。
# 改 SUN_SIZE_RATIO / SUN_DIST 时阈值自动跟着走（缩星范围永远等于光晕范围）。
static func glow_disc_cos() -> float:
	return cos(atan((SUN_QUAD_SIZE * 0.5) / SUN_DIST))


# 缩星系数：与原版 LerpDouble(0.8, 1, 1, 0.35, dot) 同构，
# 只是把硬编码的 0.8 换成我们自己的光晕边缘 cos。
# dot ≤ 阈值 → 1.0（不缩）；dot = 1（正对太阳）→ 0.35。
static func star_shrink_factor(dot_value: float) -> float:
	var edge := glow_disc_cos()
	if dot_value <= edge:
		return 1.0
	# t: 0（在光晕边缘）→ 1（正对太阳）
	var t := (dot_value - edge) / (1.0 - edge)
	return 1.0 + (STAR_SHRINK_MIN - 1.0) * t

# 太阳方向（世界空间单位向量，指向太阳）。由 planet.gd 的单一数据源写入。
var direction := DEFAULT_DIRECTION

var _material: ShaderMaterial


func _ready() -> void:
	_ensure_mesh()
	_apply_basis()


# 网格与材质惰性装配（_ready 在 --script 测试环境里触发时机不可靠，
# 与 star_dome 的 _ensure_* 同风格）
func _ensure_mesh() -> void:
	if mesh != null:
		return
	var quad := QuadMesh.new()
	quad.size = Vector2(SUN_QUAD_SIZE, SUN_QUAD_SIZE)
	mesh = quad
	_material = ShaderMaterial.new()
	_material.shader = SUN_SHADER
	_material.render_priority = SUN_RENDER_PRIORITY
	material_override = _material


# 设置太阳方向（世界空间）。方向变了才需要重算 quad 的朝向，
# 之后每帧只改位置。
func set_direction(dir: Vector3) -> void:
	if dir.length_squared() < 1e-9:
		return
	direction = dir.normalized()
	_apply_basis()


# quad 的平面 ⟂ 太阳方向：法线 = direction，相机正好在这条法线上看它，
# 于是永远是正面圆盘。用切平面正交基构造（与 star_dome 同款），
# 并对「方向接近竖直轴」做退化保护。
func _apply_basis() -> void:
	var z_axis := direction
	var helper := Vector3.UP if absf(direction.y) < 0.9 else Vector3.RIGHT
	var x_axis := (helper - direction * helper.dot(direction)).normalized()
	var y_axis := z_axis.cross(x_axis)
	global_basis = Basis(x_axis, y_axis, z_axis)


# 每帧把太阳贴到相机前方 SUN_DIST 处（相机相对 → 角尺寸恒定、无视差）。
# 成本：一次 transform 赋值；网格从不因相机动而重建。
func _process(_delta: float) -> void:
	var vp := get_viewport()
	if vp == null:
		return
	var cam := vp.get_camera_3d()
	if cam != null:
		follow(cam.global_position)


# 贴到给定相机位置前方（与 _process 共用；测试直接调它，不依赖视口）。
func follow(cam_pos: Vector3) -> void:
	global_position = cam_pos + direction * SUN_DIST


# 种子 → 太阳方向：落在「首屏视线」旁的取景里。
# view_fwd = 生成后镜头的视线方向（focus_on(_region_center) 之后，
# 视线 = -_region_center，见 planet.gd）。
# 确定性：同一 seed 永远得到同一方向（独立随机流，不碰星球噪声）。
static func derive_direction(seed_value: int, view_fwd: Vector3) -> Vector3:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value ^ SEED_XOR
	var az := rng.randf_range(AZIM_MIN, AZIM_MAX)
	if rng.randf() < 0.5:
		az = -az
	var el := rng.randf_range(ELEV_MIN, ELEV_MAX)
	var f := view_fwd.normalized()
	# 视线的「屏幕右 / 屏幕上」基（f 与竖直轴共线时换参考轴，避免退化）
	var up_ref := Vector3.UP if absf(f.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	var right := f.cross(up_ref).normalized()
	var up := right.cross(f).normalized()
	var az_r := deg_to_rad(az)
	var el_r := deg_to_rad(el)
	return (f * cos(el_r) * cos(az_r)
			+ right * cos(el_r) * sin(az_r)
			+ up * sin(el_r)).normalized()
