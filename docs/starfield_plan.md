# 星空实现规划（基于 RimWorld 星空逆向文档）

> 参考文档：`D:/workspace/ref/rimworld/docs/21-Starfield.md`（原版 `WorldLayer_Stars` /
> `WorldLayer_Sun` / `WorldLayer_Glow` / 双相机合成的完整逆向）。
> 本文档回答三个问题：原版星空的机制是什么、哪些能抄哪些不能抄、在本项目里怎么落地。
> **状态：规划稿，未编码。**

---

## 1. 当前项目现状盘点（规划的出发点）

| 项 | 现状 | 对星空方案的影响 |
| --- | --- | --- |
| 场景结构 | `planet.tscn` 仅一个根 Node3D，HUD/相机/星球网格全部由 `planet.gd` 代码装配 | 星空也应延续"代码构建"风格，不引入手摆场景节点 |
| 渲染管线 | GL Compatibility（微信端 WebGL2），Godot 4.7.2 | sky shader 在 Compatibility/WebGL2 可用（4.3+），但要多一层 Environment 配套验证 |
| 光照 | **无任何光源**，`planet_surface.gdshader` 为 `unshaded` 顶点色 | 星星同样用 unshaded 即可，无需考虑光照一致性；也意味着"太阳/昼夜"系统目前**不存在** |
| 相机 | `orbit_camera.gd` 代码创建，`dist ∈ [1.15, 10.0]`，FOV 75°（默认），far 4000（默认） | 星穹半径取几百量级即可远超最远视距、沉在远平面内 |
| 星球 | `PLANET_RADIUS = 1.0`，Goldberg 贴片，不透明管线 | 星星必须且必然被星球遮挡（深度测试自然成立） |
| 拾取 | 纯数学射线求交，不走物理 | MultiMesh 星穹不会误进拾取，无需过滤 |
| 背景 | 无 Environment，Godot 默认清屏色（灰） | 换星空的同时必须换背景色，否则深空里飘"灰底"，违和 |

---

## 2. 原版机制的三个要点（决定"什么是正确的星感"）

引自 21 号文档，只列对实现有约束力的结论：

1. **"无限远天球"的真实实现**：星星在半径 10 的球面上，但顶点着色器把
   `_WorldSpaceCameraPos` 加回顶点（`worldPos = R·vertex + cameraPos`），于是星穹
   **永远以相机为中心**，只有方向、没有平移视差。`DistanceToStars = 10` 能成立全靠这一手。
2. **星不是贴图球，是 1500 个 quad**：球面均匀撒 1500 个方向（三高斯归一化，种子=世界种子），
   每个方向放一个朝向球心的 quad，每个 quad 显示同一张 64×64"三颗四芒星"贴图的**完整 UV**，
   实际星点 ≈ 4500 个；随机尺寸 1–3.8（相对半径 0.1–0.38）、随机绕法线旋转消重复感。
   alpha 混合、无深度写入、无光照、**不闪烁**（shader 里没有时间项）。
3. **合成方式**：原版是"天空相机 FOV 60 画星空 + 世界相机 FOV 20 画星球"的双相机技巧；
   文档明确警告 **Godot 里不要硬搬双相机**（Unity 的 clearFlags/depth 语义不可移植），
   要用 sky shader 或"相机相对/大半径星穹"。

一句话：**星感的灵魂 = 相机相对天球 + 一张多星 glyph 贴图 + 随机旋转/缩放。**

---

## 3. 方案对比与选型

| | 方案 A：sky shader 程序化星空 | 方案 B：MultiMesh 星穹（推荐） | 方案 C：硬搬 Unity 双相机 |
| --- | --- | --- | --- |
| 观感还原 | 程序 hash 星点，能做到"像星野"，但还原不了"三颗四芒星 + 随机旋转 + 大小分级"的 glyph 观感 | ✅ 完整还原原版星感（同一张贴图 × 随机旋转变换出千变星群） | ✅ 同 B |
| 相机视差 | 天生无（按视线方向着色） | 挂到相机位置即可无（见 §4.3） | 同 B |
| 深度/遮挡 | 天生在"最深处"，星球自然遮住 | 星穹半径远大于最远视距且小于 far，普通深度测试自然遮挡 | 需手动复刻清深度语义，易踩坑 |
| 与现有代码风格 | 需要引入 Environment + Sky 资源链 | ✅ 一个脚本 + 一个 shader + 一张贴图，纯代码装配，与现有结构一致 | 引入两台相机，改动大 |
| 微信/WebGL2 兼容 | 可用，但 sky shader 是逐像素分支最多的路径之一，低端机需实测 | ✅ MultiMesh + unshaded 是最保守路径，单 draw call（6000 顶点） | 双相机在 WebGL2 上是两帧 pass，成本翻倍 |
| 性能 | 极好（无几何） | 极好（1 draw call / 6000 verts，静态网格不重建） | 差 |
| 失败回退 | — | 回退到 A | — |

**结论：选方案 B**（采 21 号文档 §9.2 路线，但把"大半径"与"跟随相机"合用，双保险）。
选它的核心理由：本项目无光照系统、无昼夜，B 恰好把全部复杂度收在"一次生成 + 一动不动"里；
A 作为回退方案记录在案，但先不引入 Environment 这条新依赖。

---

## 4. 系统设计（方案 B 展开）

### 4.1 文件与职责

> 实施后快照（与规划初稿的差异）：glyph 贴图**不做资产烘焙**——烘焙工具/png/重导
> import 的往返在实施中两度拖住迭代（打乱码 + 重导入），且与本项目"全代码构建"
> 的既有风格不一致；改为 `star_dome.gd` 内运行期程序化生成 64×64 Image 细化 alpha，
> 公式与参数都在代码常量区，改观感零 import 成本。规划初稿的 M1（bake 工具）
> 连同 `assets/starfield/stars.png` 退役。
>
> **第 2 轮调校（对标 RimWorld 原版截图）**：首版渲染出来是「巨大的硬边白色十字」，
> 与原版差得远。原因有三：① 贴图是硬边几何体（实心菱形核 + 实心十字臂，无 AA）；
> ② 星星全部纯白、毫无亮度变化（instance color 根本没生效）；
> ③ 没有星球大气辉光来压制背景的相对亮度。修法见 §4.2 参数表与 §4.5。

| 文件 | 职责 |
| --- | --- |
| `starfield.gdshader`（新） | `shader_type spatial; render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;`；`ALBEDO = COLOR.rgb`（**顶点色 × instance color = 每颗星的亮度/色温**），`ALPHA = tex.a * COLOR.a`（只承载形状，不掺亮度）；保持**深度测试开启**（靠远距自然被星球遮挡，这是与原版 `ZTest Off` 的有意差异——我们没有双相机，开深度反而更稳），深度写入关闭 |
| `star_dome.gd`（新，`class_name StarDome extends MultiMeshInstance3D`） | ① `_make_star_tex()`：运行期程序化烘焙 64×64「菱形核（pow 平滑衰减）+ 极细暗十字臂」三颗 glyph（纯白 RGB、只动 alpha），再过一遍 3×3 盒式模糊 + 峰值归一化；② `build(seed)`：SeededRNG → 高斯均匀球面方向 × 1500 → 每 quad 一个 instance（切平面 basis + 随机绕法线旋转 + 随机尺寸 + 随机 instance color），transform 先算进 GDScript 数组 `_built`、颜色进 `_built_colors`（冒烟可测）再提交 MultiMesh（dummy 渲染器读不回）；③ `_process`：仅做 `global_position = cam.global_position`；④ 种子变了才重建 |
| `atmosphere.gdshader`（新，第 2 轮新增） | 星球大气辉光：包住星球的球壳（1.081× 半径），按「视线到球心的最近距离 d」算一条 `a = max(0, 1 - |(d-1)/0.08|)` 的带，`ALPHA = a³·intensity`，加法混合（对照原版 `Custom_PlanetGlow`） |
| `planet.gd`（改，~10 行） | `_ready`：`add_child(_star_dome); _star_dome.build(0)`（菜单相位即有星空）；`_on_generate_requested` 换种子时 `build(seed)`；星球上线时 `_build_atmosphere()` 挂辉光球壳 |
| `tools/test_starfield.gd`（新，冒烟护栏） | 数量/确定性（同 seed 逐位一致、换 seed 变化）/方向分布均匀/材质就绪/**亮度随机性（暗星占比 ~0.90、use_colors 已开）**/相机跟随，共 7 项 |

装配后场景树（全部运行期代码构建，与现有风格一致）：

```
Planet (Node3D)
├── TileHUD
├── OrbitCamera (Camera3D)
├── WorldMenu
├── MeshInstance3D   ← 星球（半径 1）
├── MeshInstance3D   ← 大气辉光球壳（半径 1.081）
└── StarDome (MultiMeshInstance3D)   ← 星穹（半径 400，每帧贴相机位置）
```

### 4.2 参数表（最终值快照，全部在 `star_dome.gd` 常量区）

| 常量 | 终值 | 备注 |
| --- | --- | --- |
| `DOME_RADIUS` | 400 | 最远视距 10 的 40 倍，沉入 far(4000) 内 |
| `STAR_COUNT` | 1500 | = 原版 StarsCount |
| `STAR_SIZE_MIN / MAX` | **0.015 / 0.08** | 角尺寸 ≈ 0.86°~4.6°。**第 2 轮从 0.04/0.22 再砍一个数量级**——首版星点还是太大太扎眼；现在星星只占画面很小的面积，亮度交给 instance color 控制 |
| `DIM_SIZE_MAX` / `BRIGHT_SIZE_MIN` | 0.045 / 0.03 | 暗星一律偏小、亮星允许更大：亮度与尺寸弱相关 → 少数「主角星」+ 满屏细碎噪点 |
| `DIM_RATIO` | **0.90** | 90% 暗星（灰 0.2~0.6）、10% 亮星（灰 0.8~1.0）；亮星里 15% 染成极淡冷蓝/暖黄 |
| `GLYPHS` | 半箭长 11 / 5 / 4.5 px | 三颗星（中央大 + 右上/左下小） |
| `GLYPH_CORE_R` / `GLYPH_FALLOFF` | **0.45 / 3.0** | 菱形核 = 曼哈顿距离场经 `pow(1 - d/0.45, 3)` 平滑衰减：**中心亮、边缘快速变暗**（不再是实心硬边） |
| `GLYPH_ARM_LEN / ARM_W` / `GLYPH_ARM_BRIGHT` | 1.6 / 0.09 / **0.10** | 十字臂：极细极暗，远看几乎不可见，拉近才隐约是 ✦ 的四芒 |
| `TEX_SIZE` + 3×3 盒式模糊 + 峰值归一化 | 64 | 模糊抹掉硬锯齿；归一化把被模糊削掉的中心亮度补回来（否则整片星空偏暗） |
| `BACKGROUND` | `#10171E` | RadWorld 天空相机清色；写入 project.godot 的 default_clear_color |
| `ATMOSPHERE_RADIUS`（`planet.gd`） | 1.081 | 大气辉光球壳半径 / 星球半径（= 原版 108.1/100） |
| 辉光 `band_width` / `intensity` | 0.08 / 0.45 | = 原版 `_GlowRadius` 8/100；`a³` 三次方让带边缘迅速熄灭 |

第 2 轮调校的核心认识：**原版 RimWorld 的星星本身就是「暗色噪点 + 少数亮星」**，
不是「一堆亮十字」。首版之所以完全不像，是因为亮度维度根本没参与——
所有星星的 ALBEDO 都是纯白，唯一的区分手段是几何大小，于是只能靠放大来「显得有层次」，
结果就是刺眼的硬边白十字。第 2 轮把层次从「几何大小」搬到「instance color 的亮度」，
几何就可以缩到很小很碎，刺眼感自然消失。

> **instance color 的一个坑（务必记住）**：`MultiMesh.set_instance_color()` 是
> **乘在网格顶点色上**的（引擎文档原话：*multiplying* the mesh's existing vertex colors）。
> 若底网格没有顶点色，`COLOR` 恒为白 → 每颗星亮度相同 → 随机性彻底失效。
> 所以 `star_dome.gd` 的 `_make_quad_mesh()` 显式给了一份**白色顶点色**。
> 这一点在 GL Compatibility 的 `scene.glsl` 里能直接看到：
> `color_interp = color_attrib_input; color_interp *= instance_color;`（仅当 `COLOR_USED`）。


### 4.3 关键实现语义（对照原版逐条列）

| 原版语义 | 本项目对应实现 | 为什么不用原版的写法 |
| --- | --- | --- |
| 顶点着色器加 `_WorldSpaceCameraPos`（相机相对） | `_process` 里 `global_position = 相机位置`，网格本身静止 | 等价效果零 shader 依赖；每帧只写一次 transform，成本忽略 |
| `ZTest Off / ZWrite Off`（双相机合成的一部分） | 深度测试照常开、深度写入关 | 单相机 + 大半径下自然成立；星球按深度遮挡星星，无需依赖渲染顺序 |
| 反绕序让 quad 内表面朝向球心 | `CULL_DISABLED` + 切平面 basis 直接把 quad 法向朝球心 | 一次生成，不值得为省填充率去抠绕序 |
| `Rand.Seed = 世界种子` + Push/PopState | `RandomNumberGenerator.seed = 世界种子`（独立 RNG，不碰星球噪声序列） | 星空与星球同种子但随机流隔离，保证互不干扰 |
| 球面均匀 = 三高斯归一化 | `Vector3(rng.randfn(), rng.randfn(), rng.randfn()).normalized()` | 避开"立方体投影两极偏密"的坑（文档 §3.2 显式警告） |
| 选点页静态 / 游戏随太阳转、太阳附近缩小 | 第 1 期静态（identity 旋转）；太阳相关全部后议 | 本项目无时间系统、无太阳概念，旋转没有参照物 |
| 1500 Node × 编辑器爆卡 | 单 MultiMesh | 文档 §9.4 坑表原话 |

### 4.4 与二次生成/中心变化的交互

- 二次生成（`_on_generate_requested`）若换 seed → `build(new_seed)` 重铺星穹；
  同 seed 不重铺（与星球本身的短路语义对齐）。
- 星穹跟随相机后，`focus_on` / 拖拽 / 缩放全都不会引起视差滚动，不需要任何额外对齐逻辑。
- 选区球冠、水面、选中环、HUD 均不感知星空，零耦合。

### 4.5 星球大气辉光（Rim Glow，第 2 轮新增）

原版 RimWorld 星球外有一层半径 108.1（星球 100）的辉光壳，片元算法是
**「视线到球心的最近距离 d」上开一条带**，而不是菲涅尔：

```
a = max(0, 1 - |(d - 100) / 8|)      → 半径 100 上下 8 宽的一圈
intensity = a³ · (0.28·sun² + 0.02)  → 三次方让带边缘迅速熄灭
color = (0.706, 0.839, 1)             → 偏蓝白
Blend SrcAlpha One / ZTest Off / ZWrite Off
```

本项目对应实现（`atmosphere.gdshader` + `planet.gd` 的 `_build_atmosphere()`）：

| 原版 | 本项目 | 说明 |
| --- | --- | --- |
| 球壳半径 108.1 / 星球 100 | `ATMOSPHERE_RADIUS = 1.081` × `PLANET_RADIUS` | 比例 1:1 照搬 |
| `a = max(0, 1 - \|(d-100)/8\|)` | `a = max(0, 1 - \|(d-1)/0.08\|)` | 归一化到星球半径 1 |
| `a³` | `a*a*a` | 同 |
| 颜色 (0.706, 0.839, 1) | 同 | 偏蓝白 |
| `Blend SrcAlpha One` | `blend_add` | 加法混合 |
| `ZTest Off / ZWrite Off` | `depth_draw_never`（深度测试仍开） | 我们是单相机，深度测试留着更稳：辉光壳不写深度，不影响别的物体 |
| 日照侧更亮（`sun²`） | 固定 `intensity` | 本项目无太阳/昼夜概念，留一个常量 |
| — | `cull_front` | 只画球壳远侧半球：一层就够，不重复叠加 |

**为什么不用菲涅尔（`1 - dot(N, V)`）**：菲涅尔在球壳上恒等于「壳自己的剪影」，
只能把光画在壳的轮廓上——实测出来是一圈**边缘生硬的蓝色甜甜圈**（像贴纸，不像大气）。
原版的「距离带」把光锁在**星球剪影**那一圈、内外两侧都平滑衰减，才是 RimWorld 观感里
那圈柔和的蓝白边。参考图 2 的星球边缘光晕正是这种形态。

**附带作用**：亮边压住背景星空的相对亮度，星空因此显得更深邃（这正是需求里
「缺少星球大气光晕 → 星空不够深邃」的补偿项）。


---

## 5. 分期与工作量

**第 1 期（本期目标）：静态星穹**
1. M1 贴图：`tools/bake_star_tex.gd` 烘焙 64×64 三星 glyph → `assets/starfield/stars.png`（≈100 行，~0.5h）；
2. M2 星穹：`star_dome.gd`（build + 跟随 + 种子重建）+ `starfield.gdshader` + `planet.gd` 三处装配 + `default_clear_color`（≈150 行，~1.5h）；
3. M3 验证 + 调参（STAR_SIZE_REL / 背景色观感微信实测）（~0.5h）。

**第 2 期（可选，等 1 期观感拍板后议）**
- 太阳：无贴图加法 quad + 径向衰减 shader（原版 §5 的 Godot 对应形）；
- 引入一个"虚拟太阳方向"全局量，作为将来昼夜/季节系统的锚点——这是原版
  "先定太阳向量，再让光/太阳/星空全部从它派生"的做法，值得提前定接口。

**第 2 轮调校（已实施：对标 RimWorld 原版截图）**
- 贴图柔化：菱形核改 `pow` 平滑衰减 + 十字臂调细调暗 + 3×3 盒式模糊 + 峰值归一化；
- 尺寸：quad 角尺寸从 2.3°~12.6° 砍到 **0.86°~4.6°**（`STAR_SIZE_MIN/MAX` = 0.015/0.08）；
- 亮度随机性：`MultiMesh.set_instance_color()` + 底网格显式白色顶点色（第 2 轮的坑，见 §4.2）；
- 大气辉光：新增 `atmosphere.gdshader`（距离带算法，对照原版 `Custom_PlanetGlow`）；
- 护栏：冒烟脚本新增「亮度随机性」断言（共 7 项）。

**明确不做**（与原版对齐，写进了规划避免歧义）：
- 星星闪烁（原版 shader 无时间项）；
- 地图侧/菜单侧加星（原版世界地图夜景无星空）；
- 双相机（Unity 特有合成，文档明确勿搬）。

---

## 6. 风险与对策

| 风险 | 现象 | 对策 |
| --- | --- | --- |
| glyph 贴图形态失真 | 星点像"圆点"而非四芒星，星感假 | 烘焙工具先出图放大对比原版 alpha 分布，参数可调（角锐度指数、三星位置） |
| 高斯均匀性写错（用了 inside_unit_sphere 之类偏挤） | 两极/角落星密不均 | 冒烟脚本断言方向分布：分量均值≈0、三轴方差相等（数值容差） |
| WebGL2 上 alpha 混合渗边 | 星点边缘发灰圈 | 导入不开 mip、`alpha_cut` 不用（保持纯 mix）、必要时预乘 alpha |
| 星穹进入近景裁剪/穿模 | 拉到最近 1.15 时星星穿星球表面 | 不可能：dome 400 ≫ 视距 10，且深度测试开着（写深度关着反而不会污染别的物体） |
| 微信端 MultiMesh 兼容 | 个别低端机因 instance 数多掉帧 | STAR_COUNT 可降位（750 也几乎看不出差异）；draw call 始终 1，实际风险约等于零 |
| 配置文件非 ASCII 注释乱码（实施中实踩） | project.godot 里中文注释被编辑管线破坏，注释与下一行键名黏成非法键，设置静默失效 | **project.godot/export_presets.cfg 这类引擎配置文件保持 ASCII-only**，中文说明写进脚本注释或文档；拼写修复后需重启编辑器让游戏重新读取 |
| 编辑器回写覆盖陷阱 | 编辑器内存态旧版 + 保存动作会把外部改动整块冲掉 | 改project.godot 前先关编辑器（实施流程：quit → 改文件 → 验证 → 重启） |
| **instance color 乘在顶点色上（第 2 轮实踩）** | 底网格没有顶点色 → `COLOR` 恒白 → 每颗星亮度相同，随机性彻底失效（且**不报错，肉眼才发现**） | 底网格显式给白色顶点色（`_make_quad_mesh()`）；冒烟脚本加断言兜住（`use_colors` + 暗星占比 ~0.90） |
| **菲涅尔画不出大气（第 2 轮实踩）** | `1 - dot(N,V)` 在球壳上恒等于壳的剪影 → 一圈边缘生硬的蓝色甜甜圈 | 改用原版的「距离带」算法（§4.5）；辉光强度靠 `intensity` 调，不靠形状 |
| **`ImageTexture.create_from_image()` 只收 1 个参数** | 传 mipmaps 布尔 → Parse Error | 4.7 的签名是 `create_from_image(image)`；mipmaps 由 `Image` 自己带（`create_empty(..., use_mipmaps=true)` + `generate_mipmaps()`） |
| **`MultiMesh.set_instance_custom_data()` 收 Color 不收 Vector4** | 传 Vector4 → Parse Error | 4.7 签名是 `set_instance_custom_data(instance, custom_data: Color)` |

---

## 7. 验收标准（沿用本项目护栏风格）

1. **视觉**：godot-ai 窗口截图——星空铺满背景、星球清晰遮挡星星、星点带大小差异与旋转差异、无闪烁；拉远到 10 与拉近到 1.15 两档截图各一张。
   **第 2 轮追加**：① 画面必须是「深邃黑底 + 细碎暗色噪点 + 极少数亮星」，
   **绝不能再出现「巨大白色十字到处飘」**；② 星球边缘有一圈柔和的蓝白光晕（不是硬边蓝环）；
   ③ 1.15 / 2.05 / 5.0 / 10.0 四档缩放都要成立。
2. **确定性**：headless 冒烟——同 seed 两次 `build()` 的 MultiMesh transform 数组逐位一致；种子变化 → 布局变化；
3. **亮度随机性**（第 2 轮新增）：`use_colors` 已开、暗星占比 ≈ 0.90、存在亮星（防止 instance color 静默失效）；
4. **无耦合回归**：星球生成打点（④/⑤ 段耗时）与生成结果逐位不变；选中环/拖拽/缩放/菜单全程无异常、拾取不受星穹影响；
5. **性能**：星穹生成 < 10ms（一次性）；窗口与微信端帧率无回归；
6. **包体**：`godot.zip` 增量 < 10KB（仅一张 64×64 贴图）。

---

## 8. 一句话规划

**一个种子驱动的 MultiMesh 星穹（1500 个带"三颗四芒星"glyph 的 quad，随机旋转缩放，挂在相机位置上静止不动）+ 一张烘好的 64×64 贴图 + 默认清屏色换成 #10171E——单 draw call、零视差、零光照依赖、同种子同星空。**
