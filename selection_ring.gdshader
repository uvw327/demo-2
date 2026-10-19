// 选中贴片的“向内溢出光晕”高亮（点击选区的选中态特效）。
//
// 环带几何由 planet.gd 生成：
//   · 外沿自贴片边界略微内收，因此光完全不向外渗（不会糊到相邻地块）；
//   · 内沿按贴片半径的比例向内延伸，形成一条不厚的溢光带；
//   · 半径整体抬了一点，避免与地表深度冲突。
// 顶点色 a 通道存 0..1 的径向参数：0 = 贴边界（全亮），1 = 内沿（透明）。
// 片元里按 pow(1 - t) 衰减，得到“边缘亮白、越往内越透明”的光晕。
// 按需求不做呼吸/脉动：无任何时间参与，选中的环恒定发光。
shader_type spatial;
render_mode unshaded, cull_back, blend_mix, depth_draw_never;

// 衰减指数：越大衰减越陡、光晕视觉越薄（调薄厚改这里最直接）
uniform float fade_power : hint_range(1.0, 8.0) = 2.2;

void fragment() {
	// COLOR.a 由顶点色线性插值而来（0=贴边界，1=内沿）
	float t = COLOR.a;
	// 纯白色；alpha 沿径向快速衰减，中心区域（环带之外）光自然为 0
	ALPHA = pow(1.0 - t, fade_power);
	ALBEDO = vec3(1.0);
}
