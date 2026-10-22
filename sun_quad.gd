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

# —— 取景参数：太阳藏在镜头后面 ——
# 首屏（生成完成的第一帧）**看不到**太阳：玩家必须转动镜头到对应方向才能找到它。
# 理由：太阳是纯加法混合的强光源，开局就怼在画面里会晃眼、抢走
# 「星球才是主角」的注意力；藏起来则成了玩家主动探索才能发现的彩蛋。
#
# 基准 = 首屏视线的**正后方**（方位角 180°）→ 太阳整个在视锥之外，
# 连一丝光晕都漏不进画面。左右再加 ±22° 随机：不同世界的太阳藏在
# 不同侧后方，转镜头去找它的手感不一样。
const HIDE_AZIM := 180.0        # 基准方位角（相对首屏视线；180 = 正后方）
const AZIM_JITTER := 22.0       # ±22° 方位抖动
const ELEV_JITTER := 18.0       # ±18° 仰角抖动
# 种子异或常量："SUN1" → 独立随机流（不碰星球噪声/星穹的随机流）
const SEED_XOR := 0x53554e31
# 菜单相位（还没生成星球）的默认方向：相对默认镜头（前视 -Z）**正后方**偏 ~21°。
# 菜单本身是不透明全屏面板、玩家看不到天空，但保持「太阳不抢戏」的一致性，
# 且菜单相位的星空收缩区也跟着躲在背后。
const DEFAULT_DIRECTION := Vector3(0.30, 0.21, 0.93)

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


# 种子 → 太阳方向：**藏在首屏镜头后面**。
# view_fwd = 生成后首屏的视线方向（focus_on(_region_center) 之后，
# 视线 = -_region_center，见 planet.gd）。
# 方位角 180°±22°（= 视线的正后方）、仰角 ±18° → 太阳整个在视锥之外
# （实测夹角 140°~180°，而视锥半对角才 ~54°），首屏一帧不露；
# 玩家转动镜头到对应方向才会找到。
# 确定性：同一 seed 永远得到同一方向（独立随机流，不碰星球噪声）。
#
# ★ 关键几何（已实测）：太阳是**世界方向固定**的，而相机永远看向星球中心。
#   于是「太阳离视轴多远」只取决于玩家绕到哪一边：
#     · 相机在太阳这一侧 → 太阳在镜头背后（首屏状态，完全看不见）；
#     · 相机正对太阳   → 星球恰好挡在中间 → 全食，只见一圈日冕；
#     · 相机绕到侧后方 → 太阳偏出星球边缘，日面完整可见（就是「找到它」那一刻）。
#   「可见窗口」= 视线与太阳夹角 ∈ (星球角半径 ~29°, 视锥半角 ~54°)。
#   这与原版世界视图同构：太阳是远处的固定光源，绕轨过去才能看见它。
static func derive_direction(seed_value: int, view_fwd: Vector3) -> Vector3:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value ^ SEED_XOR
	var az := deg_to_rad(HIDE_AZIM + rng.randf_range(-AZIM_JITTER, AZIM_JITTER))
	var el := deg_to_rad(rng.randf_range(-ELEV_JITTER, ELEV_JITTER))
	var f := view_fwd.normalized()
	# 视线的「屏幕右 / 屏幕上」基（f 与竖直轴共线时换参考轴，避免退化）
	var up_ref := Vector3.UP if absf(f.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	var right := f.cross(up_ref).normalized()
	var up := right.cross(f).normalized()
	return (f * cos(el) * cos(az)
			+ right * cos(el) * sin(az)
			+ up * sin(el)).normalized()
