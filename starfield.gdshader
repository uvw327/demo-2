shader_type spatial;
// 星空 glyph 材质：unshaded 纯显示 + alpha 混合；cull_disabled 双面（quad 法向朝球心，
// 相机在球心，正面即被看到；双面是绕序保险）。
// depth_draw_never：星星不写深度（透明件的默认正确姿势）；
// 深度【测试】保持开启——星穹半径远大于星球，星球按深度自然遮挡星星，
// 这是对原版 ZTest Off 的有意差异（我们是单相机大半径，不需要双相机合成的 ZTest Off）。
render_mode unshaded, cull_disabled, depth_draw_never;

// 64×64「三颗四芒星」glyph：RGB 纯白，只有 alpha 变化；每个 quad 显示完整 UV
uniform sampler2D star_tex : source_color, filter_linear;

void fragment() {
	ALBEDO = vec3(1.0, 1.0, 1.0);
	ALPHA = texture(star_tex, UV).a;
}
