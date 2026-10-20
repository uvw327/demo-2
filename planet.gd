extends Node3D
# 行星场景：Goldberg 多面体当行星，3D 噪声生成海拔与气候，
# 每个六边形/五边形贴片按“群系颜色 + 地形等级”表现（顶点色 + shader 显示）。
#
# 两个独立维度（同一贴片各管各的，别混）：
#   · 群系颜色（渲染层）：森林/沙漠/冰原… 决定“长什么样子”；
#   · 地形等级（数据层）：平原/小丘陵/大丘陵/山区/不可逾越，由海拔划分，
#     决定“好不好走、能不能建”。海洋贴片地形是“平原”（海底也是陆地）。
#
# 全球覆盖率：不被覆盖率划进去的贴片是“未生成区域”——没有地形数据、
# 不可交互，渲染为海洋底色。选区算法按大尺度噪声等高线切刀，
# 切出的是一整片形状随机自然、面积贴近目标覆盖率的连贯大陆。
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
const SELECTION_RING_SHADER := preload("res://selection_ring.gdshader")
# level：递归二分段数，f = 2^level → 贴片总数 = 10·4^level + 2
# level=7 → f=128 → 163842 个贴片
const LEVEL := 7
# 【性能对照已测毕】临时切成 level=6（40962 贴片，与 planet_demo 对齐）实测：
# headless 纯计算 558ms，窗口内墙钟 629/724/729ms——与 JS demo 同级（~320ms）
# 属同量级，详见 2026-10 性能对照分析。需要复测时取消下行注释并注释上一行。
#const LEVEL := 6
const SUBDIV := 1 << LEVEL # 每条棱的等分数 f
const PLANET_RADIUS := 1.0

# —— 生成管线的分帧预算：墙钟制 ——
# 旧方案“每帧固定处理 N 项”在所有刷新率下都得凑整帧：帧间隔里的空转
# 是硬地板（60Hz 每帧 16.7ms，微信 30fps 更是 33ms）。现在改为按墙钟
# 切片：实测上一帧的真实节奏，把本帧的计算吃满 ~70%，其余还给渲染与
# 进度条刷新。纯计算量不变，省掉的是等帧空转（高刷屏收益最大）。
const GEN_SLICE_RATIO := 0.70 # 每帧让生成吃掉的帧间隔比例
const GEN_SLICE_MIN_MS := 30  # 切片下限：块头要够大，60fps 一帧干货 ~30ms（老方案 30-80ms 哲学）
const GEN_SLICE_MAX_MS := 64  # 切片上限：进度条仍以 ~15fps 刷新，低配端避免大卡死

# ---- 生物群系纯色（RGB 0..1）----
const C_OCEAN := Color(0.13, 0.32, 0.57)  # 海洋
const C_DESERT := Color(0.87, 0.74, 0.47) # 沙漠
const C_FOREST := Color(0.25, 0.56, 0.26) # 温带森林
const C_TAIGA := Color(0.15, 0.38, 0.30)  # 寒带（针叶林）
const C_TUNDRA := Color(0.56, 0.56, 0.45) # 苔原
const C_ICE := Color(0.93, 0.95, 0.97)    # 冰盖
# 未生成区域（覆盖率外）：直接渲染为“纯海洋底色”——和海洋同一片深蓝，
# 视觉上像一张没有贴图的平坦海面，星球整体连续、不出现黑色地块；
# 逻辑上它属于“未生成”，没有地形数据也不可交互（见 is_tile_interactable）。
const C_UNGENERATED := C_OCEAN

# ---- 群系 id 表：颜色与 HUD 显示同源（_biome_id 判定，BIOME_NAMES/ COLORS 查表）----
const BIOME_NONE := 255 # 未生成贴片没有群系
const BIOME_NAMES := ["海洋", "海冰", "冰盖", "苔原", "寒带", "沙漠", "温带森林"]
const BIOME_COLORS: Array[Color] = [C_OCEAN, C_ICE, C_ICE, C_TUNDRA, C_TAIGA, C_DESERT, C_FOREST]

# ---- 地形等级（“地形五级”，由海拔高度划分，与群系颜色是两套独立维度）----
# 群系颜色只负责“长什么样子”（森林/沙漠/冰原…），地形数据只负责“好不好走”：
# 同一块平原数据可以是森林色也可以是沙漠色。五级从平坦到无法通行：
#   平原 → 地势平坦，最适合建造与通行
#   小丘陵 → 有些起伏，但影响不大
#   大丘陵 → 崎岖，可能影响移动和建造布局
#   山区 → 群山覆盖，地块内通常有大量可开采岩石和山洞
#   不可逾越 → 无法翻越的高山（商队会绕行）
# 注意：海洋贴片没有“海洋”这种地形等级——海底也是陆地（海底平原），
# 数据上一律记为“平原”，只有渲染时才用海洋色（见 _tile_appearance）。
enum TerrainLevel { NOT_GENERATED, FLAT, SMALL_HILLS, LARGE_HILLS, MOUNTAINOUS, IMPASSABLE }
# 地形等级的可读名字（只用于日志统计输出）
const TERRAIN_NAMES := ["未生成", "平原", "小丘陵", "大丘陵", "山区", "不可逾越"]
# 海平面以上的海拔分级阈值（噪声输出约 -1..1，陆地海拔大致落在 SEA_LEVEL..0.9）
# 平原 = 海平面以上、HILL1_ELEV 以下（含所有海洋贴片的海底平原）
const HILL1_ELEV := 0.18 # 高于它 → 小丘陵
const HILL2_ELEV := 0.32 # 高于它 → 大丘陵
const MOUNT_ELEV := 0.48 # 高于它 → 山区
const PEAK_ELEV := 0.62  # 高于它 → 不可逾越（数量很少，顶端尖峰）
const C_ROCK := Color(0.45, 0.42, 0.39) # 山体基岩色：高级地形把群系色往这里压
# 大陆内部洞保留成“内陆湖”的最小贴片数：小于它的是碎斑级别的小洞，
# 直接补平成陆地；大于它的算一个可观的水体（里海式内陆海），
# 保留下来更像真实世界，渲染用海洋色。
const MIN_LAKE_TILES := 200

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
var _continent_noise: FastNoiseLite # 大陆形状噪声：决定“已生成区域”长在哪
# 地形等级查询表：贴片索引 → TerrainLevel（NOT_GENERATED 的贴片没有地形）
var _terrain: PackedByteArray = PackedByteArray()
# 大陆内部的内陆湖表：贴片索引 → 1(内陆湖：渲染海色，地形平原)
var _inland_water: PackedByteArray = PackedByteArray()
# —— HUD 显示用的逐贴片缓存（阶段 B 填充，二次生成时重置）——
var _tile_biome := PackedByteArray()    # 群系 id（BIOME_NONE=未生成）
var _tile_elev := PackedFloat32Array()  # 海拔噪声值
var _tile_temp := PackedFloat32Array()  # 温度
var _tile_humid := PackedFloat32Array() # 湿度

var _menu: CanvasLayer           # “创建世界”菜单 UI
var _rain_shift := 0.0           # 本次生成的湿度整体偏移
var _temp_shift := 0.0           # 本次生成的温度整体偏移
var _prog_calls := 0             # 性能打点：_progress 调用次数（≈分帧 await 帧数）
# 大陆质心方向（单位向量）：以它为中心的半球承载的可交互面积最大，
# 星球生成完把镜头对准它——玩家看到的正是“陆地最多的那一面”。
var _region_center := Vector3.UP
# 当前装配的星球模型：再次生成时先撤旧的，避免两颗星球叠在一起渲染
var _mesh_instance: MeshInstance3D
# 未生成区域查询用的拓扑缓存（方向→贴片）。全部指向单位球面。
var _topo_verts: Array[Vector3] = []
var _generated: PackedByteArray = PackedByteArray() # 贴片是否已生成（可交互）

# —— 点击选区：拾取 + 选中高亮 ——
# 每块贴片的边界顶点（单位球面）：阶段 B 建网格时顺手缓存，
# 点击选中时据此生成“向内溢出的白色光晕环”（见 _rebuild_selection_ring）。
var _tile_polys: Array[PackedVector3Array] = []
var _selected_tile := -1                  # 当前选中贴片索引；-1 = 未选中
var _orbit: OrbitCamera                   # 轨道相机（点按事件从这里进来）
var _selection_ring: MeshInstance3D       # 选中环：独立实例，切换选中时重建其 mesh
var _selection_material: ShaderMaterial   # 选中环材质（白光向内衰减，无呼吸）
var _hud: TileHud                         # 贴片信息 HUD：选中贴片时亮出，取消选中即隐藏


func _ready() -> void:
	# 贴片信息 HUD：平时隐藏，选中贴片时亮出（数据在 select_tile 时组装）
	_hud = TileHud.new()
	add_child(_hud)

	# 轨道相机控制器：桌面左键/中键拖拽 + 滚轮，触屏单指拖拽 + 双指捏合；
	# 短按不动（点按）经 view_tapped 转发到这里做贴片拾取
	_orbit = OrbitCameraScript.new()
	add_child(_orbit)
	_orbit.view_tapped.connect(_on_view_tapped)

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

	# 旧星球退场：二次生成时撤掉上一颗，避免叠在一起渲染
	if _mesh_instance != null:
		_mesh_instance.queue_free()
	# 星球上线：材质固定，MeshInstance 装配后加入场景
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.mesh = mesh
	var mat := ShaderMaterial.new()
	mat.shader = load("res://planet_surface.gdshader")
	_mesh_instance.material_override = mat
	add_child(_mesh_instance)

	# 生成完把画面交给玩家：大陆最多的那面朝向镜头、北极朝上。
	# focus_on 对准大陆质心方向（以它为中心的半球覆盖面积最大），
	# 而 look_at 的“上”参考恒为 +Y，北极自然始终在画面上方。
	for child in get_children():
		if child is OrbitCamera:
			child.focus_on(_region_center)

	print("星球生成完毕：种子 ", params["seed"],
			"，覆盖率 ", roundi(params["coverage"] * 100), "%，总耗时 ",
			Time.get_ticks_msec() - t0, " ms")

	# 菜单使命完成：先隐藏（避免和相机拖拽抢鼠标）再销毁。
	# 二次生成（代码直调 _on_generate_requested）时菜单可能已被撤掉，判空兜底。
	if _menu != null:
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
	# 大陆形状噪声：频率比海拔还低（尺度更大）→ 覆盖率切出来的生成区
	# 是少数几大块连贯的“大陆”，而不是碎岛。
	_continent_noise = FastNoiseLite.new()
	_continent_noise.seed = seed_value + 57
	_continent_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_continent_noise.frequency = 0.8  # 非常低的频率 → 区域足够大、连续不碎
	_continent_noise.fractal_octaves = 4 # 多倍频 → 海岸线有多尺度的犬牙细节


# —— 气候模型：连续温度场取代“纬度硬切带” ——
# temperature = cos(纬度) + 噪声扰动 − 海拔制冷 + 菜单温度档偏移
# 同一个温度场海陆共用：海洋冷到阈值就是海冰，陆地冷到阈值就是冰原。
# 性能说明：不返回 Dictionary——逐贴片调用时每次分配字典+字符串键哈希
# 是显著热点；改为把结果写进调用方复用的 out 数组（[elev, temp, humidity]）。
func _climate_fill(center: Vector3, out: Array) -> void:
	# 地心纬度：贴片中心方向与赤道面的夹角，单位度
	var lat := rad_to_deg(asin(clampf(center.y, -1.0, 1.0)))
	var lat_factor := cos(deg_to_rad(lat))          # 纬度基底：赤道 1 → 极点 0（平滑）
	var elev := _elev_noise.get_noise_3dv(center)   # 海拔（将来“山脉抬升”直接复用它）
	out[0] = elev
	out[1] = clampf(
		lat_factor
		+ _temp_noise.get_noise_3dv(center) * TEMP_NOISE_AMP # 暖流/大陆性扰动：边界起伏的来源
		- maxf(elev, 0.0) * ELEV_COOL                        # 海拔越高越冷（只冷陆地，海洋不扣）
		+ _temp_shift,                                       # 菜单“总体温度”：整场平移
		0.0, 1.0)
	out[2] = clampf(
		0.5 + 0.5 * _humid_noise.get_noise_3dv(center) + _rain_shift, # 菜单“总体降雨”：整场平移
		0.0, 1.0)


# —— 生物群系判定/纯色（颜色只描述“长什么样”，地形数据另算）——
# id 与名字/颜色同源：同一套分支出 id，群系名（HUD）与渲染色都查表。
func _biome_id(elev: float, temp: float, humid: float) -> int:
	# 海洋：低于海平面。极区海水冷过冻结阈值 → 变成海冰（冰盖自然延伸出海）
	if elev < SEA_LEVEL:
		return 0 if temp >= T_FREEZE else 1

	# 陆地：按温度分带（阈值+噪声 → 犬牙交错的自然边界），低纬再看湿度
	if temp < T_FREEZE:
		return 2 # 冰盖
	if temp < T_TUNDRA:
		return 3 # 苔原
	if temp < T_TAIGA:
		return 4 # 寒带
	if humid < DESERT_HUMID:
		return 5 # 沙漠
	return 6     # 温带森林


func _biome_color(elev: float, temp: float, humid: float) -> Color:
	return BIOME_COLORS[_biome_id(elev, temp, humid)]


# —— 地形等级判定：单看海拔（ Bonus：同一个贴片的群系颜色与地形是两个维度）——
# 海洋贴片记为“平原”（海底平原：海底下面也是陆地，只是被水盖了）；
# 陆地从海平面往上爬，按阈值逐级抬升为丘陵→山区；极高的尖峰不可逾越。
# 冰盖/苔原是“群系颜色”维度的事，它们能不能走、好不好建依然由海拔说了算
# ——想让冻土更难通行，把 HILL1_ELEV 往下调一档即可，不需要新逻辑。
func _terrain_level(elev: float) -> int:
	if elev < HILL1_ELEV:
		return TerrainLevel.FLAT # 海面（海底平原）与沿海平地都是平原
	if elev < HILL2_ELEV:
		return TerrainLevel.SMALL_HILLS
	if elev < MOUNT_ELEV:
		return TerrainLevel.LARGE_HILLS
	if elev < PEAK_ELEV:
		return TerrainLevel.MOUNTAINOUS
	return TerrainLevel.IMPASSABLE # 极高尖峰：建不了也翻不过去


# —— 贴片外观：群系纯色打底，地形等级做明暗与基岩色倾斜 ——
# 越高级的地形越暗、山越高越接近基岩色；玩家肉眼就能读出“哪里翻不过去”。
# 平原不动颜色（海洋贴片按底色规则正常渲染成海色，与地形数据无关）。
func _tile_appearance(base: Color, level: int) -> Color:
	var rock_mix := 0.0 # 往基岩色压的比例
	match level:
		TerrainLevel.SMALL_HILLS:
			base = base * 0.92 # 一点点暗：腿脚还行
		TerrainLevel.LARGE_HILLS:
			base = base * 0.82
		TerrainLevel.MOUNTAINOUS:
			base = base * 0.72
			rock_mix = 0.4 # 山区：群系色 + 灰褐基岩对半
		TerrainLevel.IMPASSABLE:
			base = base * 0.6
			rock_mix = 0.8 # 不可逾越：几乎纯基岩，一眼识别
	return base.lerp(C_ROCK, rock_mix)


# —— 覆盖率选区：从噪声峰值出发的“纯噪声序漫灌 + 洞区清洗”（协程式分帧）——
# 以大陆噪声得分最高的贴片做种子，每次取噪声分最高的边界贴片并入大陆，
# 长到目标覆盖率后清洗大陆内部残留的未生成碎块：
#   · 很小的洞（< MIN_LAKE_TILES，漫灌止步时差一点没轮到的碎斑）
#     → 补成陆地，面积几乎不变；
#   · 大块的洞（大陆噪声低洼盆地）→ 保留为“内陆湖”：可交互、有地形
#     （和海底平原同一套），渲染成海洋色——“水下也是陆地”的延续。
# 不变量：**可交互区整体 1 个连通块**（湖被陆地包着，不破坏区域连续），
# 且面积精确贴合目标覆盖率（不超预算，全程不做任何蚀退）。
#
# 两个此前踩过的坑，记录在这防止回退：
#   · 想用逐贴片抖动让海岸犬牙 → 抖动远大于相邻贴片噪声差，扩张顺序
#     近乎随机，停止时会残留一大片“银河状”边界碎斑（用户截图的根因）；
#     现在把犬牙交给多倍频噪声本身（相邻贴片分差远小于噪声梯度），
#     边界残留只剩一圈贴着海岸的“下一圈等值线”薄带，视觉是一条大陆架。
#   · 想用蚀退收回面积 → 无论“最低分级联下挖”还是“逐圈削皮”都会沿
#     低洼处/半岛细腰把大陆劈成两半。索性不蚀退，大洞保留成内陆湖。
# 种子来自噪声种子（同源），同一种子的星球大陆永远一个样。
#
# 分帧说明：打分/邻接/漫灌/清洗都是长循环，按各自帧预算切片，
# 每片更新一次进度条并 await 让帧，几百毫秒的大活不再冻结画面。
# pct_from / pct_to：本函数占用全局进度条的区间（内部再分：打分 18%、
# 邻接 22%、最多 3 轮选区各占 20%）。
# 返回：{ "region": 贴片→1(已生成,可交互)/0(未生成,无地形),
#         "inland_water": 贴片→1(大陆内内陆湖,渲染海色,地形平原)/0(普通) }
func _select_generated_region(verts: Array[Vector3], tris: Array[Vector3i],
		coverage: float, pct_from := 30.0, pct_to := 44.0) -> Dictionary:
	var total := verts.size()
	var region := PackedByteArray()
	region.resize(total)
	var inland_water := PackedByteArray()
	inland_water.resize(total)
	var target := roundi(total * coverage)
	if target <= 0:
		return {"region": region, "inland_water": inland_water} # 覆盖率 0：整球不可探索
	if target >= total:
		region.fill(1) # 100%：整球都是大陆（没有大洋，也没有湖）
		return {"region": region, "inland_water": inland_water}

	var span := pct_to - pct_from
	var score_to := pct_from + span * 0.18 # 打分占区间的 18%
	var adj_to := pct_from + span * 0.40  # 打分 + 邻接共占 40%，余下给选区
	var flood_to := adj_to + span * 0.24  # 单轮漫灌共占 24%（快照续灌挤进各轮前半段）
	var wash_span := span * 0.12          # 每轮清洗占 12%（最多 3 轮，合计 36%）
	var t_sel := Time.get_ticks_msec()     # 选区内部阶段打点

	# 1) 大陆噪声打分（分片），并记住得分最高的贴片当种子
	var scores := PackedFloat32Array()
	scores.resize(total)
	var best := 0
	var sc_at := 0
	while sc_at < total:
		var sc_end := mini(sc_at + SLICE_CHECK_STRIDE, total)
		for i in range(sc_at, sc_end):
			scores[i] = _continent_noise.get_noise_3dv(verts[i])
			if scores[i] > scores[best]:
				best = i
		sc_at = sc_end
		# 墙钟切片：每 ~512 项结一次钟，用满本帧就先算下一批
		if Time.get_ticks_msec() - _gen_slice_t0 >= _gen_budget:
			await _slice_yield(pct_from + (score_to - pct_from) * float(sc_at) / total)
	t_sel = _stage_mark("④a大陆打分", t_sel)

	# 2) 邻接表：对偶贴片相邻 = 细分网格三角形一条棱的两端（分片）
	var neighbors: Array = []
	neighbors.resize(total)
	for i in total:
		neighbors[i] = PackedInt32Array()
	var ti_at := 0
	while ti_at < tris.size():
		var ti_end := mini(ti_at + SLICE_CHECK_STRIDE, tris.size())
		for ti in range(ti_at, ti_end):
			var t := tris[ti]
			neighbors[t.x].append(t.y)
			neighbors[t.y].append(t.x)
			neighbors[t.y].append(t.z)
			neighbors[t.z].append(t.y)
			neighbors[t.z].append(t.x)
			neighbors[t.x].append(t.z)
		ti_at = ti_end
		# 墙钟切片：每 ~512 项结一次钟，用满本帧就让出
		if Time.get_ticks_msec() - _gen_slice_t0 >= _gen_budget:
			await _slice_yield(score_to + (adj_to - score_to) * float(ti_at) / tris.size())
	t_sel = _stage_mark("④b邻接表", t_sel)

	# 3) 选区漫灌：每次边界贴片按噪声分纯序入堆、并掉分最高的那个。
	#    不加逐贴片随机抖动——抖动会让扩张顺序近乎随机，停止时残留一大片
	#    散碎边界（碎斑根因）；海岸犬牙细节由多倍频噪声梯度自己撕出来。
	#    原实现“灌到 target→清洗→量偏差→从头整灌到回调后的预算”最多跑 3
	#    轮，每轮都把同一串弹堆重复了一遍（同种子同分数 → 弹出顺序固定）。
	#    现改为：漫灌只做一次、灌到 target；从 target×50% 起每跨过一个
	#    面积里程碑就把（state、边界堆、已并数）快照一份，漫灌终点本身
	#    也补一份快照。每轮评价时从“不高于该轮停止面积的最近快照”续灌
	#    到精确面积——续灌与从头整灌逐位等价（同序弹出同一批贴片），
	#    绝大部分重复弹堆被省掉，语义（偏差回调、清洗规则）完全不变。
	# 贴片状态：0 还没碰到、1 在边界堆里待命、2 已并入大陆
	var state := PackedByteArray()
	state.resize(total)
	var heap := _TileHeap.new()
	state[best] = 2
	var count := 1
	for nb in neighbors[best]:
		if state[nb] == 0:
			state[nb] = 1
			heap.push(scores[nb], nb)
	var next_ms := roundi(target * 0.5)      # 快照覆盖 target×50% → target
	var ms_step := maxi(1, roundi(target * 0.04)) # 快照面积步长：只影响续灌工作量，不影响结果
	var snap_states: Array = []              # PackedByteArray：里程碑时刻的漫灌状态
	var snap_heaps: Array = []               # [prio, idx]：里程碑时刻的边界堆（COW 快照）
	var snap_counts: Array = []              # 与上两表同序的“已并入面积”
	while count < target and heap.size() > 0:
		# 墙钟切片：以 ~512 pop 为一批，批内零查钟，批尾结一次钟
		var pop_end := count + SLICE_CHECK_STRIDE
		while count < target and heap.size() > 0 and count < pop_end:
			var v := heap.pop()
			if state[v] == 2:
				continue
			state[v] = 2
			count += 1
			for nb in neighbors[v]:
				if state[nb] == 0:
					state[nb] = 1
					heap.push(scores[nb], nb)
			if next_ms <= count and next_ms <= target:
				snap_states.append(state.duplicate())
				snap_heaps.append([heap._prio.duplicate(), heap._idx.duplicate()])
				snap_counts.append(count)
				next_ms += ms_step
		if Time.get_ticks_msec() - _gen_slice_t0 >= _gen_budget:
			await _slice_yield(adj_to + (flood_to - adj_to)
					* float(mini(count, target)) / float(target))
	# 漫灌终点（=target 或堆提前死掉）也补一份快照：评价轮要从“最靠后的
	# ≤停止面积”的快照续灌，终点快照能把续灌工作量压到最小。
	snap_states.append(state.duplicate())
	snap_heaps.append([heap._prio.duplicate(), heap._idx.duplicate()])
	snap_counts.append(count)
	t_sel = _stage_mark("④c漫灌单轮", t_sel)

	# 4) 轮次评价：每轮从快照续灌到该轮精确停止面积，再清洗、量偏差、
	#    回调生长预算（最多 3 轮，与旧实现的轮次语义一致）。下面的清洗
	#    注释沿用旧实现原文。
	var grow_target := target
	var final_state: PackedByteArray = snap_states[snap_states.size() - 1] # 兜底：评价轮极端早退时=漫灌终点
	var final_water := PackedByteArray()
	final_water.resize(total)
	for eval_i in 3:
		# 定位快照：最后一个“已并面积 ≤ 本轮生长预算”的快照
		var si := -1
		while si + 1 < snap_counts.size() and snap_counts[si + 1] <= grow_target:
			si += 1
		if si < 0:
			# 理论极端（生长预算回撤到首个快照面积以下）：用保底结果收尾
			print("选区：生长预算回撤到首个快照面积以下，提前收尾（罕见）")
			break
		var st: PackedByteArray = snap_states[si].duplicate()
		var h2 := _TileHeap.new()
		# load 必须喂“再复制一份”的数组：续灌的弹堆/入堆会写堆数组，
		# 直接装快照本体（无复制共享）会把快照写脏，下一轮的续灌起点就被污染。
		h2.load(snap_heaps[si][0].duplicate(), snap_heaps[si][1].duplicate())
		var grown: int = snap_counts[si]
		# 快照续灌到精确停止面积：与从头整灌同序弹出，结果逐位等价；
		# 续灌会写 st/堆数组，COW 会让它们自动脱离快照本体。
		while grown < grow_target and h2.size() > 0:
			# 墙钟切片：以 ~512 pop 为一批，批内零查钟，批尾结一次钟
			var pop_end := grown + SLICE_CHECK_STRIDE
			while grown < grow_target and h2.size() > 0 and grown < pop_end:
				var v := h2.pop()
				if st[v] == 2:
					continue
				st[v] = 2
				grown += 1
				for nb in neighbors[v]:
					if st[nb] == 0:
						st[nb] = 1
						h2.push(scores[nb], nb)
			if Time.get_ticks_msec() - _gen_slice_t0 >= _gen_budget:
				await _slice_yield(flood_to + wash_span
						* (float(eval_i) + 0.5 * float(grown) / float(grow_target)))

		# 4) 洞区清洗：漫灌停在 grow_target 时，堆里必然还剩一圈“差一点该
		#    轮到”的边界贴片。纯噪声序下它们贴着海岸连成一条“下一圈等值线”
		#    薄带，与外侧大洋相连、视觉自然，不用管；但大陆内部噪声凹陷处
		#    的未生成碎块与外侧大洋不连通，需要清洗：
		#      · 小于 MIN_LAKE_TILES 的碎块 → 补成陆地（就是当初的碎斑）；
		#      · 大于等于 MIN_LAKE_TILES 的盆块 → 保留为内陆湖：
		#        可交互、有地形（同海底平原），渲染海色。
		#    判定标准：把“未生成 + 堆内残留”整体看作海面，
		#    所有与最大海面不相连的连通块就是“大陆内部的洞”。
		#    BFS 也分帧：外层扫种子贴片 + 内层弹栈都按预算切片。
		var seen := PackedByteArray()
		seen.resize(total)
		var comps: Array = [] # 大陆内部海面连通块（每个 PackedInt32Array）
		var s0 := 0
		var pops := 0
		while s0 < total:
			if st[s0] == 2 or seen[s0] == 1:
				s0 += 1
				continue
			var comp := PackedInt32Array()
			var stack: Array = [s0]
			seen[s0] = 1
			while stack.size() > 0:
				# 墙钟切片：以 ~512 pop 为一批，批内零查钟，批尾结一次钟
				var pop_end := pops + SLICE_CHECK_STRIDE
				while stack.size() > 0 and pops < pop_end:
					var w: int = stack.pop_back()
					comp.append(w)
					pops += 1
					for nb in neighbors[w]:
						if st[nb] != 2 and seen[nb] == 0:
							seen[nb] = 1
							stack.append(nb)
				if Time.get_ticks_msec() - _gen_slice_t0 >= _gen_budget:
					await _slice_yield(flood_to + wash_span * (float(eval_i) + 0.5
							+ 0.5 * float(pops) / float(total)))
			comps.append(comp)
			s0 += 1
		# 最大的海面连通块是外侧大洋本体；其余与大陆相邻的是内陆盆地
		var ocean_size := 0
		var ocean_at := -1
		for ci in comps.size():
			if comps[ci].size() > ocean_size:
				ocean_size = comps[ci].size()
				ocean_at = ci
		var lake_sizes := []
		var absorbed := 0
		var iw := PackedByteArray()
		iw.resize(total)
		for ci in comps.size():
			if ci == ocean_at:
				continue
			var comp: PackedInt32Array = comps[ci]
			absorbed += comp.size()
			if comp.size() < MIN_LAKE_TILES:
				# 碎斑级小洞：直接补成陆地（该地区照常生成地形群系）
				for w in comp:
					st[w] = 2
			else:
				# 内陆湖：并入可交互区，但渲染成海洋色
				lake_sizes.append(comp.size())
				for w in comp:
					st[w] = 2
					iw[w] = 1
		# 本轮结束后的可交互区面积；偏差用于把下轮生长预算往回收
		var region_size := grown + absorbed
		var dev := region_size - target
		print("选区第 %d 轮：生长 %d + 吞洞 %d = %d 贴片（目标 %d，偏差 %d）；内陆湖 %s"
				% [eval_i, grown, absorbed, region_size, target, dev, str(lake_sizes)])
		final_state = st
		final_water = iw
		t_sel = _stage_mark("④d清洗%d轮" % eval_i, t_sel)
		if dev == 0:
			break
		grow_target -= dev
		if grow_target <= 0 or grow_target >= total:
			break

	for i in total:
		region[i] = 1 if final_state[i] == 2 else 0
	inland_water = final_water
	return {"region": region, "inland_water": inland_water}


# 选区扩张用的简易二叉最大堆（优先级高的贴片先并入大陆；
# 并行数组存优先级 + 贴片索引，几十行自给自足，GDScript 没有内置堆）。
class _TileHeap:
	var _prio := PackedFloat64Array()
	var _idx := PackedInt32Array()

	func size() -> int:
		return _prio.size()

	# 从快照灌装（数组进堆）：COW 语义保证 push/pop 时才写拷贝，
	# 不会碰坏快照本体。
	func load(p: PackedFloat64Array, i: PackedInt32Array) -> void:
		_prio = p
		_idx = i

	func push(p: float, i: int) -> void:
		_prio.append(p)
		_idx.append(i)
		var c := _prio.size() - 1 # 新元素上浮：比父节点大就交换
		while c > 0:
			var parent := (c - 1) / 2
			if _prio[parent] >= _prio[c]:
				break
			var t := _prio[parent]
			_prio[parent] = _prio[c]
			_prio[c] = t
			var t2 := _idx[parent]
			_idx[parent] = _idx[c]
			_idx[c] = t2
			c = parent

	func pop() -> int:
		var top := _idx[0]
		var last := _prio.size() - 1
		_idx[0] = _idx[last]
		_prio[0] = _prio[last]
		_prio.resize(last)
		_idx.resize(last)
		var p := 0 # 堆顶新元素下沉：把大的孩子换上来
		while true:
			var l := p * 2 + 1
			if l >= _prio.size():
				break
			var big := l
			if l + 1 < _prio.size() and _prio[l + 1] > _prio[l]:
				big = l + 1
			if _prio[p] >= _prio[big]:
				break
			var t := _prio[p]
			_prio[p] = _prio[big]
			_prio[big] = t
			var t2 := _idx[p]
			_idx[p] = _idx[big]
			_idx[big] = t2
			p = big
		return top



# 全程分帧版生成管线：过去“点生成世界后僵住几秒”的根因是阶段 A（拓扑 +
# 打分 + 邻接 + 选区）一口气同步算完，画面毫无反馈。现在每个重活按帧切
# 片：每帧吃一小块、更新一次进度条、让出一帧给 UI。准备工作也计入进度：
#   ① 2~6%     二十面体基本顶点 + 棱插值点（量小，一口气完成）
#   ② 6~26%    逐个基本面细分出全球小三角网格（每个基本面一帧）
#   ③ 26~30%   顶点 → 相邻三角形索引表（分片扫描全部三角形）
#   ④ 30~44%   覆盖率选区：打分 + 漫灌 + 洞区清洗（协程式分帧，见下）
#   ⑤ 44~97%   对偶贴片 + 颜色 + 网格数组（每帧一批）
#   ⑥ 97~100%  组装 ArrayMesh 收尾
# coverage：0..1，全球覆盖率——多大比例的球面生成真实地形（陆地/群系）。
# 选区由 _select_generated_region 漫灌长出：单块连通、面积精确；
# 其余贴片渲染为纯海洋底色且无地形数据，星球视觉连续不破相。
func _build_goldberg_mesh_async(coverage: float) -> ArrayMesh:
	_progress(2.0)
	_slice_begin() # 管线起点即首帧切片起点（入口前刚让过一帧）
	var t_stage := Time.get_ticks_msec()  # 阶段耗时打点起点

	# ===== ① 二十面体 12 顶点 + 30 条棱的插值点（几百次向量运算，量小）=====
	var t := (1.0 + sqrt(5.0)) / 2.0
	var verts: Array[Vector3] = [
		Vector3(-1,  t, 0), Vector3(1,  t, 0), Vector3(-1, -t, 0), Vector3(1, -t, 0),
		Vector3(0, -1,  t), Vector3(0, 1,  t), Vector3(0, -1, -t), Vector3(0, 1, -t),
		Vector3( t, 0, -1), Vector3( t, 0, 1), Vector3(-t, 0, -1), Vector3(-t, 0, 1),
	]
	for i in verts.size():
		verts[i] = verts[i].normalized() # 全部归一化到单位球面
	# 基本面的三个顶点环。
	var base_faces: Array[Vector3i] = [
		Vector3i(0, 11, 5), Vector3i(0, 5, 1), Vector3i(0, 1, 7), Vector3i(0, 7, 10), Vector3i(0, 10, 11),
		Vector3i(1, 5, 9),   Vector3i(5, 11, 4), Vector3i(11, 10, 2), Vector3i(10, 7, 6), Vector3i(7, 1, 8),
		Vector3i(3, 9, 4),   Vector3i(3, 4, 2),  Vector3i(3, 2, 6),   Vector3i(3, 6, 8),  Vector3i(3, 8, 9),
		Vector3i(4, 9, 5),   Vector3i(2, 4, 11), Vector3i(6, 2, 10),  Vector3i(8, 6, 7), Vector3i(9, 8, 1),
	]
	# 棱插值点：每条棱只算一次（key = 两端顶点号排序后的 Vector2i），
	# 存中间点索引；同一顶点被相邻基本面共用，这样顶点数自然去重不“翻倍”。
	var edge_pts := {}
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
	_progress(6.0)

	# 棱上取点 lambda：u、v 两端各存了一份中间点（方向相反），取用前转回正向
	var edge_between := func(u: int, v: int) -> Array:
		var key := Vector2i(mini(u, v), maxi(u, v))
		var pts := Array(edge_pts[key])
		if u > v:
			pts.reverse()
		return pts

	# ===== ② 细分基本面 → 全球小三角网格：每个基本面让出一帧 =====
	var tris: Array[Vector3i] = []
	for fi in base_faces.size():
		var f := base_faces[fi]
		var a := f.x
		var b := f.y
		var c := f.z
		# grid[i][j]：从 a 出发，向 a→b 方向走 i 格、向 a→c 方向走 j 格（i+j ≤ SUBDIV）
		var grid := []
		for i in range(SUBDIV + 1):
			var row := []
			for j in range(SUBDIV + 1 - i):
				var idx: int
				if i == 0 and j == 0:
					idx = a # 角点 a 本尊
				elif i == SUBDIV and j == 0:
					idx = b # 角点 b 本尊
				elif i == 0 and j == SUBDIV:
					idx = c # 角点 c 本尊
				elif j == 0:
					idx = edge_between.call(a, b)[i - 1] # a→b 棱上的第 i 个中间点
				elif i == 0:
					idx = edge_between.call(a, c)[j - 1] # a→c 棱上的第 j 个中间点
				elif i + j == SUBDIV:
					# b→c 边：grid[i][n-i] = lerp(c, b, i/n)，向 b 角数第 n-i 个
					idx = edge_between.call(b, c)[SUBDIV - i - 1]
				else:
					# 内部点：全局只算一次（去重），直接线性组合坐标
					# 重心坐标 (1 - i/n - j/n, i/n, j/n)
					var fi2 := float(i) / SUBDIV
					var fj := float(j) / SUBDIV
					var p := (verts[a] * (1.0 - fi2 - fj) + verts[b] * fi2 + verts[c] * fj).normalized()
					verts.append(p)
					idx = verts.size() - 1
				row.append(idx)
			grid.append(row)
		# 每个大三角形网格内部生成小三角形
		for i in range(SUBDIV):
			for j in range(SUBDIV - i):
				tris.append(Vector3i(grid[i][j], grid[i + 1][j], grid[i][j + 1]))
				if j < SUBDIV - 1 - i:
					tris.append(Vector3i(grid[i + 1][j], grid[i + 1][j + 1], grid[i][j + 1]))
			# 墙钟切片以面粒度让帧（基本面只有 ~20/8 个，逐面查钟不贵）
			if Time.get_ticks_msec() - _gen_slice_t0 >= _gen_budget:
				await _slice_yield(6.0 + 20.0 * float(fi + 1) / base_faces.size())
		_progress(6.0 + 20.0 * float(fi + 1) / base_faces.size())

	t_stage = _stage_mark("②基本面细分", t_stage)

	# ===== ③ 顶点 → 相邻三角形索引表（vert_faces，分片扫描）=====
	# 对偶贴片的“边”由它定：贴片 v 的对偶多边形顶点 = 它周围一圈三角形的重心
	var total := verts.size()
	# 预分配 Array[PackedInt32Array]：整数键 Dictionary 每三角要 3 次哈希+装箱，
	# 预分配数组按索引直达，热循环零哈希。
	var vert_faces: Array = []
	vert_faces.resize(total)
	for i in total:
		vert_faces[i] = PackedInt32Array()
	var tri_at := 0
	while tri_at < tris.size():
		var endi := mini(tri_at + SLICE_CHECK_STRIDE, tris.size())
		for ti in range(tri_at, endi):
			var tri := tris[ti]
			vert_faces[tri.x].append(ti)
			vert_faces[tri.y].append(ti)
			vert_faces[tri.z].append(ti)
		tri_at = endi
		# 墙钟切片：每 ~512 项结一次钟，用满本帧就让出
		if Time.get_ticks_msec() - _gen_slice_t0 >= _gen_budget:
			await _slice_yield(26.0 + 4.0 * float(tri_at) / tris.size())

	# 保留拓扑方向表：生成完仍要回答“这个球面点能不能交互”
	_topo_verts = verts
	t_stage = _stage_mark("③邻接面表", t_stage)

	# ===== ④ 覆盖率选区：一整块连通的“可交互区域”（内部全程分帧，30→44%）=====
	# 旧实现：洗牌取前 coverage 比例 → 生成区是满天星的碎孤岛。
	# 新实现见 _select_generated_region：面积精确、单块连通、形状随机自然，
	# 大陆内部的大盆地保留为内陆湖（渲染海色，地形平原）。
	var select_result: Dictionary = await _select_generated_region(
			verts, tris, coverage, 30.0, 44.0)
	var explored: PackedByteArray = select_result["region"]
	_inland_water = select_result["inland_water"]
	_generated = explored            # 运行期“能否交互”查询表
	_terrain.resize(total)           # 地形等级在阶段 B 逐贴片填充
	# HUD 显示缓存：群系 id / 海拔 / 温湿度（未生成贴片保持 BIOME_NONE / 0）
	_tile_biome.resize(total)
	_tile_biome.fill(BIOME_NONE)
	_tile_elev.resize(total)
	_tile_temp.resize(total)
	_tile_humid.resize(total)
	t_stage = _stage_mark("④覆盖率选区", t_stage)

	# ===== 大陆质心：把“陆地最多的那面”记下来，生成完交给镜头对准 =====
	# 以质心方向为中心的半球承载的可交互贴片最多（半球面积最大化的方向），
	# 镜头对准它 = 玩家一进来先看到大陆。
	_region_center = Vector3.ZERO
	var region_n := 0
	var cc_at := 0
	while cc_at < total:
		var cc_end := mini(cc_at + SLICE_CHECK_STRIDE, total)
		for i in range(cc_at, cc_end):
			if explored[i] == 1:
				_region_center += verts[i]
				region_n += 1
		cc_at = cc_end
		# 质心阶段进度条无变化，用记忆的当前值喂回保持刷新节奏
		if Time.get_ticks_msec() - _gen_slice_t0 >= _gen_budget:
			await _slice_yield(_gen_pct)
	if region_n > 0:
		_region_center = (_region_center / region_n).normalized()
	else:
		_region_center = Vector3.UP # 兜底：全海时面朝北极
	t_stage = _stage_mark("④b大陆质心", t_stage)

	# ===== 阶段 B：对偶贴片 + 颜色 + 网格数组（分帧） =====
	# 二次生成：贴片几何全部重来，旧的选择状态一并清掉（避免索引错位/悬空高亮）
	_tile_polys = []
	deselect()
	var cli := [0.0, 0.0, 0.0] # 气候复用缓冲：[elev, temperature, humidity]，热循环零分配
	# 网格数组精确预分配：Σ贴片角点数 = 3×三角形数（每个三角形的三个角各归属
	# 一块贴片），索引数 = Σ3×(n−2)（凸多边形扇形三角化）。预分配后按索引直写，
	# 免掉逐元素 append 的扩容拷贝——⑤ 阶段最大的单项开销。
	var total_corners := tris.size() * 3
	var mesh_verts := PackedVector3Array()
	var mesh_colors := PackedColorArray()
	mesh_verts.resize(total_corners)
	mesh_colors.resize(total_corners)
	var mesh_indices := PackedInt32Array()
	mesh_indices.resize(3 * (total_corners - 2 * total))
	var vert_cursor := 0 # 已写满的角点数（同时是下一块贴片的顶点基址）
	var idx_cursor := 0  # 已写满的索引数
	for v in total:
		var axis := verts[v] # 已是单位向量
		# 收集该点周围一圈三角形的重心（对偶多边形的顶点）
		var cents: Array[Vector3] = []
		for ti in vert_faces[v]:
			var tri := tris[ti]
			cents.append((verts[tri.x] + verts[tri.y] + verts[tri.z]).normalized())
		# 把相邻面重心按“绕 axis 的方位角”排序，才能连成不自交的多边形。
		# 5/6 个元素的小数组：先算好角度再手写插入排序——比 sort_custom 的
		# GDScript lambda 回调（每贴片 ~11 次脚本调用）快一个数量级。
		var e1: Vector3 = (cents[0] - axis * cents[0].dot(axis)).normalized()
		var e2 := axis.cross(e1)
		var n := cents.size()
		var angs := PackedFloat32Array()
		angs.resize(n)
		for k in n:
			angs[k] = _tangent_angle(cents[k], axis, e1, e2)
		for k in range(1, n):
			var ca := angs[k]
			var cp := cents[k]
			var j := k - 1
			while j >= 0 and angs[j] > ca:
				angs[j + 1] = angs[j]
				cents[j + 1] = cents[j]
				j -= 1
			angs[j + 1] = ca
			cents[j + 1] = cp
		var poly := PackedVector3Array(cents)

		# 缓存贴片边界顶点（单位球面，顺序与 cents 的方位角排序一致）：
		# 点击选中时用它们生成高亮环；索引与 _topo_verts/_terrain 一致
		_tile_polys.append(poly)

		# 贴片颜色：未生成 → 纯海洋底色，不做任何噪声采样（这些贴片没有地形）；
		# 内陆湖 → 海洋色 + 平原地形（“水下也是陆地”）；
		# 其余已生成 → 群系纯色 + 地形明暗
		var center := Vector3.ZERO
		for p in poly:
			center += p
		center = (center / poly.size()).normalized() # 贴片中心方向：噪声与纬度的采样点
		var level := TerrainLevel.NOT_GENERATED
		var col := C_UNGENERATED
		if explored[v] == 1:
			# 气候采样：湖贴片同样采样（HUD 要显示它的海拔/温湿度），
			# 但湖的地形与颜色仍走湖规则——生成结果与此前完全一致。
			_climate_fill(center, cli) # 复用数组，热循环零字典分配
			var elev: float = cli[0]
			var temp: float = cli[1]
			var humid: float = cli[2]
			_tile_elev[v] = elev
			_tile_temp[v] = temp
			_tile_humid[v] = humid
			if _inland_water[v] == 1:
				level = TerrainLevel.FLAT
				col = C_OCEAN
				_tile_biome[v] = 0 # 内陆湖：群系按海洋计（渲染同为海色）
			else:
				level = _terrain_level(elev)
				var biome := _biome_id(elev, temp, humid)
				_tile_biome[v] = biome
				col = _tile_appearance(BIOME_COLORS[biome], level)
		_terrain[v] = level

		# 每个贴片用一组“独占”顶点（不与其他贴片共享）→ 顶点色插值后整片均匀
		var base := vert_cursor
		for k in poly.size():
			mesh_verts[base + k] = poly[k] * PLANET_RADIUS
			mesh_colors[base + k] = col
		# 凸多边形扇形三角化（五/六边形都是凸的）
		for i in range(1, n - 1):
			mesh_indices[idx_cursor] = base
			mesh_indices[idx_cursor + 1] = base + i
			mesh_indices[idx_cursor + 2] = base + i + 1
			idx_cursor += 3
		vert_cursor += n

		# 让出线程：每 ~512 贴片结一次墙钟，本帧吃满才让（批内零查钟）
		if v % SLICE_CHECK_STRIDE == SLICE_CHECK_STRIDE - 1 or v == total - 1:
			if Time.get_ticks_msec() - _gen_slice_t0 >= _gen_budget:
				await _slice_yield(44.0 + 53.0 * float(v + 1) / total)

	# —— 地形分布统计（顺手把五级各有多少贴片打到日志里，调参数时好对照）——
	var counts := {}
	for lv in _terrain:
		counts[lv] = counts.get(lv, 0) + 1
	var parts := PackedStringArray()
	for lv in TERRAIN_NAMES.size():
		if counts.has(lv):
			parts.append("%s %d" % [TERRAIN_NAMES[lv], counts[lv]])
	var ungenerated: int = counts.get(0, 0)
	print("地形分布：", "，".join(parts), "（已生成 ", total - ungenerated, " / ", total, " 贴片）")
	t_stage = _stage_mark("⑤对偶贴片+网格", t_stage)

	# ===== ⑥ 收尾：组装 ArrayMesh（让 97% 先画出来再干最后一下）=====
	_progress(97.0)
	await get_tree().process_frame
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = mesh_verts
	arrays[Mesh.ARRAY_COLOR] = mesh_colors
	arrays[Mesh.ARRAY_INDEX] = mesh_indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_progress(100.0)
	t_stage = _stage_mark("⑥组装ArrayMesh", t_stage)
	return mesh


var _gen_pct := 0.0 # 最近一次喂给进度条的百分比（无进度阶段让帧时原样喂回）

func _progress(percent: float) -> void:
	_prog_calls += 1  # 性能打点：每次进度刷新≈一次分帧 await，用于统计各阶段帧数
	_gen_pct = percent
	if _menu != null:
		_menu.set_progress(percent)


# 性能打点：打印一个生成阶段的耗时与分帧次数（_progress≈每帧一次），
# 返回当前时刻作为下一阶段计时起点。只打印，不影响任何功能。
func _stage_mark(stage: String, t_prev: int) -> int:
	var now := Time.get_ticks_msec()
	print("[gen] %s：%d ms / %d 帧" % [stage, now - t_prev, _prog_calls])
	_prog_calls = 0
	return now


# —— 墙钟切片三件套：让“每帧干多少活”贴合真实帧率而不是凑整帧空转 ——
# 用法（所有生成热循环同款，“批处理式”：批内零查钟，批尾结一次钟）：
#   while 条件:
#       var 批尾 := 当前数 + SLICE_CHECK_STRIDE
#       while 条件 and 当前数 < 批尾:
#           ...一个小步的工作...
#       if Time.get_ticks_msec() - _gen_slice_t0 >= _gen_budget:
#           await _slice_yield(当前进度)
var _gen_frame_ms := 16.0    # 实测帧间隔（指数平滑，初值按 60Hz 估）
var _gen_slice_t0 := 0       # 本帧切片起点
var _gen_slice_prev_t0 := 0  # 上一帧切片起点（用来量真实帧间隔）


# 让帧归来时调用：以两帧切片起点的间隔平滑出帧率节奏
func _slice_begin() -> void:
	var now := Time.get_ticks_msec()
	if _gen_slice_prev_t0 > 0:
		var dt := float(now - _gen_slice_prev_t0)
		if dt >= 1.0 and dt < 500.0: # 过滤进度条被窗口阻塞之类的时间毛刺
			_gen_frame_ms = lerpf(_gen_frame_ms, dt, 0.3)
	_gen_slice_prev_t0 = now
	_gen_slice_t0 = now
	_gen_budget = clampi(roundi(_gen_frame_ms * GEN_SLICE_RATIO), GEN_SLICE_MIN_MS, GEN_SLICE_MAX_MS)


# 墙钟切片的检查写法有讲究：Time.get_ticks_msec() 绑定调用 ~1-2μs、
# GDScript 调 GDScript 的函数 ~0.5μs——百万次的热循环里两者都是语言税。
# 因此采用“批处理式”结构：内层 for 连续处理 ~SLICE_CHECK_STRIDE 项
# （零检查），批尾才结一次钟（批 = 512 项，最长超支 ~0.3-3ms 可接受）。
const SLICE_CHECK_STRIDE := 512
var _gen_budget := 11           # 当前帧的计算墙钟预算 ms（_slice_begin 按帧率刷新）


# 让出一帧并刷新进度（协程：切片位点用 await 调用）。
# 归来（下一帧起点）即重置切片起点——所有位点统一在“归来帧”重新计费，
# 阶段边界处的首帧不会被上一阶段的旧计时冤枉成超时。
func _slice_yield(p: float) -> void:
	_progress(p)
	await get_tree().process_frame
	_slice_begin()


# —— 贴片查询：交互与地形 ——
# 传入球面某点的方向（世界坐标方向，自动归一化）。实现：线性扫描细分网格
# 顶点，取与 dir 点积最大者即最近贴片。163842 个点的一次扫描对偶发点击
# 足够快（<10ms）；将来交互变频繁时再换空间哈希，接口不用改。
func _nearest_tile(world_dir: Vector3) -> int:
	var dir := world_dir.normalized()
	var best := 0
	var best_dot := -2.0
	for i in _topo_verts.size():
		var d := _topo_verts[i].dot(dir)
		if d > best_dot:
			best_dot = d
			best = i
	return best


# 该方向的贴片是否已生成（可点击、可降落）：
# 未生成区域是“整块大陆以外的空白海面”——没有地形，当然也不可交互。
func is_tile_interactable(world_dir: Vector3) -> bool:
	if _generated.is_empty():
		return false # 还没生成过任何星球 → 全部不可交互
	return _generated[_nearest_tile(world_dir)] == 1


# 该方向贴片的地形等级（TerrainLevel）：
# 未生成 → NOT_GENERATED（顺应“不可探索区域没有地形”的设计）；
# 已生成 → 平原 / 小丘陵 / 大丘陵 / 山区 / 不可逾越（海洋贴片的地形是平原）。
func get_tile_terrain(world_dir: Vector3) -> int:
	if _generated.is_empty():
		return TerrainLevel.NOT_GENERATED
	return _terrain[_nearest_tile(world_dir)]


# —— 点击选区：屏幕点按 → 贴片索引 → 白光内溢高亮环 ——
# 设计约定（与需求确认过的语义一致）：
#   · 点到星空（射线没碰到星球）→ 取消选中；
#   · 点到未生成区域（不可探索的空白海面）→ 取消选中；
#   · 生成区内的海洋贴片可以选中；
#   · 点到已选中的同一块 → 保持选中（重建同一枚环，无副作用）。

func _on_view_tapped(screen_pos: Vector2) -> void:
	# 相机射线与单位球的解析求交（不需要物理体）：
	# |from + t·dir|² = 1 → t² + 2b·t + c = 0，b = from·dir，c = |from|² − 1
	var from := _orbit.cam.project_ray_origin(screen_pos)
	var dir := _orbit.cam.project_ray_normal(screen_pos)
	var b := from.dot(dir)
	var c := from.length_squared() - 1.0
	var disc := b * b - c
	if disc < 0.0:
		deselect()   # 穿过星空（射线与球不相交）→ 取消
		return
	var t := -b - sqrt(disc)
	if t <= 0.0:
		deselect()
		return
	var tile := _nearest_tile((from + dir * t).normalized())
	if _generated.is_empty() or _generated[tile] != 1:
		deselect()   # 未生成的空白海面没有地形数据，不可选中
		return
	select_tile(tile)


# 选中某块贴片（后续玩法层可直接调用）。重复选中同一块等价于保持选中。
func select_tile(tile: int) -> void:
	if _tile_polys.is_empty() or tile < 0 or tile >= _tile_polys.size():
		return
	_selected_tile = tile
	_rebuild_selection_ring()
	_update_hud(tile)


# 取消选中：状态位清零、环隐藏（mesh 留着，下次选中直接复用节点）、HUD 收起。
func deselect() -> void:
	_selected_tile = -1
	if _selection_ring != null:
		_selection_ring.visible = false
	if _hud != null:
		_hud.hide_panel()


# —— HUD 内容组装：贴片编号 / 地形 / 群系 / 海拔 / 温湿度 / 经纬度 ——
# 数据源：阶段 B 逐贴片缓存的 _terrain / _tile_biome / _tile_elev 等；
# 经纬度由贴片中心方向反算（lat = asin(y)，lon = atan2(z, x)，赤道零纬度、
# x 正方向为经度零点——世界坐标约定，不对应真实地理）。
func _update_hud(tile: int) -> void:
	# 生成尚未跑到阶段 B 时缓存数组还是空的（只可能来自测试的直接调用），静默跳过
	if _hud == null or _tile_biome.is_empty() or tile >= _tile_biome.size():
		return
	var poly: PackedVector3Array = _tile_polys[tile]
	var center := Vector3.ZERO
	for p in poly:
		center += p
	center = (center / poly.size()).normalized()
	var lat := rad_to_deg(asin(clampf(center.y, -1.0, 1.0)))
	var lon := rad_to_deg(atan2(center.z, center.x))
	var lat_str := "%.1f°%s" % [absf(lat), "N" if lat >= 0.0 else "S"]
	var lon_str := "%.1f°%s" % [absf(lon), "E" if lon >= 0.0 else "W"]
	var biome := _tile_biome[tile]
	var biome_str: String = "未生成" if biome == BIOME_NONE else BIOME_NAMES[biome]
	var lake_mark := "（内陆湖）" if _inland_water[tile] == 1 else ""
	var lines := PackedStringArray([
		"地形：%s" % TERRAIN_NAMES[_terrain[tile]],
		"群系：%s%s" % [biome_str, lake_mark],
		"海拔：%.3f" % _tile_elev[tile],
		"温度：%.2f　湿度：%.2f" % [_tile_temp[tile], _tile_humid[tile]],
		"经纬度：%s，%s" % [lat_str, lon_str],
	])
	_hud.show_tile("贴片 #%d" % tile, lines)


# 生成选中高亮环：
# 沿贴片边界做两个同向内收的环——外沿（亮边）与内沿（透明端）
# 连成一条细环带，几何半径与地表完全一致（不抬升），
# 由 shader 的 vertex 深度偏移避免 z-fighting——零视差错位。
# 顶点色 a = 径向参数（外沿 0 / 内沿 1），shader 里 pow(1−a) 做向内衰减。
# 环宽随贴片半径而定 → 拉远拉近观感一致；环内收 → 光不会溢到相邻地块。
func _rebuild_selection_ring() -> void:
	const EDGE_INSET := 0.05  # 外沿自贴片边界向内收（贴片半径的比例）
	const GLOW_LENGTH := 0.44 # 光晕向内延伸到的比例（决定晕带厚度）
	const LIFT := 1.0         # 环带与地表共面（=1.0），深度避让交给 shader 的视线偏移
	const MIN_BAND_PX := 4.0  # 屏幕像素兜底：整球远观时晕带至少约这么宽（屏上）
	const BAND_MAX_RATIO := 0.55  # 晕带最厚不超过贴片半径的比例，不吞地块
	var poly: PackedVector3Array = _tile_polys[_selected_tile]
	var axis := _topo_verts[_selected_tile]  # 贴片中心方向（单位向量）
	var count := poly.size()
	# 贴片外接半径（世界单位）：中心方向到边界角点的最大弦长
	var tile_r := 0.0
	for e in poly:
		tile_r = maxf(tile_r, axis.distance_to(e))
	# 光晕带宽 = max(贴片半径比例, 屏幕像素兜底换算的世界宽度)，封顶 BAND_MAX_RATIO。
	# 像素换算：像素/世界 = 视口高 / (2·tan(fov/2)·相机到地表距离)
	var cam_surf := maxf(0.2, _orbit.dist - PLANET_RADIUS)
	var px_per_world := get_viewport().get_visible_rect().size.y \
			/ (2.0 * tan(deg_to_rad(_orbit.cam.fov * 0.5)) * cam_surf)
	var band_world := MIN_BAND_PX / maxf(1.0, px_per_world)
	var inner_ratio := clampf(maxf(GLOW_LENGTH, band_world / tile_r), EDGE_INSET * 2.0, BAND_MAX_RATIO)
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	for k in count:
		var edge := poly[k]
		# 从中心方向向边界方向插值：外沿几乎贴边（亮边），内沿更深（透明端）
		var outer := axis.lerp(edge, 1.0 - EDGE_INSET).normalized() * PLANET_RADIUS * LIFT
		var inner := axis.lerp(edge, 1.0 - inner_ratio).normalized() * PLANET_RADIUS * LIFT
		verts.append(outer)
		colors.append(Color(1.0, 1.0, 1.0, 0.0))  # t=0 → 边缘全亮
		verts.append(inner)
		colors.append(Color(1.0, 1.0, 1.0, 1.0))  # t=1 → 内沿完全透明
	# 环带四边形：外环与内环按同一角度序连接；顶点布局 [O0,I0,O1,I1,…]
	# 注意 Godot 的正面三角形是順时针绕序：这里先按"从外看顺时针"连接，
	# 保证 cull_back 下环带不被剔除（此前反序导致整环消失，已用截图实证）。
	for k in count:
		var k1 := (k + 1) % count
		indices.append(k * 2)
		indices.append(k1 * 2 + 1)
		indices.append(k1 * 2)      # 半环带 1：外沿(当前)→内沿(下一角)→外沿(下一角)
		indices.append(k * 2)
		indices.append(k * 2 + 1)
		indices.append(k1 * 2 + 1)  # 半环带 2：外沿(当前)→内沿(当前)→内沿(下一角)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var ring_mesh := ArrayMesh.new()
	ring_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if _selection_material == null:
		_selection_material = ShaderMaterial.new()
		_selection_material.shader = SELECTION_RING_SHADER
	if _selection_ring == null:
		_selection_ring = MeshInstance3D.new()
		_selection_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_selection_ring)
	_selection_ring.material_override = _selection_material
	_selection_ring.mesh = ring_mesh
	_selection_ring.visible = true


# 向量 p 在切平面（以 axis 为法线、e1 为 0° 参考方向）上的方位角
func _tangent_angle(p: Vector3, axis: Vector3, e1: Vector3, e2: Vector3) -> float:
	var pp := (p - axis * p.dot(axis)).normalized()
	return atan2(pp.dot(e2), pp.dot(e1))
