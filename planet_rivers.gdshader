// 星球河流层（一期）：固定宽度、方头、贴地 decal。
//
// 几何半径 = 1.0（与地表共面），宽度在 vertex 里按屏幕最小宽度展开；
// 深度避让不靠径向抬升，而是沿“相机→顶点”的视线推近 depth_bias。
// 透视下屏幕投影严格不变，所以不会在大圆边缘（limb）浮空/错位，
// 掠射角也不会像径向抬升那样把深度差压到 0。
// 同款手法见 selection_ring.gdshader（depth_bias=0.006）。
//
// 图层顺序（由 planet.gd 的 render_priority 钉死）：
//   地表(不透明) → 低丘 0 → 河流 1 → 高山 2 → 太阳 10 → 大气 20
// 选中环最终应在河流之上（priority 5），但一期暂不改；当前它仍是默认 0，
// 局部会被河流盖住（已与需求方确认，后续再处理）。
//
// 前提：星球节点在世界原点且无旋转/缩放（当前架构：相机绕星球转）。
// 若以后给星球加变换，改用 world_vertex_coords，或把相机变换到模型空间。
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;

uniform vec4 river_color : source_color = vec4(0.20, 0.48, 0.78, 1.0);
uniform float base_half_width = 0.0018;
uniform float min_width_px = 2.2;
uniform float edge_softness_px = 1.0;

// 沿视线向相机推近的世界单位：只改深度，不改屏幕投影。
// 移动端初值 0.004；若设备是 16-bit 深度且远看仍闪，见 docs/planet_rivers_plan.md §9.7.6。
uniform float depth_bias = 0.004;
// 调试：0=视线偏移（默认），1=径向抬升（对照），2=不偏移（复现 z-fighting）。
uniform int depth_mode = 0;

void vertex() {
	vec3 side = normalize(NORMAL);

	// 宽度展开：仍在模型空间；MODELVIEW_MATRIX 只用来算当前深度下
	// 1 像素对应的世界尺寸。
	vec4 view_pos = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	float depth = max(-view_pos.z, 1e-4);
	float px_world = 2.0 * depth
			/ (PROJECTION_MATRIX[1][1] * VIEWPORT_SIZE.y);
	float half_w = max(base_half_width, 0.5 * min_width_px * px_world);
	VERTEX += side * (UV.x * 2.0 - 1.0) * half_w;

	if (depth_mode == 0) {
		vec3 to_cam = normalize(CAMERA_POSITION_WORLD - VERTEX);
		VERTEX += to_cam * depth_bias;
	} else if (depth_mode == 1) {
		// 对照方案：径向抬升；limb 会浮空，不推荐作为主方案。
		VERTEX += normalize(VERTEX) * depth_bias;
	}
}

void fragment() {
	float edge = abs(UV.x * 2.0 - 1.0);
	float aa = max(fwidth(UV.x * 2.0), 1e-5) * edge_softness_px;
	ALBEDO = river_color.rgb;
	ALPHA = river_color.a * (1.0 - smoothstep(1.0 - aa, 1.0, edge));
}
