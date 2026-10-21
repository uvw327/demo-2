shader_type spatial;
// 星空 glyph 材质：unshaded 纯显示 + alpha 混合；cull_disabled 双面（quad 法向朝球心，
// 相机在球心，正面即被看到；双面是绕序保险）。
// depth_draw_never：星星不写深度（透明件的默认正确姿势）；
// 深度【测试】保持开启——星穹半径远大于星球，星球按深度自然遮挡星星，
// 这是对原版 ZTest Off 的有意差异（我们是单相机大半径，不需要双相机合成的 ZTest Off）。
// blend_mix：普通 alpha 混合（星星半透明地叠在深空背景上）。
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;

// 64×64「四芒星」glyph：RGB 纯白，只有 alpha 变化；每个 quad 显示完整 UV。
// filter_linear_mipmap：缩小时按屏幕占比取 mip 层，避免星点边缘闪烁。
uniform sampler2D star_tex : source_color, filter_linear_mipmap;

void fragment() {
	vec4 tex_color = texture(star_tex, UV);
	// COLOR = 网格顶点色 × MultiMesh instance color。
	// 顶点色是白的（见 star_dome.gd 的 _make_quad_mesh），所以 COLOR 就是
	// 每颗星随机出来的亮度/色温（instance color）—— 乘进 ALBEDO 即得明暗随机。
	ALBEDO = COLOR.rgb;
	// alpha 只承载贴图形状（柔和衰减），不掺亮度：否则亮度会被乘两次，
	// 暗星直接被压没了。COLOR.a 恒为 1，留着是为了将来需要时能控整体透明度。
	ALPHA = tex_color.a * COLOR.a;
}
