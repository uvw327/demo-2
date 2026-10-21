shader_type spatial;
// 星球地表三层质感（见 docs/planet_textures_plan.md）：
//   ① 生态色卡贴图（原版手绘低对比噪声，逐片按 UV2 定位图集格子）
//   × ② WorldMacro 宏观噪声（大陆尺度斑块，全星球共享，打散平铺重复感）
//   × ③ 顶点色调制器（贴片级地形明暗 + 山体基岩混合）
// unshaded：颜色全部由上面三层给出，不受场景光照影响。
// cull_disabled：双面渲染（沿用原实现——放大穿进去看时内壁也有颜色）。
render_mode unshaded, cull_disabled;

// 生态色卡图集（biome_atlas.gd 运行期打包：4×2 共 8 格，第 8 格=未生成纯色）。
// 采样坐标经 fract() 折进本格，不依赖 repeat；mipmap 由打包时 generate_mipmaps 提供。
uniform sampler2D biome_atlas : source_color, filter_linear_mipmap;
// 全局宏观噪声（整张平铺，低频）——UV 超出 [0,1]，必须 repeat。
uniform sampler2D macro_tex : source_color, filter_linear_mipmap, repeat_enable;
// 单格有效区 UV 尺寸（不含 gutter），由 planet.gd 从图集打包结果回填。
uniform vec2 cell_uv = vec2(0.2222, 0.4444);

// 山体基岩色：与 planet.gd 的 C_ROCK 同值，顶点色 a（岩石混合量）向它 lerp。
const vec3 ROCK_COLOR = vec3(0.45, 0.42, 0.39);
// 主贴图每立方体面平铺次数（原版 20；我们贴片数是原版 4 倍、颗粒相对更细，
// 初值 8 —— 出截图后按 docs/planet_textures_plan.md §4 调参）。
const float TILING = 8.0;
// WorldMacro 每面平铺次数（照抄原版 1.5 → 大陆尺度斑块）。
const float MACRO_TILING = 1.5;

// 顶点色 = 色调制器：rgb = 明暗乘数（1.0 = 原亮度），a = 岩石混合量。
varying vec4 v_tile_color;
// UV2 = 图集格子原点（贴片内全部顶点同值 → 插值无损，逐片恒定）。
varying vec2 v_cell_origin;
// 世界坐标（vertex 算一次，fragment 归一化后做盒式投影）。
varying vec3 v_world_pos;

void vertex() {
	v_tile_color = COLOR;
	v_cell_origin = UV2;
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
	vec3 base = textureLod(biome_atlas, v_cell_origin + fract(p * TILING) * cell_uv,
			lod).rgb;
	// 宏观斑块：整张 WorldMacro 低频平铺，全星球连续（相邻生态共享同一批斑块 → 边界被洗软）。
	// WorldMacro 导入未开 mip（mipmaps/generate=false）→ texture() 恒采 base 层，
	// 切轴处导数突跳不产生混色伪影；若日后开 mip 需换成同款手算 LOD。
	vec3 macro = texture(macro_tex, p * MACRO_TILING).rgb;
	// ③ 顶点色：rgb 明暗乘数（丘陵压暗），a 岩石混合（山区往基岩色压）。
	vec3 tinted = mix(base * v_tile_color.rgb, ROCK_COLOR, v_tile_color.a);
	ALBEDO = tinted * macro;
	// 故意不写 ALPHA：保持不透明渲染管线（biome 边界不能出现半透明缝）。
}
