shader_type spatial;
// 星空 glyph 材质：unshaded 纯显示 + alpha 混合；cull_disabled 双面（quad 法向朝球心，
// 相机在球心，正面即被看到；双面是绕序保险）。
// depth_draw_never：星星不写深度（透明件的默认正确姿势）；
// 深度【测试】保持开启——星穹半径远大于星球，星球按深度自然遮挡星星，
// 这是对原版 ZTest Off 的有意差异（我们是单相机大半径，不需要双相机合成的 ZTest Off）。
// blend_mix：普通 alpha 混合（星星半透明地叠在深空背景上）。
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;

// 紧凑星点图集（由 star_atlas.gd 从 RimWorld 原版 Stars.png 切出来）：
// 每格一颗柔光星点，格与格之间留了白边，mipmap 不会串味。
uniform sampler2D star_tex : source_color, filter_linear_mipmap;

// 每颗星采样图集里的哪一块：UV 矩形 (u0, v0, du, dv)。
// 经 INSTANCE_CUSTOM 逐实例传入（GL Compatibility 的顶点阶段同样支持）。
varying vec2 v_star_uv;

void vertex() {
	// INSTANCE_CUSTOM = (u0, v0, du, dv)
	vec4 rect = INSTANCE_CUSTOM;
	v_star_uv = vec2(UV.x * rect.z + rect.x, UV.y * rect.w + rect.y);
}

void fragment() {
	vec4 tex_color = texture(star_tex, v_star_uv);
	// COLOR = 网格顶点色 × MultiMesh instance color。
	// 顶点色是白的（见 star_dome.gd 的 _make_quad_mesh），所以 COLOR 就是
	// 每颗星随机出来的亮度/色温（instance color）—— 乘进 ALBEDO 即得明暗随机。
	ALBEDO = COLOR.rgb;
	// alpha 只承载贴图形状（柔光衰减），不掺亮度：否则亮度会被乘两次，
	// 暗星直接被压没了。COLOR.a 恒为 1，留着是为了将来需要时能控整体透明度。
	ALPHA = tex_color.a * COLOR.a;
}
