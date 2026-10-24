// 星球河流层：河岸与水芯由**几何**分层，而不是在 fragment 里按 UV 区间涂色。
//
// 为什么这么改（见 docs/planet_rivers_plan.md §25–§26）：
//   原来的做法是「河岸 = 图元自身 |UV.x*2-1| 落在 [inner, 1] 的那圈」。对单条
//   ribbon 来说这恰好等于「到水体边界的距离」，所以一直是对的；但汇合点圆盘
//   复用了同一个公式，而圆盘的半径（= 汇合处半宽）是**内切**于干流的——
//   它大半都在水体内部，于是整个圆环被涂成河岸色，就是截图里那圈小圆环。
//   正确判据是「到水体**并集**边界的距离」，那是 fragment 拿不到的信息。
//
//   于是把河岸做成真正的几何：同一条河流 = 并集的全宽填充（河岸色）
//   + 并集的内缩（水色）。内缩不需要第二份顶点数据 —— 每个顶点相对中心线的
//   偏移向量是现成的：NORMAL(侧向/径向) × (UV.x*2-1) × UV2.x。
//   所以同一份 ArrayMesh 画两遍，只差 width_scale / base_color / render_priority。
//   构造即正确：汇合、河口圆头、以后的正弦蜿蜒都自动成立。
//
// shader 仍负责：
//  ① 远视角最小屏幕宽度补偿（只对细支流生效，干流走真实几何宽度）
//  ② 近景最大屏幕宽度封顶（避免贴脸时干流变成蓝色高速公路）
//  ③ 「窄河让出水芯」（全宽 ≤2px 时整条画河岸色）+ 边缘抗锯齿 + 源头端 alpha 渐隐
//  ④ 岸线裁剪（河口按最后一块陆地贴片的边线裁掉，见下方 coast）
//  ⑤ 视线深度偏移（零视差 decal）
//
// 顶点语义（§26）：VERTEX = **中心线**球面点（圆盘是圆心），
//   NORMAL = 切平面侧向单位向量（圆盘是径向），UV.x = 0/1（0.5 = 圆心 → 偏移 0），
//   UV2.x = 偏移长度（世界单位，含 miter 放大），UV2.y = 弧长归一，
//   COLOR.r = alpha（源头端渐细渐隐），COLOR.g = 到岸线的有符号距离编码。
//
// 配色（见 docs/planet_water_plan.md）：河水 = 近岸海水 = #495264，河岸 = #565860。
//   两者都从 planet.gd 的 WATER_COLOR 派生，所以入海口两侧本来就是同一个值 ——
//   不需要任何过渡（参考图 temp/river10.png 正是如此）。
//
// 像素换算：px_world = depth / focal_px。
//   focal_px 由 GDScript 每帧写入（planet.gd 的 _update_river_camera_params），
//   口径与 orbit_camera.gd 的拖动增益一致：focal = 0.5·视口高 / tan(fov/2)。
//   ⚠ 不要在这里用 PROJECTION_MATRIX / VIEWPORT_SIZE 反推：实测在
//   GL Compatibility 下二者乘积与真实光栅高度对不上（偏大约一个数量级），
//   会把 px_world 算小，进而让下面的封顶把整条河网压成 1 像素。
//
// 深度避让不靠径向抬升，而是沿“相机→顶点”的视线推近 depth_bias：
// 透视下屏幕投影严格不变，所以不会在大圆边缘（limb）浮空/错位，
// 掠射角也不会像径向抬升那样把深度差压到 0。
// 同款手法见 selection_ring.gdshader（depth_bias=0.006）。
//
// 图层顺序（由 planet.gd 的 render_priority 钉死）：
//   地表(不透明) → 低丘 0 → 河岸 1 → 水芯 2 → 高山 3 → 太阳 10 → 大气 20
// 选中环最终应在河流之上（priority 5），但一期暂不改；当前它仍是默认 0，
// 局部会被河流盖住（已与需求方确认，后续再处理）。
//
// 前提：星球节点在世界原点且无旋转/缩放（当前架构：相机绕星球转）。
// 若以后给星球加变换，改用 world_vertex_coords，或把相机变换到模型空间。
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;

// 本遍的纯色：河岸遍传 water_bank_color()（#565860），水芯遍传 WATER_COLOR（#495264）。
uniform vec4 base_color : source_color = vec4(0.2863, 0.3216, 0.3922, 1.0);
// 水芯边界（相对全宽）：0.74 = 水芯占 74%，两岸各 13%（参考图实测 11.8%~14.3%）。
// 只在 core_pass = 1 的那遍使用；窄河时按屏幕像素宽度往下收，可收到 0。
uniform float bank_inner = 0.74;
// 0 = 河岸遍（width_scale = 1，画并集全宽）；1 = 水芯遍（width_scale = inner）。
// 两个材质只差这一个开关 + base_color + render_priority。
uniform float core_pass = 0.0;
// 屏幕最小宽度：只有「烘焙半宽 < 该值」的细支流会被加宽，
// 干流在远视角仍保留真实宽度差，不会整条河网一样粗。
uniform float min_width_px = 1.6;
// 屏幕最大宽度：默认 0 = 不封顶。近景封顶会把干/支一起压成同一条带，
// 把几何里做好的分级重新抹平（实测），所以只在需要时手工调大。
uniform float max_width_px = 0.0;
uniform float edge_softness_px = 1.0;
// —— 岸线裁剪（§24）——
// COLOR.g 编码「到岸线的有符号距离」：0.5 = 岸线，< 0.5 陆地侧，> 0.5 水域侧，
// 0 = 深在陆地（哨兵）。planet.gd 用的是最后一块陆地贴片的**朝水边平面**
// （过球心 + 该边两个角点，与地表六边形海岸是同一条直线），所以这里把
// 水域侧裁掉之后，河口正好落在陆地的边线上 —— 严丝合缝，没有圆头也没有缝。
// clip_scale 必须等于 planet.gd 的 RIVER_COAST_SCALE。
uniform float clip_scale = 0.02;
// 裁剪边缘的抗锯齿宽度（像素）：0 = 硬裁，1 = 约 1 像素的柔和过渡。
uniform float coast_softness_px = 1.0;

// 焦距（像素）：depth=1 处 1 世界单位投影多少像素。
// 由 planet.gd 按当前相机 fov 与视口高度写入。
uniform float focal_px = 800.0;

// 沿视线向相机推近的世界单位：只改深度，不改屏幕投影。
uniform float depth_bias = 0.004;
// 调试：0=视线偏移（默认），1=径向抬升（对照），2=不偏移（复现 z-fighting）。
uniform int depth_mode = 0;

varying float v_alpha;
// 到岸线的有符号距离（世界单位，≤ 0 = 在陆地上）
varying float v_coast;

void vertex() {
	vec3 side = normalize(NORMAL);
	// 中心线点（圆盘 = 圆心）。偏移全部在这里重新展开。
	vec3 center = VERTEX;

	// 屏幕宽度上下限：几何已按 Q 烘焙好宽度，这里只做差额补偿。
	vec4 view_pos = MODELVIEW_MATRIX * vec4(center, 1.0);
	float depth = max(-view_pos.z, 1e-4);
	float px_world = depth / max(focal_px, 1.0);

	float half_lo = 0.5 * min_width_px * px_world;
	// 先兜最小屏幕宽度：远景时细支流不至于消失。
	float want = max(UV2.x, half_lo);
	// 再做软封顶：超过 60% 上限后按 exp 渐近逼近上限。
	// 必须是软膝而不是 clamp——clamp 会把所有超过上限的河道压成同一宽度，
	// 近景干流/支流全变成一样粗（正是「统一粗细」的老问题）。
	// exp 形式严格单调：Q 大的永远比 Q 小的宽，次序不会反转，也就不会出现
	// 「这里粗、那里细、过一会又变粗」。
	if (max_width_px > 0.0) {
		float half_hi = 0.5 * max_width_px * px_world;
		float knee = 0.6 * half_hi;
		if (want > knee) {
			float over = max(half_hi - knee, 1e-8);
			want = knee + over * (1.0 - exp(-(want - knee) / over));
		}
	}

	// lateral：-1 左岸 / 0 中心（圆盘圆心）/ +1 右岸（圆盘环）。
	float lateral = UV.x * 2.0 - 1.0;

	// 窄河让出水芯：屏幕上全宽 ≤2px 时整条都是河岸色（细流本来就看不到水芯），
	// ≥5px 时恢复 bank_inner 比例。用解析半宽算像素宽度，不再依赖 fwidth——
	// 原来在 fragment 里靠 fwidth(UV.x) 反推，逐像素各算各的，会在远近过渡处
	// 出现台阶；这里是逐顶点的物理量，插值后连续。
	float full_px = 2.0 * want / px_world;
	float inner = bank_inner * smoothstep(2.0, 5.0, full_px);

	// 河岸遍画全宽，水芯遍按 inner 内缩。两者共用同一份顶点数据。
	float ws = mix(1.0, inner, core_pass);
	// 球面展开：切平面线性偏移再投回球面（与构建期烘焙的口径完全一致）。
	VERTEX = normalize(center + side * lateral * want * ws);

	v_alpha = COLOR.r;
	v_coast = (COLOR.g - 0.5) * (2.0 * clip_scale);

	if (depth_mode == 0) {
		vec3 to_cam = normalize(CAMERA_POSITION_WORLD - VERTEX);
		VERTEX += to_cam * depth_bias;
	} else if (depth_mode == 1) {
		// 对照方案：径向抬升；limb 会浮空，不推荐作为主方案。
		VERTEX += normalize(VERTEX) * depth_bias;
	}
}

void fragment() {
	// 边缘抗锯齿：几何边界就在 |e| = 1 处（水芯遍也是——UV 不缩放，位置缩放）。
	float e = UV.x * 2.0 - 1.0;
	float edge = abs(e);
	float aa = max(fwidth(e), 1e-5) * edge_softness_px;
	// 岸线裁剪：aa 用世界坐标的像素足迹（不要用 fwidth(v_coast)——
	// 哨兵值 0 与真实值之间有跳变，会把整片区域的导数放大、把河道裁成半透明）。
	float cw = max(length(fwidth(VERTEX)), 1e-6) * coast_softness_px;
	float coast = 1.0 - smoothstep(-cw, cw, v_coast);
	ALBEDO = base_color.rgb;
	ALPHA = base_color.a * v_alpha * coast
			* (1.0 - smoothstep(1.0 - aa, 1.0, edge));
}
