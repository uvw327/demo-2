shader_type spatial;
// 星球大气光晕（Rim Glow）：包住星球的一层球壳（半径 1.06× 星球半径），
// 只在「星球轮廓那一圈」发出柔和的白光。
//
// 参照原版 RimWorld 的 Custom_PlanetGlow.shader（见 docs/../21-Starfield.md §5.3）：
// 原版不是菲涅尔，而是按「视线到星球中心的最近距离 d」算一条带：
//   a = max(0, 1 - |(d - R) / W|)   → 半径 R 上下 W 宽的一圈
//   intensity = a³ · k              → 三次方让带边缘迅速熄灭
//   颜色 (0.706, 0.839, 1)          → 原版是偏蓝白；本项目改成纯白（见下方
//                                     glow_color 注释：实测「太蓝」，像霓虹描边）
// 球壳半径 108.1 / 星球半径 100 → 比值 1.081（W = 8/100；本项目的 W 见下方 band_width）。
//   ⚠️ 本项目不再照搬这个比例：球壳跟带宽联动（≈ 1 + 0.9×band_width），现为 1.06。
//
// 为什么不用「菲涅尔 + cull_front」：
//   菲涅尔项 1 - dot(N, V) 在球壳上恒等于「壳的轮廓」——它只能把光画在
//   壳自己的剪影上，于是得到一圈边缘生硬的蓝色甜甜圈（实测：像贴纸，不像大气）。
//   原版的「距离带」把光锁在星球剪影那一圈，内外两侧都平滑衰减，
//   这才是 RimWorld 观感里那圈柔和的蓝白边。
//
// —— 距离衰减（本项目新增，原版没有）——
// 问题：这条带是按「星球半径为单位」定义的，峰值 ALPHA 恒等于 intensity，
//   与相机距离无关。拉远时带会变细（角宽 ∝ 1/√(D²-1)），但**亮度一点不变**
//   → 无论远近都是同一条亮白线，实测「不太符合自然现象」。
// 修法（打补丁，不换实现）：把 intensity 再乘一个随「相机 → 星球中心距离」
//   下降的系数。距离直接复用下面 fragment 里已经算好的 center_view
//   （视空间里相机恒在原点，length(center_view) 就是相机到球心的距离）
//   → 每片元只多一次 length() + 一次 smoothstep，无新 pass、无贴图、无额外矩阵运算。
// ⚠️ 反过来也要说清楚：**换成菲涅尔同样解决不了这个问题**——菲涅尔项与
//   相机距离一样无关，照样是恒定亮度的一圈线。
//
// cull_front：只画球壳的远侧半球（近侧半球剔除）——一层就够，不重复叠加。
// depth_draw_never：不写深度，纯加法叠加，不影响后续物体的深度判定。
// blend_add：加法混合，光晕只提亮、不遮暗（与原版 Blend SrcAlpha One 一致）。
render_mode unshaded, cull_front, depth_draw_never, blend_add;

// 辉光底色 = **纯白**。
// 原版 RimWorld 的 Custom_PlanetGlow.shader 用 (0.706, 0.839, 1)（偏蓝白），
// 本项目最初也照搬过那一档（先 (0.42,0.60,1.0) 后 (0.57,0.71,1.0)），但实测
// 观感「太蓝」：在深色太空背景上那一圈蓝边像贴纸/霓虹描边，不像大气。
// 现在改成纯白 —— 白光在黑背景上读作「空气散射」，比带色的边更自然，
// 也让画面里唯一的彩色留给星球本身（海洋/植被）。
//
// 注意颜色空间：uniform 默认值按**线性**写、经 sRGB 输出才显示成目标色。
// 纯白 (1,1,1) 线性 → 显示也是纯白，无需任何 gamma 修正。
uniform vec3 glow_color = vec3(1.0, 1.0, 1.0);
// 带的半宽（星球半径的比例）：原版 8/100 = 0.08；本项目按观感收到 0.065
// （曾加厚到 0.13，实测「太厚」——粗蓝边把星球轮廓糊掉，像镶了圈灯带）。
// 调它必须同步动 planet.gd 的 ATMOSPHERE_RADIUS（≈ 1 + 0.9×W），否则带的
// 外尾被球壳剪影硬切。
uniform float band_width = 0.065;
// 整体强度：原版靠日照侧提亮，本项目无太阳概念，取一个固定的自发光强度
uniform float intensity = 0.42;

// —— 距离衰减参数（见文件头「距离衰减」段）——
// 相机到星球中心的距离 ≤ dist_fade_start 时满强度；
// ≥ dist_fade_end 时降到 dist_fade_min（>0 = 远端仍留一丝大气，0 = 彻底消失）。
// 取值 3.0 / 9.0 / 0.15 的理由：
//   · 默认相机距离 2.05 < 3.0 → 开场帧系数恒等于 1.0，画面**完全不变**；
//   · 3~9 之间平滑过渡（smoothstep，两端导数为 0 → 缩放时不会「跳一下」）；
//   · 0.15 的残留：拉到最远（10）时边缘光仍有一点点，读作「远处也还有大气」，
//     而不是星球凭空变成真空球。
uniform float dist_fade_start = 3.0;
uniform float dist_fade_end = 9.0;
uniform float dist_fade_min = 0.15;

void fragment() {
	// 星球中心（世界原点）在视空间的位置：视空间里相机恒在原点，
	// 所以「相机 → 片元」这条射线就是视空间的位置向量本身。
	vec3 center_view = (VIEW_MATRIX * MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 ray_dir = normalize(VERTEX);
	// 视线到星球中心的最近距离 d = |center × ray|（相机在原点时成立）
	float d = length(cross(center_view, ray_dir));
	// 以星球半径 1.0 为中心的一条带
	float a = max(0.0, 1.0 - abs((d - 1.0) / band_width));
	// 距离衰减：center_view 已在上面算好，length() 就是相机到球心的距离。
	// ⚠️ smoothstep 的 edge0 必须 < edge1（反向写是 GLSL 未定义行为），
	//    所以这里用 1.0 - smoothstep(低, 高, x) 的形式而不是反向 smoothstep。
	float cam_dist = length(center_view);
	float dist_fade = mix(dist_fade_min, 1.0,
			1.0 - smoothstep(dist_fade_start, dist_fade_end, cam_dist));
	// 三次方：带边缘迅速熄灭（与原版 a³ 一致）
	ALBEDO = glow_color;
	ALPHA = a * a * a * intensity * dist_fade;
}
