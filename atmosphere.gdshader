shader_type spatial;
// 星球大气光晕（Rim Glow）：包住星球的一层球壳（半径 1.081× 星球半径），
// 只在「星球轮廓那一圈」发出柔和的蓝白光。
//
// 参照原版 RimWorld 的 Custom_PlanetGlow.shader（见 docs/../21-Starfield.md §5.3）：
// 原版不是菲涅尔，而是按「视线到星球中心的最近距离 d」算一条带：
//   a = max(0, 1 - |(d - R) / W|)   → 半径 R 上下 W 宽的一圈
//   intensity = a³ · k              → 三次方让带边缘迅速熄灭
//   颜色 (0.706, 0.839, 1)          → 偏蓝白
// 球壳半径 108.1 / 星球半径 100 → 比值 1.081（W = 8/100 → 本项目 0.08）。
//
// 为什么不用「菲涅尔 + cull_front」：
//   菲涅尔项 1 - dot(N, V) 在球壳上恒等于「壳的轮廓」——它只能把光画在
//   壳自己的剪影上，于是得到一圈边缘生硬的蓝色甜甜圈（实测：像贴纸，不像大气）。
//   原版的「距离带」把光锁在星球剪影那一圈，内外两侧都平滑衰减，
//   这才是 RimWorld 观感里那圈柔和的蓝白边。
//
// cull_front：只画球壳的远侧半球（近侧半球剔除）——一层就够，不重复叠加。
// depth_draw_never：不写深度，纯加法叠加，不影响后续物体的深度判定。
// blend_add：加法混合，光晕只提亮、不遮暗（与原版 Blend SrcAlpha One 一致）。
render_mode unshaded, cull_front, depth_draw_never, blend_add;

// 偏蓝白的辉光色（取自原版 PlanetGlow 的颜色）
uniform vec3 glow_color = vec3(0.706, 0.839, 1.0);
// 带的半宽（星球半径的比例）：0.08 = 原版 8/100
uniform float band_width = 0.08;
// 整体强度：原版靠日照侧提亮，本项目无太阳概念，取一个固定的自发光强度
uniform float intensity = 0.45;

void fragment() {
	// 星球中心（世界原点）在视空间的位置：视空间里相机恒在原点，
	// 所以「相机 → 片元」这条射线就是视空间的位置向量本身。
	vec3 center_view = (VIEW_MATRIX * MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 ray_dir = normalize(VERTEX);
	// 视线到星球中心的最近距离 d = |center × ray|（相机在原点时成立）
	float d = length(cross(center_view, ray_dir));
	// 以星球半径 1.0 为中心的一条带
	float a = max(0.0, 1.0 - abs((d - 1.0) / band_width));
	// 三次方：带边缘迅速熄灭（与原版 a³ 一致）
	ALBEDO = glow_color;
	ALPHA = a * a * a * intensity;
}
