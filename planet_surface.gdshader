shader_type spatial;
// 星球地表三层质感（见 docs/planet_textures_plan.md）：
//   ① 生态色卡贴图（原版手绘低对比噪声，逐片按 UV2 定位图集格子；
//        **水格不采色卡**——底色换成 Ocean 卡的均色纯色，见 ocean_flat 说明）
//   × ② WorldMacro 宏观噪声（大陆尺度斑块，全星球共享，打散平铺重复感；
//        陆地/海冰/冰盖全保留；水格不带（纯色海面，ocean_macro 调节档））
//   × ③ 顶点色调制器（贴片级地形明暗 + 山体基岩混合）
// unshaded：颜色全部由上面三层给出，不受场景光照影响。
// cull_disabled：双面渲染（沿用原实现——放大穿进去看时内壁也有颜色）。
render_mode unshaded, cull_disabled;

// 生态色卡图集（biome_atlas.gd 运行期打包：4×2 共 8 格，第 8 格=未生成深洋的
// Ocean 卡备份）。采样坐标经 fract() 折进本格，不依赖 repeat；mipmap 由打包时
// generate_mipmaps 提供。
uniform sampler2D biome_atlas : source_color, filter_linear_mipmap;
// 全局宏观噪声（整张平铺，低频）——UV 超出 [0,1]，必须 repeat。
uniform sampler2D macro_tex : source_color, filter_linear_mipmap, repeat_enable;
// 单格有效区 UV 尺寸（不含 gutter），由 planet.gd 从图集打包结果回填。
uniform vec2 cell_uv = vec2(0.2222, 0.4444);
// 单格 gutter（四边）的 UV 尺寸，由 planet.gd 从图集打包结果回填。
// 用途：从 UV2（格子原点）反推格号 → 判定该贴片是不是水格（见 vertex）。
// 默认值 = 打包常量算出的真值（GUTTER=64, aw=4*384=1536, ah=2*384=768）：
//   gutter_uv = (64/1536, 64/768) = (0.0416667, 0.0833333)
uniform vec2 gutter_uv = vec2(0.0416667, 0.0833333);

// 山体基岩色：与 planet.gd 的 C_ROCK 同值，顶点色 a（岩石混合量）向它 lerp。
const vec3 ROCK_COLOR = vec3(0.45, 0.42, 0.39);
// 主贴图每立方体面平铺次数（原版 20；我们贴片数是原版 4 倍、颗粒相对更细，
// 初值 8 —— 出截图后按 docs/planet_textures_plan.md §4 调参）。
const float TILING = 8.0;
// WorldMacro 每面平铺次数（照抄原版 1.5 → 大陆尺度斑块）。
const float MACRO_TILING = 1.5;
// WorldMacro 的**原始字节空间**均值 —— ocean_macro 调节档的基准常数。
// ⚠️ 为什么不是 sRGB→线性后的均值（0.78902…）：本工程的色卡/宏观噪声在 shader 里
// 取到的就是 PNG 原字节值（source_color 未再解码），显示端也不二次编码 ——
// 实测「海面像素 = 色卡原值 × 乘数」逐位成立：
//   改前 0.2728 × 0.90036 = 0.2456 ≈ 实测 0.2437；
//   用线性均值时 0.2728 × 0.78902 = 0.2153 ≈ 实测 0.2131（海面暗 12.5%）。
// 实测（assets/WorldMacro.png 全部 65536 texel，逐通道字节平均）：
//   (0.90036, 0.89907, 0.90036)，逐通道标准差 6.33/255 → 乘数范围 0.801~0.969。
const vec3 MACRO_MEAN = vec3(0.90036, 0.89907, 0.90036);
// 水格保留的 WorldMacro 振荡比例：0 = 净色（默认，海面就是平滑深蓝纯色），
// 1 = 与陆地同款（大陆尺度宏观噪声）。现场可调（set_shader_parameter("ocean_macro",
// x)），零改码。默认 0 的依据：宏观噪声乘在纯色底上呈大片脏斑（2026-10 用户实测
// 反馈「看着有点脏」），净色档 σ≈1.9e-13 完美均匀；平均亮度与 1 档完全一致
//（宏观噪声的均值恰为 MACRO_MEAN）。
uniform float ocean_macro = 0.0;
// 海面纯色底 = Ocean 色卡 256² 的逐通道均值（biome_atlas.gd 打包时实测回填；
// 兜底值 = 手测 (59,70,92)/255）。为什么水格不采色卡：色卡自带「细颗粒 + 低频
// 亮斑」，被 fract(p*TILING) 平铺 16×16 次/立方体面后呈**规则点阵**（2026-10
// 实测三证据：自相关峰恰在平铺周期 115px@dist2.5 且 r=0.447、TILING 8→16 峰位
// 115→57 严格反比、采常数 UV 则 sd=0.000000）。格子 0 与 7 底色同为一常数 →
// 未生成深洋与已生成海域逐像素一致，覆盖区边界无缝的性质不变。
uniform vec3 ocean_flat = vec3(0.2328, 0.2765, 0.3590);

// 顶点色 = 色调制器：rgb = 明暗乘数（1.0 = 原亮度），a = 岩石混合量。
varying vec4 v_tile_color;
// UV2 = 图集格子原点（贴片内全部顶点同值 → 插值无损，逐片恒定）。
varying vec2 v_cell_origin;
// 水格标记（1 = 该贴片是海面），逐片恒定（由 UV2 反推格号得到）。
varying float v_is_water;
// 世界坐标（vertex 算一次，fragment 归一化后做盒式投影）。
varying vec3 v_world_pos;

void vertex() {
	v_tile_color = COLOR;
	v_cell_origin = UV2;
	// —— 水格标记：从 UV2（格子原点）反推格号 ——
	// 格原点 = (GUTTER + (i%COLS)*cell) / aw → (origin - gutter_uv) / 格距 = 格号（整数）。
	// 格距 = cell_uv + 2*gutter_uv（含 gutter 的整格步距）。
	// 图集布局 4 列 × 2 行：格 0 = Ocean（海洋/内陆湖），格 7 = 未生成深洋备份
	//（覆盖率外的"不可探索区域"）。这两格就是全部的水 → 净色纯色海面（ocean_flat）。
	// 改 biome_atlas 的 COLS/ROWS 时，这里的两个格号判据要同步改。
	vec2 pitch = cell_uv + 2.0 * gutter_uv;
	vec2 ij = round((v_cell_origin - gutter_uv) / pitch);
	float d_ocean = length(ij - vec2(0.0, 0.0)); // 第 0 格
	float d_deep = length(ij - vec2(3.0, 1.0));  // 第 7 格
	v_is_water = clamp((1.0 - step(0.5, d_ocean)) + (1.0 - step(0.5, d_deep)), 0.0, 1.0);
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

// 盒式投影：按主导轴把球面方向摊到 [-1,1] 平面（原版 WorldTerrain 同款）。
// 逐片独立选主导轴 → 同 biome 跨片纹理连续，无「每六边形一张图」的接缝。
vec2 box_project(vec3 n) {
	vec3 a = abs(n);
	if (a.x >= a.y && a.x >= a.z) {
		return n.zy / a.x; // 主导轴 ±x：投影到 zy 平面
	}
	if (a.y >= a.z) {
		return n.xz / a.y;
	}
	return n.xy / a.z;
}

void fragment() {
	vec3 n = normalize(v_world_pos);
	vec2 p = box_project(n);
	// LOD 手算 + textureLod()，避开两处屏幕导数突跳（实证截图里过视图中心的
	// 细暗十字 = fract 整数边界处 UV 跨整格跳变 → 导数爆炸 → 误采最高 mip →
	// 与图集 gutter/邻格混色；切轴边界处 p 本身跳变，同理会炸）：
	//   n 处处连续；|p| 与主导轴幅值在切轴边界两侧相等 → jac 连续 → LOD 平滑。
	float a_dom = max(max(abs(n.x), abs(n.y)), abs(n.z));
	float jac = (1.0 + length(p)) / a_dom; // 盒式投影雅可比上界（切轴处连续）
	float sn = max(length(dFdx(n)), length(dFdy(n)));
	// 平铺 1 单位 = 1 格 = 256px（与 biome_atlas.gd 的 SPRITE 对应）→ 图素足迹；
	// 下限 1 → 放大时 lod=0 采原图，不被 log2 负值带偏。
	float lod = log2(max(sn * jac * TILING * 256.0, 1.0));
	vec2 uv_card = v_cell_origin + fract(p * TILING) * cell_uv;
	// 水格：底色换成 Ocean 卡均色常数（见 ocean_flat 注释——色卡平铺 16×16 次/
	// 立方体面后细颗粒+亮斑呈规则点阵，纯色底让点阵从数学上消失）。陆地路径不变。
	vec3 base = mix(textureLod(biome_atlas, uv_card, lod).rgb, ocean_flat, v_is_water);
	// 宏观斑块：整张 WorldMacro 低频平铺，全星球连续（相邻生态共享同一批斑块 → 边界被洗软）。
	// WorldMacro 导入未开 mip（mipmaps/generate=false）→ texture() 恒采 base 层，
	// 切轴处导数突跳不产生混色伪影；若日后开 mip 需换成同款手算 LOD。
	vec3 macro = texture(macro_tex, p * MACRO_TILING).rgb;
	// ③ 顶点色：rgb 明暗乘数（丘陵压暗），a 岩石混合（山区往基岩色压）。
	vec3 tinted = mix(base * v_tile_color.rgb, ROCK_COLOR, v_tile_color.a);
	// —— 水格：净色纯色（有意偏离原版，见 docs/planet_textures_plan.md §3⑤）——
	// 原版海面 = Ocean 卡 × WorldMacro。这里水格“色卡 × 宏观噪声”全都不乘：
	//   · 色卡内容平铺 16×16 次/立方体面会呈规则点阵（摊平版实测自相关尖峰
	//     r=0.447 恰在平铺周期）→ 底色换纯色常数，点阵从数学上消失；
	//   · 宏观噪声乘在纯色底上呈大片低频脏斑（用户实测「海面看着有点脏」）
	//     → 默认也关掉，海面就是平滑深蓝纯色；
	//   · 平均亮度不变：ocean_macro=0 时乘 MACRO_MEAN（=宏观噪声的均值），与
	//     全强度档的平均亮度完全一致，海陆之间无亮度台阶。
	// ocean_macro=1 → 回到「纯色底 × 完整 WorldMacro」（大陆尺度低频斑块）。
	vec3 macro_final = MACRO_MEAN + (macro - MACRO_MEAN) * mix(1.0, ocean_macro, v_is_water);
	ALBEDO = tinted * macro_final;
	// 故意不写 ALPHA：保持不透明渲染管线（biome 边界不能出现半透明缝）。
}
