shader_type spatial;
// 丘陵/山脉手绘贴片层（第 2 期，见 docs/planet_textures_plan.md §4 步骤 5-6）：
// 每个 level ≥ 小丘陵 的贴片头顶一个切线 quad（hills_atlas.gd 打包的 4 格图集，
// 按地形等级选格 + 2×2 随机变体，UV 直接写在 quad 顶点上），alpha 混合贴在
// 球面上 —— 山的「立体感」来自贴图明暗与 alpha 轮廓，球面几何仍是完美球
//（原版 WorldLayer_Hills 同款哲学，参考 22-PlanetTextures.md §6）。
//
// unshaded：与地表 shader 一致不受光照影响（本项目无太阳/昼夜，规划 §8）。
// cull_disabled：与星球壳一致，镜头钻进内壁也看得到贴片。
// depth_draw_never：只测深度、不写深度（原版 WorldOverlayTransparentLit 的
//   ZWrite Off）→ 不与球面 z-fighting（quad 在 1.005×R 处深度测试自然赢），
//   也不遮挡星空；透明队列在不透明星球之后渲 → 深度已有球面，limb 处
//   贴片被背后的球面正确裁切。
// 采样直接 texture()：quad 内 UV 连续、恒在变体内，无地表 fract 平铺那种导数
//   突跳；跨 quad 边界的 1px 足迹抖动落在贴图自带的透明留白区，无感
//   （地表的手算 LOD 是因为 fract 才需要，这里不适用）。
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;

// 4 格丘陵图集（SmallHills/LargeHills/Mountains/Impassable，运行期打包）
uniform sampler2D hills_atlas : source_color, filter_linear_mipmap;

void fragment() {
	vec4 c = texture(hills_atlas, UV);
	ALBEDO = c.rgb;
	ALPHA = c.a;
}
