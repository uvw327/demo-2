shader_type spatial;
// unshaded：纯色显示，不受光照影响（学习项目保持“所见即颜色”）
// cull_disabled：双面渲染。球体是封闭凸面其实单面就够，
// 这里保持和 cube 场景一致，放大穿进去看时内壁也有颜色
render_mode unshaded, cull_disabled;

// 顶点色 varying：每个贴片的全部顶点都带同一个“生物群系纯色”，
// 同一贴片内插值结果处处相等 → 贴片呈现为均匀色块；
// 顶点不跨贴片共享，所以相邻贴片之间也不会互相串色。
varying vec4 v_tile_color;

void vertex() {
	v_tile_color = COLOR; // COLOR = 网格的顶点色属性（GDScript 里 PackedColorArray）
}

void fragment() {
	ALBEDO = v_tile_color.rgb;
	// 故意不写 ALPHA：保持不透明渲染管线（理由见 cube 场景的 surface.gdshader）
}
