shader_type spatial;
// unshaded：关闭光照，输出就是纯色
// cull_disabled：双面渲染，正面背面都画，便于观察
render_mode unshaded, cull_disabled;

// ---- 颜色 ----
// source_color 提示：颜色在编辑器里显示为取色器
uniform vec4 base_color : source_color = vec4(0.5, 0.5, 0.5, 1.0);
uniform vec4 line_color : source_color = vec4(0.0, 0.06, 0.30, 1.0);

// ---- 折线：3 个点 = 2 段线段（范围按 cube -1..1）----
uniform vec3 line_p0 = vec3(0.0, 0.0, 1.0); // front face（z=1 面上）
uniform vec3 line_p1 = vec3(1.0, 0.0, 1.0); // 共享棱（front 与 right 交界）
uniform vec3 line_p2 = vec3(1.0, 0.0, 0.0); // right face（x=1 面上）

uniform float line_half_width = 0.04; // 线半宽（模型空间单位，全宽 0.08）
uniform float edge_aa = 0.002;        // 窄过渡宽度，约 1 像素

// ---- 玉米贴图 ----
// source_color：按 sRGB 解码颜色；repeat_disable：UV 超出 0..1 不平铺
uniform sampler2D corn_tex : source_color, filter_linear, repeat_disable;
uniform float corn_width   = 0.30; // 玉米宽（模型空间单位）
uniform float corn_height  = 0.30; // 玉米高（底边站在折线上，向上长）
uniform float corn_spacing = 0.50; // 每隔多远种一棵（沿折线弧长）
uniform float corn_offset  = 0.25; // 第一棵的起点偏移

// varying 的必要性：
// fragment 阶段里内置的 VERTEX 是【视图空间】坐标，会跟着相机/物体旋转变化；
// 而 vertex() 里拿到的 VERTEX 是【模型空间】坐标，只由模型自身形状决定。
// 用 varying 把模型空间坐标转发给 fragment，三角形插值后得到每个像素的
// 模型空间位置——这样算出的“到折线的距离”不随旋转改变，图案才钉在表面上。
varying vec3 v_model_pos;

void vertex() {
	v_model_pos = VERTEX; // “存图”：把模型空间坐标交给 fragment
}

// 点 p 到线段 a-b 的最短距离
// clamp 的作用：p 在直线上的投影比例 t 未必落在 [0,1] 内，
// 钳制到 0..1 之后，投影在端点外时距离就成了到端点的距离——
// 得到的是“线段”，而不是无限延伸的“直线”。
float dist_to_segment(vec3 p, vec3 a, vec3 b) {
	vec3 ab = b - a;
	float t = clamp(dot(p - a, ab) / max(dot(ab, ab), 1e-6), 0.0, 1.0);
	return length(p - (a + t * ab));
}

// 采样玉米贴图。
// 思路：把像素参数化成（沿折线的弧长 u，离线的高度 y）→
// 判断它落在哪一棵玉米的“竖矩形”里 → 换算成贴图 UV 采样。
// 返回值 a > 0.5 表示命中玉米（调用方用它做 cutout 硬切）。
vec4 corn_sample(vec3 p) {
	// 1) 判断像素属于哪个面，换算沿折线的弧长 u：
	//    front 面（z≈+1）：第 1 段，u = p.x（段本身覆盖 0..1）
	//    right 面（x≈+1）：第 2 段，u = 2 − p.z（棱处 u=1，与第 1 段连续）
	//    折线只在这两个面上，其他面直接返回“未命中”。
	//    （z>0.9 优先判断：棱附近的像素两值都接近 1，归给 front 也无妨）
	float u;
	if (p.z > 0.9) {
		u = p.x;         // front 面
	} else if (p.x > 0.9) {
		u = 2.0 - p.z;   // right 面
	} else {
		return vec4(0.0);
	}

	// 2) 高度方向：底边贴着折线（y=0），向上长 corn_height
	if (p.y < 0.0 || p.y > corn_height) {
		return vec4(0.0); // 不在玉米矩形的高度范围内
	}

	// 3) 找最近的玉米中心：中心位于 corn_offset + k * corn_spacing
	float k = floor((u - corn_offset) / corn_spacing + 0.5);
	float center = corn_offset + k * corn_spacing;
	// 玉米中心必须落在折线范围内（弧长 0..2），
	// 否则线段延长线的面外区域会“凭空长出”玉米
	if (center < 0.0 || center > 2.0) {
		return vec4(0.0);
	}
	float dx = u - center;
	if (abs(dx) > corn_width * 0.5) {
		return vec4(0.0); // 不在玉米宽度范围内
	}

	// 4) 换算贴图 UV 并采样：
	//    横向：矩形内 [-w/2, w/2] 映射到 [0,1]
	//    纵向：Godot 贴图原点在左上（v=0 是图顶部），
	//    所以 y=0（玉米底）要取 v=1，y=h（玉米顶）取 v=0，图案才不倒置
	vec2 uv = vec2(dx / corn_width + 0.5, 1.0 - p.y / corn_height);
	return texture(corn_tex, uv);
}

void fragment() {
	// 当前像素到 2 段折线的最短距离（模型空间）
	float d = min(
		dist_to_segment(v_model_pos, line_p0, line_p1),
		dist_to_segment(v_model_pos, line_p1, line_p2)
	);

	// smoothstep 两个参数（half_width - aa .. half_width + aa）离得极近，
	// 只有半宽上下约 0.004 的过渡带——相当于 1 像素级的抗锯齿，
	// 既不像 step 那样硬切（严重锯齿），也不是宽柔的渐变。
	float line = 1.0 - smoothstep(
		line_half_width - edge_aa,
		line_half_width + edge_aa,
		d
	);

	// mix 第三个参数是 weight：0=完全取前面(base)，1=完全取后面(line)
	vec3 col = mix(base_color.rgb, line_color.rgb, line);

	// 玉米：用 cutout（阈值硬切）而不是 alpha 混合！
	// 原因：在 fragment 里写 ALPHA 会让材质进“透明渲染”管线
	//（无深度写入、靠绘制顺序叠色），Compatibility 下会被其他面盖掉——
	// 折线吃过这个亏。cutout 命中就是玉米色，不命中保持灰/蓝，
	// 全程不碰 ALPHA，始终留在不透明管线里。
	vec4 corn = corn_sample(v_model_pos);
	if (corn.a > 0.5) {
		col = corn.rgb; // 玉米盖在灰底和折线上面（玉米长在线上）
	}

	ALBEDO = col;
	// 注意：这里【故意不写 ALPHA】= 完全不透明，理由见上
}
