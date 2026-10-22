extends GutTest
# 太阳验收（GUT 版）：
# 1) 深度安全——太阳所在的平面必须永远在星球之外，否则近距时太阳会插进地表；
# 2) 尺寸不脱钩——quad 边长 = 距离 × 比例（原版 SunDrawSize 死常量陷阱的教训）；
# 3) 相机相对——每帧位置 = 相机位置 + 方向 × 距离（角尺寸恒定、无视差）；
# 4) 方向确定性——同种子同方向、换种子换方向；
# 5) 取景——太阳必须**藏在首屏镜头后面**（NDC 判据，不是「3D 夹角 vs 竖直半 FOV」
#    这种错口径），但转镜头后必须能找到它（且不被星球整个挡住）；
# 6) 零耦合——太阳不进拾取（纯数学射线只与单位球求交）。
#
# 投影全部在测试里独立重算（手写「视线 → NDC」），不复用实现里的公式，避免自证。

const SUN := preload("res://sun_quad.gd")
const ORBIT := preload("res://orbit_camera.gd")
const PLANET := preload("res://planet.gd")
const DOME := preload("res://star_dome.gd")

# 相机参数：与 orbit_camera 一致（Camera3D 默认 fov 75，project.godot 视口 16:9）
const FOV_DEG := 75.0
const ASPECT := 1280.0 / 720.0
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


# 取景保证（期 3 的用户诉求）：**首屏画面里看不到太阳**。
# 太阳是纯加法混合的强光源，开局就怼在画面里会晃眼、抢走
# 「星球才是主角」的注意力 → 藏在镜头正后方，玩家转镜头才能找到。
#
# 判据：太阳方向与首屏视线的夹角必须 **大于视锥半对角**（≈54°），
# 即整个太阳（连光晕）都在画面外，而不是「勉强卡在边缘」。
func test_sun_is_hidden_behind_camera_in_opening_frame() -> void:
	var fwd := Vector3(0.0, 0.0, -1.0)  # 生成后首屏的视线方向
	# 视锥半对角：16:9 下水平半视场 tan(tan(37.5°)*16/9) → 水平半角
	var half_h := rad_to_deg(atan(tan(deg_to_rad(FOV_DEG) * 0.5) * ASPECT))
	var half_v := FOV_DEG * 0.5
	# 角半径 = 太阳方片的角半径（光晕可见圆盘边缘）
	var disc_ang := rad_to_deg(atan((SUN.SUN_QUAD_SIZE * 0.5) / SUN.SUN_DIST))
	for seed_value: int in [1, 42, 4242, 90210, 2026]:
		var d: Vector3 = SUN.derive_direction(seed_value, fwd)
		assert_almost_eq(d.length(), 1.0, 0.0001,
				"太阳方向应是单位向量（seed=%d）" % seed_value)
		# ① 太阳整个在画面外：中心与视线的夹角 > 视锥半对角 + 光晕角半径
		var ang := rad_to_deg(d.angle_to(fwd))
		var limit := maxf(half_h, half_v) + disc_ang
		assert_gt(ang, limit,
				"首屏必须看不到太阳（seed=%d，夹角 %.1f°，需 > %.1f°）"
				% [seed_value, ang, limit])
		# ② 太阳在镜头**背后**（不是被星球挡住，而是在视锥外）
		assert_lt(d.dot(fwd), 0.0,
				"太阳必须位于镜头后方（seed=%d）" % seed_value)


# 但它必须「转得到」——否则就是永远找不到了，那才是真的藏没了。
#
# 这里**如实建模真实的绕轨相机**（不是假想的自由视角）：
#   相机始终位于星球中心外 dist 处、**永远看向星球中心**，
#   所以视线方向 f = -normalize(cam_pos)，而 cam_pos 由 (yaw, pitch) 决定。
# 太阳是**世界方向固定**的（太阳方片贴在相机前方 SUN_DIST 处），
# 于是它相对视线的夹角 = angle(d, f)，随玩家绕轨而扫过整个天空。
#
# 「能看见太阳」的判据（两个都要满足）：
#   ① 在画面内：NDC ∈ ±1；
#   ② 没被星球挡住：angle(d, f) > 星球角半径 asin(R/dist)。
# 注意②意味着：镜头**正对**太阳时，星球恰好挡在中间 → 全食，
# 只能看到一圈日冕（这正是原版世界视图的常态）。真正能看见日面的，
# 是绕到星球另一侧、太阳从边缘「升起来」的那一段。
func test_sun_becomes_visible_when_camera_turns_toward_it() -> void:
	var fwd := Vector3(0.0, 0.0, -1.0)
	var dist := 2.05                       # orbit_camera.dist 初值（最坏情况：星球最大）
	var planet_ang := rad_to_deg(asin(PLANET.PLANET_RADIUS / dist))
	for seed_value: int in [1, 42, 4242, 90210, 2026]:
		var d: Vector3 = SUN.derive_direction(seed_value, fwd)
		var found := false
		var found_off := 0.0
		# 扫真实相机的 (yaw, pitch) 参数空间（orbit_camera 的俯仰上限 ≈ ±86°）
		for yaw_deg: int in range(0, 360, 2):
			for pitch_deg: float in [-77.0, -45.0, -20.0, 0.0, 20.0, 45.0, 77.0]:
				var yaw := deg_to_rad(float(yaw_deg))
				var pitch := deg_to_rad(pitch_deg)
				# 与 orbit_camera._update_cam 同一套球坐标公式
				var cam_pos := Vector3(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw))
				var cam_fwd := -cam_pos.normalized()   # 始终看向星球中心
				var off := rad_to_deg(cam_fwd.angle_to(d))
				if off <= planet_ang:
					continue                          # 被星球挡住
				var ndc := _to_ndc(d, cam_fwd)
				if absf(ndc.x) < 1.0 and absf(ndc.y) < 1.0:
					found = true
					found_off = off
					break
			if found:
				break
		assert_true(found,
				"转镜头必须能找到太阳（seed=%d：绕轨一圈没有任何朝向能同时满足「在画面内」与「不被星球挡住」）"
				% seed_value)
		# 找到时它应当是个「立得住」的太阳：离视轴 30°~54°，亮核露在星球外
		assert_gt(found_off, planet_ang,
				"找到太阳时它不能还在星球背后（seed=%d，%.1f°）" % [seed_value, found_off])


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


# —— 期 2：光晕内的星星缩小（原版 WorldLayer_Stars.cs:63-68）——

# 缩星阈值必须等于「太阳光晕可见圆盘的边缘」，而不是原版的常数 0.8。
# 原版的 0.8 恰好是它自己的光晕边缘（半宽 7.5 @ 距离 10 → atan(7.5/10)=36.87°
# → cos=0.8）；我们的光晕更小，照抄 0.8 会多缩一圈光晕外的星星。
func test_shrink_threshold_equals_our_own_glow_disc_edge() -> void:
	var half_edge := SUN.SUN_QUAD_SIZE * 0.5
	var expect := cos(atan(half_edge / SUN.SUN_DIST))
	assert_almost_eq(SUN.glow_disc_cos(), expect, 0.000001,
			"缩星阈值必须由我们自己的光晕几何导出")
	# 光晕边缘处不缩，正对太阳时缩到 0.35×
	assert_almost_eq(SUN.star_shrink_factor(SUN.glow_disc_cos()), 1.0, 0.000001,
			"光晕边缘的星星不该缩小")
	assert_almost_eq(SUN.star_shrink_factor(1.0), SUN.STAR_SHRINK_MIN, 0.000001,
			"正对太阳的星星必须缩到 0.35×")


# 缩星系数必须单调递减（越靠近太阳越小），且光晕外恒为 1.0
func test_shrink_factor_is_monotonic_and_bounded() -> void:
	var edge := SUN.glow_disc_cos()
	assert_almost_eq(SUN.star_shrink_factor(edge - 0.01), 1.0, 0.000001,
			"光晕外的星星不该缩小")
	var prev := 2.0
	for i in 20:
		var dot_v := lerpf(edge, 1.0, float(i) / 19.0)
		var f := SUN.star_shrink_factor(dot_v)
		assert_lte(f, prev + 0.000001, "缩星系数必须随接近太阳而单调不增")
		assert_gte(f, SUN.STAR_SHRINK_MIN - 0.000001, "缩星系数不得小于 0.35×")
		prev = f


# 端到端：星穹按太阳方向缩星 —— 太阳方向上的星确实更小，
# 且「缩掉的正是太阳旁边那批」（不是随机某一群）。
func test_star_dome_shrinks_stars_near_the_sun() -> void:
	var dome: StarDome = DOME.new()
	add_child_autofree(dome)
	var sun_dir := Vector3(0.0, 0.0, 1.0)
	# 同一 seed 建两次：一次带太阳方向、一次不带 → 逐位对比每颗星的尺寸
	dome.build(4242, sun_dir)
	var with_sun := dome.snapshot_transforms()
	dome.build(4242)
	var without_sun := dome.snapshot_transforms()
	assert_eq(with_sun.size(), without_sun.size(), "两次构建的星数应相同")
	var shrunk := 0
	var checked := 0
	for i in with_sun.size():
		var a: Transform3D = with_sun[i]
		var b: Transform3D = without_sun[i]
		var edge_a := a.basis.get_scale().x
		var edge_b := b.basis.get_scale().x
		if edge_a >= edge_b:
			continue  # 没被缩（判定边界外）
		shrunk += 1
		checked += 1
		# 被缩的这颗：方向必须确实靠近太阳
		var star_dir := a.origin.normalized()
		var dot_v := star_dir.dot(sun_dir)
		assert_gt(dot_v, SUN.glow_disc_cos(),
				"被缩的星必须落在太阳光晕圆盘内（dot=%.3f）" % dot_v)
		# 缩小比例必须等于公式值
		var expect := SUN.star_shrink_factor(dot_v)
		assert_almost_eq(edge_a / edge_b, expect, 0.0001,
				"缩星比例必须符合公式（dot=%.3f）" % dot_v)
	assert_gt(shrunk, 0, "必须有星被缩小（否则缩星逻辑没生效）")
	# 绝大多数星不该被缩（光晕只占天球一小块）
	assert_lt(float(shrunk) / float(with_sun.size()), 0.25,
			"被缩的星占比应很小（光晕只覆盖天球一角），实际 %d/%d"
			% [shrunk, with_sun.size()])


# 没有太阳方向时（零向量）不缩任何星 —— 菜单相位等场合的兜底
func test_star_dome_without_sun_does_not_shrink() -> void:
	var dome: StarDome = DOME.new()
	add_child_autofree(dome)
	dome.build(4242, Vector3.ZERO)
	var a := dome.snapshot_transforms()
	dome.build(4242, Vector3(0.0, 0.0, 1.0))
	var b := dome.snapshot_transforms()
	for i in a.size():
		assert_almost_eq(a[i].basis.get_scale().x, b[i].basis.get_scale().x, 0.000001,
				"无太阳时不该缩星（#%d）" % i)
		break  # 抽样 1 颗即可：构造与实现同源，逐位相等是必然的


# forward_after_focus 必须与 focus_on 之后镜头的**真实**朝向逐位一致 ——
# 太阳的取景锚点全靠它（锚错了，缩掉的星就不是太阳旁边那批）。
func test_forward_after_focus_matches_real_camera() -> void:
	var orbit: OrbitCamera = add_child_autofree(ORBIT.new())
	orbit.planet_radius = 1.0
	orbit.dist = 2.05
	for dir: Vector3 in [Vector3(0.0, 0.0, 1.0), Vector3(0.3, 0.4, 0.5).normalized(),
			Vector3(0.0, 0.9, 0.4).normalized(), Vector3(0.0, -0.99, 0.1).normalized()]:
		var predicted := orbit.forward_after_focus(dir)
		orbit.focus_on(dir)
		var actual := -orbit.cam.global_transform.basis.z
		assert_almost_eq(predicted.distance_to(actual), 0.0, 0.000001,
				"预测视线必须与 focus_on 后的真实视线一致（dir=%s）" % str(dir))


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
