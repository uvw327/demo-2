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

| 文件 | 职责 |
| --- | --- |
| `starfield.gdshader`（新） | `shader_type spatial; render_mode unshaded, cull_disabled, depth_draw_never;`；`ALBEDO = 白`，`ALPHA = tex.a`；保持**深度测试开启**（靠远距自然被星球遮挡，这是与原版 `ZTest Off` 的有意差异——我们没有双相机，开深度反而更稳），深度写入关闭 |
| `star_dome.gd`（新，`class_name StarDome extends MultiMeshInstance3D`） | ① `_make_star_tex()`：运行期程序化烘焙 64×64「菱形核 + 细十字臂」三颗 glyph（纯白 RGB、只动 alpha）；② `build(seed)`：SeededRNG → 高斯均匀球面方向 × 1500 → 每 quad 一个 instance（切平面 basis + 随机绕法线旋转 + 随机尺寸），transform 先算进 GDScript 数组 `_built`（冒烟可测）再提交 MultiMesh（dummy 渲染器读不回）；③ `_process`：仅做 `global_position = cam.global_position`；④ 种子变了才重建 |
| `planet.gd`（改，~10 行） | `_ready`：`add_child(_star_dome); _star_dome.build(0)`（菜单相位即有星空）；`_on_generate_requested` 换种子时 `build(seed)` |
| `tools/test_starfield.gd`（新，冒烟护栏） | 数量/确定性（同 seed 逐位一致、换 seed 变化）/方向分布均匀/材质就绪/相机跟随，共 6 项 |

装配后场景树（全部运行期代码构建，与现有风格一致）：

```
Planet (Node3D)
├── TileHUD
├── OrbitCamera (Camera3D)
├── WorldMenu
├── MeshInstance3D   ← 星球（半径 1）
└── StarDome (MultiMeshInstance3D)   ← 星穹（半径 400，每帧贴相机位置）
```

### 4.2 参数表（最终值快照，全部在 `star_dome.gd` 常量区）

| 常量 | 终值 | 备注 |
| --- | --- | --- |
| `DOME_RADIUS` | 400 | 最远视距 10 的 40 倍，沉入 far(4000) 内 |
| `STAR_COUNT` | 1500 | = 原版 StarsCount |
| `STAR_SIZE_MIN / MAX` | 0.04 / 0.22 | 实体亮核视尺寸 ≈ 0.7°~4°。**规划初稿按原版比例取 0.10~0.38 是错的**——实测实体亮核会大到 4~10°，星桥连成白雾；应先定「实体亮核目标角尺寸」再反推 quad 比例 |
| `GLYPHS` | 半箭长 8 / 3.5 / 3 px | 三颗星（中央大 + 右上/左下小） |
| `GLYPH_RIM` | 0.5 | 菱形核：内半段全亮 + AA 过渡，防爆亮 |
| `GLYPH_ARM_LEN / ARM_W` | 1.8 / 0.12 | 细长十字臂（✦ 的尖芒）；首版臂 1.0s/0.16 在屏幕上不可见 |
| `BACKGROUND` | `#10171E` | RadWorld 天空相机清色；写入 project.godot 的 default_clear_color |

glyph 直观角尺寸核算：quad 4.6°~21.5° 最差，实体亮核 = 0.25×quad 角宽（2·(1−RIM)·s / 64px 贴图边）≈ 0.7°~4°，小点星到大 sparkle，与原版选点页观感一致。

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

---

## 5. 分期与工作量

**第 1 期（本期目标）：静态星穹**
1. M1 贴图：`tools/bake_star_tex.gd` 烘焙 64×64 三星 glyph → `assets/starfield/stars.png`（≈100 行，~0.5h）；
2. M2 星穹：`star_dome.gd`（build + 跟随 + 种子重建）+ `starfield.gdshader` + `planet.gd` 三处装配 + `default_clear_color`（≈150 行，~1.5h）；
3. M3 验证 + 调参（STAR_SIZE_REL / 背景色观感微信实测）（~0.5h）。

**第 2 期（可选，等 1 期观感拍板后议）**
- 太阳：无贴图加法 quad + 径向衰减 shader（原版 §5 的 Godot 对应形）；
- 大气 rim 辉光：半径 1.081 球壳 + 日照侧 Fresnel（贴片 unshaded 前提下的纯视觉件）；
- 引入一个"虚拟太阳方向"全局量，作为将来昼夜/季节系统的锚点——这是原版
  "先定太阳向量，再让光/太阳/星空全部从它派生"的做法，值得提前定接口。

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

---

## 7. 验收标准（沿用本项目护栏风格）

1. **视觉**：godot-ai 窗口截图——星空铺满背景、星球清晰遮挡星星、星点带大小差异与旋转差异、无闪烁；拉远到 10 与拉近到 1.15 两档截图各一张；
2. **确定性**：headless 冒烟——同 seed 两次 `build()` 的 MultiMesh transform 数组逐位一致；种子变化 → 布局变化；
3. **无耦合回归**：星球生成打点（④/⑤ 段耗时）与生成结果逐位不变；选中环/拖拽/缩放/菜单全程无异常、拾取不受星穹影响；
4. **性能**：星穹生成 < 10ms（一次性）；窗口与微信端帧率无回归；
5. **包体**：`godot.zip` 增量 < 10KB（仅一张 64×64 贴图）。

---

## 8. 一句话规划

**一个种子驱动的 MultiMesh 星穹（1500 个带"三颗四芒星"glyph 的 quad，随机旋转缩放，挂在相机位置上静止不动）+ 一张烘好的 64×64 贴图 + 默认清屏色换成 #10171E——单 draw call、零视差、零光照依赖、同种子同星空。**
