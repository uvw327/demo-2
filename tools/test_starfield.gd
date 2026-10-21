# 星空回归护栏（headless 冒烟）：构建/数量/确定性/种子切换/方向分布/贴图加载/相机跟随。
# 运行：godot --headless --path . --script res://tools/test_starfield.gd
# 对应规划文档 docs/starfield_plan.md §7 的验收标准 1/2（可自动化的部分）。
extends SceneTree

var _dome: StarDome    # 相机跟随断言用的星穹引用（随 --initialize 装配，帧回调里核对）
var _cam: Camera3D
var _follow_frames := 0  # 跟随断言的帧计数：第 2 帧（dome._process 已跑过一拍）才判


func _initialize() -> void:
	var dome: StarDome = load("res://star_dome.gd").new()
	root.add_child(dome)
	# 材质在 build() 惰性装配（--script 环境下 _ready 时机不可靠），先构建再断言
	dome.build(4242)
	if dome.material_override == null or dome.material_override.get_shader_parameter("star_tex") == null:
		print("FAIL: 星穹材质/程序化贴图未就绪")
		quit(1)
		return
	print("PASS: 星穹材质与程序化贴图就绪")

	# 1) 构建 + 数量
	dome.build(4242)
	if dome.multimesh == null or dome.multimesh.instance_count != StarDome.STAR_COUNT:
		print("FAIL: 构建异常 count=", dome.multimesh.instance_count if dome.multimesh else -1)
		quit(1)
		return
	print("PASS: 构建成功，instance_count=", dome.multimesh.instance_count)

	# 2) 确定性：同 seed 两次 build 逐位一致
	var snap_a := _snapshot(dome)
	dome.build(4242)
	var snap_b := _snapshot(dome)
	if _snap_diff(snap_a, snap_b) >= 0:
		print("FAIL: 同种子两次构建不一致，首个差异在 #", _snap_diff(snap_a, snap_b))
		quit(1)
		return
	print("PASS: 同种子确定性逐位一致（", snap_a.size(), " 个 transform）")

	# 3) 种子切换：换了 seed 必须变布局
	dome.build(777)
	var snap_c := _snapshot(dome)
	if _snap_diff(snap_a, snap_c) < 0:
		# 全部相同 = 没变 = 异常
		print("FAIL: 换种子后星穹布局完全没变")
		quit(1)
		return
	print("PASS: 换种子布局变化（首个差异在 #", _snap_diff(snap_a, snap_c), "）")

	# 3.5) 亮度/色温随机性：instance color 必须真的写进 MultiMesh，
	# 且分布符合「九成暗星（灰 0.2~0.6）、一成亮星（灰 0.8~1.0）」。
	# 这条是「星空不再一片死白」的核心护栏：use_colors 没开 / 颜色没写进去
	# 都会让所有星星同亮，回归时肉眼极难发现，必须有自动断言兜住。
	var colors := dome.snapshot_colors()
	var dim := 0
	var bright := 0
	for c in colors:
		var lum := (c.r + c.g + c.b) / 3.0
		if lum <= StarDome.DIM_GRAY_MAX + 0.001:
			dim += 1
		elif lum >= StarDome.BRIGHT_GRAY_MIN - 0.001:
			bright += 1
	var total := colors.size()
	var dim_ratio := float(dim) / float(total)
	if not dome.multimesh.use_colors:
		print("FAIL: MultiMesh.use_colors 未开启 —— instance color 不会生效")
		quit(1)
		return
	if dim_ratio < 0.85 or dim_ratio > 0.97:
		print("FAIL: 暗星占比异常 =", dim_ratio, "（期望 ~0.92）")
		quit(1)
		return
	if bright == 0:
		print("FAIL: 没有一颗亮星 —— 亮度随机性丢失")
		quit(1)
		return
	print("PASS: 亮度随机性（暗星 ", dim, " / 亮星 ", bright, "，use_colors 已开）")

	# 3.6) 星点密度护栏：
	#   ① 图集必须切出**多颗**独立精灵（每颗星随机采样其中一颗）——
	#      切不出来就退化成「所有星长得一样」。
	#   ② 每颗星各有各的 instance color —— 这是「每颗星亮度独立」的前提
	#      （同一 quad 塞多颗星会共享一个颜色，缩小后糊成等亮三胞胎）。
	#   ③ quad 数不能太少，否则屏幕上会变成稀疏星场（原版观感是密而不挤）。
	if dome.sprite_count() < 4:
		print("FAIL: 图集只切出 ", dome.sprite_count(),
			" 颗星 —— 采样素材太少，星星会长得千篇一律")
		quit(1)
		return
	if StarDome.STAR_COUNT < 3000:
		print("FAIL: STAR_COUNT = ", StarDome.STAR_COUNT,
			" 过少 —— 屏幕上会变成稀疏星场（原版观感是密而不挤）")
		quit(1)
		return
	print("PASS: 星点密度（图集 ", dome.sprite_count(),
		" 颗精灵，", StarDome.STAR_COUNT, " 个 quad）")

	# 4) 方向分布：球面均匀 → 三轴均值≈0、方差相等。以原图位置还原单位方向后统计。
	var sx := 0.0
	var sy := 0.0
	var sz := 0.0
	var vx := 0.0
	var vy := 0.0
	var vz := 0.0
	for t in snap_a:
		var d: Vector3 = (t.origin / StarDome.DOME_RADIUS).normalized()
		sx += d.x
		sy += d.y
		sz += d.z
		vx += d.x * d.x
		vy += d.y * d.y
		vz += d.z * d.z
	var n := float(snap_a.size())
	var mx := sx / n
	var my := sy / n
	var mz := sz / n
	var vxx := vx / n - mx * mx
	var vyy := vy / n - my * my
	var vzz := vz / n - mz * mz
	var ok_mean := maxf(absf(mx), maxf(absf(my), absf(mz))) < 0.08
	var var_avg := (vxx + vyy + vzz) / 3.0
	var ok_var := vxx / var_avg > 0.8 and vxx / var_avg < 1.2 and vyy / var_avg > 0.8 \
			and vyy / var_avg < 1.2 and vzz / var_avg > 0.8 and vzz / var_avg < 1.2
	if not ok_mean or not ok_var:
		print("FAIL: 分布不均 mean=", Vector3(mx, my, mz), " var=", Vector3(vxx, vyy, vzz))
		quit(1)
		return
	print("PASS: 方向分布均匀（|mean|<0.08，三轴方差比 0.8~1.2）")

	# 5) 相机跟随：交由引擎真实帧驱动（--script 模式下 root 的视口句柄要等主循环
	# 起来才可用，手动喊 _process 拿不到 viewport）。等 process_frame 后再判。
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.position = Vector3(100.0, 5.0, -7.0)
	_dome = dome
	_cam = cam
	# process_frame 是 SceneTree 自己的信号（root 是 Window，没有它——上一行注释防再犯）。
	# 该信号在每帧节点 _process **之前**发出，所以要等第 2 拍（届时 dome 已跑过一拍 _process）。
	process_frame.connect(_check_follow)


# 相机跟随断言（process_frame 触发后执行，此时 dome._process 已由引擎跑过一拍）
func _check_follow() -> void:
	_follow_frames += 1
	if _follow_frames < 2:
		return  # 第 1 拍：process_frame 在 _process 之前，此时还没更新，等到第 2 拍
	if _dome.global_position.distance_to(_cam.global_position) > 1e-4:
		print("FAIL: 天球未跟随相机 pos=", _dome.global_position)
		quit(1)
		return
	print("PASS: 天球每帧贴相机位置（无视差）")
	quit(0)


# 抓全部 instance transform（确定性对比用 GDScript 侧快照——dummy 渲染器上
# MultiMesh.get_instance_transform 读不回写入值，恒为 zero，不能作为测试依据）
func _snapshot(dome: StarDome) -> Array[Transform3D]:
	return dome.snapshot_transforms()


# 返回首个差异下标；完全一致返回 -1
func _snap_diff(a: Array[Transform3D], bts: Array[Transform3D]) -> int:
	for i in a.size():
		var ta: Transform3D = a[i]
		var tb: Transform3D = bts[i]
		if ta.origin != tb.origin or ta.basis.x != tb.basis.x \
				or ta.basis.y != tb.basis.y or ta.basis.z != tb.basis.z:
			return i
	return -1
