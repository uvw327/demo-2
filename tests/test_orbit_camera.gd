extends GutTest
# 轨道相机手感验收（GUT 版）：
# 1) 拖动 1:1——在近地 / 默认 / 拉远三档距离上，拖 N 像素，屏幕中心的地表点
#    就该移动 N 像素（旧版固定 0.005 弧度/像素时近地超调约 15 倍、拉远滞后约 4 倍，
#    近↔远相差约 60 倍，即“同样距离拖动、旋转幅度不一致”的根因）；
# 2) 死区不再丢位移——越线当帧补转“累计 − 阈值”的超出量；
# 3) 点按判定不受死区改动影响（< 阈值的拖动仍算点）；
# 4) 平滑收敛且松手即停（无惯性、无滑行）。
# 投影全部在测试里独立重算（手写球坐标→屏幕），不复用实现里的公式，避免“自证”。

const ORBIT := preload("res://orbit_camera.gd")

const CHECK_DISTS: Array[float] = [1.15, 2.05, 10.0]
const RADIUS := 1.0
# 用 20px 的小位移验 1:1：球面在超大位移下会向轮廓线饱和，那是几何必然，
# 不是灵敏度算错（那种场景不该拿线性标定去卡）。
const DRAG_PX := 20.0


func _make_orbit(dist: float) -> OrbitCamera:
	var orbit: OrbitCamera = add_child_autofree(ORBIT.new())
	orbit.planet_radius = RADIUS
	orbit.dist = dist
	# 镜头摆到 +Z（yaw=0、pitch=0）：画面中心的地表点就是 (0, 0, RADIUS)
	orbit.focus_on(Vector3(0.0, 0.0, 1.0))
	return orbit


# 独立重算的透视投影：按 look_at 约定重建相机基（right = fwd × UP），
# 再用与实现不同的方式推屏幕坐标。focal 取同一视口、同一 fov，口径与实现一致。
func _project(orbit: OrbitCamera, world_pos: Vector3) -> Vector2:
	var origin := orbit.cam.global_transform.origin
	var fwd := -orbit.cam.global_transform.basis.z
	var right := fwd.cross(Vector3.UP).normalized()
	var up := right.cross(fwd).normalized()
	var v := world_pos - origin
	var depth := v.dot(fwd)
	var vp := orbit.get_viewport().get_visible_rect().size
	var focal := 0.5 * vp.y / tan(deg_to_rad(orbit.cam.fov) * 0.5)
	return Vector2(
			vp.x * 0.5 + v.dot(right) / depth * focal,
			vp.y * 0.5 - v.dot(up) / depth * focal)


# 拖动增益必须 = 相机到地表深度 / 焦距（1:1 抓取模型的核心公式）
func test_drag_gain_is_surface_depth_over_focal() -> void:
	for d: float in CHECK_DISTS:
		var orbit := _make_orbit(d)
		var vp := orbit.get_viewport().get_visible_rect().size
		var focal := 0.5 * vp.y / tan(deg_to_rad(orbit.cam.fov) * 0.5)
		var depth: float = maxf(d - RADIUS, orbit.MIN_GRAB_DEPTH)
		assert_gt(focal, 0.0, "视口高度应有效（focal>0），实际 %s" % focal)
		assert_almost_eq(orbit._drag_gain(), depth / focal, 0.0000005,
				"dist=%s 的增益应为 depth/focal" % d)


# 三档距离各拖 20px：屏幕中心地表点的位移都应 ≈ 20px，且三档比值 ≈ 1
func test_horizontal_drag_is_one_to_one_at_all_distances() -> void:
	var moved: Array[float] = []
	for d: float in CHECK_DISTS:
		var orbit := _make_orbit(d)
		var before := _project(orbit, Vector3(0.0, 0.0, RADIUS))
		orbit._orbit_rotate(Vector2(DRAG_PX, 0.0))  # 直接入旋转层（死区单独测）
		await wait_seconds(0.7)  # 等平滑器（τ=0.05s）收敛并落位
		var after := _project(orbit, Vector3(0.0, 0.0, RADIUS))
		var got := absf(after.x - before.x)
		moved.append(got)
		assert_almost_eq(got, DRAG_PX, DRAG_PX * 0.15,
				"dist=%s 横拖 %s px，地表应移动 %s px，实际 %.2f px" % [d, DRAG_PX, DRAG_PX, got])
	var lo: float = float(moved.min())
	var hi: float = float(moved.max())
	assert_almost_eq(hi / lo, 1.0, 0.2,
			"三档距离的拖动位移应一致（旧版近↔远相差约 60 倍），实际比值 %.2f" % [hi / lo])


# 纵向拖动同样 1:1（方向：往下拖 = 地表跟着往下走）
func test_vertical_drag_is_one_to_one() -> void:
	var orbit := _make_orbit(2.05)
	var before := _project(orbit, Vector3(0.0, 0.0, RADIUS))
	orbit._orbit_rotate(Vector2(0.0, DRAG_PX))
	await wait_seconds(0.7)
	var after := _project(orbit, Vector3(0.0, 0.0, RADIUS))
	assert_almost_eq(after.y - before.y, DRAG_PX, DRAG_PX * 0.15,
			"纵拖 %s px，地表应向下移动 %s px，实际 %.2f px" % [DRAG_PX, DRAG_PX, after.y - before.y])


# 死区内不转；越线只补转“累计 − 阈值”；越线后整段位移照常生效
func test_dead_zone_credits_excess_instead_of_dropping_it() -> void:
	var orbit := _make_orbit(2.05)
	var gain := orbit._drag_gain()
	orbit._press_begin(Vector2.ZERO)
	orbit._rotate(Vector2(4.0, 0.0))   # 累计 4 ≤ 10
	orbit._rotate(Vector2(4.0, 0.0))   # 累计 8 ≤ 10
	assert_almost_eq(orbit._target_yaw, 0.0, 1e-9, "死区内不应旋转")
	orbit._rotate(Vector2(4.0, 0.0))   # 累计 12 > 10 → 只补转超出的 2px
	assert_almost_eq(orbit._target_yaw, -2.0 * gain, 1e-9,
			"越线当帧应补转 2px（死区位移不再被丢弃）")
	orbit._rotate(Vector2(4.0, 0.0))   # 累计 16 → 补转额度 6 > 本帧 4 → 整段生效
	assert_almost_eq(orbit._target_yaw, -6.0 * gain, 1e-9,
			"越线后整段位移照常生效")
	orbit._press_end(Vector2.ZERO)


# 小于点按阈值的拖动：不转，但点按照常上报（点选链路不能被死区改动打断）
func test_small_drag_still_counts_as_tap() -> void:
	var orbit := _make_orbit(2.05)
	watch_signals(orbit)
	orbit._press_begin(Vector2(500.0, 300.0))
	orbit._rotate(Vector2(5.0, 0.0))   # 5px < CLICK_MAX_DRAG_PX(10)
	orbit._press_end(Vector2(500.0, 300.0))
	assert_almost_eq(orbit._target_yaw, 0.0, 1e-9, "5px 拖动不应旋转")
	assert_signal_emitted_with_parameters(orbit, "view_tapped", [Vector2(500.0, 300.0)])


# 超过点按阈值的拖动不再算点按（不会误触贴片选择）
func test_large_drag_does_not_emit_tap() -> void:
	var orbit := _make_orbit(2.05)
	watch_signals(orbit)
	orbit._press_begin(Vector2(500.0, 300.0))
	orbit._rotate(Vector2(6.0, 0.0))
	orbit._rotate(Vector2(6.0, 0.0))   # 累计 12 > 10 → 取消点按资格
	orbit._press_end(Vector2(500.0, 300.0))
	assert_signal_not_emitted(orbit, "view_tapped")


# 平滑器：输入只写目标角，实际角随帧收敛；收敛后彻底静止（松手即停，无惯性）
func test_smoothing_converges_then_stops_dead() -> void:
	var orbit := _make_orbit(2.05)
	orbit._orbit_rotate(Vector2(30.0, 10.0))
	assert_almost_eq(orbit.yaw, 0.0, 1e-9, "输入当帧尚未平滑，实际角应保持原值")
	assert_true(absf(orbit._target_yaw - orbit.yaw) > 1e-6, "输入应写进目标角")
	await wait_seconds(0.7)   # τ=0.05s → 0.7s ≈ 14τ，必然收敛并落位
	assert_almost_eq(orbit.yaw, orbit._target_yaw, 1e-6, "平滑应收敛到目标角")
	assert_almost_eq(orbit.pitch, orbit._target_pitch, 1e-6, "俯仰平滑应收敛到目标角")
	var settled: float = orbit.yaw
	await wait_seconds(0.3)
	assert_almost_eq(orbit.yaw, settled, 1e-9, "松手后不得继续转动（无惯性、无滑行）")


# 俯仰上限回归：再怎么往下拖也不会越过 ±1.5（look_at 的 UP 参考会失效）
func test_pitch_is_clamped() -> void:
	var orbit := _make_orbit(2.05)
	orbit._press_begin(Vector2.ZERO)
	for i: int in 40:
		orbit._rotate(Vector2(0.0, 50.0))
	assert_almost_eq(orbit._target_pitch, 1.5, 1e-9, "俯仰上限应 clamp 到 1.5")
	orbit._press_end(Vector2.ZERO)
