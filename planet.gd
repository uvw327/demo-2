extends Node3D
# 行星场景：Goldberg 多面体当行星，3D 噪声生成海拔与气候，
# 每个六边形/五边形贴片按生物群系涂一种纯色（顶点色 + shader 显示）。
#
# 流程：启动 → 立刻显示“创建世界”菜单（原本的空窗期被菜单占掉）→
#      点击“生成世界” → 进度条 + 分帧生成 → 完成 → 隐藏菜单、显示星球。
#
# Goldberg 多面体怎么来的（三步）：
#   1) 二十面体：12 顶点、20 个三角形面；
#   2) 细分：每条棱 f 等分，把每个大三角形切成 f×f 个小三角形，
#      所有顶点归一化到单位球面；
#   3) 取对偶：细分网格的每个顶点，把它周围一圈三角形的“重心”
#      依次连成多边形——12 个顶点在原二十面体角上 → 12 个五边形，
#      其余 → 六边形。
#      贴片总数 = 10 × f² + 2（f = 每条棱的等分数）。

const OrbitCameraScript := preload("res://orbit_camera.gd")
const WorldMenuScript := preload("res://world_menu.gd")

# level：递归二分段数，f = 2^level → 贴片总数 = 10·4^level + 2
# level=7 → f=128 → 163842 个贴片
const LEVEL := 7
const SUBDIV := 1 << LEVEL # 每条棱的等分数 f
const PLANET_RADIUS := 1.0

# 每“帧”处理这么多贴片再让出一帧给 UI 刷新（分帧生成，进度条才能动）
const TILES_PER_FRAME := 1200

# ---- 生物群系纯色（RGB 0..1）----
const C_OCEAN := Color(0.13, 0.32, 0.57)  # 海洋
const C_DESERT := Color(0.87, 0.74, 0.47) # 沙漠
const C_FOREST := Color(0.25, 0.56, 0.26) # 温带森林
const C_TAIGA := Color(0.15, 0.38, 0.30)  # 寒带（针叶林）
const C_TUNDRA := Color(0.56, 0.56, 0.45) # 苔原
const C_ICE := Color(0.93, 0.95, 0.97)    # 冰盖
const C_UNEXPLORED := Color(0.10, 0.11, 0.14) # 未生成区域：深色剪影（覆盖率 < 100% 时出现）

# ---- 气候参数（想调 planetary 外观就改这里）----
const SEA_LEVEL := -0.05  # 海平面：海拔低于它的贴片是海洋
# 温度场：temperature = cos(纬度) + 噪声扰动 − 海拔制冷，范围 0(极寒)..1(酷热)
# 生物群系阈值只负责“界线画在哪”，噪声负责“界线长什么样”——
# 所以冰盖不是正圆、苔原不是环带，交界处会自然犬牙交错。
const TEMP_NOISE_AMP := 0.22 # 气候扰动幅度（相当于纬度边界摆动约 ±12°）
const ELEV_COOL := 0.35      # 海拔制冷系数（目前只有陆地海拔>0，做山脉之后更有意义）
const T_FREEZE := 0.18       # 温度低于它 → 冻结成冰盖（海冰+陆冰同一判定）
const T_TUNDRA := 0.38       # 低于它 → 苔原
const T_TAIGA := 0.55        # 低于它 → 寒带针叶林
const DESERT_HUMID := 0.35   # 湿度(0..1)低于它 → 沙漠

# ---- 菜单三档 “总体降雨/总体温度” 的整体偏移量 ----
# 选中“高/普通/低”时，把整个湿度场/温度场平移这么多：
# 全星球一起变湿/变干、变暖/变冷，群系边界随之自然移动（冰盖扩张、沙漠北移…）。
const RAIN_SHIFT := 0.25   # 降雨档位 × 此值 → 加到湿度上
const TEMP_SHIFT := 0.15   # 温度档位 × 此值 → 加到温度上

var _elev_noise: FastNoiseLite   # 海拔噪声
var _humid_noise: FastNoiseLite  # 湿度噪声（决定沙漠/森林）
var _temp_noise: FastNoiseLite   # 温度扰动噪声（洋流/大陆气候，撕碎纬度带）

var _menu: CanvasLayer           # “创建世界”菜单 UI
var _rain_shift := 0.0           # 本次生成的湿度整体偏移
var _temp_shift := 0.0           # 本次生成的温度整体偏移


func _ready() -> void:
	# 轨道相机控制器：和 cube 场景同款交互（中键环绕 + 滚轮缩放）
	add_child(OrbitCameraScript.new())

	# 启动只做一件事：摆出菜单。星球生成推迟到玩家点击“生成世界”之后，
	# 之前的“界面一片空白、程序在后台闷头算”被消除了。
	_menu = WorldMenuScript.new()
	add_child(_menu)
	_menu.generate_requested.connect(_on_generate_requested)


# 收到菜单参数 → 配置噪声与偏移 → 分帧生成 → 完成后撤掉菜单
func _on_generate_requested(params: Dictionary) -> void:
	_init_noise(params["seed"])
	_rain_shift = params["rainfall"] * RAIN_SHIFT
	_temp_shift = params["temperature"] * TEMP_SHIFT

	var t0 := Time.get_ticks_msec()
	# 先让出一帧，让进度条状态先画到屏幕上，再开始第一段比较重的同步计算
	await get_tree().process_frame

	var mesh := await _build_goldberg_mesh_async(params["coverage"])

	# 星球上线：材质固定，MeshInstance 装配后加入场景
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var mat := ShaderMaterial.new()
	mat.shader = load("res://planet_surface.gdshader")
	mi.material_override = mat
	add_child(mi)

	print("星球生成完毕：种子 ", params["seed"],
			"，覆盖率 ", roundi(params["coverage"] * 100), "%，总耗时 ",
			Time.get_ticks_msec() - t0, " ms")

	# 菜单使命完成：先隐藏（避免和相机拖拽抢鼠标）再销毁
	_menu.hide_menu()
	_menu.queue_free()
	_menu = null


# 种子 → 三路噪声。各路在种子上加固定偏移，保证彼此不“串味”，
# 且同一个种子永远生成同一颗星球（菜单里的“随机”按钮只是换种子数字）。
func _init_noise(seed_value: int) -> void:
	_elev_noise = FastNoiseLite.new()
	_elev_noise.seed = seed_value
	_elev_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_elev_noise.frequency = 1.2      # 频率低 → 大陆板块尺度
	_elev_noise.fractal_octaves = 4  # 多倍频叠加 → 海岸线更破碎自然
	_humid_noise = FastNoiseLite.new()
	_humid_noise.seed = seed_value + 13
	_humid_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_humid_noise.frequency = 1.6     # 湿度变化尺度比海拔小一些
	_temp_noise = FastNoiseLite.new()
	_temp_noise.seed = seed_value + 29
	_temp_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_temp_noise.frequency = 1.5      # 尺度要大：气候扰动像“暖流”，不是碎斑
	_temp_noise.fractal_octaves = 2  # 少倍频 → 更平滑的大尺度弯曲


# —— 气候模型：连续温度场取代“纬度硬切带” ——
# temperature = cos(纬度) + 噪声扰动 − 海拔制冷 + 菜单温度档偏移
# 同一个温度场海陆共用：海洋冷到阈值就是海冰，陆地冷到阈值就是冰原。
func _climate(center: Vector3) -> Dictionary:
	# 地心纬度：贴片中心方向与赤道面的夹角，单位度
	var lat := rad_to_deg(asin(clampf(center.y, -1.0, 1.0)))
	var lat_factor := cos(deg_to_rad(lat))          # 纬度基底：赤道 1 → 极点 0（平滑）
	var elev := _elev_noise.get_noise_3dv(center)   # 海拔（将来“山脉抬升”直接复用它）
	var temperature := clampf(
		lat_factor
		+ _temp_noise.get_noise_3dv(center) * TEMP_NOISE_AMP # 暖流/大陆性扰动：边界起伏的来源
		- maxf(elev, 0.0) * ELEV_COOL                        # 海拔越高越冷（只冷陆地，海洋不扣）
		+ _temp_shift,                                       # 菜单“总体温度”：整场平移
		0.0, 1.0)
	var humidity := clampf(
		0.5 + 0.5 * _humid_noise.get_noise_3dv(center) + _rain_shift, # 菜单“总体降雨”：整场平移
		0.0, 1.0)
	return {"elev": elev, "temperature": temperature, "humidity": humidity}


func _biome_color(center: Vector3) -> Color:
	var c := _climate(center)

	# 1) 海洋：低于海平面。极区海水冷过冻结阈值 → 变成海冰（冰盖自然延伸出海）
	if c["elev"] < SEA_LEVEL:
		return C_OCEAN if c["temperature"] >= T_FREEZE else C_ICE

	# 2) 陆地：按温度分带（阈值+噪声 → 犬牙交错的自然边界），低纬再看湿度
	if c["temperature"] < T_FREEZE:
		return C_ICE
	if c["temperature"] < T_TUNDRA:
		return C_TUNDRA
	if c["temperature"] < T_TAIGA:
		return C_TAIGA
	if c["humidity"] < DESERT_HUMID:
		return C_DESERT
	return C_FOREST


# 分帧版生成管线：
#   阶段 A（同步，约 1~2 秒）：拓扑结构——细分二十面体、邻接表；
#   阶段 B（分帧）：对偶出每个贴片 + 按覆盖率决定“生成/未生成” + 填充网格数组，
#                  每处理 TILES_PER_FRAME 个贴片让出一帧并更新进度条。
# coverage：0..1，全球覆盖率——决定多大比例的贴片被真正生成（其余为深色未生成区）。
func _build_goldberg_mesh_async(coverage: float) -> ArrayMesh:
	_progress(2.0) # 阶段 A 开始前先亮相

	# ===== 阶段 A：二十面体 + 棱细分 + 小三角形 + 邻接表 =====
	var topo := _build_topology()
	var verts: Array[Vector3] = topo["verts"]
	var tris: Array[Vector3i] = topo["tris"]
	var vert_faces: Dictionary = topo["vert_faces"]
	_progress(6.0)

	# 探索顺序：用种子把全部贴片索引洗牌，前 coverage 比例记为“已生成”——
	# 这样未生成区在星球上呈随机分布，且同一个种子的分布固定不变。
	var order := PackedInt32Array()
	order.resize(verts.size())
	for i in order.size():
		order[i] = i
	var rng := RandomNumberGenerator.new()
	rng.seed = int(_elev_noise.seed) + 101 # 洗牌种子与噪声种子同源
	for i in range(order.size() - 1, 0, -1): # Fisher–Yates 洗牌
		var j := rng.randi_range(0, i)
		var tmp := order[i]
		order[i] = order[j]
		order[j] = tmp
	var explored_n := maxi(1, roundi(verts.size() * coverage))
	var explored := PackedByteArray()
	explored.resize(verts.size())
	for k in explored_n:
		explored[order[k]] = 1

	# ===== 阶段 B：对偶贴片 + 颜色 + 网格数组（分帧） =====
	var mesh_verts := PackedVector3Array()
	var mesh_colors := PackedColorArray()
	var mesh_indices := PackedInt32Array()
	var total := verts.size()
	for v in total:
		var axis := verts[v] # 已是单位向量
		# 收集该点周围一圈三角形的重心（对偶多边形的顶点）
		var cents: Array[Vector3] = []
		for ti in vert_faces[v]:
			var tri := tris[ti]
			cents.append((verts[tri.x] + verts[tri.y] + verts[tri.z]).normalized())
		# 把相邻面重心按“绕 axis 的方位角”排序，才能连成不自交的多边形
		var e1: Vector3 = (cents[0] - axis * cents[0].dot(axis)).normalized()
		var e2 := axis.cross(e1)
		cents.sort_custom(func(p, q):
			return _tangent_angle(p, axis, e1, e2) < _tangent_angle(q, axis, e1, e2))
		var poly := PackedVector3Array(cents)

		# 贴片颜色：已生成 → 生物群系纯色；未生成 → 深色剪影（不做噪声采样，省时间）
		var center := Vector3.ZERO
		for p in poly:
			center += p
		center = (center / poly.size()).normalized() # 贴片中心方向：噪声与纬度的采样点
		var col := _biome_color(center) if explored[v] == 1 else C_UNEXPLORED

		# 每个贴片用一组“独占”顶点（不与其他贴片共享）→ 顶点色插值后整片均匀
		var base := mesh_verts.size()
		for p in poly:
			mesh_verts.append(p * PLANET_RADIUS)
			mesh_colors.append(col)
		# 凸多边形扇形三角化（五/六边形都是凸的）
		for i in range(1, poly.size() - 1):
			mesh_indices.append(base)
			mesh_indices.append(base + i)
			mesh_indices.append(base + i + 1)

		# 让出线程：攒够一批就刷新进度条并等下一帧，UI 才能持续响应
		if v % TILES_PER_FRAME == TILES_PER_FRAME - 1:
			_progress(6.0 + 92.0 * float(v + 1) / total)
			await get_tree().process_frame

	print("Goldberg level ", SUBDIV, "：贴片 ", total,
			" 个（12 五边形 + ", total - 12, " 六边形），网格顶点 ", mesh_verts.size(),
			"，已生成 ", explored_n, " 个")

	_progress(100.0)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = mesh_verts
	arrays[Mesh.ARRAY_COLOR] = mesh_colors
	arrays[Mesh.ARRAY_INDEX] = mesh_indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _progress(percent: float) -> void:
	if _menu != null:
		_menu.set_progress(percent)


# ===== 拓扑构建（纯几何，无噪声，同步一次算完） =====
# 返回 { verts, tris, vert_faces }：细分网格的球面顶点、三角形、顶点→三角形邻接
func _build_topology() -> Dictionary:
	# ---- 二十面体（黄金比例 t 摆出 12 个顶点）----
	var t := (1.0 + sqrt(5.0)) / 2.0
	var verts: Array[Vector3] = [
		Vector3(-1,  t, 0), Vector3(1,  t, 0), Vector3(-1, -t, 0), Vector3(1, -t, 0),
		Vector3(0, -1,  t), Vector3(0, 1,  t), Vector3(0, -1, -t), Vector3(0, 1, -t),
		Vector3( t, 0, -1), Vector3( t, 0, 1), Vector3(-t, 0, -1), Vector3(-t, 0, 1),
	]
	for i in verts.size():
		verts[i] = verts[i].normalized() # 归一化到单位球

	var base_faces: Array[Vector3i] = [
		Vector3i(0, 11, 5), Vector3i(0, 5, 1), Vector3i(0, 1, 7), Vector3i(0, 7, 10), Vector3i(0, 10, 11),
		Vector3i(1, 5, 9),   Vector3i(5, 11, 4), Vector3i(11, 10, 2), Vector3i(10, 7, 6), Vector3i(7, 1, 8),
		Vector3i(3, 9, 4),   Vector3i(3, 4, 2),  Vector3i(3, 2, 6),   Vector3i(3, 6, 8),  Vector3i(3, 8, 9),
		Vector3i(4, 9, 5),   Vector3i(2, 4, 11), Vector3i(6, 2, 10),  Vector3i(8, 6, 7), Vector3i(9, 8, 1),
	]

	# ---- 棱细分：每条棱只处理一次（key = 两端小号在前），中间点索引天然共享——
	# 相邻三角形引用同一批顶点，不靠浮点坐标去重，绝无“裂缝”。
	var edge_pts := {} # Vector2i(min,max) → PackedInt32Array（沿 min→max 方向的中间点）
	for f in base_faces:
		for e in [[f.x, f.y], [f.y, f.z], [f.z, f.x]]:
			var key := Vector2i(mini(e[0], e[1]), maxi(e[0], e[1]))
			if edge_pts.has(key):
				continue
			var pts: PackedInt32Array = []
			for k in range(1, SUBDIV):
				var p := verts[key.x].lerp(verts[key.y], float(k) / SUBDIV).normalized()
				verts.append(p)
				pts.append(verts.size() - 1)
			edge_pts[key] = pts

	# 取沿 u→v 方向的棱中间点（若存储方向相反则反转）
	var edge_between := func(u: int, v: int) -> Array:
		var key := Vector2i(mini(u, v), maxi(u, v))
		var pts := Array(edge_pts[key])
		if u > v:
			pts.reverse()
		return pts

	# ---- 细分出全部小三角形 ----
	var tris: Array[Vector3i] = []
	for f in base_faces:
		var a := f.x
		var b := f.y
		var c := f.z
		# grid[i][j]：从 a 沿 a→b 走 i 格、沿 a→c 走 j 格（i+j ≤ SUBDIV）
		var grid := []
		for i in range(SUBDIV + 1):
			var row := []
			for j in range(SUBDIV + 1 - i):
				var idx: int
				if i == 0 and j == 0:
					idx = a # 角点 a 本身
				elif i == SUBDIV and j == 0:
					idx = b # 角点 b 本身
				elif i == 0 and j == SUBDIV:
					idx = c # 角点 c 本身
				elif j == 0:
					idx = edge_between.call(a, b)[i - 1] # a→b 棱上第 i 个中间点
				elif i == 0:
					idx = edge_between.call(a, c)[j - 1] # a→c 棱上第 j 个中间点
				elif i + j == SUBDIV:
					# b→c 棱：grid[i][n-i] = lerp(c, b, i/n)，从 b 数是第 n-i 个
					idx = edge_between.call(b, c)[SUBDIV - i - 1]
				else:
					# 三角形内部点：全网格只有这一个三角形用到，直接新建。
					# 重心坐标 (1 - i/n - j/n, i/n, j/n)
					var fi := float(i) / SUBDIV
					var fj := float(j) / SUBDIV
					var p := (verts[a] * (1.0 - fi - fj) + verts[b] * fi + verts[c] * fj).normalized()
					verts.append(p)
					idx = verts.size() - 1
				row.append(idx)
			grid.append(row)
		# 每个梯形格切两个小三角形
		for i in range(SUBDIV):
			for j in range(SUBDIV - i):
				tris.append(Vector3i(grid[i][j], grid[i + 1][j], grid[i][j + 1]))
				if j < SUBDIV - 1 - i:
					tris.append(Vector3i(grid[i + 1][j], grid[i + 1][j + 1], grid[i][j + 1]))

	# ---- 顶点 → 相邻三角形 的邻接表 ----
	var vert_faces := {}
	for ti in tris.size():
		var tri := tris[ti]
		for v in [tri.x, tri.y, tri.z]:
			if not vert_faces.has(v):
				vert_faces[v] = []
			vert_faces[v].append(ti)

	return {"verts": verts, "tris": tris, "vert_faces": vert_faces}


# 向量 p 在切平面（以 axis 为法线、e1 为 0° 参考方向）上的方位角
func _tangent_angle(p: Vector3, axis: Vector3, e1: Vector3, e2: Vector3) -> float:
	var pp := (p - axis * p.dot(axis)).normalized()
	return atan2(pp.dot(e2), pp.dot(e1))
