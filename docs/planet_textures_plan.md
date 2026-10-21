# 星球地表纹理化规划（Biome 色卡 + WorldMacro + 丘陵贴片）

> 参考来源：`D:/workspace/ref/rimworld/docs/22-PlanetTextures.md`（RimWorld 星球贴图专题）
> 与 `D:/workspace/ref/rimworld/WorldMapTexturePaths.md`（贴图路径总表）。
> 本项目贴图已从原版游戏提取并复制进 `assets/`（AssetStudio 导出，源目录
> `D:/workspace/ref/rimworld_assets/Texture2D/`）。
>
> **原则：不照抄 RimWorld，只借思路。** 架构按本项目「全代码动态构建、
> 单 draw call、headless 可测」的风格重做；目标是把「纯色贴片的玩具感」
> 升级为「手绘贴图 + shader 多层质感」的游戏氛围。

---

## 0. 先给结论

**现状**：星球 = 40962 个 Goldberg 贴片（LEVEL=6）的单个 ArrayMesh，颜色全靠
顶点色，`planet_surface.gdshader` 只做 `ALBEDO = 顶点色`，没有 UV 通道 ——
纯色块，无质感，像玩具。

**目标方案**：三层质感叠加（这是原版「像一颗星球而不像色块球」的核心哲学）：

| 层 | 来源 | 尺度 | 作用 |
| --- | --- | --- | --- |
| ① 底色 + 细颗粒 | 7 张生态色卡（512²，手绘低对比度噪声） | 细节 | 每个生态的独特质感 |
| ② 大陆斑块 | `WorldMacro.png`（256² 近白云状噪声，全星球共享） | 大陆级 | 打散平铺重复、软化 biome 边界 |
| ③ 地形明暗 | 现有顶点色（丘陵压暗 / 山区往基岩灰压） | 贴片级 | 地形可读性（哪里翻不过去） |

最终像素 = `生态色卡 × WorldMacro × 顶点色调制器`，保持 opaque 渲染管线。

---

## 1. 原版机制速记（供实现时对照，详见参考文档 22）

- 原版每 biome 一张 **512×512 RGB 不透明色卡**：底色接近纯色 + 极低对比度噪声
  （通道标准差仅 1.4~5.6/255）。**不是卫星照片**，低对比度是刻意为之 ——
  平铺 40 次也不显重复，「星球感」靠三层叠加而不是贴图本身。
- shader 用**世界坐标的盒式投影**采样（不用 UV）：选 |N| 最大的轴，
  主贴图每立方体面平铺 20×、WorldMacro 平铺 1.5×，逐像素相乘。
- UV0.x 装的是**高程**（不是贴图坐标），供高程提亮与海洋深浅用。
- 丘陵/山是**贴在球面的二维 quad 贴片**（不是几何起伏）：128×128 图集
  （2×2 四变体带 alpha），按 hilliness 档位选图，随机抖动 + 随机旋转，
  离球面 0.005 防 z-fighting。
- 生态边界是**硬切**（每 tile 一个材质），被 WorldMacro 和相邻色卡本来就接近的
  颜色「洗」得看不出来。
- 原版均值色（调参对照用）：温带森林 `#766B39` 橄榄绿 / 寒带 `#64522C` 深橄榄 /
  苔原 `#836958` 灰棕 / 沙漠 `#9A7956` 沙色 / 冰盖 `#9F9F9F` 灰白 /
  海冰 `#939393` 灰 / 海洋 `#3B465C` 蓝灰（⚠️ 成品海蓝色靠 shader 上色，
  Ocean.png 本身偏灰）。

---

## 2. 我们的贴图资产清单（已复制进 `assets/`，含 .import）

| 文件 | 尺寸 | 用途 |
| --- | --- | --- |
| `TemperateForest.png` | 512² | 生态色卡：温带森林 |
| `BorealForest.png` | 512² | 生态色卡：寒带 |
| `Tundra.png` | 512² | 生态色卡：苔原 |
| `Desert.png` | 512² | 生态色卡：沙漠 |
| `IceSheet.png` | 512² | 生态色卡：冰盖 |
| `IceSheetOcean.png` | 512² | 生态色卡：海冰（注意文件名带 Ocean） |
| `Ocean.png` | 512² | 生态色卡：海洋（Lake 与 Ocean 共用，我们也共用） |
| `WorldMacro.png` | 256² | 全局宏观噪声：大陆尺度明暗斑块，所有生态共享 |
| `SmallHills.png` | 128² | 丘陵贴片：小丘（2×2 图集，不透明占比 ~5%） |
| `LargeHills.png` | 128² | 丘陵贴片：大丘（~14%） |
| `Mountains.png` | 128² | 丘陵贴片：山地（~24%） |
| `Impassable.png` | 128² | 丘陵贴片：不可逾越（~46%） |

与我们 7 个 biome id 的对应（`planet.gd` BIOME_NAMES 顺序）：

| id | 生态 | 色卡文件 |
| --- | --- | --- |
| 0 | 海洋 | `Ocean.png` |
| 1 | 海冰 | `IceSheetOcean.png` |
| 2 | 冰盖 | `IceSheet.png` |
| 3 | 苔原 | `Tundra.png` |
| 4 | 寒带 | `BorealForest.png` |
| 5 | 沙漠 | `Desert.png` |
| 6 | 温带森林 | `TemperateForest.png` |

5 级地形（`TerrainLevel`）与丘陵贴片的对应：小丘陵→SmallHills、
大丘陵→LargeHills、山区→Mountains、不可逾越→Impassable、平原→不画。

---

## 3. 核心设计决策（与原版的差异点，实现时不要走偏）

### ① 图集 + UV2，而不是「一个 biome 一个材质」

原版：一个 biome 一个 subMesh + 材质 → 7+ 次 draw call。
我们：启动时把 7 张色卡打包成**一张图集**，每贴片把「自己 biome 的格子原点」
写进新启用的 **UV2 通道**（`ARRAY_TEX_UV2`；贴片内所有顶点同值，插值无损），
fragment 按 UV2 定位格子 → **7 个 biome 仍只有 1 次 draw call**，比原版更省。

### ② 逐片盒式投影采样，不用几何 UV

fragment 用 `normalize(world_pos)` 盒式投影得球面方向 `p`，
`fract(p × TILING)` 重映射进 UV2 指定的图集格子。好处：
- 采样只依赖世界坐标 → 同 biome 跨贴片**纹理连续**，无「每六边形一张图」接缝；
- biome 交界自然硬切（与原版一致），被 WorldMacro 洗掉；
- 每片独立选主导轴 → 无跨面拉伸。

### ③ 顶点色语义升级：「最终色」→「色调制器」

`_tile_appearance` 改为输出**明暗系数 + 基岩混合**（不再是最终色）。
最终色 = 贴图 × macro × 顶点色。地形可读性（越高级越暗、山越灰）完整保留。
现有系数照搬：小丘 ×0.92、大丘 ×0.82、山区 ×0.72 + 40% 岩石、
不可逾越 ×0.6 + 80% 岩石（`C_ROCK`）。

### ④ 未生成区域 = 第 8 格 Ocean 备份（遥远深洋）

覆盖率的语义 =「系统生成并管理的可玩范围」：区外没有地形数据、不可选中、
不可探索——概念上就是围绕可玩世界边缘的遥远深洋。因此第 8 格不画纯色，
而是再放一张 Ocean 卡（运行期重复打包同一张卡，零新资产），
未生成贴片的 UV2 指向它：

- 观感与已生成海域**逐像素一致**（同一格贴图 × 同一张 WorldMacro × 同一
  全白调制器，宏观噪声按世界坐标连续）→ 覆盖区边界无缝，
  不再出现「浅蓝死海」色块（初版纯色 `C_UNGENERATED` 实测对比过强，已废弃）；
- 顶点色恰与生成海域的 `_tile_appearance(FLAT)`（全白不动色）同值，无亮度台阶；
- 仍保住「已生成 + 未生成」1 次 draw call；
- 已知后果：极区已生成海域会结冰（海冰 biome），区外永远是普通海面——
  「冰只出现在被管理的水域」，符合区外无气候模拟的设定。

---

## 4. 分期实施

### 第 1 期：生态色卡 + 宏观噪声（底色质感）

1. **`biome_atlas.gd`（新，仿 `star_atlas.gd` 运行期打包风格）**
   - preload 7 张色卡 → 各缩到 256²（近纯色噪声，缩半无损观感）→
     打包成 4×2 图集，格间留 gutter（防 mipmap 串味）
   - 第 8 格再放一份 Ocean 卡（未生成贴片 = 遥远深洋，与已生成海域同观感）
   - preload `WorldMacro.png`
   - 返回 { texture, cell_origins(每 biome 的格子原点 UV2), macro_texture }
   - 一次构建缓存，换种子不重做
2. **`planet.gd`**
   - 网格数组加 `ARRAY_TEX_UV2`，逐贴片写 biome 格子原点
     （未生成 → 第 8 格；水域贴片按其 biome 正常写）
   - `_tile_appearance` 返回值改为色调制器（乘法系数 + 岩石 lerp）
   - 材质装配处（`_on_generate_requested`）挂图集 + macro 纹理
3. **`planet_surface.gdshader`（重写 fragment，vertex 不变仍传 COLOR）**
   ```glsl
   // 关键结构（实现稿）：
   varying vec4 v_tile_color;   // 顶点色 = 色调制器（沿用）
   varying vec2 v_biome_cell;   // UV2 = 图集格子原点（新增）
   // fragment：
   vec3 n = normalize(world_pos);          // world_pos 在 vertex 里算
   vec2 p = box_project(n);                // 选 |n| 最大轴，另两轴/主导分量 → [-1,1]
   vec2 tiled = fract(p * TILING);
   vec3 main  = texture(biome_atlas, v_biome_cell + tiled * CELL_SIZE).rgb;
   vec3 macro = texture(macro_tex, p * MACRO_TILING).rgb;
   ALBEDO = main * macro * v_tile_color.rgb;
   // 不写 ALPHA，保持 opaque
   ```
   - `world_pos`：vertex() 里 `(MODEL_MATRIX * vec4(VERTEX,1)).xyz`
   - 纹理 uniform：`source_color, filter_linear_mipmap, repeat_enable`
     （盒式投影 UV 超 [0,1]，repeat 必须开）
4. **可调常量**（放 `planet.gd` 或 shader 顶部，出截图后逐轮调）：
   - `TILING`：每立方体面平铺次数，初值 **8**（原版 20，但它 10242 贴片、
     我们 40962，我们颗粒相对更细，初值保守）
   - `MACRO_TILING`：初值 **1.5**（照抄原版，大陆尺度斑块）
   - gutter 宽度、色卡缩放（256²）

### 第 2 期：丘陵/山脉手绘贴片层（「造型」感的主要来源）〔已实现〕

5. **丘陵图集**：`hills_atlas.gd`（新）——4 张 Hills 贴片（各含 2×2 四变体）
   运行期拼成一张 2×2 小图集：
   - 原生 128² 打包**不缩放**（变体只有 64²，再缩就糊），GUTTER=16 边缘像素
     延展填充 + `generate_mipmaps()`（同 biome 图集防串味手法；带 alpha 的图
     透明边延展透明，天然正确）
   - 返回 { texture, cell_origins(4 格左上角 UV), sprite_uv }
6. **贴片网格**：`planet.gd _build_hills_mesh()`（新）——每个 `level ≥ 小丘陵`
   的贴片，在其中心方向加抖动后的位置、离球面 1.005× 半径处贴一个**切线 quad**：
   - 边长 0.9–1.1 × `avg_tile`（= 4/√贴片总数，单位球等面积圆直径，与原版
     averageTileSize 同语义）；球面位置抖动按等级递减 0.37/0.20/0.08/0.08
     × `avg_tile`（小山最散、大山最贴中心，原版 §6.2 表）
   - 随机绕法线旋转（消复制感）；UV 按地形等级选图集格 + 2×2 变体随机
   - `planet_hills.gdshader`（新）：`unshaded, cull_disabled, depth_draw_never`
     + alpha 混合；直接 `texture()`——quad 内 UV 连续、恒在变体内，无地表
     fract 平铺那种导数突跳，**不需要**手算 LOD
   - 独立 MeshInstance3D，仍是 1 次 draw call；随机流独立
     （`rng.seed = world_seed ^ 0x48494c4c`，"HILL"），不碰地形/气候随机流
     → 主生成确定性不受影响（同种子 quad 数组逐位一致，测试断言）
   - 数量：30% 档 3660 quad、100% 档约 1.2 万，与星空 16000 quad 同量级，无压力
   - 做法参考 `star_dome.gd`（切平面 basis + 随机旋转 + ArrayMesh 装配）

---

## 5. 验证方案

1. **headless 回归**（仿 `tools/test_starfield.gd`，新 `tools/test_planet_texture.gd`）：
   - 图集构建成功（尺寸、格子数 ≥ 8）
   - UV2 通道存在且逐片指向正确格子（抽查若干已知 biome 贴片）
   - 未生成贴片指向第 8 格（Ocean 备份格，内容与第 0 格逐位一致）
   - 同种子确定性不破坏（网格数组逐位对比，注意 UV2 也要比）
   - 现有 `tools/test_tile_hud.gd` 必须继续 PASS（HUD 只用 BIOME_NAMES）
2. **视觉验证**：`tools/capture_final.gd` 三档距离截图逐轮调参：
   - 1.15 近景 → 看颗粒质感、biome 边界
   - 2.33 中景 → 看大陆斑块、重复感
   - 10 远景 → 看整体氛围（是否还「像玩具」）
3. **性能**：生成总耗时打点不明显劣化（图集打包应在启动时一次性完成，
   不进生成管线热路径）；窗口帧率无回归。
4. **headless 回归（第 2 期）**：`tools/test_planet_hills.gd`：
   - 图集 2×2 打包（尺寸 / mipmap / 4 格 / sprite_uv）、gutter 最远端 == 内容缘；
   - 四格 alpha 覆盖率分档：全像素 `a>0` 口径 = 4.8/14.3/23.7/45.8%（与原版
     提取实测精确对齐；注意 `a>0.5` 口径只有 1.6/3.4/7.1/33.3%——原图整体半透明，
     见 §7.2）；
   - quad 数 == `terrain ≥ 小丘陵` 的贴片数（精确相等 → 平原/水域/未生成无 quad）；
   - 顶点半径全部 = 1.005±0.001（离球面防 z-fighting、贴而不浮）；
   - UV 逐 quad 落在对应等级格的 2×2 变体内；
   - 确定性：同种子重建 quad 数组逐位一致、换种子必有差异。
5. **视觉验证（第 2 期截图复检结论）**：1.15 近景四级贴片质感清晰、旋转随机、
   无接缝/黑晕/z-fighting；2.33 中景山地块为有质感的深色岩簇斑块（不再是死色块）；
   10 远景 mip 平滑淡出、无闪烁无雾霭，limb 干净无浮空。

---

## 6. 性能账

- Draw call：地形 1 + 丘陵贴片 1（第 2 期）+ 现有大气/星空/选中环 —— 不新增逐帧 CPU 工作
- fragment 成本 = 2 次纹理采样 + 几行算术（与原版同级，手机端已验证的方案）
- 纹理内存：生态图集 ~1280×640 RGBA ≈ 3.3MB（含 mipmap ~4.4MB）
  + macro 256² + 丘陵图集几百 KB —— 微信小游戏可接受
- 生成期一次性开销：图集打包几毫秒（启动时做一次）

---

## 7. 风险与对策

| 风险 | 对策 |
| --- | --- |
| 盒式投影 45° 接缝 | 逐片独立选轴 + 贴图低对比度（原版实证不可见）；LOD 用 `n` 的导数算（见 §7.1 ②），切轴处不炸；截图验证 |
| 图集 mipmap 串味 | 格间 gutter 用**本格边缘像素延展**填充 + `fract` 重映射限制在格内；GUTTER=64 兜住远景（见 §7.1 ③） |
| 平铺重复感 | WorldMacro 低频斑块打散（原版核心手法）；不够就调 TILING / 加 macro 强度 |
| 山区岩石色调制 × 贴图后发闷 | 先出截图看效果；必要时把「岩石混合」从乘法改成向岩石色 lerp |
| Ocean.png 本身偏灰（海蓝色靠原版 shader） | 已实证无此问题：海洋渲染为自然海蓝，暂不动 |
| 丘陵贴图整体半透明（alpha 上限仅 0.69–0.81，见 §7.2） | 原设计如此（叠在地表色上，RimWorld 同款）；若截图观感偏淡，在 hills shader 加 alpha 增益 uniform |
| 跨 quad 边界 1px LOD 抖动 | quad 内 UV 连续，足迹抖动只发生在两 quad 交界，且落在贴图自带的透明留白区——三档截图复检无感，无需手算 LOD |
| 小丘 quad 呈准周期点阵感 | 一贴片一 quad + 抖动 0.37×贴片宽是原版参数；嫌规律可加大抖动或加尺寸方差（参数集中在 planet.gd「丘陵参数表」，整表可调） |

### 7.1 接缝修复实录（第 1 期实现后截图复检）

第 1 期首次截图（dist 1.15/2.33/10 三档）发现两类接缝伪影，逐一排除、修复：

1. **近景细暗十字/暗线**（过视图中心的竖横线 + 角落斜线）
   - 先排除内容 wrap：实测 3 张贴图边缘差 ≤ 内部基线（WorldMacro 边差 0.08/0.26
     vs 内部 0.59/0.26）→ PNG 本身基本无缝，不是内容接缝；
   - 真元凶：`fract()` 整数边界处 UV 跨整格突跳 → GPU 屏幕导数爆炸 → 误判极远
     → 采最高 mip → 最高层混进图集**透明黑 gutter**（原 `Color(0,0,0,0)` 留白）
     → 每条平铺边界渲出 1px 细暗线；
   - 修复（两层，缺一不可）：
     - `biome_atlas.gd`：gutter 改为**边缘像素延展填充**（标准 atlas padding，
       `_pad_gutter()`，在 `generate_mipmaps()` 之前做）→ 任何 mip 层级混到
       gutter 拿回的都是同色延展，暗线根源掐掉；
     - `planet_surface.gdshader`：手算 LOD + `textureLod()`，且必须取
       **`fract()` 之前的连续量**——最终用处处连续的 `n` × 盒式投影雅可比上界
       `jac = (1+|p|)/a_dom`（切轴边界两侧 `|p|`、主导轴幅值相等 → jac 连续）
       计算：`lod = log2(max(sn*jac*TILING*256, 1))`。
       若只用 `dFdx(p*TILING)`：fract 边界是连续了，但**切轴边界 p 本身跳变**，
       炸点换到切轴处。
2. **远景（dist 10）海洋上的浅色细弧**
   - 元凶：高 LOD（≈4-5）采样足迹 ±32-64px 跨出 16px gutter，伸进**图集邻格**
     的延展区——Ocean 格右邻是 IceSheetOcean（浅色）→ fract 边界混入邻格色
     → 海洋上浅色亮弧（左侧格边界无邻格内容，故只呈现半个平铺网格，弧数减半）；
   - 修复：GUTTER 16 → **64**（LOD L 足迹约 ±2^L px，64px 兜住 LOD ≤5 = 实测
     最大观察距离 dist 10 的需求）；测试断言覆盖 gutter 最远端 == 本格内容色。
3. 复检：三档截图暗十字/斜线/亮弧全部消失；`test_planet_texture.gd` 7/7 PASS
   （含 gutter 延展断言 g0/gfar/角 == 内容色、无透明黑）。

### 7.2 第 2 期实现记录（丘陵贴片层）

1. **覆盖率断言口径**：首跑 `test_planet_hills.gd` FAIL——断言按 `alpha>0.5`
   取样得 1.9/3.6/9.4/32.6%，远低于文档图数 5/14/24/46%。探针实测发现四张
   贴图 alpha 上限只有 **0.69/0.69/0.72/0.81**（无一像素全不透明），而 `a>0`
   口径精确复现 4.8/14.3/23.7/45.8% → 文档图数本就是 `a>0`（有笔迹即计）。
   断言改全像素 `a>0` 计数（零采样噪声），带宽按实测 ±50% 定档，8/8 PASS。
   渲染含义：山体是半透明贴图、与地表色叠色（原版同款设计），观感偏淡时
   可在 shader 加 alpha 增益（暂不需要，截图已达标）。
2. **quad 位置抖动的等效实现**：原版「中心 + UnitVector3×量程 → normalize×半径」
   在我们这等价于「(中心 + 随机单位向量×量程).normalized()」——归一化天然
   去掉径向分量，纯角位置抖动，顶点半径恒 = 1.005（测试断言 ±0.001 兜底）。
3. **测试口径坑**：quad 数组构建序 = `_terrain` 中 ≥小丘 贴片的遍历序，
   UV 落格断言按此反推；RNG 每合格 quad 固定消耗 7 次随机数
   （单位向量 3 + 角度 1 + 尺寸 1 + 变体 2），确定性由「种子 + 遍历序」锁定。
4. 复检：三档截图目检通过（见 §5 第 5 条）；`test_planet_hills.gd` 8/8 PASS，
   全套回归绿（texture 8/8、tile_hud、selection_smoke 5/5、selection_chain
   与 Phase 1 基线逐行一致、starfield 8/8、region_cap 8/8）。

---

## 8. 不在本期范围（后续可选）

- 海洋深度渐变 / 岸边白浪 / 镜面高光（原版 WorldOcean shader 的深浅逻辑）
- 昼夜光照系统（原版半球光照；本项目目前无太阳/时间概念）
- 河流 / 道路（原版是路径网格系统，与生态底图无关）
- 高程提亮（原版 UV0.x 高程加白；我们顶点色已表达地形明暗，暂不需要）

---

## 9. 一句话总结

**把 7 张原版生态色卡打包成一张图集，每个贴片用 UV2 指自己的格子，
fragment 用世界坐标盒式投影采样（底色 × WorldMacro × 顶点色调制器）
—— 1 次 draw call 拿到原版三层质感；再给高级地形贴一层手绘丘陵 quad
（第 2 期），把「更暗的色块」变成「看得见的山」。**
