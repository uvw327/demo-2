shader_type spatial;
// 太阳：程序化径向渐变，**零贴图**。
//
// 参考 RimWorld 的 `Custom/Sun`（见 D:/workspace/ref/rimworld/docs/23-Sun.md §4.4）：
// 原版的世界太阳不是一张图、也不是一个 Unity 光源，而是「一个用片元着色器算出来的、
// 相机相对的加法 quad」。本文件是它的 Godot 对应形（规划见 docs/sun_plan.md）。
//
// —— 原版公式（逐行对照 §4.4 的反汇编）——
//   float2 p = uv - 0.5;
//   float d = length(p);
//   float a = max(0, 1 - 2*d);          // 中心 1，UV 半径 0.5 处归零
//   float core = a*a*a*a;              // a^4：白核集中
//   float3 rgb = min(1, core*(1,0.847,0) + a) * a;
//   return float4(rgb, 1);
//
// —— 为什么是加法混合而不是普通 alpha（§4.7）——
// 原版 `Blend SrcAlpha One` + alpha=1，等价于「背景 + 太阳RGB」。
// 太阳只能提亮背景、不能压暗；边缘靠 RGB 自身衰减到 0 淡出，
// 所以**不会**留下方形暗边。若换成普通 alpha 混合（SrcAlpha OneMinusSrcAlpha），
// 黑色边缘会参与覆盖插值，反而出现一圈暗框 —— 复刻时最容易踩的坑。
// Godot 的 `blend_add` 正是 (SRC_ALPHA, ONE)，与原版一致。
//
// —— 深度（与原版的差异，是有意为之）——
// 原版 ZTest Off / ZWrite Off：它只被天空相机看到，靠「双相机合成」让星球盖住它。
// 本项目是单相机：改成**保留深度测试、不写深度** —— 太阳 quad 恒在
// 「相机前方固定距离」（见 sun_quad.gd），该距离 > 最远视距 + 星球半径，
// 于是星球按深度自然遮住太阳，效果与原版合成等价，但不需要第二台相机。
//
// —— 颜色空间 ——
// 原版公式里的常量是**线性值**（§4.5 明确「RGB 为线性值近似，未做 sRGB 转换」），
// Godot 的 ALBEDO 同样是线性值、由引擎在输出时做 sRGB 编码 —— 两边一致，
// 所以这里直接写公式结果，不做任何手工 gamma 转换
// （项目里的 atmosphere.gdshader 用的是同一条约定：uniform 写线性值）。
// 想调外观：改 core_color / intensity 两个 uniform，不用改公式。

render_mode unshaded, blend_add, depth_draw_never, cull_disabled;

// 核心暖黄（线性值，与原版硬编码的 (1, 0.847, 0) 一致）
uniform vec3 core_color = vec3(1.0, 0.847, 0.0);
// 整体强度：原版没有这个参数（等价 1.0），留出来方便按观感微调
uniform float intensity = 1.0;

void fragment() {
	// 到 quad 中心的归一化距离（UV 中心 0.5，半径 0.5 = 方片边中点）
	float d = length(UV - vec2(0.5));
	// 亮度包络：中心 1，向外线性归零
	float a = max(0.0, 1.0 - 2.0 * d);
	// 四次方 → 白核集中、边缘迅速熄灭
	float core = a * a * a * a;
	// 核心染暖黄 + 抬起中间亮度 + 饱和到白 + 最后乘 a 平滑归零
	vec3 rgb = min(vec3(1.0), core * core_color + vec3(a)) * a;
	ALBEDO = rgb * intensity;
	// alpha 必须恒为 1：加法混合下亮度全部由 RGB 承载，
	// 若把衰减写进 ALPHA 会二次相乘（暗框/过暗）。
	ALPHA = 1.0;
}
