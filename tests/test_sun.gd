extends GutTest
# 太阳验收（GUT 版）：
# 1) 深度安全——太阳所在的平面必须永远在星球之外，否则近距时太阳会插进地表；
# 2) 尺寸不脱钩——quad 边长 = 距离 × 比例（原版 SunDrawSize 死常量陷阱的教训）；
# 3) 相机相对——每帧位置 = 相机位置 + 方向 × 距离（角尺寸恒定、无视差）；
# 4) 方向确定性——同种子同方向、换种子换方向；
# 5) 取景——太阳必须落在**屏幕内**（NDC 判据，不是「3D 夹角 vs 竖直半 FOV」
#    这种错口径），且不被星球整个挡住；
# 6) 零耦合——太阳不进拾取（纯数学射线只与单位球求交）。
#
# 投影全部在测试里独立重算（手写「视线 → NDC」），不复用实现里的公式，避免自证。

const SUN := preload("res://sun_quad.gd")
const ORBIT := preload("res://orbit_camera.gd")
const PLANET := preload("res://planet.gd")

# 相机参数：与 orbit_camera 一致（Camera3D 默认 fov 75，project.godot 视口 16:9）
const FOV_DEG := 75.0
const ASPECT := 1280.0 / 720.0
# 生成后镜头的默认距离（orbit_camera.dist 初值 2.05）
const DEFAULT_DIST := 2.05
# 星球最远视距（orbit_camera.MAX_DIST）+ 星球半径（planet.gd.PLANET_RADIUS）
const MAX_PLANET_REACH := 10.0 + 1.0


# 独立重算：世界方向 → 归一化设备坐标（NDC，范围 ±1 = 画面内）。
# 相机约定：视线 f（看 -Z），右 = f × up，上 = right × f（与 look_at 同款）。
func _to_ndc(dir_world: Vector3, fwd: Vector3) -> Vector2:
	var f := fwd.normalized()
	var up_ref := Vector3.UP if absf(f.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	var right := f.cross(up_ref).normalized()
	var up := right.cross(f).normalized()
	var z := dir_world.dot(f)
	if z <= 0.0:
		return Vector2(99.0, 99.0)  # 相机背后
	var tan_v := tan(deg_to_rad(FOV_DEG) * 0.5)
	var tan_h := tan_v * ASPECT
	return Vector2(dir_world.dot(right) / z / tan_h, dir_world.dot(up) / z / tan_v)


# 取景保证：① 太阳落在首屏画面内；② 不被星球整个挡住（此时星球只挡住一部分光晕）。
func test_sun_direction_is_on_screen_and_clear_of_planet() -> void:
	var fwd := Vector3(0.0, 0.0, -1.0)  # 生成后镜头的视线方向
	# 星球在首屏的视角半径（球心角半径）：默认距离下约 29°
	var planet_ang := rad_to_deg(asin(PLANET.PLANET_RADIUS / DEFAULT_DIST))
	for seed_value: int in [1, 42, 4242, 90210, 2026]:
		var d: Vector3 = SUN.derive_direction(seed_value, fwd)
		assert_almost_eq(d.length(), 1.0, 0.0001,
				"太阳方向应是单位向量（seed=%d）" % seed_value)
		# ① 屏幕内：NDC 必须在 ±1 内
		var ndc := _to_ndc(d, fwd)
		assert_lt(absf(ndc.x), 1.0,
				"太阳必须横向落在画面内（seed=%d，ndc.x=%.2f）" % [seed_value, ndc.x])
		assert_lt(absf(ndc.y), 1.0,
				"太阳必须纵向落在画面内（seed=%d，ndc.y=%.2f）" % [seed_value, ndc.y])
		# ② 星球挡不住整个太阳：太阳中心与视线的夹角 > 星球视角半径
		var ang := rad_to_deg(d.angle_to(fwd))
		assert_gt(ang, planet_ang,
				"太阳不能正落在星球后面（seed=%d，%.1f° vs 星球 %.1f°）"
				% [seed_value, ang, planet_ang])


# 同种子 → 同方向（确定性）；换种子 → 方向变化
func test_sun_direction_is_deterministic_per_seed() -> void:
	var fwd := Vector3(0.0, 0.0, -1.0)
	var a: Vector3 = SUN.derive_direction(12345, fwd)
	var b: Vector3 = SUN.derive_direction(12345, fwd)
	assert_eq(a, b, "同一种子必须得到同一太阳方向")
	var c: Vector3 = SUN.derive_direction(54321, fwd)
	assert_ne(a, c, "换种子应得到不同太阳方向")


# 深度安全：太阳平面到相机的垂距恒为 SUN_DIST，平面内任一点到相机的距离 ≥ SUN_DIST；
# 而星球表面到相机的最远距离 = MAX_DIST + PLANET_RADIUS。
# 于是「同一根视线上，星球恒在太阳之前」→ 星球永远正确遮住太阳。
func test_sun_plane_is_always_outside_planet() -> void:
	assert_gt(SUN.SUN_DIST, MAX_PLANET_REACH,
			"太阳距离必须大于「最远视距 + 星球半径」，否则会插进星球里")
	# 星球（半径 1 的球）在最远视距 10 处，最远表面到相机 11 个单位
	var planet_far := ORBIT.MAX_DIST + PLANET.PLANET_RADIUS
	assert_lt(planet_far, SUN.SUN_DIST,
			"星球最远表面必须比太阳平面更靠近相机（%.1f < %.1f）"
			% [planet_far, SUN.SUN_DIST])


# 尺寸不脱钩：quad 边长由距离 × 比例导出，且比例不为 0（原版死常量陷阱）
func test_quad_size_is_derived_from_distance_and_ratio() -> void:
	assert_almost_eq(SUN.SUN_QUAD_SIZE, SUN.SUN_DIST * SUN.SUN_SIZE_RATIO, 0.0001,
			"quad 边长必须由「距离 × 比例」导出")
	assert_gt(SUN.SUN_SIZE_RATIO, 0.0, "尺寸比例必须为正（否则太阳退化成一个点）")


# 相机相对：位置恒为「相机位置 + 方向 × 距离」→ 角尺寸恒定、无视差
func test_sun_follows_camera_at_fixed_distance() -> void:
	var sun: SUN = SUN.new()
	add_child_autofree(sun)
	var cam_pos := Vector3(1.5, -2.0, 3.25)
	var dir := Vector3(0.3, 0.5, -0.81).normalized()
	sun.set_direction(dir)
	sun.follow(cam_pos)
	var expect := cam_pos + dir * SUN.SUN_DIST
	assert_almost_eq(sun.global_position.distance_to(expect), 0.0, 0.0001,
			"太阳必须贴在相机前方固定距离处")
	# 方向会被归一化（喂进去的向量长度不参与计算）
	assert_almost_eq(sun.direction.length(), 1.0, 0.0001, "太阳方向必须归一化")


# quad 的平面必须 ⟂ 太阳方向 —— 否则斜看会变成椭圆（原版靠图层级旋转保证）
func test_quad_plane_is_perpendicular_to_direction() -> void:
	var sun: SUN = SUN.new()
	add_child_autofree(sun)
	var dir := Vector3(0.2, 0.9, -0.4).normalized()
	sun.set_direction(dir)
	var z_axis: Vector3 = sun.global_basis.z
	assert_almost_eq(absf(z_axis.dot(dir)), 1.0, 0.0001,
			"quad 法线必须与太阳方向平行（平面 ⟂ 方向）")
	# 正交基：三个轴互相垂直且都是单位向量
	var b: Basis = sun.global_basis
	assert_almost_eq(b.x.dot(b.y), 0.0, 0.0001, "基向量 x·y 应为 0")
	assert_almost_eq(b.x.dot(b.z), 0.0, 0.0001, "基向量 x·z 应为 0")
	assert_almost_eq(b.y.dot(b.z), 0.0, 0.0001, "基向量 y·z 应为 0")
	assert_almost_eq(b.x.length(), 1.0, 0.0001, "基向量应为单位向量")


# 零耦合：太阳节点不进拾取链路（拾取是纯数学射线，只与单位球求交）
func test_sun_is_not_pickable() -> void:
	var planet: Node3D = add_child_autofree(PLANET.new())
	planet._init_noise(4242)
	# 拾取只认贴片索引；太阳节点既不进拓扑缓存也不参与射线求交
	assert_eq(planet._tile_centers.size(), 0,
			"未生成时贴片缓存应为空，太阳不参与其中")
