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
const StarDomeScript := preload("res://star_dome.gd")
const SunQuadScript := preload("res://sun_quad.gd")
const WorldMenuScript := preload("res://world_menu.gd")
const BiomeAtlasScript := preload("res://biome_atlas.gd")
const HillsAtlasScript := preload("res://hills_atlas.gd")
const SELECTION_RING_SHADER := preload("res://selection_ring.gdshader")
const ATMOSPHERE_SHADER := preload("res://atmosphere.gdshader")
const HILLS_SHADER := preload("res://planet_hills.gdshader")
const RIVER_SHADER := preload("res://planet_rivers.gdshader")
# level：递归二分段数，f = 2^level → 贴片总数 = 10·4^level + 2
# level=7 → f=128 → 163842 个贴片
const LEVEL := 6
# 【性能对照已测毕】临时切成 level=6（40962 贴片，与 planet_demo 对齐）实测：
# headless 纯计算 558ms，窗口内墙钟 629/724/729ms——与 JS demo 同级（~320ms）
# 属同量级，详见 2026-10 性能对照分析。需要复测时取消下行注释并注释上一行。
#const LEVEL := 6
const SUBDIV := 1 << LEVEL # 每条棱的等分数 f
const PLANET_RADIUS := 1.0
# 大气光晕球壳半径 / 星球半径（1.06 → 壳比星球大 6%，光晕只出现在轮廓外缘；
# 球壳要包住辉光带的整个外尾：ATMOSPHERE_RADIUS ≈ 1 + 0.9 × band_width，
# 否则带的尾巴被壳剪影硬切出一圈亮边——band_width 调整时这里必须跟着动）
#
# 取 1.06 的依据：band_width = 0.065（atmosphere.gdshader），带的数学外沿在
# d = 1.065，壳取 1 + 0.9×0.065 = 1.0585 ≈ 1.06 —— 刚好收住带的尾巴
#（尾巴处 a = 0.1 → a³ = 0.001，切口不可见），同时球壳尽量小（透明球壳是
# 大面积加法 pass，壳越小越省填充率）。
const ATMOSPHERE_RADIUS := 1.06
# 大气光晕的透明绘制优先级：必须高于太阳（sun_quad.gd 的 10），
# 对应原版材质队列 辉光 3001 > 太阳 1001（见 _build_atmosphere 的注释）。
const ATMOSPHERE_RENDER_PRIORITY := 20

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
# 未生成区域（覆盖率外）：渲染为「遥远的不可探索深洋」——UV2 指向图集第 8 格
# （Ocean 卡备份），贴图 × macro × 顶点色与已生成海域逐像素一致，覆盖区边界
# 无缝，不再出现与海洋对比强烈的浅蓝死海块；逻辑上它仍属于“未生成”，
# 没有地形数据也不可交互（见 is_tile_interactable）。
# 注：第 8 格与第 0 格都是「水格」→ shader 里同走深海净色（+贴岸近白噪带），
#     两格处理一致，逐像素一致的不变量不受影响。

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

# ---- 气候参数（想调 planetary 外观就改这里）----
# ---- 气候参数（想调 planetary 外观就改这里）----
const SEA_LEVEL := -0.05  # 海平面：海拔低于它的贴片是海洋# 温度场：temperature = cos(纬度) + 噪声扰动 − 海拔制冷，范围 0(极寒)..1(酷热)
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

# ---- 海岸收边参数（ConvertToIsland 思路，见 _climate_fill）----
# 选区（扰动球冠）的边缘带内把海拔往海平面下压：
#   过渡带（角距 θ−TRANS·θ .. θ）内海拔线性压向海底；
#   角距越过 θ−KILL·θ 之后完全压到水下（SEA_LEVEL − DEPTH）。
# 效果：交互区最外圈永远是海，和区域外的未生成海面无缝相接（大陆架观感），
# 陆地绝不会被“一刀切断”在区域边界上。
const COAST_WIGGLE := 0.22 # key 半径的噪声扰动幅度：海岸犬牙的撕扯强度
const COAST_TRANS := 0.25  # 过渡带宽度 = 区域角距 θ 的比例
const COAST_KILL := 0.08   # 完全水下的带宽 = θ 的比例
const COAST_DEPTH := 0.06  # 压死后的海底深度（海平面再往下压这么多）

# ---- 近岸白噪带（参考 24-OceanShoreNoise.md，实现见 docs/planet_textures_plan.md §3⑥）----
# 原版近岸“白色噪声” = 贴岸一圈的「色卡细颗粒 × WorldMacro + 白抬升」，深海被权重混成
# 常量深海。不照抄它的高程公式（E∈[-320,0]）：我们的覆盖率边界把最外圈强行压到
# SEA_LEVEL−COAST_DEPTH 的海底，高程做白带会沿世界边缘出现一圈**假白环**，破坏刚做好的
# 覆盖区无缝。改为**离岸距离场**：贴片图上从陆地贴片多源 BFS（只在开放水域传播，
# 海冰既不算岸也不传播），逐角点取汇于该角 3 贴片的距离均值 → 归一化 shore∈[0,1]
# （1=岸线，0=深海），由 ⑤c 写进水贴片顶点色 a。深海 shore=0 → 走净色纯色逐位不变；
# 陆地 a 仍是岩石量，shader 用图集格号区分，两义互不污染。
const SHORE_BAND_HOPS := 4.0 # 带宽（离岸格数）：1 格 ≈1.1°，4 格 ≈4.4° ≈ 参考图雾斑宽度（仍够不到覆盖区强制浅滩外缘，无假白环）
# 小水域剔除阈值：完全被已生成陆地包住的连通水域 ≤ 这么多贴片 → 生成期填成
# 陆地。原因：微型内陆湖整湖都落在 4 跳白噪带里 → 整片泛白像白斑
# （temp/sea_wave*.png）。与未生成深洋（BIOME_NONE）连通的分量是真海/内海，
# 永不剔除；11 片 ≈ 截图案例上限（链状湖 11 片），更大的湖保留。
const MIN_LAKE_TILES := 11
const LAKE_FILL_ELEV := 0.02  # 填湖后的海拔 = 海平面+0.02：判成陆地、地形 FLAT 不长丘陵
# 有效带宽自适应（⑤b0b）：白噪带视觉宽度 = 水域半径（分量最大离岸跳数）× 比例，
# 下限保证最小湖也有岸线感的一圈、上限 = SHORE_BAND_HOPS（大洋/内海封顶，观感不变）。
# 0.35（用户拍板）→ 半径 ≤4 跳的小湖雾带只贴岸 1~2 圈，湖心回归深蓝净色，
# 不再整湖被白雾淹没（temp/sea_wave3.png）。
const LAKE_RING_RATIO := 0.35
const MIN_LAKE_RING_HOPS := 1.5

var _elev_noise: FastNoiseLite   # 海拔噪声
var _humid_noise: FastNoiseLite  # 湿度噪声（决定沙漠/森林）
var _temp_noise: FastNoiseLite   # 温度扰动噪声（洋流/大陆气候，撕碎纬度带）
var _continent_noise: FastNoiseLite # 大陆形状噪声：决定“已生成区域”长在哪
# 地形等级查询表：贴片索引 → TerrainLevel（NOT_GENERATED 的贴片没有地形）
var _terrain: PackedByteArray = PackedByteArray()
# 区内水域表：贴片索引 → 1(区内海拔<海平面的水域：内海/内陆湖/大陆架，
# 渲染群系海色、地形按海拔自然为平原) 。选区阶段不再产出，⑤ 循环里派生。
var _inland_water: PackedByteArray = PackedByteArray()
# 小水域剔除计数（⑤b0 填湖统计）：冒烟护栏用来断言剔除确实发生且规模合理
var _lake_culled := 0
# —— HUD 显示用的逐贴片缓存（阶段 B 填充，二次生成时重置）——
var _tile_biome := PackedByteArray()    # 群系 id（BIOME_NONE=未生成）
var _tile_elev := PackedFloat32Array()  # 海拔噪声值
var _tile_temp := PackedFloat32Array()  # 温度
var _tile_humid := PackedFloat32Array() # 湿度

var _menu: CanvasLayer           # “创建世界”菜单 UI
var _rain_shift := 0.0           # 本次生成的湿度整体偏移
var _temp_shift := 0.0           # 本次生成的温度整体偏移
var _prog_calls := 0             # 性能打点：_progress 调用次数（≈分帧 await 帧数）
# 区域（球冠）中心方向（单位向量）：**输入**而非输出——生成请求时取镜头
# 正对方向，大陆永远围着玩家当前看到的半球长；生成完镜头 focus_on 同一方向，
# 无需再做事后质心校准。
var _region_center := Vector3.UP
# —— 海岸收边状态（选区阶段设置，_climate_fill 消费；只服务生成管线）——
var _cap_shore := false          # 是否启用收边（100% 档整球无边 → 关）
var _cap_center := Vector3.UP    # 球冠中心方向（同 _region_center）
var _cap_cos_lerp0 := 1.0        # 收边带内边界：cos 角距低于它开始下压海拔
var _cap_cos_kill := -1.0        # 收边带外边界：cos 角距低于它完全压到水下
# 当前装配的星球模型：再次生成时先撤旧的，避免两颗星球叠在一起渲染
var _mesh_instance: MeshInstance3D
# 未生成区域查询用的拓扑缓存（方向→贴片）。全部指向单位球面。
var _topo_verts: Array[Vector3] = []
var _generated: PackedByteArray = PackedByteArray() # 贴片是否已生成（可交互）
var _generated_ids := PackedInt32Array()  # 已生成贴片索引（河流/统计热循环只遍历这一份）

# —— 点击选区：拾取 + 选中高亮 ——
# 每块贴片的边界顶点（单位球面）：阶段 B 建网格时顺手缓存，
# 点击选中时据此生成“向内溢出的白色光晕环”（见 _rebuild_selection_ring）。
var _tile_polys: Array[PackedVector3Array] = []
# 每块贴片的中心方向（单位球面，与 _tile_polys 同序同生命周期）：
# 阶段 B 同一处缓存，丘陵 quad 按它定位（见 _build_hills_meshes）。
var _tile_centers := PackedVector3Array()
# —— 丘陵/山脉贴片层（第 2 期）：按 TerrainLevel 拆低丘/高山两个实例 ——
# 拆分原因见 docs/planet_rivers_plan.md §9.4/§9.7.5：河流要压住低丘、但被高山压住。
var _hills_low_instance: MeshInstance3D = null   # SmallHills / LargeHills，priority 0
var _hills_high_instance: MeshInstance3D = null  # Mountainous / Impassable，priority 2
var _hills_atlas: Dictionary = {} # 丘陵图集（惰性打包一次，换种子不重做）

# —— 河流层（第 3 期一期）：贴片中心线水网 + 独立 ribbon mesh ——
# 邻接 N×6（不足 6 个用 -1 填充）由 ⑤b 的 tri_tiles + vert_faces 建出；
# 水文只在已生成区（_generated==1）内跑，水面是终点。
var _tile_neighbors := PackedInt32Array()
var _tile_neighbor_count := PackedByteArray()
var _river_edges := PackedInt32Array() # 扁平 [from, to, from, to, ...]，下游方向
var _river_edge_count := 0
# 水文中间结果（调试/测试用；parent=-1 表示水面种子）
var _river_parent := PackedInt32Array()
var _river_flow := PackedFloat32Array()
var _river_filled := PackedFloat32Array()
var _river_instance: MeshInstance3D = null
var _river_material: ShaderMaterial = null
var _river_stats: Dictionary = {}
# —— 渲染派生数据（§20）：河宽分级 + 分支链 ——
var _river_half_width := PackedFloat32Array()   # 每贴片半宽，0 = 非河网
var _river_child_count := PackedInt32Array()    # 河网内上游支流条数（0=源头，≥2=汇合点）
var _river_down := PackedInt32Array()           # 下游邻居（-1=无河段）
var _river_widest_child := PackedInt32Array()   # 最宽上游支流（汇合点处给 miter 定向）
var _river_junctions: PackedInt32Array = PackedInt32Array()  # 汇合点节点（放圆角接头）
var _river_branch_nodes := PackedInt32Array()   # 分支链节点串（扁平）
var _river_branch_offsets := PackedInt32Array() # CSR 偏移，长度 = 链数 + 1
var _river_branch_n := 0
var _river_render_stats: Dictionary = {}
var _selected_tile := -1                  # 当前选中贴片索引；-1 = 未选中
var _orbit: OrbitCamera                   # 轨道相机（点按事件从这里进来）
var _selection_ring: MeshInstance3D       # 选中环：独立实例，切换选中时重建其 mesh
var _selection_material: ShaderMaterial   # 选中环材质（白光向内衰减，无呼吸）
var _hud: TileHud                         # 贴片信息 HUD：选中贴片时亮出，取消选中即隐藏
var _star_dome: StarDome                  # 背景星空：代码构建（种子驱动，见 star_dome.gd）
var _sun_quad: SunQuad                    # 太阳：相机相对 quad + 零贴图加法 shader（见 sun_quad.gd）
# 太阳方向：**唯一数据源**（规划文档 §5）。期 1 只有太阳本体消费它；
# 期 3 的昼夜联动（大气日照侧、地表明暗）也从这一个向量派生 ——
# 与原版「先定 sunDir，再让光/太阳/星空全部从它派生」同构。
var _sun_dir := Vector3.FORWARD
var _music: AudioStreamPlayer             # 背景音乐（These_Lands.ogg）：星球生成完毕后才开始播
var _atmosphere: MeshInstance3D           # 星球大气光晕：半径 1.12× 的球壳（见 atmosphere.gdshader）

# —— 生态色卡图集（一次性运行期打包，见 biome_atlas.gd / docs/planet_textures_plan.md）——
# 结果缓存：换种子重建星球只重铺网格，不重做图集。
var _biome_atlas: Dictionary = {}
# 图集 8 个格子的原点 UV（[0..6]=生态色卡按 BIOME_NAMES 顺序，
# [7]=Ocean 卡备份 = 未生成深洋）：网格构建（⑤ 阶段写 UV2）与材质装配都要用，
# _ensure_biome_atlas 里一并回填。
var _biome_cell_origins: Array[Vector2] = []


# 图集惰性装配：build 网格与材质装配都会兜底调用（同 star_dome 的 _ensure_* 风格）
func _ensure_biome_atlas() -> Dictionary:
	if _biome_atlas.is_empty():
		_biome_atlas = BiomeAtlasScript.build()
		_biome_cell_origins = _biome_atlas["cell_origins"]
	return _biome_atlas


# —— 第 2 期：丘陵/山脉手绘贴片层（规划 §4 步骤 5-6，参考 22-PlanetTextures.md §6）——
# 参数表（集中调参，出截图后逐轮调）：
const HILLS_OFFSET := 0.005   # quad 离球面高度（×R）：原版同值防 z-fighting；过大 limb 会浮空
const QUAD_SIZE_MIN := 0.9    # quad 边长 / 平均贴片宽下限（原版 BaseSizeRange 0.9–1.1）
const QUAD_SIZE_MAX := 1.1
# 球面位置抖动上限（× 平均贴片宽，按地形等级递减：小山最散、大山最贴中心——原版 §6.2 表）
const JITTER_SMALL_HILLS := 0.37
const JITTER_LARGE_HILLS := 0.20
const JITTER_HIGH := 0.08 # 山区 / 不可逾越同值

# —— 河流层参数（第 3 期做数据与图层；§20 二期改为按流量分级河宽）——
# 几何半径 1.0（贴地），深度避让靠 shader 的视线偏移；详见 docs/planet_rivers_plan.md §9.7 / §20。
const RIVER_MIN_WIDTH_PX := 1.6   # 屏幕最小宽度（只兜最细的支流，不再让全网红一样粗）
# 屏幕最大宽度默认关闭（0 = 不封顶）：实测近景下这类上限会把干/支一起压到
# 同一条带上（半宽区间整体落在膝点以上 → 压缩成 1.7×），等于把几何里做好的
# 分级又抹平了。宽度已经在几何层按贴片尺度过一遍（§23.2），远看不需要再封。
# 真要封，必须往下调 `RIVER_MIN_WIDTH_PX` 一起调，别单独开这个。
const RIVER_MAX_WIDTH_PX := 0.0
const RIVER_DEPTH_BIAS := 0.004
const RIVER_MAX_ARC_DEG := 2.5
const RIVER_COLOR := Color(0.20, 0.48, 0.78, 1.0)
# —— 河宽分级（§20.6 / §21 P2）：半宽由节点流量 Q 决定，宽度烘到几何里，shader 不再展开 ——
# Q 沿下游单调不减（§7.3 不变量）→ 半宽也单调不减，不会出现「粗—细—粗」。
# 映射在对数空间做：half = exp(lerp(ln MIN, ln MAX, t))，t 由 ln Q 在 [P5, P99] 上归一化。
# 等价于幂律 half ∝ Q^b（b 由数据自动定出，约 0.35–0.45），正是水力学里的
# 「河宽 ∝ Q^0.5」；线性刻度 + clamp 会把流量前 10% 全压成同一宽度（§21.1 实测 12%），
# 对数刻度在高流量段天然保留分辨率，只有 P99 以上才顶到上限。
# —— 宽度尺度以「贴片」为准，不以「星球」为准 ——
# level 6 贴片：边长 a=0.01087、对边宽 L=0.01882。玩法上河不能吃掉太多陆地
# （玩家降落后要发展，靠河流发电但陆地不能太小），所以干流全宽上限压到
# 0.0064 = 34% L（改造前是 0.0140 = 74% L，几乎占满一整个贴片）。
# 测试里有硬护栏：2 × 实测最大半宽 / L ≤ 0.40。
const RIVER_HALF_MIN := 0.00095       # 最细支流半宽 = 0.050 L（全宽 10% L）
const RIVER_HALF_MAX := 0.00320       # 最粗干流半宽 = 0.170 L（全宽 34% L，干/支 3.4×）
const RIVER_WIDTH_Q_LO_PCT := 0.05    # 宽度下端点对应的 Q 分位
const RIVER_WIDTH_Q_HI_PCT := 0.99    # 宽度上端点对应的 Q 分位
const RIVER_MITER_MAX_RATIO := 1.4    # miter 偏移上限（×半宽），尖角只切角不爆刺
# —— 形状后处理（§21 P0/P3/P4）——
# 折角：路径沿六边形网格的边走，方向量化到 60° 整数倍（实测 p90 转角 61.6°）。
# Chaikin 角切 2 次 → 转角 p90 降到 16°、最大 19°，而端点是钉住的，
# 所以链两端的切线方向完全不变（汇合点接头按端切线算，不受影响）。
const RIVER_SMOOTH_ITERS := 2         # Chaikin 迭代次数（0 = 关闭）
const RIVER_TIP_LEN_DEG := 3.0        # 源头渐细/渐隐的弧长（度）
const RIVER_TIP_TAPER := 0.30         # 源头最末端的半宽比例
# 河口：ribbon 沿(最后陆地片→水域片)方向一直画到 0.70（岸线在 0.5 处），也就是
# **一定跨过岸线**；跨出去的那截不靠几何收口，而是由下面的「岸线裁剪」逐像素裁掉。
# 为什么必须跨过去：六边形海岸是锯齿，河心与岸线的交点落在哪儿取决于河流的角度，
# 靠摆一个端点或圆头去"刚好贴住"岸线永远会有缝或有凸出。
const RIVER_MOUTH_PAST := 0.70        # 河口端点的位置（0.5 = 岸线；> 0.5 = 伸进水面）
const RIVER_MOUTH_LEN_DEG := 0.6      # 河口喇叭口弧长（度）
const RIVER_MOUTH_FLARE := 1.15       # 入海口半宽放大倍数（做过头会像码头）
# —— 岸线裁剪（§24）——
# 地表是「每片贴片一个多边形」，它的边就是 _tile_polys 里相邻两个角点之间的直弦。
# 所以最后一块陆地贴片朝水的每条边，都唯一确定一个「过球心 + 该边」的平面，
# 平面与球面的交线就是那条海岸线本身。把「到岸线的有符号距离」烘进 COLOR.g
# （0.5 = 岸线，< 0.5 = 陆地侧，> 0.5 = 水域侧，0 = 深在陆地 = 哨兵），
# fragment 里把水域侧裁掉 —— 河道正好在陆地的边线上收口，与海岸严丝合缝，
# 而且不需要为裁剪新增任何三角形（对导出微信小游戏的性能最友好）。
const RIVER_COAST_SCALE := 0.02        # COLOR.g 编码量程：±0.02 世界单位（≈±1.15°≈2 个贴片）
# 汇合点圆角接头：半径 = 该点半宽（圆角 join 的定义），只补两条正截面之间的夹角。
const RIVER_JOIN_SEG := 14            # 圆弧边数（14 边时弦高 < 2.5% 半径，看不出多边形）
# 产流/汇流参数（一期初值；先看日志里的河段密度/Q，再按截图调）
const RIVER_OROGRAPHIC := 0.8
const RIVER_PET_MIN := 0.05
const RIVER_PET_MAX := 0.65
const RIVER_PET_EXP := 1.4
const RIVER_SNOW_FADE_LO := 0.05
const RIVER_SNOW_FADE_HI := 0.05
const RIVER_SLOPE_NORM := 0.25
const RIVER_RUNOFF_FLAT := 0.25
const RIVER_RUNOFF_STEEP := 0.85
const RIVER_FILL_EPS := 1e-6
# priority-flood 精确分桶队列的桶数。filled 单调不减，桶内再按
# (filled, tile) 精确取最小；实测最大桶只有几十个元素。
const RIVER_FLOOD_BUCKETS := 4096
# 河段阈值与选边（A 方案，见 docs/planet_rivers_plan.md §18）：
# 先低阈值拿候选水网，再用“整树规模 + 叶枝长度”两级过滤去掉小短线。
# 不再用 RIVER_MIN_Q / RIVER_DENSITY 的隐式除法：那个 0.15 不是实际密度。
const RIVER_SOURCE_QC := 1.0          # 候选源阈值；一期基线是 4.0
const RIVER_TREE_MIN_EDGES := 8       # 保留树的最小边数（1 边 = 1 贴片河段）
const RIVER_BRANCH_MIN_EDGES := 4     # 保留叶枝的最小边数
const RIVER_FILTER_MAX_PASSES := 64   # 整树/短枝交替过滤的安全上限


# 丘陵图集惰性装配（一次打包，换种子不重做——与 biome 图集同策略）
func _ensure_hills_atlas() -> Dictionary:
	if _hills_atlas.is_empty():
		_hills_atlas = HillsAtlasScript.build()
	return _hills_atlas


# 构建丘陵贴片网格（第 2 期核心）：每个 terrain ≥ 小丘陵 的贴片，在其中心方向
# 加抖动后的位置上方贴一个切线 quad（alpha 混合渲染，见 planet_hills.gdshader）。
# · 随机性走独立 RNG（seed ^ "HILL"）：不碰地形/气候随机流 → 主生成确定性不破坏；
#   quad 数组只依赖 (world_seed, _terrain, _tile_centers) → 同种子重建逐位一致。
# · 一次同步构建（30% 档 ~3.7k quad、100% 档 ~12k quad，毫秒级，不进分帧热路径）。
func _build_hills_meshes(world_seed: int) -> Dictionary:
	var hills := _ensure_hills_atlas()
	var cells: Array[Vector2] = hills["cell_origins"]
	var sprite_uv: Vector2 = hills["sprite_uv"]
	var variant_uv := sprite_uv * 0.5 # 每格 2×2 变体 = 半个 sprite
	var rng := RandomNumberGenerator.new()
	rng.seed = world_seed ^ 0x48494c4c # "HILL"：独立随机流（同 star_dome.build 语义）
	var total := _terrain.size()
	# 平均贴片宽（单位球等面积圆直径 = 4/√N，弧度 × R 换算世界单位）：与原版
	# averageTileSize 同语义，quad 边长与球面抖动都以它为尺
	var avg_tile := 4.0 / sqrt(float(total))
	# 低丘 / 高山各一组数组：一次 RNG 遍历分别追加，保持同种子逐位一致。
	# 河流层要插在两者之间（低丘 0 → 河流 1 → 高山 2），所以不能合成一个 mesh。
	var low_verts := PackedVector3Array()
	var low_uvs := PackedVector2Array()
	var low_indices := PackedInt32Array()
	var high_verts := PackedVector3Array()
	var high_uvs := PackedVector2Array()
	var high_indices := PackedInt32Array()
	var low_quad_n := 0
	var high_quad_n := 0
	for v in total:
		var lv: int = _terrain[v]
		if lv < TerrainLevel.SMALL_HILLS:
			continue # 平原 / 水域 / 未生成（NOT_GENERATED=0、FLAT=1）都不贴
		# 位置抖动：中心 + 随机单位向量 × 量程再归一化（归一化去掉径向分量
		# → 与原版「加 UnitVector3 再 normalize*半径」等效，纯角位置抖动）
		var is_high: bool = lv >= TerrainLevel.MOUNTAINOUS
		var j := JITTER_SMALL_HILLS
		if lv == TerrainLevel.LARGE_HILLS:
			j = JITTER_LARGE_HILLS
		elif is_high:
			j = JITTER_HIGH
		var dir := (_tile_centers[v] + Vector3(rng.randfn(), rng.randfn(),
				rng.randfn()).normalized() * (j * avg_tile)).normalized()
		# 切平面正交基（同 star_dome）：法线 = dir（朝外）
		var helper := Vector3.UP if absf(dir.y) < 0.9 else Vector3.RIGHT
		var x_axis := (helper - dir * helper.dot(dir)).normalized()
		var y_axis := dir.cross(x_axis)
		# 随机绕法线旋转（原版 randomizeRotation 同款，消复制感）
		var angle := rng.randf() * TAU
		var xr := x_axis.rotated(dir, angle)
		var yr := y_axis.rotated(dir, angle)
		# 半边长 = 随机尺寸 × 平均贴片宽 / 2（quad 边长在贴片宽上下浮动）
		var half := rng.randf_range(QUAD_SIZE_MIN, QUAD_SIZE_MAX) * avg_tile \
				* 0.5 * PLANET_RADIUS
		var pos := dir * ((1.0 + HILLS_OFFSET) * PLANET_RADIUS)
		# UV：按地形等级选图集格 + 2×2 变体随机（原版 Rand.Range(0,2) 两轴）
		var cell := cells[lv - TerrainLevel.SMALL_HILLS]
		var o := cell + Vector2(rng.randi_range(0, 1), rng.randi_range(0, 1)) \
				* variant_uv
		if is_high:
			var vi := high_verts.size()
			high_verts.append(pos - xr * half - yr * half)
			high_verts.append(pos + xr * half - yr * half)
			high_verts.append(pos + xr * half + yr * half)
			high_verts.append(pos - xr * half + yr * half)
			# 纹理「上」对齐 +y_axis（与 star_dome 的 quad UV 同构；随机旋转后朝向天然随机）
			high_uvs.append(o + Vector2(0, 1) * variant_uv)
			high_uvs.append(o + Vector2(1, 1) * variant_uv)
			high_uvs.append(o + Vector2(1, 0) * variant_uv)
			high_uvs.append(o + Vector2(0, 0) * variant_uv)
			# 三角形（与 star_dome 的 quad 同构：0,1,2 / 0,2,3）
			high_indices.append(vi)
			high_indices.append(vi + 1)
			high_indices.append(vi + 2)
			high_indices.append(vi)
			high_indices.append(vi + 2)
			high_indices.append(vi + 3)
			high_quad_n += 1
		else:
			var vi := low_verts.size()
			low_verts.append(pos - xr * half - yr * half)
			low_verts.append(pos + xr * half - yr * half)
			low_verts.append(pos + xr * half + yr * half)
			low_verts.append(pos - xr * half + yr * half)
			low_uvs.append(o + Vector2(0, 1) * variant_uv)
			low_uvs.append(o + Vector2(1, 1) * variant_uv)
			low_uvs.append(o + Vector2(1, 0) * variant_uv)
			low_uvs.append(o + Vector2(0, 0) * variant_uv)
			low_indices.append(vi)
			low_indices.append(vi + 1)
			low_indices.append(vi + 2)
			low_indices.append(vi)
			low_indices.append(vi + 2)
			low_indices.append(vi + 3)
			low_quad_n += 1
	print("丘陵贴片层：低丘 ", low_quad_n, " quad，高山 ", high_quad_n,
			" quad（/ ", total, " 贴片）")
	return {
		"low": _make_quad_mesh(low_verts, low_uvs, low_indices),
		"high": _make_quad_mesh(high_verts, high_uvs, high_indices),
		"low_n": low_quad_n,
		"high_n": high_quad_n,
	}


func _make_quad_mesh(verts: PackedVector3Array, uvs: PackedVector2Array,
		indices: PackedInt32Array) -> ArrayMesh:
	if verts.is_empty():
		return null # 该组没有 quad：不建空 surface（Godot 会报 ERR_INVALID_DATA）
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _make_hills_instance(mesh: ArrayMesh, priority: int) -> MeshInstance3D:
	var inst := MeshInstance3D.new()
	inst.mesh = mesh
	var hmat := ShaderMaterial.new()
	hmat.shader = HILLS_SHADER
	hmat.set_shader_parameter("hills_atlas", _ensure_hills_atlas()["texture"])
	hmat.render_priority = priority
	inst.material_override = hmat
	return inst


# ===== 河流层（第 3 期一期）=====
# 数据 → 水文 → ribbon。全部同步执行（40k 贴片量级，先保证可见；后续再按需分帧）。
func _build_river_layer() -> void:
	var t0 := Time.get_ticks_msec()
	_compute_river_edges()
	if _river_edges.is_empty():
		print("河流层：没有河段（产流为 0 或阈值过高），跳过 mesh")
		return
	var mesh := _build_river_mesh_from_branches()
	if mesh == null:
		return
	_river_instance = MeshInstance3D.new()
	_river_instance.mesh = mesh
	_river_material = ShaderMaterial.new()
	_river_material.shader = RIVER_SHADER
	_river_material.set_shader_parameter("river_color", RIVER_COLOR)
	_river_material.set_shader_parameter("min_width_px", RIVER_MIN_WIDTH_PX)
	_river_material.set_shader_parameter("max_width_px", RIVER_MAX_WIDTH_PX)
	_river_material.set_shader_parameter("depth_bias", RIVER_DEPTH_BIAS)
	_river_material.set_shader_parameter("depth_mode", 0)
	# 岸线裁剪的编码量程必须与烘进 COLOR.g 的一致
	_river_material.set_shader_parameter("clip_scale", RIVER_COAST_SCALE)
	# 像素换算必须由 CPU 给：shader 里用 PROJECTION_MATRIX/VIEWPORT_SIZE
	# 反推会算小一个数量级（实测），整条河网被封顶压成 1 像素。
	_update_river_camera_params()
	# 低丘 0 → 河流 1 → 高山 2：河流压住低丘，但被高山压住
	_river_material.render_priority = 1
	_river_instance.material_override = _river_material
	_river_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# 宽度烘进几何后不再是零面积三角形，AABB 直接用 mesh 的真实包围盒
	add_child(_river_instance)
	print("河流层：", _river_edge_count, " 条河段 / ", _river_branch_n, " 条分支链，mesh ",
			mesh.get_surface_count(), " surface，构建 ", Time.get_ticks_msec() - t0, " ms")
	print("河宽：%.4f–%.4f（p50 %.4f，p90 %.4f），幂律 b=%.2f，顶到上限 %.1f%%"
			% [_river_render_stats.get("half_min", 0.0),
			_river_render_stats.get("half_max", 0.0),
			_river_render_stats.get("half_p50", 0.0),
			_river_render_stats.get("half_p90", 0.0),
			_river_render_stats.get("width_exp", 0.0),
			100.0 * float(_river_render_stats.get("half_at_max", 0.0))])
	var vp := get_viewport()
	if vp != null and not vp.size_changed.is_connected(_update_river_camera_params):
		vp.size_changed.connect(_update_river_camera_params)


# 把「焦距（像素）」写进河流 shader：depth=1 处 1 世界单位投影多少像素。
#   focal_px = 0.5·视口高 / tan(fov/2)
# 口径与 orbit_camera.gd 的 _drag_gain、选中环的 px_per_world 完全一致。
#
# 为什么不用 shader 里的 PROJECTION_MATRIX / VIEWPORT_SIZE 反推：
# 实测（Godot 4.7 GL Compatibility）二者乘积与真实光栅高度对不上，算出的
# px_world 比实际小一个数量级，导致 max_width_px 封顶把整条河网压成 1 像素。
# CPU 侧这两个量是确定的，直接给。
func _update_river_camera_params() -> void:
	if _river_material == null:
		return
	var vp := get_viewport()
	if vp == null:
		return
	# 优先用轨道相机（与拖动增益同一台），拿不到再退回视口当前相机
	var cam: Camera3D = _orbit.cam if _orbit != null else null
	if cam == null:
		cam = vp.get_camera_3d()
	if cam == null:
		return
	var vp_h := vp.get_visible_rect().size.y
	if vp_h <= 0.0:
		return
	var focal := 0.5 * vp_h / tan(deg_to_rad(cam.fov * 0.5))
	if focal <= 0.0:
		return
	_river_material.set_shader_parameter("focal_px", focal)


# 产流 → priority-flood → 汇流 → 阈值 → _river_edges（扁平 from/to 对）
func _compute_river_edges() -> void:
	_river_edges = PackedInt32Array()
	_river_edge_count = 0
	_river_parent = PackedInt32Array()
	_river_flow = PackedFloat32Array()
	_river_filled = PackedFloat32Array()
	_river_stats = {}
	var total := _tile_centers.size()
	if total == 0:
		return

	# —— 1) 产流 injection（水面/未生成 = 0）——
	var injection := PackedFloat32Array()
	injection.resize(total)
	injection.fill(0.0)
	var land_n := 0
	var water_n := 0
	var max_land_elev := SEA_LEVEL
	var generated_ids := _generated_ids
	for v in generated_ids:
		if _inland_water[v] == 1:
			water_n += 1
			continue
		land_n += 1
		var elev := _tile_elev[v]
		if elev > max_land_elev:
			max_land_elev = elev
		var temp := _tile_temp[v]
		var humid := _tile_humid[v]
		# 最大正高差：只跟陆地邻居比（水面/未生成不算坡）
		var max_drop := 0.0
		var base := v * 6
		for k in _tile_neighbor_count[v]:
			var u := _tile_neighbors[base + k]
			if u < 0 or _generated[u] != 1 or _inland_water[u] == 1:
				continue
			var drop := elev - _tile_elev[u]
			if drop > max_drop:
				max_drop = drop
		var p := clampf(humid, 0.0, 1.0) \
				* (1.0 + RIVER_OROGRAPHIC * maxf(elev - SEA_LEVEL, 0.0))
		var warm := clampf((temp - T_FREEZE) / (1.0 - T_FREEZE), 0.0, 1.0)
		var pet := RIVER_PET_MIN + (RIVER_PET_MAX - RIVER_PET_MIN) \
				* pow(warm, RIVER_PET_EXP)
		var snow := 1.0 - smoothstep(T_FREEZE - RIVER_SNOW_FADE_LO,
				T_FREEZE + RIVER_SNOW_FADE_HI, temp)
		var slope01 := clampf(max_drop / RIVER_SLOPE_NORM, 0.0, 1.0)
		var r := maxf(0.0, p - pet) * (1.0 - snow) \
				* lerpf(RIVER_RUNOFF_FLAT, RIVER_RUNOFF_STEEP, slope01)
		injection[v] = clampf(r, 0.0, 1.0)

	# —— 2) priority-flood：水面是种子，填平洼地并记录 parent ——
	# 精确分桶队列：filled 单调不减，桶间按高度递增，桶内再按
	# (filled, tile) 扫描取最小，因此与二叉堆的 pop 顺序逐位一致。
	var filled := PackedFloat32Array()
	filled.resize(total)
	filled.fill(0.0)
	var parent := PackedInt32Array()
	parent.resize(total)
	parent.fill(-1)
	var visited := PackedByteArray()
	visited.resize(total)
	# 未生成贴片直接视为已访问，flood 邻居循环里就不必再查 _generated[u]。
	visited.fill(1)
	for v in generated_ids:
		visited[v] = 0
	var order := PackedInt32Array()
	var bucket_head := PackedInt32Array()
	bucket_head.resize(RIVER_FLOOD_BUCKETS)
	bucket_head.fill(-1)
	var bucket_tail := PackedInt32Array()
	bucket_tail.resize(RIVER_FLOOD_BUCKETS)
	bucket_tail.fill(-1)
	var bucket_next := PackedInt32Array()
	bucket_next.resize(total)
	bucket_next.fill(-1)
	var bucket_span := maxf(max_land_elev - SEA_LEVEL, 1e-6)
	var bucket_scale := float(RIVER_FLOOD_BUCKETS - 1) / bucket_span
	# 水面种子 key 全是 SEA_LEVEL：先按 tile 升序全部处理，再把邻居推入桶。
	# 不能直接把种子塞进 bucket 0，否则每次 pop 都会扫描全部种子。
	var seed_tiles := PackedInt32Array()
	for v in generated_ids:
		if _inland_water[v] == 1:
			seed_tiles.append(v)
	if seed_tiles.is_empty():
		# 100% 陆地兜底：最低已生成陆地当虚拟出海口
		var lowest := -1
		var lowest_elev := INF
		for v in generated_ids:
			if _tile_elev[v] < lowest_elev:
				lowest_elev = _tile_elev[v]
				lowest = v
		if lowest >= 0:
			seed_tiles.append(lowest)
			print("河流层警告：没有水面种子，使用最低陆地贴片 ", lowest,
					" 作为虚拟出海口")
	var remaining := 0
	var seed_count := seed_tiles.size()
	for v in seed_tiles:
		filled[v] = SEA_LEVEL
		visited[v] = 1
		order.append(v)
		var seed_fv := filled[v]
		var seed_base := v * 6
		for k in _tile_neighbor_count[v]:
			var u := _tile_neighbors[seed_base + k]
			if u < 0 or visited[u] != 0:
				continue
			visited[u] = 1
			if _inland_water[u] == 1:
				continue
			filled[u] = maxf(_tile_elev[u], seed_fv + RIVER_FILL_EPS)
			parent[u] = v
			var seed_b := int((filled[u] - SEA_LEVEL) * bucket_scale)
			if seed_b < 0:
				seed_b = 0
			elif seed_b >= RIVER_FLOOD_BUCKETS:
				seed_b = RIVER_FLOOD_BUCKETS - 1
			if bucket_tail[seed_b] < 0:
				bucket_head[seed_b] = u
				bucket_tail[seed_b] = u
			else:
				bucket_next[bucket_tail[seed_b]] = u
				bucket_tail[seed_b] = u
			remaining += 1
	var cur_bucket := 0
	while remaining > 0:
		while cur_bucket < RIVER_FLOOD_BUCKETS and bucket_head[cur_bucket] < 0:
			cur_bucket += 1
		if cur_bucket >= RIVER_FLOOD_BUCKETS:
			break
		# 当前桶内精确取 (filled, tile) 最小；桶内通常只有 1–20 个元素。
		var best := -1
		var best_key := INF
		var prev := -1
		var best_prev := -1
		var scan := bucket_head[cur_bucket]
		while scan >= 0:
			var key := filled[scan]
			if key < best_key or (key == best_key and scan < best):
				best = scan
				best_key = key
				best_prev = prev
			prev = scan
			scan = bucket_next[scan]
		if best < 0:
			break
		if best_prev < 0:
			bucket_head[cur_bucket] = bucket_next[best]
		else:
			bucket_next[best_prev] = bucket_next[best]
		if bucket_tail[cur_bucket] == best:
			bucket_tail[cur_bucket] = best_prev
		bucket_next[best] = -1
		remaining -= 1
		order.append(best)
		var pop_fv := filled[best]
		var pop_base := best * 6
		for k in _tile_neighbor_count[best]:
			var u := _tile_neighbors[pop_base + k]
			if u < 0 or visited[u] != 0:
				continue
			visited[u] = 1
			if _inland_water[u] == 1:
				continue
			filled[u] = maxf(_tile_elev[u], pop_fv + RIVER_FILL_EPS)
			parent[u] = best
			var push_b := int((filled[u] - SEA_LEVEL) * bucket_scale)
			if push_b < 0:
				push_b = 0
			elif push_b >= RIVER_FLOOD_BUCKETS:
				push_b = RIVER_FLOOD_BUCKETS - 1
			if bucket_tail[push_b] < 0:
				bucket_head[push_b] = u
				bucket_tail[push_b] = u
			else:
				bucket_next[bucket_tail[push_b]] = u
				bucket_tail[push_b] = u
			remaining += 1

	# —— 3) 倒序汇流：q = injection + 所有上游 ——
	var flow := injection.duplicate()
	for i in range(order.size() - 1, -1, -1):
		var v := order[i]
		var p := parent[v]
		if p >= 0:
			flow[p] += flow[v]

	# —— 4) 候选阈值：Qc 直接给定（A 方案，不再用隐式除法）——
	var qc := RIVER_SOURCE_QC
	var sel := _collect_river_edges(parent, flow, qc, generated_ids)
	if int(sel["tiles"]) == 0:
		# 保底：绝对阈值一条都选不出时，回退到 top 5% 分位。
		# Qc=1 时通常不会走到这里；保留是为了极端干种子仍能看到河。
		var qs: Array[float] = []
		for v in generated_ids:
			if _inland_water[v] == 0 \
					and parent[v] >= 0 and flow[v] > 0.0:
				qs.append(flow[v])
		if not qs.is_empty():
			qs.sort()
			var target := clampi(int(land_n * 0.05), 1, qs.size())
			qc = qs[maxi(0, qs.size() - target)]
			sel = _collect_river_edges(parent, flow, qc, generated_ids)
			print("河流层：绝对阈值过高，回退到 top 5% 分位 Q=", snappedf(qc, 0.001))
	var candidate_edges: PackedInt32Array = sel["edges"]
	var candidate_tiles: int = int(sel["tiles"])
	# 候选图紧凑化：过滤/统计只处理候选贴片（C 通常远小于 total），
	# 不再为每轮过滤分配 total 大小的数组。local_parent=-1 表示入海/父节点未入选。
	var candidate_graph := _build_river_candidate_graph(
			candidate_edges, candidate_tiles, parent, order)
	var cand_tiles: PackedInt32Array = candidate_graph["tiles"]
	var local_parent: PackedInt32Array = candidate_graph["parent"]
	var local_order: PackedInt32Array = candidate_graph["order"]
	var selected := PackedByteArray()
	selected.resize(candidate_tiles)
	selected.fill(1)

	# —— 5) A 方案：整树规模 + 叶枝长度交替过滤 ——
	var filtered := _filter_river_selection(local_parent, local_order, selected)
	var final_selected: PackedByteArray = filtered["selected"]
	var final_sel := _collect_edges_from_selection(cand_tiles, parent, final_selected)
	var edges: PackedInt32Array = final_sel["edges"]
	_river_edges = edges
	_river_edge_count = int(final_sel["tiles"])
	# 保留中间结果：测试可验证 parent 链最终入水、没有环。
	_river_parent = parent
	_river_flow = flow
	_river_filled = filled

	# —— 5b) 渲染派生数据：河宽分级 + 分支链（§20）——
	# 必须在过滤之后算：宽度只关心最终留下的河段，链也只在最终河网上分。
	_compute_river_widths()
	_build_river_branches()

	# —— 6) 统计（日志 + 测试断言用）——
	var max_fill := 0.0
	for v in generated_ids:
		if _inland_water[v] == 0 and parent[v] >= 0:
			max_fill = maxf(max_fill, filled[v] - _tile_elev[v])
	var density := 0.0
	if land_n > 0:
		density = float(_river_edge_count) / float(land_n)
	# 跨高山河段数：高山是分水岭，河网通常绕开；>0 时由 priority 2 压住。
	var high_edges := 0
	for e in _river_edge_count:
		var ha: int = _terrain[_river_edges[e * 2]]
		var hb: int = _terrain[_river_edges[e * 2 + 1]]
		if ha >= TerrainLevel.MOUNTAINOUS or hb >= TerrainLevel.MOUNTAINOUS:
			high_edges += 1
	var river_stats := _river_selection_stats(local_parent, local_order, final_selected)
	_river_stats = {
		"land": land_n,
		"water": water_n,
		"candidate_tiles": candidate_tiles,
		"tree_pruned_tiles": int(filtered["tree_pruned"]),
		"branch_pruned_tiles": int(filtered["branch_pruned"]),
		"filter_passes": int(filtered["passes"]),
		"river_tiles": _river_edge_count,
		"edges": _river_edge_count,
		"density": density,
		"max_q": float(sel["max_q"]),
		"threshold": qc,
		"mouths": int(final_sel["mouths"]),
		"tree_min": int(river_stats["tree_min"]),
		"tree_p50": float(river_stats["tree_p50"]),
		"branch_min": int(river_stats["branch_min"]),
		"branch_p50": float(river_stats["branch_p50"]),
		"branch_n": int(river_stats["branch_n"]),
		"trunk_p50": float(river_stats["trunk_p50"]),
		"max_fill": max_fill,
		"seeds": seed_count,
		"high_edges": high_edges,
	}
	_river_stats.merge(_river_render_stats)
	print("河流：候选 ", candidate_tiles, " 条 → 整树 -", int(filtered["tree_pruned"]),
			" / 短枝 -", int(filtered["branch_pruned"]), "（", int(filtered["passes"]),
			" 轮）→ 河段 ", _river_edge_count, " 条，河道贴片 ", _river_edge_count,
			" / 陆地 ", land_n, "（", snappedf(density * 100.0, 0.1), "%），阈值=",
			snappedf(qc, 0.01), "，入海口 ", int(final_sel["mouths"]),
			"，最短枝 ", int(river_stats["branch_min"]), "，枝长 p50 ",
			snappedf(float(river_stats["branch_p50"]), 0.1), "，干流 p50 ",
			snappedf(float(river_stats["trunk_p50"]), 0.1))
	print("河流：最大 Q=", snappedf(float(sel["max_q"]), 0.01), "，跨高山 ",
			high_edges, "，填洼最大深度=", snappedf(max_fill, 0.0001))
	print("河流：", _river_branch_n, " 条分支链，半宽 p50=",
			snappedf(float(_river_render_stats["half_p50"]), 0.0001), " p90=",
			snappedf(float(_river_render_stats["half_p90"]), 0.0001), " max=",
			snappedf(float(_river_render_stats["half_max"]), 0.0001),
			"（干流/支流比 ", snappedf(float(_river_render_stats["half_max"])
			/ maxf(float(_river_render_stats["half_p10"]), 1e-6), 0.1), "×）")


# 给定阈值收集河段：每个陆地贴片最多一条 (v -> parent[v])，天然无重复/无环
func _collect_river_edges(parent: PackedInt32Array, flow: PackedFloat32Array,
		qc: float, generated_ids: PackedInt32Array) -> Dictionary:
	var edges := PackedInt32Array()
	var tiles := 0
	var mouths := 0
	var max_q := 0.0
	for v in generated_ids:
		if _inland_water[v] == 1 or parent[v] < 0:
			continue
		var q := flow[v]
		if q > max_q:
			max_q = q
		if q >= qc:
			edges.append(v)
			edges.append(parent[v])
			tiles += 1
			if _inland_water[parent[v]] == 1:
				mouths += 1
	return {"edges": edges, "tiles": tiles, "mouths": mouths, "max_q": max_q}


func _build_river_candidate_graph(candidate_edges: PackedInt32Array,
		candidate_tiles: int, parent: PackedInt32Array,
		order: PackedInt32Array) -> Dictionary:
	var tiles := PackedInt32Array()
	tiles.resize(candidate_tiles)
	var local_of := PackedInt32Array()
	local_of.resize(parent.size())
	local_of.fill(-1)
	for e in candidate_tiles:
		var v := candidate_edges[e * 2]
		tiles[e] = v
		local_of[v] = e
	var local_parent := PackedInt32Array()
	local_parent.resize(candidate_tiles)
	for e in candidate_tiles:
		var p := parent[tiles[e]]
		local_parent[e] = local_of[p] if p >= 0 else -1
	var local_order := PackedInt32Array()
	local_order.resize(candidate_tiles)
	var n := 0
	for v in order:
		var li := local_of[v]
		if li >= 0:
			local_order[n] = li
			n += 1
	if n != candidate_tiles:
		# 防御：候选陆地正常都在 priority-flood order 中；若索引不完整则补齐，
		# 避免过滤阶段静默漏节点。正常情况下这段不会执行。
		var seen := PackedByteArray()
		seen.resize(candidate_tiles)
		for i in n:
			seen[local_order[i]] = 1
		for i in candidate_tiles:
			if seen[i] == 0:
				local_order[n] = i
				n += 1
		local_order.resize(n)
	return {"tiles": tiles, "parent": local_parent, "order": local_order}


func _collect_edges_from_selection(cand_tiles: PackedInt32Array,
		parent: PackedInt32Array, selected: PackedByteArray) -> Dictionary:
	var edges := PackedInt32Array()
	var tiles := 0
	var mouths := 0
	for i in selected.size():
		if selected[i] == 0:
			continue
		var v := cand_tiles[i]
		var p := parent[v]
		if p < 0:
			continue
		edges.append(v)
		edges.append(p)
		tiles += 1
		if _inland_water[p] == 1:
			mouths += 1
	return {"edges": edges, "tiles": tiles, "mouths": mouths}


func _river_child_counts(parent: PackedInt32Array,
		selected: PackedByteArray) -> PackedInt32Array:
	var child := PackedInt32Array()
	child.resize(selected.size())
	for v in selected.size():
		if selected[v] == 0:
			continue
		var p := parent[v]
		if p >= 0:
			child[p] += 1
	return child


# A 方案：先删小整树，再剪短叶枝；交替到稳定。
# 返回值里的 selected 是新数组（Packed 数组按值传递，避免调用方误以为被原地修改）。
func _filter_river_selection(parent: PackedInt32Array, order: PackedInt32Array,
		start_selected: PackedByteArray) -> Dictionary:
	var selected: PackedByteArray = start_selected.duplicate()
	var tree_pruned := 0
	var branch_pruned := 0
	var passes := 0
	var stable := false
	while passes < RIVER_FILTER_MAX_PASSES:
		passes += 1
		var tr := _remove_small_trees(parent, order, selected,
				RIVER_TREE_MIN_EDGES)
		selected = tr["selected"]
		tree_pruned += int(tr["removed"])
		var br := _prune_short_branches(parent, selected,
				RIVER_BRANCH_MIN_EDGES)
		selected = br["selected"]
		branch_pruned += int(br["removed"])
		if int(tr["removed"]) == 0 and int(br["removed"]) == 0:
			stable = true
			break
	if not stable:
		print("河流层警告：两级过滤达到上限 ", RIVER_FILTER_MAX_PASSES,
				" 轮，提前停止")
	return {
		"selected": selected,
		"tree_pruned": tree_pruned,
		"branch_pruned": branch_pruned,
		"passes": passes,
	}


# 删除边数 < tmin 的整棵汇流树。顺序用 priority-flood 的 order：
# 正序 parent 先于 child，逆序 child 先于 parent，所以一次扫描就能算子树大小。
func _remove_small_trees(parent: PackedInt32Array, order: PackedInt32Array,
		selected: PackedByteArray, tmin: int) -> Dictionary:
	var total := selected.size()
	var size := PackedInt32Array()
	size.resize(total)
	for i in range(order.size() - 1, -1, -1):
		var v := order[i]
		if selected[v] == 0:
			continue
		size[v] += 1
		var p := parent[v]
		if p >= 0 and selected[p] == 1:
			size[p] += size[v]
	var root := PackedInt32Array()
	root.resize(total)
	root.fill(-1)
	var remove_root := PackedByteArray()
	remove_root.resize(total)
	var small_roots := 0
	for v in order:
		if selected[v] == 0:
			continue
		var p := parent[v]
		if p >= 0 and selected[p] == 1 and root[p] >= 0:
			root[v] = root[p]
		else:
			root[v] = v
			if size[v] < tmin:
				remove_root[v] = 1
				small_roots += 1
	if small_roots == 0:
		return {"selected": selected, "removed": 0}
	var alive: PackedByteArray = selected.duplicate()
	var removed := 0
	for v in order:
		if selected[v] == 0:
			continue
		var r := root[v]
		if r >= 0 and remove_root[r] == 1:
			alive[v] = 0
			removed += 1
	return {"selected": alive, "removed": removed}


# 迭代剪掉长度 < lmin 的叶枝：叶子沿下游走到第一个汇流点/入海口，
# 整条叶枝删除；剪完后父节点可能变成新的短叶枝，所以重复到稳定。
func _prune_short_branches(parent: PackedInt32Array,
		selected: PackedByteArray, lmin: int) -> Dictionary:
	var total := selected.size()
	var alive: PackedByteArray = selected.duplicate()
	var removed_total := 0
	while true:
		var child := _river_child_counts(parent, alive)
		var remove := PackedByteArray()
		remove.resize(total)
		var any_removed := false
		for v in total:
			if alive[v] == 0 or child[v] != 0:
				continue
			var path: Array[int] = []
			var cur := v
			var length := 0
			while true:
				path.append(cur)
				length += 1
				var p := parent[cur]
				if p < 0 or alive[p] == 0 or child[p] >= 2:
					break
				cur = p
			if length < lmin:
				for node in path:
					remove[node] = 1
				any_removed = true
		if not any_removed:
			break
		for v in total:
			if remove[v] == 1:
				alive[v] = 0
				removed_total += 1
	return {"selected": alive, "removed": removed_total}


# 过滤后的树/枝/干流统计；只读，供日志和测试断言。
func _river_selection_stats(parent: PackedInt32Array, order: PackedInt32Array,
		selected: PackedByteArray) -> Dictionary:
	var empty := {
		"tree_min": 0, "tree_p50": 0.0,
		"branch_min": 0, "branch_p50": 0.0, "branch_n": 0,
		"trunk_p50": 0.0,
	}
	if selected.size() == 0:
		return empty
	var total := selected.size()
	var size := PackedInt32Array()
	size.resize(total)
	for i in range(order.size() - 1, -1, -1):
		var v := order[i]
		if selected[v] == 0:
			continue
		size[v] += 1
		var p := parent[v]
		if p >= 0 and selected[p] == 1:
			size[p] += size[v]
	var root := PackedInt32Array()
	root.resize(total)
	root.fill(-1)
	var depth := PackedInt32Array()
	depth.resize(total)
	var max_depth := PackedInt32Array()
	max_depth.resize(total)
	var tree_sizes: Array[int] = []
	for v in order:
		if selected[v] == 0:
			continue
		var p := parent[v]
		if p >= 0 and selected[p] == 1 and root[p] >= 0:
			root[v] = root[p]
			depth[v] = depth[p] + 1
		else:
			root[v] = v
			depth[v] = 0
			tree_sizes.append(size[v])
		var r := root[v]
		if r >= 0 and depth[v] > max_depth[r]:
			max_depth[r] = depth[v]
	var child := _river_child_counts(parent, selected)
	var branch_lengths: Array[int] = []
	for v in total:
		if selected[v] == 0 or child[v] != 0:
			continue
		var length := 1
		var cur := v
		while true:
			var p := parent[cur]
			if p < 0 or selected[p] == 0 or child[p] >= 2:
				break
			cur = p
			length += 1
		branch_lengths.append(length)
	var trunks: Array[int] = []
	for v in total:
		if selected[v] == 1 and root[v] == v:
			trunks.append(max_depth[v] + 1)
	if tree_sizes.is_empty() or branch_lengths.is_empty() or trunks.is_empty():
		return empty
	tree_sizes.sort()
	branch_lengths.sort()
	trunks.sort()
	return {
		"tree_min": tree_sizes[0],
		"tree_p50": _river_pct_int(tree_sizes, 0.5),
		"branch_min": branch_lengths[0],
		"branch_p50": _river_pct_int(branch_lengths, 0.5),
		"branch_n": branch_lengths.size(),
		"trunk_p50": _river_pct_int(trunks, 0.5),
	}


func _river_pct_int(sorted: Array[int], q: float) -> float:
	var idx := clampi(int(floor(q * float(sorted.size() - 1))), 0,
			sorted.size() - 1)
	return float(sorted[idx])


# ===== 河宽分级 + 分支链（§20 / §21 P2）=====
# 半宽只由节点流量 Q 决定：Q 沿下游单调不减（§7.3 不变量）→ 半宽也单调不减，
# 视觉上永远是「源头细 → 干流粗」，不会出现「粗—细—粗」。
# 端点分位（P5 / P99）取本次生成实测值，不写死，换种子/换气候都能自适应。
func _compute_river_widths() -> void:
	var total := _tile_centers.size()
	_river_half_width = PackedFloat32Array()
	_river_half_width.resize(total)
	_river_half_width.fill(0.0)
	if total == 0 or _river_edge_count == 0:
		_river_render_stats = {"branches": 0, "q_lo": 0.0, "q_hi": 0.0,
				"width_exp": 0.0, "half_min": 0.0, "half_p10": 0.0,
				"half_p50": 0.0, "half_p90": 0.0, "half_max": 0.0,
				"half_at_max": 0.0}
		return
	var qs := PackedFloat32Array()
	qs.resize(_river_edge_count)
	for e in _river_edge_count:
		qs[e] = _river_flow[_river_edges[e * 2]]
	qs.sort()
	var q_lo := maxf(_river_pct_f32(qs, RIVER_WIDTH_Q_LO_PCT), 1e-4)
	var q_hi := maxf(_river_pct_f32(qs, RIVER_WIDTH_Q_HI_PCT), q_lo * 1.001)
	var ln_lo := log(q_lo)
	var inv_span := 1.0 / maxf(log(q_hi) - ln_lo, 1e-6)
	var ln_hmin := log(RIVER_HALF_MIN)
	var ln_hmax := log(RIVER_HALF_MAX)
	for e in _river_edge_count:
		var v: int = _river_edges[e * 2]
		if _river_half_width[v] > 0.0:
			continue
		# 对数刻度：half = exp(lerp(ln MIN, ln MAX, t))，等价于 half ∝ Q^b。
		# 只有 t 被夹到 0/1 的那一小撮（P5 以下 / P99 以上）才会取到端点值，
		# 不会像线性刻度那样让流量前 10% 全部并到 MAX 上去。
		var t := clampf((log(maxf(_river_flow[v], 1e-4)) - ln_lo) * inv_span, 0.0, 1.0)
		_river_half_width[v] = exp(lerpf(ln_hmin, ln_hmax, t))
	var hs := PackedFloat32Array()
	hs.resize(_river_edge_count)
	for e in _river_edge_count:
		hs[e] = _river_half_width[_river_edges[e * 2]]
	hs.sort()
	_river_render_stats = {
		"q_lo": q_lo,
		"q_hi": q_hi,
		"width_exp": log(RIVER_HALF_MAX / RIVER_HALF_MIN)
				/ maxf(log(q_hi / q_lo), 1e-6),
		"half_min": hs[0],
		"half_p10": _river_pct_f32(hs, 0.10),
		"half_p50": _river_pct_f32(hs, 0.50),
		"half_p90": _river_pct_f32(hs, 0.90),
		"half_max": hs[hs.size() - 1],
		"half_at_max": _river_frac_at_max(hs),
	}


func _river_pct_f32(sorted: PackedFloat32Array, q: float) -> float:
	if sorted.is_empty():
		return 0.0
	var idx := clampi(int(floor(q * float(sorted.size() - 1))), 0,
			sorted.size() - 1)
	return sorted[idx]


# 顶到上限（= 干流最大半宽）的节点占比。§21 P2 的体检指标：
# 线性刻度 + clamp 时这个数是 12%（一堆大河并成同宽），对数刻度应降到 ~1%。
func _river_frac_at_max(sorted: PackedFloat32Array) -> float:
	if sorted.is_empty():
		return 0.0
	var hi := sorted[sorted.size() - 1]
	var tol := hi * 1e-4
	var n := 0
	for v in sorted:
		if v >= hi - tol:
			n += 1
	return float(n) / float(sorted.size())


# 分支链：源头起链 → 遇汇合点（child_count ≥ 2）时把它收进链尾并断开；
# 每个汇合点再各自起一条下游链。链与链只在汇合点重叠「一个节点」，
# 且该点半宽来自同一个 Q → 两侧偏移点完全对齐，接头无缝。
func _build_river_branches() -> void:
	var total := _tile_centers.size()
	_river_child_count = PackedInt32Array()
	_river_child_count.resize(total)
	_river_child_count.fill(0)
	_river_down = PackedInt32Array()
	_river_down.resize(total)
	_river_down.fill(-1)
	_river_widest_child = PackedInt32Array()
	_river_widest_child.resize(total)
	_river_widest_child.fill(-1)
	_river_branch_nodes = PackedInt32Array()
	_river_branch_offsets = PackedInt32Array()
	_river_branch_offsets.append(0)
	_river_branch_n = 0
	if total == 0:
		return
	for e in _river_edge_count:
		var a: int = _river_edges[e * 2]
		var b: int = _river_edges[e * 2 + 1]
		_river_down[a] = b
		_river_child_count[b] += 1
		var wc: int = _river_widest_child[b]
		if wc < 0 or _river_half_width[a] > _river_half_width[wc]:
			_river_widest_child[b] = a
	# 汇合点清单（≥2 条来水且有下游）：出网格时在这里放圆角接头。
	_river_junctions = PackedInt32Array()
	for v in total:
		if _river_child_count[v] < 2 or _river_down[v] < 0:
			continue
		_river_junctions.append(v)
	for v in total:
		if _river_down[v] < 0:
			continue
		var cc: int = _river_child_count[v]
		if cc != 0 and cc < 2:
			continue # 普通中间节点：由上游链一路带下来
		var cur := v
		var guard := 0
		while guard <= total:
			_river_branch_nodes.append(cur)
			var nxt: int = _river_down[cur]
			if nxt < 0:
				break
			if _inland_water[nxt] == 1 or _river_child_count[nxt] >= 2:
				_river_branch_nodes.append(nxt) # 入海口 / 汇合点：含进链尾后收尾
				break
			cur = nxt
			guard += 1
		_river_branch_offsets.append(_river_branch_nodes.size())
		_river_branch_n += 1
	_river_render_stats["branches"] = _river_branch_n


# p → q 在 p 点切平面上的单位切向（球面走线）
func _river_dir(p: Vector3, q: Vector3) -> Vector3:
	var d := q - p
	d -= p * d.dot(p)
	var l := d.length()
	if l < 1e-9:
		return Vector3.ZERO
	return d / l


# Chaikin 角切：把六边形网格造成的 60° 硬折角磨成缓弯（§21 P0）。
# 每段取 0.25 / 0.75 两个切点，端点原样保留 —— 端点切线与原折线一致，
# 所以汇合点的端面对齐关系完全不受影响。半宽同步按同样的权重插值。
# 凸包内切 ⇒ 不会过冲、不会自交（Catmull-Rom 在 60° 折角上会回勾）。
func _river_chaikin(pts: PackedVector3Array, halves: PackedFloat32Array,
		iters: int) -> Array:
	var n := pts.size()
	if iters <= 0 or n < 3:
		return [pts, halves]
	for _it in iters:
		var m := n * 2
		var np := PackedVector3Array()
		var nh := PackedFloat32Array()
		np.resize(m)
		nh.resize(m)
		np[0] = pts[0]
		nh[0] = halves[0]
		var k := 1
		for i in n - 1:
			np[k] = (pts[i] * 0.75 + pts[i + 1] * 0.25).normalized()
			nh[k] = lerpf(halves[i], halves[i + 1], 0.25)
			np[k + 1] = (pts[i] * 0.25 + pts[i + 1] * 0.75).normalized()
			nh[k + 1] = lerpf(halves[i], halves[i + 1], 0.75)
			k += 2
		np[m - 1] = pts[n - 1]
		nh[m - 1] = halves[n - 1]
		pts = np
		halves = nh
		n = m
	return [pts, halves]


# 切平面内的角平分向量：汇合点上下游两条链用它取到同一组偏移点
func _river_bisector(p: Vector3, d_in: Vector3, d_out: Vector3) -> Vector3:
	var m := d_in + d_out
	if m.length_squared() < 1e-12:
		return d_out if d_out != Vector3.ZERO else d_in
	m -= p * m.dot(p)
	if m.length_squared() < 1e-12:
		return d_out if d_out != Vector3.ZERO else d_in
	return m.normalized()


# 河口裁剪面：最后一块陆地贴片的**朝水边**，每条边给一个单位法线（指向水域）。
# 平面过球心与该边的两个角点 —— 地表网格在这条边上画的就是这两点之间的直弦，
# 所以按平面裁出来的边界与海岸线严格重合（弦与平面只差 ~1e-5 半径，亚像素）。
# 点 x 在陆地上 ⇔ 对所有 n 都有 n·x ≤ 0（贴片是凸的，所以片内点全部满足）。
func _river_mouth_clip_planes(land_v: int) -> PackedVector3Array:
	var planes := PackedVector3Array()
	if land_v < 0 or land_v >= _tile_polys.size():
		return planes
	var poly: PackedVector3Array = _tile_polys[land_v]
	var n := poly.size()
	if n < 3:
		return planes
	for k in n:
		var a := poly[k]
		var b := poly[(k + 1) % n]
		var mid := a + b
		if mid.length_squared() < 1e-12:
			continue
		mid = mid.normalized()
		# 这条边对面是哪片贴片：边中点方向最贴近的那个邻居（六边形上唯一）
		var best := -1
		var best_dot := -2.0
		for j in 6:
			var u: int = _tile_neighbors[land_v * 6 + j]
			if u < 0:
				continue
			var dd: float = _tile_centers[u].dot(mid)
			if dd > best_dot:
				best_dot = dd
				best = u
		if best < 0 or _inland_water[best] != 1:
			continue # 对面也是陆地 → 这条边在陆地上，不是岸线
		var pn := a.cross(b)
		if pn.length_squared() < 1e-16:
			continue
		pn = pn.normalized()
		if pn.dot(_tile_centers[best]) < 0.0:
			pn = -pn # 法线朝水
		planes.append(pn)
	return planes


# 到岸线的有符号距离，直接编码成 COLOR.g（见 RIVER_COAST_SCALE）。
# 没有裁剪面（或深在陆地上）时返回 0.0 = 饱和的"陆地深处"，shader 里恒不裁。
func _river_coast_code(planes: PackedVector3Array, p: Vector3) -> float:
	if planes.is_empty():
		return 0.0
	var d := -RIVER_COAST_SCALE
	for pn in planes:
		# 多面临水（岬角）时取最靠水的那一面：任一面临水即已出陆地
		d = maxf(d, pn.dot(p))
	return clampf(0.5 + d / (2.0 * RIVER_COAST_SCALE), 0.0, 1.0)


# 分支链 → 球面 ribbon。宽度、miter、源头渐细全部烘到顶点位置；
# shader 只用 UV2.x（烘焙半宽）做远视角最小像素补偿，不再负责展开宽度。
# 顶点布局：每采样点 2 个（左 UV.x=0 / 右 1），NORMAL=侧向单位向量，COLOR.r=alpha。
func _build_river_mesh_from_branches() -> ArrayMesh:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var cols := PackedColorArray()
	var indices := PackedInt32Array()
	var sample_n := 0
	var quad_n := 0
	var mouth_pts := PackedVector3Array()
	var mouth_rad := PackedFloat32Array()
	var mouth_planes: Array[PackedVector3Array] = []
	for b in _river_branch_n:
		var start: int = _river_branch_offsets[b]
		var count: int = _river_branch_offsets[b + 1] - start
		if count < 2:
			continue
		var pts := PackedVector3Array()
		var halves := PackedFloat32Array()
		pts.resize(count)
		halves.resize(count)
		for i in count:
			var v: int = _river_branch_nodes[start + i]
			pts[i] = _tile_centers[v]
			halves[i] = _river_half_width[v]
		var head_v: int = _river_branch_nodes[start]
		var tail_v: int = _river_branch_nodes[start + count - 1]
		var is_source: bool = _river_child_count[head_v] < 2
		var mouth := _inland_water[tail_v] == 1
		var ends_at_junction: bool = (not mouth) and _river_child_count[tail_v] >= 2
		var is_dead_end: bool = (not mouth) and (not ends_at_junction)
		# 河口：最后一块陆地贴片 + 它的岸线平面（只有河口链才有，别的链保持空）
		var land_v: int = -1
		var planes := PackedVector3Array()
		if mouth:
			land_v = _river_branch_nodes[start + count - 2]
			planes = _river_mouth_clip_planes(land_v)
			# ribbon 沿(陆地片→水域片)方向**一定跨过岸线**（0.70 > 0.5），跨出去
			# 的那截由 shader 按岸线平面逐像素裁掉（见 _river_coast_code）。
			# 这样做的好处：河心与岸线的交点在哪里、河流以什么角度撞岸，全都不
			# 需要特殊处理——裁出来的边永远落在陆地边线上，不会有缝也不会有圆头。
			pts[count - 1] = pts[count - 2].slerp(pts[count - 1],
					RIVER_MOUTH_PAST).normalized()
			halves[count - 1] = halves[count - 2]
		elif ends_at_junction:
			# 汇合点：干流（= 最宽的那条来水）**保留汇合后的半宽**——上游最后一段
			# 自然张开成汇流喇叭；支流则按自身半宽收口（否则细支流会在口上胀到
			# 干流宽度，被斜切端面切成一个方块凸起）。两者端面之间的那个凹角，
			# 由汇合点圆盘（半径正好 = 汇合后半宽）填成圆角。
			if _river_widest_child[tail_v] != _river_branch_nodes[start + count - 2]:
				halves[count - 1] = halves[count - 2]
		# 链头落在汇合点时不用特别处理：halves[0] 本来就是汇合后的半宽，
		# 与上游干流在汇合点的端面完全一致（改造前这里还做了一次 min() 收缩，
		# 结果加宽被挤到汇合点之后的那一段里，看起来就是"过一会儿突然肿一下"）。

		# —— 折角平滑（§21 P0）：Chaikin ×N，端点钉住 ——
		# 端点处第一/最后一段的方向严格等于原折线的第一/最后一段（凸包内切只切角、
		# 不动端点切线），所以汇合点接头按端切线算依然成立，无需重算。
		var sm := _river_chaikin(pts, halves, RIVER_SMOOTH_ITERS)
		pts = sm[0]
		halves = sm[1]
		var n: int = pts.size()
		count = n
		var alphas := PackedFloat32Array()
		alphas.resize(n)
		alphas.fill(1.0)
		# 岸线裁剪只作用在「河口尾巴」：Chaikin 后找离最后一块陆地贴片中心最近的
		# 采样点，从它往后才可能越过岸线。上游一律给哨兵（= 不裁）——海岸是锯齿，
		# 岸线平面往远处延伸会切进别的贴片，把同一条链上游贴着另一段海岸的部分误裁。
		var tail_i := n
		if mouth:
			var best := INF
			var p_land: Vector3 = _tile_centers[land_v]
			for i in n:
				var da := pts[i].angle_to(p_land)
				if da < best:
					best = da
					tail_i = i

		# —— 弧长参数：端头的渐细/渐隐按「离端点多远」而不是「第几个点」 ——
		var cum := PackedFloat32Array()
		cum.resize(n)
		cum[0] = 0.0
		for i in n - 1:
			cum[i + 1] = cum[i] + pts[i].angle_to(pts[i + 1])
		var total_arc: float = cum[n - 1]
		if total_arc < 1e-9:
			continue
		if is_source:
			# 源头：在 3° 弧内由 0.30× 半宽 + 透明长回满宽不透明，河"消失在山坡上"，
			# 不再是一根针尖。链太短时按链长的 35% 收（否则半条支流都被吃掉）。
			var tip_len := minf(deg_to_rad(RIVER_TIP_LEN_DEG), total_arc * 0.35)
			tip_len = maxf(tip_len, 1e-9)
			for i in n:
				var s: float = cum[i]
				if s > tip_len:
					break
				var u := s / tip_len
				halves[i] *= lerpf(RIVER_TIP_TAPER, 1.0, smoothstep(0.0, 1.0, u))
				alphas[i] = smoothstep(0.0, 0.5, u)
		if mouth:
			# 入海口：短喇叭口，alpha 保持 1（不做淡出——淡出落在岸带白色雾面上
			# 就是一坨"没入海"的透明；伸进水面之后自然被水面接住）。
			var mlen := minf(deg_to_rad(RIVER_MOUTH_LEN_DEG), total_arc * 0.5)
			mlen = maxf(mlen, 1e-9)
			var m0: float = total_arc - mlen
			for i in n:
				var s2: float = cum[i]
				if s2 < m0:
					continue
				var u := clampf((s2 - m0) / mlen, 0.0, 1.0)
				halves[i] *= lerpf(1.0, RIVER_MOUTH_FLARE,
						u * u * (3.0 - 2.0 * u))
		elif is_dead_end:
			# 断头于干涸洼地：从尾部同样收细（只收宽度，不做透明），
			# 免得在荒地里留一个平口。
			var dlen := minf(deg_to_rad(RIVER_TIP_LEN_DEG), total_arc * 0.35)
			dlen = maxf(dlen, 1e-9)
			for i in range(n - 1, -1, -1):
				var ds: float = total_arc - cum[i]
				if ds > dlen:
					break
				var du := ds / dlen
				halves[i] *= lerpf(RIVER_TIP_TAPER, 1.0,
						smoothstep(0.0, 1.0, du))

		# —— 段方向（p 点切平面内的单位向量）——
		var dirs := PackedVector3Array()
		dirs.resize(count - 1)
		for i in count - 1:
			dirs[i] = _river_dir(pts[i], pts[i + 1])

		# —— 每个节点的 miter 方向 + 侧向偏移长度 ——
		var sides := PackedVector3Array()
		var offs := PackedFloat32Array()
		sides.resize(count)
		offs.resize(count)
		for i in count:
			var p := pts[i]
			var d_in := dirs[i - 1] if i > 0 else Vector3.ZERO
			var d_out := dirs[i] if i < count - 1 else Vector3.ZERO
			# 链头落在汇合点：把「最宽的那条来水」的方向当成自己的来向；
			# 链尾落在汇合点（或带着链路走向河口）：把「下游节点方向」当成去向往外接。
			# 这样每个端头都是**自己这条河道**与下游河道之间的标准 miter 接头，
			# 干流尾端与下游链头端会算出**完全相同**的角平分方向与偏移量 → 端面重合。
			if d_in == Vector3.ZERO and _river_child_count[head_v] >= 2:
				var wc: int = _river_widest_child[head_v]
				if wc >= 0:
					d_in = _river_dir(p, _tile_centers[wc])
			if d_out == Vector3.ZERO:
				var dn: int = _river_down[tail_v]
				if dn >= 0:
					d_out = _river_dir(p, _tile_centers[dn])
			var m := Vector3.ZERO
			var at_end := (i == 0 or i == count - 1)
			if at_end:
				# 链的两端用**自己的切向**，不做 miter 拉伸：端面就是本河道的一个
				# 正截面（离轴正好 ±半宽）。转角由汇合点的圆角接头去接，
				# 端面本身绝不能斜切——斜切会在干流边上啃掉一个角，那就是缺口。
				m = d_out if i == 0 else d_in
				if m == Vector3.ZERO:
					m = d_in if d_in != Vector3.ZERO else d_out
			else:
				m = _river_bisector(p, d_in, d_out)
			if m == Vector3.ZERO:
				m = Vector3.UP
			var side := p.cross(m)
			if side.length_squared() < 1e-12:
				var helper := Vector3.UP if absf(p.y) < 0.9 else Vector3.RIGHT
				side = p.cross(helper)
			sides[i] = side.normalized()
			if at_end:
				offs[i] = halves[i]
			else:
				# 内点 miter：把 ±半宽 推到两条边线的交点上，拐角外沿才不会被切角。
				# Chaikin 之后最大转角 19°，实际补偿 ≤1.5%，钳到 1.4× 只兜异常值。
				var cos_h := clampf(m.dot(d_out), 1.0 / RIVER_MITER_MAX_RATIO, 1.0)
				offs[i] = halves[i] / cos_h

		# —— 采样：每段按 2.5° 细分，位置/侧向/偏移/alpha 沿线插值 ——
		# 平滑后单段只有原段长的 1/4～1/2（≤0.55°），nseg 基本恒为 1；
		# 保留细分是为了让 RIVER_SMOOTH_ITERS=0 时仍然正确。
		var arc := PackedFloat32Array()
		arc.resize(count - 1)
		for i in count - 1:
			arc[i] = cum[i + 1] - cum[i]
		var base := verts.size()
		var acc := 0.0
		var first := true
		for i in count - 1:
			var nseg := maxi(1, ceili(arc[i] / deg_to_rad(RIVER_MAX_ARC_DEG)))
			for k in nseg + 1:
				if k == 0 and not first:
					continue # 段接缝处复用上一段的末采样，不重复顶点
				var t := float(k) / float(nseg)
				var p := pts[i].slerp(pts[i + 1], t).normalized()
				var side: Vector3
				var off: float
				var al: float
				if k == 0:
					side = sides[i]
					off = offs[i]
					al = alphas[i]
				elif k == nseg:
					side = sides[i + 1]
					off = offs[i + 1]
					al = alphas[i + 1]
				else:
					side = sides[i].slerp(sides[i + 1], t)
					if side.length_squared() < 1e-12:
						side = sides[i]
					side = (side - p * side.dot(p)).normalized()
					off = lerpf(offs[i], offs[i + 1], t)
					al = lerpf(alphas[i], alphas[i + 1], t)
				var vl := (p - side * off).normalized()
				var vr := (p + side * off).normalized()
				verts.append(vl)
				verts.append(vr)
				normals.append(side)
				normals.append(side)
				var v_arc := (acc + arc[i] * t) / total_arc
				uvs.append(Vector2(0.0, v_arc))
				uvs.append(Vector2(1.0, v_arc))
				uv2s.append(Vector2(off, v_arc))
				uv2s.append(Vector2(off, v_arc))
				# COLOR.g = 到岸线的有符号距离（0.5 = 岸线，见 _river_coast_code）；
				# 只有河口尾巴填真值，其余恒 0 = 深在陆地 → shader 不裁。
				# 左右两侧各按**自己的位置**算，裁线才严格落在岸线平面上。
				var cg0 := 0.0
				var cg1 := 0.0
				var pidx := i + (0 if k < nseg else 1)
				if mouth and pidx >= tail_i:
					cg0 = _river_coast_code(planes, vl)
					cg1 = _river_coast_code(planes, vr)
				cols.append(Color(al, cg0, 0.0, 1.0))
				cols.append(Color(al, cg1, 0.0, 1.0))
				first = false
			acc += arc[i]
		var emitted := (verts.size() - base) >> 1
		for k in emitted - 1:
			var q0 := base + k * 2
			indices.append(q0)
			indices.append(q0 + 1)
			indices.append(q0 + 2)
			indices.append(q0 + 1)
			indices.append(q0 + 3)
			indices.append(q0 + 2)
		sample_n += emitted
		quad_n += emitted - 1
		if mouth:
			mouth_pts.append(pts[count - 1])
			mouth_rad.append(halves[count - 1])
			mouth_planes.append(planes)

	# —— 汇合点圆角接头（round join）——
	# 每条链在汇合点处以「自己的正截面」结束，两个截面之间那个夹角由一段
	# **以汇合点为圆心、半径正好等于该点半宽**的圆弧补上。这就是制图学里的
	# round join：圆弧在两边的切点处与两条岸线相切 → 既没有 miter 的尖刺，
	# 也没有切角留下的缺口；而且半径 = 半宽，圆弧永远不会伸出河道轮廓之外。
	# 支流比干流细，它的端面本来就落在圆弧内部，露不出来。
	# 改造前这里是一个纵向拉伸 1.8× 的椭圆"汇水潭"：斜向半径能到 1.35× 半宽，
	# 于是干流边上肿出一块——截图里的"突出"和"肿胀"都是它。
	var join_n := 0
	var join_seg := RIVER_JOIN_SEG
	for jv in _river_junctions:
		var jr: float = _river_half_width[jv]
		if jr <= 0.0:
			continue
		var pc: Vector3 = _tile_centers[jv]
		var helper := Vector3.UP if absf(pc.y) < 0.9 else Vector3.RIGHT
		var e1: Vector3 = pc.cross(helper).normalized()
		var e2: Vector3 = pc.cross(e1).normalized()
		var ci := verts.size()
		verts.append(pc)
		normals.append(e1)
		uvs.append(Vector2(0.5, 0.0))
		uv2s.append(Vector2(jr, 0.0))
		cols.append(Color(1.0, 0.0, 0.0, 1.0))
		for k in join_seg:
			var a := TAU * float(k) / float(join_seg)
			var rad: Vector3 = e1 * cos(a) + e2 * sin(a)
			verts.append((pc + rad * jr).normalized())
			normals.append(rad)
			# UV.x = 1 → shader 里 (UV.x*2-1) = +1，与径向 NORMAL 同向，
			# 远看的屏幕最小宽度补偿才会把圆盘补大而不是缩没。
			uvs.append(Vector2(1.0, 0.0))
			uv2s.append(Vector2(jr, 0.0))
			cols.append(Color(1.0, 0.0, 0.0, 1.0))
		for k in join_seg:
			indices.append(ci)
			indices.append(ci + 1 + k)
			indices.append(ci + 1 + (k + 1) % join_seg)
		join_n += 1

	# —— 河口端头：半径 = 河口半宽的圆 ——
	# 圆头本身也带同一套岸线裁剪值 → 伸到水面上的那半圈会被裁掉，留在陆地上的
	# 只有「河道与海岸线之间的两个圆角」，河口就是圆润地融进海岸，而不是一截
	# 突兀的圆头浮在水面上（改造前的样子）。
	var mouth_clipped := 0
	for mi in mouth_pts.size():
		var mp: Vector3 = mouth_pts[mi]
		var mr: float = mouth_rad[mi]
		if mr <= 0.0:
			continue
		var mpl: PackedVector3Array = mouth_planes[mi]
		var mh := Vector3.UP if absf(mp.y) < 0.9 else Vector3.RIGHT
		var me1: Vector3 = mp.cross(mh).normalized()
		var me2: Vector3 = mp.cross(me1).normalized()
		if _river_coast_code(mpl, mp) > 0.5:
			mouth_clipped += 1 # 圆心已在水面一侧 → 这条河口确实会被裁到
		var mci := verts.size()
		verts.append(mp)
		normals.append(me1)
		uvs.append(Vector2(0.5, 0.0))
		uv2s.append(Vector2(mr, 0.0))
		cols.append(Color(1.0, _river_coast_code(mpl, mp), 0.0, 1.0))
		for k in join_seg:
			var ma := TAU * float(k) / float(join_seg)
			var mrad: Vector3 = me1 * cos(ma) + me2 * sin(ma)
			var mv := (mp + mrad * mr).normalized()
			verts.append(mv)
			normals.append(mrad)
			uvs.append(Vector2(1.0, 0.0))
			uv2s.append(Vector2(mr, 0.0))
			cols.append(Color(1.0, _river_coast_code(mpl, mv), 0.0, 1.0))
		for k in join_seg:
			indices.append(mci)
			indices.append(mci + 1 + k)
			indices.append(mci + 1 + (k + 1) % join_seg)
	if verts.is_empty():
		return null
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_river_render_stats["samples"] = sample_n
	_river_render_stats["quads"] = quad_n
	_river_render_stats["joins"] = join_n
	_river_render_stats["mouths"] = mouth_pts.size()
	_river_render_stats["mouth_clipped"] = mouth_clipped
	print("河流 mesh：", sample_n, " 采样点 / ",
			quad_n * 2 + (join_n + mouth_pts.size()) * join_seg,
			" 三角形（", _river_branch_n, " 条链，", join_n, " 个汇合点圆角，",
			mouth_pts.size(), " 个河口，", mouth_clipped, " 条按岸线裁剪）")
	return mesh


func _ready() -> void:
	# 贴片信息 HUD：平时隐藏，选中贴片时亮出（数据在 select_tile 时组装）
	_hud = TileHud.new()
	add_child(_hud)

	# 轨道相机控制器：桌面左键/中键拖拽 + 滚轮，触屏单指拖拽 + 双指捏合；
	# 短按不动（点按）经 view_tapped 转发到这里做贴片拾取
	_orbit = OrbitCameraScript.new()
	# 半径传给相机：拖动 1:1 增益按“相机到地表深度”换算（见 orbit_camera._drag_gain）
	_orbit.planet_radius = PLANET_RADIUS
	add_child(_orbit)
	_orbit.view_tapped.connect(_on_view_tapped)

	# 太阳：菜单相位就建好（方向先取默认值），生成世界时按种子换向
	#（见 _on_generate_requested）。注意菜单本身是不透明全屏面板、
	# 玩家看不到它 —— 太阳的首次可见时刻是生成完成、菜单收起的那一刻。
	_sun_dir = SunQuadScript.DEFAULT_DIRECTION
	_sun_quad = SunQuadScript.new()
	add_child(_sun_quad)
	_sun_quad.set_direction(_sun_dir)

	# 背景星空：菜单页就有（菜单背后不是死灰底）；种子等到生成请求时才填，
	# 菜单相位先用 0 号种子铺一层，玩家感知只是“星空早就挂在那了”。
	# 太阳方向一并传入：缩掉的星永远就是**当前这颗太阳**旁边的那批。
	_star_dome = StarDomeScript.new()
	add_child(_star_dome)
	_star_dome.build(0, _sun_dir)

	# 背景音乐（These_Lands.ogg）：不自动播，等星球生成完毕后再由代码开播。
	# 曲子是长循环的 BGM，导入参数已开 loop；这里再兜一次底（换资源时不失效）。
	_music = get_node_or_null("StartMusic") as AudioStreamPlayer
	if _music != null and _music.stream is AudioStreamOggVorbis:
		(_music.stream as AudioStreamOggVorbis).loop = true

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
	# 区域中心 = 生成这一刻镜头正对的方向：球冠围着玩家看到的半球长
	#（贴镜头、天然不落在极点），生成后镜头对准同一方向，零校准。
	_region_center = _camera_fwd_dir()
	# 太阳方向：由种子派生，锚在「生成后首屏」的视线**背后**（见 sun_quad.derive_direction）。
	# 锚点用 focus_on(_region_center) 之后镜头的真实朝向（forward_after_focus
	# 与 focus_on 共用同一套夹取逻辑，逐位一致）——这样即使玩家在生成过程中
	# 拖动镜头，首屏构图也不受影响。
	# 它是一个**世界方向**：之后玩家转镜头时太阳像真的那样在天空里移动
	#（视差由「相机相对定位」消除）。首屏它整个在视锥之外 —— 画面干净，
	# 玩家绕到星球另一侧才会看到它从边缘升出来。
	_sun_dir = SunQuadScript.derive_direction(
			params["seed"], _orbit.forward_after_focus(_region_center))
	# 星空：同种子同星图（换种子生成才会重铺；同种子短路时星穹保持不动）。
	# 成本几毫秒级，不值得为它分帧。
	# 顺带把太阳方向传进去：落在太阳光晕圆盘内的星星按原版规则缩小
	# （原版 WorldLayer_Stars.cs:63-68）——缩掉的正是**这颗太阳**周围的那批星。
	_star_dome.build(params["seed"], _sun_dir)

	var t0 := Time.get_ticks_msec()
	# 先让出一帧，让进度条状态先画到屏幕上，再开始第一段比较重的同步计算
	await get_tree().process_frame

	var mesh := await _build_goldberg_mesh_async(params["coverage"], _region_center)

	# 旧星球退场：二次生成时撤掉上一颗，避免叠在一起渲染
	if _mesh_instance != null:
		_mesh_instance.queue_free()
	if _atmosphere != null:
		_atmosphere.queue_free()
	# 星球上线：材质固定，MeshInstance 装配后加入场景
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.mesh = mesh
	var atlas := _ensure_biome_atlas()
	var mat := ShaderMaterial.new()
	mat.shader = load("res://planet_surface.gdshader")
	mat.set_shader_parameter("biome_atlas", atlas["texture"])
	mat.set_shader_parameter("macro_tex", atlas["macro"])
	mat.set_shader_parameter("cell_uv", atlas["cell_uv"])
	# gutter 尺寸：shader 从 UV2（格子原点）反推格号 → 判定水格（海面纯色化）
	mat.set_shader_parameter("gutter_uv", atlas["gutter_uv"])
	# 海面净色底 = Ocean 卡均色（水格不采色卡、不乘宏噪声；见 shader ocean_flat 注释）
	mat.set_shader_parameter("ocean_flat", atlas["ocean_flat"])
	_mesh_instance.material_override = mat
	add_child(_mesh_instance)
	# 大气光晕：紧跟星球上线（星球边缘那圈柔和的蓝白光晕，见 atmosphere.gdshader）
	_build_atmosphere()
	# 丘陵/山脉贴片层（第 2 期）：按 TerrainLevel 拆低丘/高山，priority 0 / 2。
	# 旧层与旧星球同步退场（同 _mesh_instance 的二次生成语义）。
	if _hills_low_instance != null:
		_hills_low_instance.queue_free()
		_hills_low_instance = null
	if _hills_high_instance != null:
		_hills_high_instance.queue_free()
		_hills_high_instance = null
	var hills := _build_hills_meshes(params["seed"])
	var low_mesh: ArrayMesh = hills["low"]
	var high_mesh: ArrayMesh = hills["high"]
	if low_mesh != null:
		_hills_low_instance = _make_hills_instance(low_mesh, 0)
		add_child(_hills_low_instance)
	if high_mesh != null:
		_hills_high_instance = _make_hills_instance(high_mesh, 2)
		add_child(_hills_high_instance)

	# 河流层（第 3 期一期）：priority 1 插在低丘/高山之间。
	# 二次生成先撤旧河，再按新地形重建。
	if _river_instance != null:
		_river_instance.queue_free()
		_river_instance = null
		_river_material = null
	_build_river_layer()

	# 生成完把画面交给玩家：镜头对准区域（球冠）中心——大陆正对着玩家，
	# 北极朝上。focus_on 对准生成前就定好的 _region_center，
	# look_at 的“上”参考恒为 +Y，北极自然始终在画面上方。
	for child in get_children():
		if child is OrbitCamera:
			child.focus_on(_region_center)

	# 太阳方向在生成一开始就定好了（见 _on_generate_requested 开头）：
	# 星空缩星与太阳本体必须用**同一个**方向，否则缩掉的星不是太阳旁边那批。
	# 太阳必定落在首屏视野内、且贴着星球轮廓外侧；不然 80% 的种子会「太阳不在画面里」。
	_sun_quad.set_direction(_sun_dir)

	print("星球生成完毕：种子 ", params["seed"],
			"，覆盖率 ", roundi(params["coverage"] * 100), "%，总耗时 ",
			Time.get_ticks_msec() - t0, " ms")

	# 背景音乐：星球生成完毕、玩家看得见星球的那一刻才开播（菜单阶段保持安静）。
	# 二次生成时若音乐已在放，不打断它（避免每次换种子都重来一遍前奏）。
	_start_music()

	# 菜单使命完成：先隐藏（避免和相机拖拽抢鼠标）再销毁。
	# 二次生成（代码直调 _on_generate_requested）时菜单可能已被撤掉，判空兜底。
	if _menu != null:
		_menu.hide_menu()
		_menu.queue_free()
		_menu = null


# 开播背景音乐（These_Lands.ogg）。
# 规则：等星球生成完毕才播——菜单与生成过程保持安静，星球一露面就有 BGM 衬底。
# 已在播就不重复触发（二次生成换种子时曲子不中断）。
func _start_music() -> void:
	if _music == null:
		return
	if not _music.playing:
		_music.play()


# 星球大气光晕（Rim Glow）：半径 1.06× 星球半径的球壳，套在星球外面。
# 纯代码构建（与项目“全代码动态构建”的风格一致），材质用 atmosphere.gdshader：
# 按「视线到球心的最近距离」开一条带 + 加法混合 → 星球轮廓外一圈**纤细的白色**光晕。
#
# 它的作用不只是好看：亮边压住背景星空的相对亮度，
# 星空因此显得更深邃（对应原版 RimWorld 的 WorldLayer_Glow）。
func _build_atmosphere() -> void:
	var sphere := SphereMesh.new()
	sphere.radius = PLANET_RADIUS * ATMOSPHERE_RADIUS
	sphere.height = PLANET_RADIUS * ATMOSPHERE_RADIUS * 2.0
	sphere.radial_segments = 64
	sphere.rings = 32
	var mat := ShaderMaterial.new()
	mat.shader = ATMOSPHERE_SHADER
	# 透明层叠次序：星空(0) → 太阳(10) → 大气光晕(20)。
	# 对应原版的材质队列 星空 1000 < 太阳 1001 < 辉光 3001（参考文档 §2.2）：
	# 太阳的光晕压在星点之上，而星点又先于辉光出现。
	# 用 render_priority 显式钉死这个次序，不依赖「按距离排序」的隐式结果
	#（星穹节点原点贴着相机，按距离排会得到相反的结论）。
	mat.render_priority = ATMOSPHERE_RENDER_PRIORITY
	_atmosphere = MeshInstance3D.new()
	_atmosphere.mesh = sphere
	_atmosphere.material_override = mat
	# 星球在原点，球壳跟着在原点即可（与星球 mesh 同坐标系）
	add_child(_atmosphere)


# 生成时刻视口相机的世界朝向（相机沿本地 -Z 看）。
# 菜单覆盖屏幕时相机也始终存在（_ready 已挂 OrbitCamera）；取不到时
# 退回 +Z 兜底，保证 _region_center 永远是单位方向。
func _camera_fwd_dir() -> Vector3:
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		var fwd := -cam.global_transform.basis.z
		if fwd.length_squared() > 1e-6:
			return fwd.normalized()
	return Vector3.FORWARD


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
	# 海岸收边（ConvertToIsland 思路）：球冠边缘带内把海拔往海平面下压，
	# 保证交互区最外圈是海——陆地不会被“一刀切断”在区域边界上，
	# 与区域外的未生成海面无缝相接（大陆架观感）。
	# 角距用 cos 代理（d 越小越靠边），带宽阈值由选区阶段预算好，
	# 逐贴片只有乘除比较，零求角函数调用；100% 档 _cap_shore=false 直接跳过。
	if _cap_shore:
		var d := _cap_center.dot(center)
		if d < _cap_cos_lerp0:
			var t := clampf((_cap_cos_lerp0 - d)
					/ (_cap_cos_lerp0 - _cap_cos_kill), 0.0, 1.0)
			elev = lerpf(elev, SEA_LEVEL - COAST_DEPTH, t)
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
func _terrain_level(elev: float) -> TerrainLevel:
	if elev < HILL1_ELEV:
		return TerrainLevel.FLAT # 海面（海底平原）与沿海平地都是平原
	if elev < HILL2_ELEV:
		return TerrainLevel.SMALL_HILLS
	if elev < MOUNT_ELEV:
		return TerrainLevel.LARGE_HILLS
	if elev < PEAK_ELEV:
		return TerrainLevel.MOUNTAINOUS
	return TerrainLevel.IMPASSABLE # 极高尖峰：建不了也翻不过去


# —— 贴片外观：顶点色 = 色调制器（不再输出最终色）——
# 最终色由 shader 里「生态贴图 ×（水格另有净色/近岸带处理）× 这里返回的调制器」合成：
#   rgb = 明暗乘数（越高级的地形越暗，玩家肉眼能读出「哪里翻不过去」）
#   a   = 往基岩色压的比例（shader 里向 ROCK_COLOR lerp；山区对半、不可逾越几乎纯岩）
# 平原/水域 = 全白不动色；海洋贴片的海色由 shader 的 ocean_flat/近岸白噪带给出。
# ⚠️ 水贴片例外：a 会被 ⑤c 改载「近岸 shore」∈[0,1]（离岸距离场，逐角点插值）
# ——陆地 a 是岩石量、水 a 是 shore，shader 用图集格号（v_is_water）区分，
# 两义互不污染；水贴片恒为 FLAT（dark=1、rock=0），改载无冲突。
func _tile_appearance(level: int) -> Color:
	var dark := 1.0 # 明暗乘数
	var rock_mix := 0.0 # 往基岩色压的比例
	match level:
		TerrainLevel.SMALL_HILLS:
			dark = 0.92 # 一点点暗：腿脚还行
		TerrainLevel.LARGE_HILLS:
			dark = 0.82
		TerrainLevel.MOUNTAINOUS:
			dark = 0.72
			rock_mix = 0.4 # 山区：贴图色 + 灰褐基岩对半
		TerrainLevel.IMPASSABLE:
			dark = 0.6
			rock_mix = 0.8 # 不可逾越：几乎纯基岩，一眼识别
	return Color(dark, dark, dark, rock_mix)


# —— 覆盖率选区：「扰动球冠」（重写于第 4 轮性能手术，参考 RimWorld WorldGrid 球冠裁切）——
# 旧实现“漫灌长大陆 + 三轮全海 BFS 清洗”的成本结构是倒挂的：
#   选区成本 ≈ 漫灌(∝覆盖率) + 清洗(∝1−覆盖率)×3轮 —— 覆盖率越低要扫的外海越大，
#   而 100% 走 fill(1) 短路一行不算。实测 30% 反而比 100% 慢数倍（微信端 9 秒级差距）。
# 新实现取第一性原理 + RimWorld 的结构性解法：区域不“浇”，直接用几何定义。
#
#   key(i) = 角距代理 (1 − dot(v_i, center)) × (1 + COAST_WIGGLE × 大陆噪声 v_i)
#   区域   = { key ≤ 第 N 小的 key }    —— 原生排序一次取第 N 名，面积精确 = N，零迭代
#
# · 面积精确：排序卡在第 N 名，无轮次无偏差回调（并列兜底见下）；
# · 单块连通：基底集合是球冠（测地凸域），噪声只把边界撕出犬牙，撕不碎主体；
# · 形状随机：COAST_WIGGLE 让每颗星球的海岸随种子变，大陆围镜头半球优先；
# · 内陆湖：不再是“洞”，区内海拔 < 海平面的低洼自然成湖（⑤ 循环里派生，
#   MIN_LAKE_TILES 语义退役）；
# · 补集税为零：区域外贴片不进任何后续循环——30% 与 100% 的耗时差
#   只剩 ⑤ 里逐贴片气候采样（∝覆盖率），倒挂结构性消失。
# 分帧：key 遍历与区域扫描按墙钟切片；排序为原生调用（10~20ms 量级）不切片。
# pct_from / pct_to：本函数占用全局进度条的区间（key 遍历 60%、区域扫描 40%）。
# 返回：{ "region": 贴片→1(已生成,可交互)/0(未生成,无地形) }；
#       收边参数写入成员 _cap_*（⑤ 气候采样时海岸收边消费）。
func _select_generated_region(verts: Array[Vector3], coverage: float,
		center: Vector3, pct_from := 30.0, pct_to := 34.0) -> Dictionary:
	var total := verts.size()
	var region := PackedByteArray()
	region.resize(total)
	var target := roundi(total * coverage)
	if target <= 0:
		_cap_shore = false # 覆盖率 0：整球不可探索，收边一并关闭
		return {"region": region}
	if target >= total:
		region.fill(1) # 100%：整球都是大陆，没有“边缘”可言，收边关闭
		_cap_shore = false
		return {"region": region}

	var span := pct_to - pct_from
	var key_to := pct_from + span * 0.6   # key 遍历占区间的 60%
	var mask_to := pct_to                  # 其余 40% 给区域扫描
	var t_sel := Time.get_ticks_msec()     # 选区内部阶段打点

	# 1) key 一遍（分片）：角距代理 × 噪声扰动。角距代理 = 1 − dot，
	#    省掉 total 次 acos 函数调用（GDScript 调用税不便宜）。
	var keys := PackedFloat32Array()
	keys.resize(total)
	var cn := _continent_noise # 本地别名：热循环里少一条成员链寻取
	var key_at := 0
	while key_at < total:
		var k_end := mini(key_at + SLICE_CHECK_STRIDE, total)
		for i in range(key_at, k_end):
			var d := 1.0 - verts[i].dot(center) # 0..2，角距的单调代理
			keys[i] = d * (1.0 + COAST_WIGGLE * cn.get_noise_3dv(verts[i]))
		key_at = k_end
		# 墙钟切片：每 ~512 项结一次钟，用满本帧就先算下一批
		if Time.get_ticks_msec() - _gen_slice_t0 >= _gen_budget:
			await _slice_yield(pct_from + (key_to - pct_from) * float(key_at) / total)
	t_sel = _stage_mark("④a大陆key遍历", t_sel)

	# 2) 精确面积：原生排序取第 N 小——key 升序副本的第 target-1 位
	#    （排序在主循环内同步完成，原生实现 10~20ms 量级，不值得切片）；
	#    keys 本体保持原序，区域扫描仍按贴片索引走。
	var order := keys.duplicate()
	order.sort()
	var theta := order[target - 1]
	t_sel = _stage_mark("④b面积排序", t_sel)

	# 3) 区域扫描（分片）：key ≤ 第 N 小 → 已生成；顺带统计并列（兜底用），
	#    并记录第 N 小 key 的贴片（它是区域内角距最大的贴片，收边 θ 以它为准——
	#    全域 key 最大的贴片多半在区域外，不能拿来当区域半径）。
	var count := 0
	var tie_cnt := 0
	var theta_tile := -1
	var mk_at := 0
	while mk_at < total:
		var m_end := mini(mk_at + SLICE_CHECK_STRIDE, total)
		for i in range(mk_at, m_end):
			if keys[i] <= theta:
				region[i] = 1
				count += 1
				if keys[i] == theta:
					tie_cnt += 1
			if keys[i] >= theta and theta_tile < 0:
				theta_tile = i
		mk_at = m_end
		# 墙钟切片：每 ~512 项结一次钟，用满本帧就让出
		if Time.get_ticks_msec() - _gen_slice_t0 >= _gen_budget:
			await _slice_yield(key_to + (mask_to - key_to) * float(mk_at) / total)
	# 并列兜底：连续 float 理论上极难同值，但真出现并列时，
	# 超出目标的贴片按索引顺序（确定性）退回未生成，面积仍然精确 = N。
	if count > target:
		var keep := tie_cnt - (count - target)
		var kept := 0
		for i in total:
			if region[i] == 0 or keys[i] != theta:
				continue
			kept += 1
			if kept > keep:
				region[i] = 0
	t_sel = _stage_mark("④c区域扫描", t_sel)

	# 4) 收边参数：θ 取区域内角距最大贴片（key = θ* 的那块）的真实角距
	#    （key 遍历的 best_i 是全域最远，多半在区域外，不能用）。过渡带/
	#    杀带宽度按 θ 比例裁（见常量表），预算好 cos 端点，⑤ 阶段气候
	#    逐贴片只做乘除比较，不调求角函数。区域小到退化（θ < 2°）时不
	#    收边：带宽除数没有意义，区域本身也只有几个贴片，观感无关紧要。
	var theta_rad := acos(clampf(verts[theta_tile].dot(center), -1.0, 1.0))
	_cap_center = center
	if theta_rad > deg_to_rad(2.0):
		_cap_shore = true
		_cap_cos_lerp0 = cos(theta_rad - theta_rad * COAST_TRANS)
		_cap_cos_kill = cos(theta_rad - theta_rad * COAST_KILL)
	else:
		_cap_shore = false
	return {"region": region}


# 全程分帧版生成管线：过去“点生成世界后僵住几秒”的根因是阶段 A（拓扑 +
# 打分 + 邻接 + 选区）一口气同步算完，画面毫无反馈。现在每个重活按帧切
# 片：每帧吃一小块、更新一次进度条、让出一帧给 UI。准备工作也计入进度：
#   ① 2~6%     二十面体基本顶点 + 棱插值点（量小，一口气完成）
#   ② 6~26%    逐个基本面细分出全球小三角网格（每个基本面一帧）
#   ③ 26~30%   顶点 → 相邻三角形索引表（分片扫描全部三角形）
#   ④ 30~34%   覆盖率选区：扰动球冠 key 遍历 + 排序取第 N + 区域扫描
#   ⑤ 34~97%   对偶贴片 + 颜色 + 网格数组（每帧一批）
#   ⑥ 97~100%  组装 ArrayMesh 收尾
# coverage：0..1，全球覆盖率——多大比例的球面生成真实地形（陆地/群系）。
# 选区由 _select_generated_region 按“扰动球冠”几何裁切：单块连通、面积精确；
# 其余贴片渲染为纯海洋底色且无地形数据，星球视觉连续不破相。
func _build_goldberg_mesh_async(coverage: float, center: Vector3) -> ArrayMesh:
	_progress(2.0)
	_slice_begin() # 管线起点即首帧切片起点（入口前刚让过一帧）
	var t_stage := Time.get_ticks_msec()  # 阶段耗时打点起点
	# 生态色卡图集：⑤ 循环逐片写 UV2 格子原点前必须就绪（惰性，一次生成只打包一次）
	_ensure_biome_atlas()

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
	# 同循环顺带预计算三角形球面重心存表：它是同一个顶点周围贴片共享的
	# 对偶顶点候选，原本 ⑤ 逐贴片要重算 3 遍，这里只算一遍（合并不白费）。
	var tri_cents := PackedVector3Array()
	tri_cents.resize(tris.size())
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
			tri_cents[ti] = (verts[tri.x] + verts[tri.y] + verts[tri.z]).normalized()
		tri_at = endi
		# 墙钟切片：每 ~512 项结一次钟，用满本帧就让出
		if Time.get_ticks_msec() - _gen_slice_t0 >= _gen_budget:
			await _slice_yield(26.0 + 4.0 * float(tri_at) / tris.size())

	# 保留拓扑方向表：生成完仍要回答“这个球面点能不能交互”
	_topo_verts = verts
	t_stage = _stage_mark("③邻接面表", t_stage)

	# ===== ④ 覆盖率选区：一整块连通的“可交互区域”（内部全程分帧，30→34%）=====
	# 旧实现：洗牌取前 coverage 比例 → 生成区是满天星的碎孤岛。
	# 现实现见 _select_generated_region：“扰动球冠”，面积精确、单块连通、
	# 形状随种子随机自然；区内低洼再派生为内海/内陆湖（⑤ 循环里）。
	var select_result: Dictionary = await _select_generated_region(
			verts, coverage, center, 30.0, 34.0)
	var explored: PackedByteArray = select_result["region"]
	_inland_water = PackedByteArray()
	_inland_water.resize(total)      # 区内水域标记由 ⑤ 循环按海拔派生填入
	_generated = explored            # 运行期“能否交互”查询表
	_terrain.resize(total)           # 地形等级在阶段 B 逐贴片填充
	# HUD 显示缓存：群系 id / 海拔 / 温湿度（未生成贴片保持 BIOME_NONE / 0）
	_tile_biome.resize(total)
	_tile_biome.fill(BIOME_NONE)
	_tile_elev.resize(total)
	_tile_temp.resize(total)
	_tile_humid.resize(total)
	t_stage = _stage_mark("④覆盖率选区", t_stage)

	# ===== 阶段 B：对偶贴片 + 颜色 + 网格数组（分帧） =====
	# 二次生成：贴片几何全部重来，旧的选择状态一并清掉（避免索引错位/悬空高亮）
	_tile_polys = []
	_tile_centers.clear()
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
	# UV2 = 生态色卡图集的格子原点（逐片恒定，见 biome_atlas.gd / 规划文档 §3①）：
	# fragment 按它定位该片 biome 的图集格子 —— 这是「7 个 biome 仍只有 1 次 draw call」的关键
	var mesh_uv2 := PackedVector2Array()
	mesh_uv2.resize(total_corners)
	var mesh_indices := PackedInt32Array()
	mesh_indices.resize(3 * (total_corners - 2 * total))
	# 每贴片输出暂存（⑤ 循环只攒数据；网格数组在 ⑤b 距离场算完后由 ⑤c 统一写）：
	#   col/cell 逐片常量；poly_tris = 按方位角排序后的「角点 → 角三角号」
	#   （⑤c 查该贴片各角点的离岸 shore 平均值要用，不能丢）。
	var tile_cols := PackedColorArray()
	var tile_cells := PackedVector2Array()
	var poly_tris: Array[PackedInt32Array] = []
	# 每贴片复用的环排序暂存（角点数 ≤6）：省掉每贴片 1 次 Array 分配 +
	# 6 次 append + 1 次 PackedFloat resize 的固定开销
	var ring_buf: Array[Vector3] = []
	ring_buf.resize(6)
	var ang_buf := PackedFloat32Array()
	ang_buf.resize(6)
	var tri_buf: Array[int] = [] # 与 ring_buf 同序的角三角号（排序时同步搬移）
	tri_buf.resize(6)
	for v in total:
		var axis := verts[v] # 已是单位向量
		# 收集该点周围一圈三角形的重心（对偶多边形的顶点，③ 阶段已算好存表）；
		# 顺带累加出贴片中心方向（center = 重心均值方向），免再开一条循环
		var vert_rings: PackedInt32Array = vert_faces[v] # 本地别名：少一次成员链寻取
		var n := vert_rings.size()
		var cent_sum := Vector3.ZERO
		var kc := 0
		for ti in vert_rings:
			var c := tri_cents[ti]
			ring_buf[kc] = c
			tri_buf[kc] = ti
			cent_sum += c
			kc += 1
		# 把相邻面重心按“绕 axis 的方位角”排序，才能连成不自交的多边形。
		# 5/6 个元素的小数组：先算好角度再手写插入排序——比 sort_custom 的
		# GDScript lambda 回调（每贴片 ~11 次脚本调用）快一个数量级。
		var e1: Vector3 = (ring_buf[0] - axis * ring_buf[0].dot(axis)).normalized()
		var e2 := axis.cross(e1)
		for kk in n:
			ang_buf[kk] = _tangent_angle(ring_buf[kk], axis, e1, e2)
		for kk in range(1, n):
			var ca := ang_buf[kk]
			var cp: Vector3 = ring_buf[kk]
			var ct: int = tri_buf[kk]
			var j := kk - 1
			while j >= 0 and ang_buf[j] > ca:
				ang_buf[j + 1] = ang_buf[j]
				ring_buf[j + 1] = ring_buf[j]
				tri_buf[j + 1] = tri_buf[j]
				j -= 1
			ang_buf[j + 1] = ca
			ring_buf[j + 1] = cp
			tri_buf[j + 1] = ct
		# 缓存贴片边界顶点（单位球面，顺序与方位角排序一致）：点击选中时
		# 用它们生成高亮环；索引与 _topo_verts/_terrain 一致。每贴片要私有
		# 数组，不能用复用缓冲，按 n 精确拷出
		var poly := PackedVector3Array()
		poly.resize(n)
		for kk in n:
			poly[kk] = ring_buf[kk]
		_tile_polys.append(poly)
		var pt := PackedInt32Array()
		pt.resize(n)
		for kk in n:
			pt[kk] = tri_buf[kk]
		poly_tris.append(pt)

		# 贴片颜色：未生成 → 深洋观感（第 8 格 Ocean 卡备份），不做地形噪声采样
		#（这些贴片没有地形）；
		# 已生成 → 气候采样，区内海拔 < 海平面的低洼自然派生为水域
		# （内海/内陆湖/大陆架）——渲染群系表的海色/海冰，地形按海拔自然
		# 落在平原；不再需要旧的“内陆湖强制海色”分支，湖与海同色同地形，
		# 极区的内陆水域还会自然结冰（比旧语义更真实）。
		# 中心方向的重心均值已在上面 cents 循环里累出（同一批球的面向量）
		var tile_dir := (cent_sum / n).normalized() # 贴片中心方向：噪声与纬度的采样点
		_tile_centers.append(tile_dir) # 中心缓存：丘陵 quad 按它定位（与 _tile_polys 同序）
		var level := TerrainLevel.NOT_GENERATED
		# 顶点色 = 色调制器（不再是最终色，最终色由「贴图 × macro × 它」合成）：
		# 未生成 → 全白不动色、a 占位 0——恰与生成海域的 _tile_appearance(FLAT)
		# 同值（且第 8 格也是 Ocean 卡）→ 三件套全对齐，覆盖区边界无亮度台阶。
		# ⚠️ 不能用 Color.WHITE——它的 a=1。
		# 水贴片（海洋0/未生成）的 a 由 ⑤c 逐角点改载「近岸 shore」（陆地 a 保持岩石量）
		var col := Color(1.0, 1.0, 1.0, 0.0)
		# 图集格子原点（UV2）：未生成 → 第 8 格（Ocean 卡备份 = 遥远深洋）；
		# 已生成 → 该片 biome 的格子
		var cell: Vector2 = _biome_cell_origins[7]
		if explored[v] == 1:
			# 气候采样：水域贴片同样采样（HUD 要显示它的海拔/温湿度）；
			# 海岸收边已在 _climate_fill 内部作用到海拔上。
			_climate_fill(tile_dir, cli) # 复用数组，热循环零字典分配
			var elev: float = cli[0]
			var temp: float = cli[1]
			var humid: float = cli[2]
			_tile_elev[v] = elev
			_tile_temp[v] = temp
			_tile_humid[v] = humid
			_inland_water[v] = 1 if elev < SEA_LEVEL else 0
			level = _terrain_level(elev)
			var biome := _biome_id(elev, temp, humid)
			_tile_biome[v] = biome
			col = _tile_appearance(level)
			cell = _biome_cell_origins[biome]
		_terrain[v] = level
		tile_cols.append(col)
		tile_cells.append(cell)

		# 让出线程：每 ~512 贴片结一次墙钟，本帧吃满才让（批内零查钟）
		if v % SLICE_CHECK_STRIDE == SLICE_CHECK_STRIDE - 1 or v == total - 1:
			if Time.get_ticks_msec() - _gen_slice_t0 >= _gen_budget:
				await _slice_yield(34.0 + 57.0 * float(v + 1) / total)

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
	t_stage = _stage_mark("⑤对偶贴片", t_stage)

	# ===== ⑤b 近岸离岸距离场（参考 24-OceanShoreNoise.md，见 docs/planet_textures_plan.md §3⑥）=====
	# 邻接不必另建搜索表：对偶贴片共享一条棱 ⇔ 共享两个角三角；而每个角三角恰有
	# 3 个汇入贴片 → 建 [角三角 → 3 贴片] 平表（tri_tiles），BFS 逐角三角扫 3 邻居。
	# 种子 = 已生成陆地贴片（biome≥2，海冰/冰盖之外都是岸线）；只在开放水域
	# （海洋 0 / 未生成 BIOME_NONE）传播；海冰(1) 不传播 —— 冰缘不出白噪带。
	# 距离单位 = 贴片跳数（Goldberg 贴片尺寸高度均匀，跳数 ≈ 角距）。
	var tri_tiles := PackedInt32Array()
	tri_tiles.resize(tris.size() * 3)
	var tri_cnt := PackedInt32Array()
	tri_cnt.resize(tris.size())
	var fill_at := 0
	while fill_at < total:
		var fill_end := mini(fill_at + SLICE_CHECK_STRIDE * 8, total)
		for w in range(fill_at, fill_end):
			for ti in vert_faces[w]:
				tri_tiles[3 * ti + tri_cnt[ti]] = w
				tri_cnt[ti] += 1
		fill_at = fill_end
		if Time.get_ticks_msec() - _gen_slice_t0 >= _gen_budget:
			await _slice_yield(91.0 + 1.0 * float(fill_at) / float(total))

	# ===== ⑤b-adj 贴片邻接（河流水文用）=====
	# 共享一条棱 ⇔ 共享两个角三角；对每个贴片，取它周围每个角三角的另外两个
	# 汇入贴片，去重后存 N×6（不足 6 个 -1）。纯拓扑，不依赖水深/群系。
	_tile_neighbors = PackedInt32Array()
	_tile_neighbors.resize(total * 6)
	_tile_neighbors.fill(-1)
	_tile_neighbor_count = PackedByteArray()
	_tile_neighbor_count.resize(total)
	var adj_at := 0
	while adj_at < total:
		var adj_end := mini(adj_at + SLICE_CHECK_STRIDE, total)
		for w in range(adj_at, adj_end):
			var cnt := 0
			for ti in vert_faces[w]:
				for s in 3:
					var u := tri_tiles[3 * ti + s]
					if u == w:
						continue
					var dup := false
					for k in cnt:
						if _tile_neighbors[w * 6 + k] == u:
							dup = true
							break
					if not dup and cnt < 6:
						_tile_neighbors[w * 6 + cnt] = u
						cnt += 1
			_tile_neighbor_count[w] = cnt
		adj_at = adj_end
		if Time.get_ticks_msec() - _gen_slice_t0 >= _gen_budget:
			await _slice_yield(91.1)

	# ===== ⑤b0 小水域剔除（封闭小湖填成陆地，见 docs/planet_textures_plan.md §3⑥）=====
	# 微型内陆湖整湖都落在近岸白噪带里 → 整片泛白像白斑（temp/sea_wave*.png），
	# 按用户确认的阈值剔除：水贴片（海洋0/海冰1/未生成255）沿角三角邻接做连通域，
	# 含未生成贴片的分量是真海/内海**永不剔除**；纯已生成且 ≤MIN_LAKE_TILES 的
	# 封闭分量（含结冰小湖）抬海拔到海平面上 → 重判群系/地形，填成陆地。
	# 放在离岸距离场**之前** → 填出来的陆地自动成为岸线种子，数据一步到位。
	var lake_seen := PackedByteArray()
	lake_seen.resize(total)
	var lake_comp := PackedInt32Array()
	var lake_culled := 0
	var lake_at := 0
	while lake_at < total:
		var lake_end := mini(lake_at + SLICE_CHECK_STRIDE * 8, total)
		for w0 in range(lake_at, lake_end):
			if lake_seen[w0] != 0:
				continue
			var bw0: int = _tile_biome[w0]
			lake_seen[w0] = 1
			if bw0 != 0 and bw0 != 1:
				continue # 陆地不是分量成员（海冰=1 仍算水：结冰小湖同样剔除）
			# BFS 收集连通分量；碰到未生成贴片 → 真海/内海，整分量保留
			lake_comp.clear()
			lake_comp.append(w0)
			var is_open := bw0 == BIOME_NONE
			var head := 0
			while head < lake_comp.size():
				var u: int = lake_comp[head]
				head += 1
				for ti in vert_faces[u]:
					var tri: Vector3i = tris[ti]
					for s in 3:
						var w2: int = tri[s]
						if lake_seen[w2] != 0:
							continue
						var bw2: int = _tile_biome[w2]
						lake_seen[w2] = 1
						if bw2 != 0 and bw2 != 1:
							continue # 陆地不入分量
						if bw2 == BIOME_NONE:
							is_open = true
						lake_comp.append(w2)
			if is_open or lake_comp.size() > MIN_LAKE_TILES:
				continue
			# 封闭小湖 → 填成陆地：海拔抬到海平面略上（FLAT 不长丘陵），
			# 群系按温湿度重判（寒带自然成冰盖/苔原，与周边气候一致）
			for u2 in lake_comp:
				_tile_elev[u2] = SEA_LEVEL + LAKE_FILL_ELEV
				_inland_water[u2] = 0
				var tb: int = _biome_id(_tile_elev[u2], _tile_temp[u2], _tile_humid[u2])
				_tile_biome[u2] = tb
				_terrain[u2] = TerrainLevel.FLAT
				tile_cols[u2] = _tile_appearance(TerrainLevel.FLAT)
				tile_cells[u2] = _biome_cell_origins[tb]
			lake_culled += lake_comp.size()
		lake_at = lake_end
		if Time.get_ticks_msec() - _gen_slice_t0 >= _gen_budget:
			await _slice_yield(91.5)
	_lake_culled = lake_culled
	print("小水域剔除：", lake_culled, " 贴片（≤", MIN_LAKE_TILES,
			" 片的封闭湖填为陆地；连通未生成深洋的分量保留）")

	var shore_dist := PackedFloat32Array()
	shore_dist.resize(total)
	shore_dist.fill(-1.0) # -1 = 未访问（被冰封死的孤立水域视为深海，不出带）
	var bfs_q := PackedInt32Array()
	var bfs_head := 0
	for w in total:
		if explored[w] == 1 and _tile_biome[w] >= 2:
			shore_dist[w] = 0.0
			bfs_q.append(w)
	while bfs_head < bfs_q.size():
		# 普通队列 BFS：等权跳数 → FIFO 出队序即最短序，首次到达即最终距离
		var q_end := mini(bfs_head + SLICE_CHECK_STRIDE * 8, bfs_q.size())
		while bfs_head < q_end:
			var u := bfs_q[bfs_head]
			bfs_head += 1
			var du := shore_dist[u] + 1.0
			for ti in vert_faces[u]:
				for s in 3:
					var w2 := tri_tiles[3 * ti + s]
					var bw2: int = _tile_biome[w2]
					if bw2 != 0 and bw2 != BIOME_NONE: # 海冰/其他非水不传播
						continue
					if shore_dist[w2] < 0.0:
						shore_dist[w2] = du
						bfs_q.append(w2)
		if bfs_head < bfs_q.size() and Time.get_ticks_msec() - _gen_slice_t0 >= _gen_budget:
			await _slice_yield(92.5)

	# ===== ⑤b0b 逐水域分量的有效带宽 ring_w（带宽随水域大小自适应）=====
	# 固定 4 跳带宽对大洋正合适，但对半径 2~4 跳的小湖会把整湖淹进白雾
	# （temp/sea_wave3.png：湖心到不了深蓝，整湖读作白斑，反而没有海岸线感）。
	# 视觉带宽应是水域半径的一个比例：ring_w = clamp(D_max × LAKE_RING_RATIO,
	# MIN_LAKE_RING_HOPS, SHORE_BAND_HOPS)——大洋/内海 D_max 大 → 封顶 = 带宽，
	# 观感与固定带宽完全一致；小湖按比例收窄 → 白雾只贴岸一圈，湖心 s=0 回归
	# 深蓝净色（s=0 恒 0 的无缝不变量与假白环防护全部原样保住）。
	# 连通域口径与 ⑤b0 剔除一致：水贴片（0/海冰1/未生成255）沿角三角邻接。
	var ring_w := PackedFloat32Array()
	ring_w.resize(total)
	ring_w.fill(SHORE_BAND_HOPS) # 陆地/未覆盖占位（陆地走 s=1 常量分支不查表）
	var comp_seen := PackedByteArray()
	comp_seen.resize(total)
	var comp_q := PackedInt32Array()
	var ring_min := SHORE_BAND_HOPS
	var comp_cnt := 0
	for w in total:
		if comp_seen[w] != 0:
			continue
		var bw: int = _tile_biome[w]
		comp_seen[w] = 1
		if bw != 0 and bw != 1 and bw != BIOME_NONE:
			continue # 陆地不属于任何水域分量
		# BFS 收集连通分量，顺带求分量内最大离岸跳数 D_max
		comp_q.clear()
		comp_q.append(w)
		var d_max := 0.0
		var c_head := 0
		while c_head < comp_q.size():
			var u: int = comp_q[c_head]
			c_head += 1
			d_max = maxf(d_max, shore_dist[u]) # 未访问 -1 不影响（max 起点 0）
			for ti in vert_faces[u]:
				for s in 3:
					var w2 := tri_tiles[3 * ti + s]
					if comp_seen[w2] != 0:
						continue
					var bw2: int = _tile_biome[w2]
					comp_seen[w2] = 1
					if bw2 != 0 and bw2 != 1 and bw2 != BIOME_NONE:
						continue # 陆地不入分量
					comp_q.append(w2)
		var ring := clampf(d_max * LAKE_RING_RATIO, MIN_LAKE_RING_HOPS,
				SHORE_BAND_HOPS)
		if comp_q.size() > 1 and ring < SHORE_BAND_HOPS:
			ring_min = minf(ring_min, ring)
		comp_cnt += 1
		for i in comp_q.size():
			ring_w[comp_q[i]] = ring
		if Time.get_ticks_msec() - _gen_slice_t0 >= _gen_budget:
			await _slice_yield(92.4)
	print("有效带宽自适应：水域分量 ", comp_cnt, " 个，ring 最小 ", ring_min,
			" 跳（RATIO ", LAKE_RING_RATIO, "，大洋封顶 ", SHORE_BAND_HOPS, "）")

	# 逐贴片 s 域归一 → 角点平均（⑤c 直接查表）：
	#   水贴片 s = clamp((ring_w − dist)/(ring_w − 1), 0, 1)：dist=1 恰拉满 1，
	#   dist ≥ ring_w → 0（小湖湖心/大洋深水同样到 0）；ring_w = 带宽时与旧公式
	#   (BAND−avg)/(BAND−1) 逐角等价（affine + 末端 clamp，实测像素无差异）。
	#   陆地 s = 1（贴岸拉满）；海冰不参与平均（冰缘不出带）；
	#   未访问水域（-1）按深海 → s 0。逐贴片 clamp 再平均 → 混合角
	#   （两湖夹一陆）各用各的 ring_w，自然处理。
	var corner_shore := PackedFloat32Array()
	corner_shore.resize(tris.size())
	var corner_at := 0
	while corner_at < tris.size():
		var corner_end := mini(corner_at + SLICE_CHECK_STRIDE * 16, tris.size())
		for ti in range(corner_at, corner_end):
			var ssum := 0.0
			var cnt := 0
			for s in 3:
				var w2 := tri_tiles[3 * ti + s]
				if _tile_biome[w2] == 1: # 海冰不参与角点平均
					continue
				var dv := shore_dist[w2]
				if dv < 0.0:
					ssum += 0.0 # 未访问水域 = 深海
				elif dv == 0.0:
					ssum += 1.0 # 陆地：贴岸角点拉满
				else:
					var rw := ring_w[w2]
					ssum += clampf((rw - dv) / maxf(rw - 1.0, 0.001), 0.0, 1.0)
				cnt += 1
			var shore := 0.0
			if cnt > 0:
				shore = clampf(ssum / float(cnt), 0.0, 1.0)
			corner_shore[ti] = shore
		corner_at = corner_end
		if Time.get_ticks_msec() - _gen_slice_t0 >= _gen_budget:
			await _slice_yield(93.5)
	t_stage = _stage_mark("⑤b离岸距离场", t_stage)

	# ===== ⑤c 写网格数组（逐角点：水贴片 a = 近岸 shore，其余照旧）=====
	_progress(94.0)
	var vert_cursor := 0 # 已写满的角点数（同时是下一块贴片的顶点基址）
	var idx_cursor := 0  # 已写满的索引数
	var write_at := 0
	while write_at < total:
		var write_end := mini(write_at + SLICE_CHECK_STRIDE, total)
		for v in range(write_at, write_end):
			var poly: PackedVector3Array = _tile_polys[v]
			var n: int = poly.size()
			var cell: Vector2 = tile_cells[v]
			var col: Color = tile_cols[v]
			var bw: int = _tile_biome[v]
			# 水贴片 = shader 的水格（海洋 0 / 未生成 BIOME_NONE）→ a 改载 shore；
			# 海冰(1)/陆地贴片保持岩石量语义（_tile_appearance 已给出）
			var shore_water: bool = bw == 0 or bw == BIOME_NONE
			var pts: PackedInt32Array = poly_tris[v]
			# 每贴片用一组“独占”顶点 → 角点 shore 片内线性插值、跨片连续：
			# 共享角点由同一组汇入贴片平均得出，两片必同值 → 无缝渐变（非等高线环）。
			var base := vert_cursor
			for k in n:
				mesh_verts[base + k] = poly[k] * PLANET_RADIUS
				var c := col
				if shore_water:
					c.a = corner_shore[pts[k]]
				mesh_colors[base + k] = c
				mesh_uv2[base + k] = cell
			# 凸多边形扇形三角化（五/六边形都是凸的）
			for i in range(1, n - 1):
				mesh_indices[idx_cursor] = base
				mesh_indices[idx_cursor + 1] = base + i
				mesh_indices[idx_cursor + 2] = base + i + 1
				idx_cursor += 3
			vert_cursor += n
		write_at = write_end
		if write_at < total and Time.get_ticks_msec() - _gen_slice_t0 >= _gen_budget:
			await _slice_yield(94.0 + 3.0 * float(write_at) / float(total))
	t_stage = _stage_mark("⑤c网格写入", t_stage)

	# 已生成贴片索引：河流 injection / 候选 / 统计都只遍历生成区，
	# 避免每次在 40,962 个贴片里反复 if _generated[v]。
	_generated_ids.resize(total)
	var gen_n := 0
	for v in total:
		if _generated[v] == 1:
			_generated_ids[gen_n] = v
			gen_n += 1
	_generated_ids.resize(gen_n)

	# ===== ⑥ 收尾：组装 ArrayMesh（让 97% 先画出来再干最后一下）=====
	_progress(97.0)
	await get_tree().process_frame
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = mesh_verts
	arrays[Mesh.ARRAY_COLOR] = mesh_colors
	arrays[Mesh.ARRAY_TEX_UV2] = mesh_uv2
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
	# 对切平面投影做 atan2 即可；atan2 对正比例缩放不变，无需 normalize
	# 转单位长度（省一次归一化，每贴片 ×6 的固定开销）。
	var pp := p - axis * p.dot(axis)
	return atan2(pp.dot(e2), pp.dot(e1))
