# 星球河流系统规划（一期）：球面水文网络 + 固定宽度河线

> 状态：**一期已落地；A 方案（河网密度/小短线）已实现并通过回归（2026-10-23）**
> 参考图：`temp/river.png`
> 主要关联文件：`planet.gd`、`planet_surface.gdshader`、`planet_hills.gdshader`
> 一期结论：**先算水网数据，再用独立河流 mesh + 独立 shader 画固定宽度线带**；一期走贴片中心线，二期可切换为贴片边界线。
> 渲染决策：**河流压住低丘（SmallHills/LargeHills），但被高山（Mountainous/Impassable）压住**；目标平台是**移动端 GL Compatibility**；选中环最终应在河流之上，本期先不改选中环，河流暂时盖住它也可接受。
> 下一步：**§20 河流渲染第二阶段（河宽分级 + 链式 ribbon 已落地，见 §20.14；配色仍待定）**。

---

## 0. 一句话总结

**把现有 `humid / temp / elev` 变成“产流 → priority-flood 流向 → 汇流 → 流量阈值”的水文网络，再把河段做成球面上的固定宽度方头 ribbon：宽度不随流量变化，屏幕空间保留约 1.2px 下限；水面只做终点，封闭湖额外生成一个单出口。**

---

## 1. 参考与一期目标

### 1.1 参考图观察

`temp/river.png` 的河流特征：

- 灰蓝色、宽度基本一致、硬边/方头线段；
- 树根/血管状分叉：支流汇入干流，最终入海或入湖；
- 转折多为 120° 左右的折线，视觉上贴着六边形/三角形地格；
- 河流不画在湖面/海面上，入海口在岸线处截断；
- 陆地颜色、地形起伏和河流是两层独立的信息。

一期不要求复刻这些绘制细节，只要求先得到**拓扑正确、密度合理、分布自然**的河网。

### 1.2 一期目标

1. 在球面陆地上生成树状河网：支流汇入干流，最终入海/入湖。
2. 河流密度随降雨、温度、蒸发变化：
   - 湿暖地区河多；
   - 干热沙漠几乎无河；
   - 冰盖内部无河；
   - 苔原/寒带保留少量融雪型河流。
3. 河流不画在水面、海冰上；入海口/入湖口在岸线截断。
4. 渲染使用固定宽度、蓝色、方头线段；先不做宽度变化、蜿蜒、反光、流动。
5. 数据层保留 `Q`（流量）和 `flow`（流向），方便二期做河宽、湖泊出流、三角洲、流动动画、玩法。

### 1.3 一期明确不做

- 不做参考图的一比一复刻；
- 不做完整水循环（湖面蒸发、地下径流、季节融雪、洪水）；
- 不做河宽随流量变化；
- 不做河道蜿蜒、平滑、分叉/三角洲；
- 不做水面高度/水体体积；
- 不修改现有气候、群系、地形字段的语义；
- 不在本期内做河流相关的玩法逻辑。

---

## 2. 现状盘点

### 2.1 网格与贴片数据

`planet.gd` 当前是 Goldberg 对偶网格：

- `LEVEL = 6`，`SUBDIV = 64`，贴片总数 `10 × f² + 2 = 40962`；
- 每个贴片是五边形或六边形；
- `_topo_verts`：细分网格顶点，也就是贴片中心方向（单位球面）；
- `_tile_polys`：每块贴片的边界顶点（`tri_cents`，单位球面，按方位角排序）；
- `_tile_centers`：每块贴片的中心方向；
- `verts`、`tris`、`tri_cents`、`vert_faces`、`tri_tiles` 是生成期拓扑数据。

已有逐贴片缓存：

| 数组 | 含义 |
|---|---|
| `_tile_elev` | 海拔噪声值，`SEA_LEVEL = -0.05` 以下为水 |
| `_tile_temp` | 温度，`0..1`，极寒到酷热 |
| `_tile_humid` | 湿度/降雨代理，`0..1` |
| `_tile_biome` | 群系 id，`BIOME_NONE = 255` 表示未生成 |
| `_terrain` | 地形等级 |
| `_inland_water` | 区内水域标记（海拔 < 海平面） |
| `_generated` | 该贴片是否已生成、可交互 |

### 2.2 已有水体/海岸处理

- `SEA_LEVEL = -0.05`；
- `_inland_water[v] == 1`：区内海拔低于海平面的水域（内海/内陆湖/大陆架）；
- 未生成贴片（`BIOME_NONE`）渲染为深洋；
- `⑤b0` 已经做过小水域剔除：完全被陆地包住且 ≤ `MIN_LAKE_TILES = 11` 的封闭小湖填成陆地；
- `⑤b` 已经做过离岸距离场 BFS，说明“从水体连通域出发做 BFS”的代码模式是现成的；
- 海冰由 `_biome_id` 判定：水温低于 `T_FREEZE = 0.18` 时为海冰。

### 2.3 已有渲染层

- 地表：`planet_surface.gdshader`，`unshaded, cull_disabled`，用 UV2 指生态图集格子，水格走净色 + 近岸白噪带；
- 丘陵：独立的 `MeshInstance3D` + `planet_hills.gdshader`，一个 draw call，`unshaded, cull_disabled, depth_draw_never, blend_mix`，半径 `1.005`；实现河流时要按 §9.4 拆成低丘/高山两组，让河流压住低丘、被高山压住；
- 大气/太阳/星空都使用显式 `render_priority`。

河流层完全可以沿用丘陵层的架构：**独立 mesh、独立材质、一次 draw call、透明队列、`depth_draw_never`**。

### 2.4 生成管线与分帧

- `_build_goldberg_mesh_async()` 是分帧协程；
- 所有重循环使用 `_slice_yield(percent)` 让帧；
- 当前阶段标记：`③邻接面表`、`④覆盖率选区`、`⑤对偶贴片`、`⑤b离岸距离场`、`⑤c网格写入`、`⑥组装ArrayMesh`；
- 新增水文阶段必须沿用“批处理 + 批尾结钟 + `_slice_yield`”的写法，不能一次性同步跑完。

### 2.5 可直接复用的结论

1. 贴片邻接可以从 `vert_faces` + `tri_tiles` 直接建，不需要新空间索引。
2. 水体连通域 BFS 已经在 `⑤b0` 出现过，湖泊单出口可以复用同一套邻接口径。
3. 河流渲染不需要动地表 shader；独立 mesh 的风险最低。
4. 生成期已经有 `_tile_elev / _tile_temp / _tile_humid`，一期不需要重新采样气候。

---

## 3. 技术选型（已拍板）

### 3.1 独立河流 mesh + shader

**选择**：新建 `planet_rivers.gdshader`，在 `planet.gd` 里构建一个独立的 `MeshInstance3D`。

理由：

- 固定宽度在几何上精确，不受贴图分辨率影响；
- 球面没有 UV 展开接缝；
- 1 个 draw call，和丘陵层同构；
- 不碰现有地表 shader，回归风险低；
- 后续要换贴图/SDF/流动效果，水文数据不用动。

### 3.2 一期贴片中心线，二期可换贴片边界

**一期选择**：节点 = 贴片中心，边 = 相邻贴片中心连线。

- 实现最简单，段长合适，树状结构清晰；
- 线会穿过贴片内部，不完全贴参考图的格边；
- 但一期重点是网络密度/分布/汇流关系，不是最终笔触。

**二期预留**：把节点换成三角形重心（`tri_cents`），边换成贴片边界，就能得到参考图那种 120° 折线。水文内核按 §4.2 的 `flow_graph` 接口设计，换图不重写算法。

### 3.3 湖泊：终点 + 单出口

- 所有水面是流动终点；
- 河流不画在水面上，入湖/入海口在岸线截断；
- 对**封闭湖**额外生成一个单出口，避免大湖“只进不出”；
- 不做多级湖链水量平衡，不做湖面水位/体积。

### 3.4 世界固定宽度 + 屏幕最小宽度

- 所有河段同宽，**不随 Q 变化**；
- 近看是固定世界宽度；
- 远看用屏幕空间下限保证可见（约 1.2px）；
- 屏幕下限只是可见性兜底，不是“按流量变宽”。

### 3.5 为什么不用贴图/直接改地表 shader

| 方案 | 优点 | 缺点 | 一期结论 |
|---|---|---|---|
| 独立 mesh + shader | 宽度精确、无接缝、1 draw call、易替换 | 透明层排序/抗锯齿要处理 | **采用** |
| 烘河网贴图 | 像素级抗锯齿、片元里可做复杂效果 | 球面展开/分辨率/接缝/显存；近看糊 | 二期可评估 |
| 直接改地表 shader | 少一个层 | 与图集/海岸雾/丘陵耦合；逐贴片多方向河道难表达 | 不采用 |

---

## 4. 总体架构：图 → 水文 → 渲染

### 4.1 三层解耦

1. **图结构层**：节点位置、高程、水面标记、产流注入、邻接。
2. **水文层**：填洼、流向、汇流、流量阈值、河段集合、湖泊出口。
3. **渲染层**：河段 → 球面 ribbon → 材质。

### 4.2 `flow_graph` 接口

水文算法只依赖这个结构，不认“贴片”还是“三角重心”：

```text
flow_graph = {
  pos:        PackedVector3Array,   # 单位球面节点位置
  elev:       PackedFloat32Array,   # 节点高程
  is_water:   PackedByteArray,      # 1 = 水面/汇点
  injection:  PackedFloat32Array,   # 该节点注入的产流
  neighbors:  PackedInt32Array,     # N×6，-1 填充
  kind:       "tile" | "corner"
}
```

输出：

```text
flow_result = {
  parent:     PackedInt32Array,     # -1 = 水面/无
  filled:     PackedFloat32Array,   # 填洼后的高程
  order:      PackedInt32Array,     # priority-flood 出堆顺序
  q:          PackedFloat32Array    # 汇流后的流量
}
```

### 4.3 一期：tile graph

| 字段 | 来源 |
|---|---|
| `pos` | `_tile_centers` |
| `elev` | `_tile_elev` |
| `is_water` | `_inland_water == 1` 或 `_generated == 0` |
| `injection` | 该贴片产流 `R`（水面为 0） |
| `neighbors` | 由 `vert_faces` + `tri_tiles` 建出的 5/6 邻接 |

邻接构建：

- 对每个贴片 `v`，它的邻接贴片 = 它周围每个角三角的另外两个汇入贴片；
- 每个邻居会从两个共享角三角各出现一次，需要去重；
- 存储为 `N×6`，不足 6 个用 `-1` 填充，另存 `neighbor_count`。

### 4.4 二期：corner graph（本期不实现）

预留给“贴片边界走线”：

- 节点 = `tri_cents`（三角形重心，也就是贴片多边形的角点）；
- 邻接 = 沿每个贴片的多边形环，把相邻角点连边；
- 角点分类：
  - **全陆角**：3 个相邻贴片都是已生成陆地；
  - **海岸角**：至少一个相邻贴片是水/未生成；
  - **全水角**：3 个都是水。
- 角点高程 = 3 个相邻贴片中陆地高程的最小值；
- 水面种子 = 海岸角/全水角，高度记 `SEA_LEVEL`；
- 产流注入：每块陆地贴片把 `R` 注入它最低的**全陆角**；没有全陆角则直接入海；
- 河段 = 贴片边界线段，天然 120° 折线。

代价：节点数约 2× 贴片数、要多一次邻接去重；好处是视觉上更贴参考图。二期再评估。

---

## 5. 产流模型

### 5.1 输入字段

一期直接使用现有字段：

- `humid = _tile_humid`：降雨代理；
- `T = _tile_temp`：温度；
- `elev = _tile_elev`：海拔。

蒸发量目前没有独立字段，用温度推导**潜在蒸散 PET**。

### 5.2 公式

```text
P    = clamp(humid, 0, 1) * (1 + OROGRAPHIC * max(elev - SEA_LEVEL, 0))
warm = clamp((T - T_FREEZE) / (1 - T_FREEZE), 0, 1)
PET  = PET_MIN + (PET_MAX - PET_MIN) * pow(warm, PET_EXP)
snow = 1 - smoothstep(T_FREEZE - SNOW_FADE_LO,
                      T_FREEZE + SNOW_FADE_HI, T)
slope01 = clamp(max_drop / SLOPE_NORM, 0, 1)
R    = max(0, P - PET) * (1 - snow) * lerp(RUNOFF_FLAT, RUNOFF_STEEP, slope01)
R    = clamp(R, 0, 1)
```

其中：

- `max_drop` = 当前陆地贴片与所有陆地邻居的最大正高差（`elev[v] - elev[u]`）；如果所有邻居更高，取 0；
- `snow` 在 `T` 低于冻结温度时趋近 1，表示降水以雪/冰存储，不产流；
- `slope01` 让陡坡产流多、平地入渗多；
- `OROGRAPHIC` 让山地增雨，河更容易从山区起头。

### 5.3 气候响应

| 气候 | 预期表现 |
|---|---|
| 湿暖（温带森林） | `P` 高、`PET` 中高，`R > 0`，河网密 |
| 干热（沙漠） | `P` 低、`PET` 高，`P - PET <= 0`，几乎无河 |
| 寒带/苔原 | `PET` 低，少量融雪型产流，河网稀但存在 |
| 冰盖/海冰 | `snow ≈ 1`，`R = 0`，无河 |
| 山地 | `OROGRAPHIC` + 坡度加成，河头更靠上 |

### 5.4 单位与守恒

- `R` 是无量纲产流，`0..1`；
- 贴片面积近似均匀，所以 `Q` 的单位是“平均贴片产流”；
- `Q` 不做真实 m³/s 换算，一期只用于相对比较和阈值；
- 湖面/海面不计算产流（水面 `injection = 0`）。

---

## 6. 流向与填洼

### 6.1 为什么不用“直接流向最低邻居”

Simplex 噪声生成的海拔有大量局部洼地。直接取最低邻居会：

- 在洼地里形成死循环；
- 或者产生“上坡河”；
- 或者把河网切成很多不连通的短段。

一期采用 **priority-flood（优先漫灌）**：先把洼地“填平”成一条单调下降的路径，再在上面汇流。

### 6.2 算法

1. 建最小堆（key = 填洼后高程，tie-break = 节点索引，保证确定性）。
2. 所有水面节点入堆：
   - `filled = SEA_LEVEL`；
   - `visited = 1`；
   - `parent = -1`。
3. 循环弹出最低节点 `v`，记录到 `order`：
   - 对每个未访问的陆地邻居 `u`：
     - `visited[u] = 1`；
     - `filled[u] = max(elev[u], filled[v] + EPS)`；
     - `parent[u] = v`；
     - `push(filled[u], u)`。
4. 结果：
   - 每个可达陆地节点都有 `parent`；
   - `parent` 链一定最终到水面；
   - 没有环；
   - `filled >= elev`，`filled - elev` 就是洼地深度。

`EPS` 取 `1e-6` 量级，只用于给填平区域制造一个极小的下游坡降。

### 6.3 100% 陆地兜底

如果覆盖率 100% 且整球没有水面：

- 选 `elev` 最低的陆地贴片作为“虚拟出海口”；
- 把它标记为水面种子，`filled = SEA_LEVEL`；
- 日志打印一条警告；
- 河网仍然能生成，只是这个点不是真实海洋。

### 6.4 `filled_elev` 的二期用途

`filled - elev` 表示“为了排水需要填多深”：

- 一期只用于流向，不改变地形；
- 二期可以把深度超过阈值的区域标成湿地/小湖，生成水面，而不是让河穿过干盆地。

---

## 7. 汇流与河道判定

### 7.1 倒序汇流

`priority-flood` 的出堆顺序是“从低到高”，所以倒序遍历就是“从上游到下游”的反向，保证子节点先于父节点：

```text
q = injection.duplicate()
for i from order.size() - 1 down to 0:
    v = order[i]
    p = parent[v]
    if p >= 0:
        q[p] += q[v]
```

- 水面节点的 `q` 可以累加，但后续不参与河段判定；
- 若 `injection` 全为 0，则 `q` 全为 0，不生成河。

### 7.2 阈值与密度

```text
Qc = RIVER_MIN_Q / RIVER_DENSITY
if q[v] >= Qc and parent[v] >= 0:
    edge (v, parent[v]) 是河段
```

- `Qc` 是绝对阈值，不是百分位；
- 湿润区 `R` 大、`Q` 容易超过阈值 → 河多；
- 沙漠 `R = 0` → 没有河；
- 菜单“总体降雨/温度”会直接改变河网密度；
- `RIVER_DENSITY` 是全局旋钮，方便 review 后调。

> **2026-10-23 更新**：实测表明 `Qc=4.0` 高于陆地流量 p90，导致密度只有 7.3%，且单纯降阈值会制造更多海岸小短线。A 方案已改为“`Qc=1.0` 候选 + 整树/枝长两级过滤”，见 §18。上式为**一期基线**，不再是当前实现。

### 7.3 不变量

实现和测试都必须满足：

1. 每个陆地节点最多一个 `parent`；
2. `parent` 链长度有限，最终到水面，无环；
3. `Q` 沿下游单调不减；
4. 河段“下游闭合”：某段是河，则它下游直到水面也都是河；
5. 水面/海冰上没有河段；
6. 同种子、同参数 → 河段集合逐位一致。

### 7.4 统计输出

生成完打印：

```text
河流：河段 N 条，河道贴片 M / 陆地 L（d%），最大 Q = ...，
      入海口 A 个，封闭湖出口 B 个，填洼最大深度 ...
```

初版目标：

- 常态种子（seed 4242，coverage 0.3，normal rainfall/temperature）：
  - 河道贴片占陆地 **10%~20%**；
- 高降雨档明显更密，低降雨档明显更稀；
- 低温档冰盖区河段减少。

具体百分比 review 时可以按视觉再定。

---

## 8. 湖泊、海洋、海冰

### 8.1 水面是终点

- `is_water == 1` 的节点不参与河段判定；
- 河流不画在水面上；
- 水面不向陆地“倒流”。

### 8.2 入海口/入湖口截断

当 `parent[v]` 是水贴片时：

- 河段不画到水贴片中心；
- 画到两贴片共享边的中点：

```text
mouth = normalize(center[v] + center[parent[v]])
```

- 方头停在岸线，不向水面延长半宽；
- 这样河网不会出现伸进海里的“尖刺”。

### 8.3 海冰与冰盖

- 海冰按水面处理：河流止于冰缘；
- 陆地冰盖因为 `snow ≈ 1`、`R = 0`，内部没有河；
- 海冰贴片不参与河段，但可以作为水面种子（如果后续要做冰下流，二期再说）。

### 8.4 封闭湖单出口

一期只做“单级出口”：

1. 复用 `⑤b0` 的水体连通域，记录：
   - `_water_comp_id: PackedInt32Array`；
   - `_water_comp_closed: PackedByteArray`（分量内没有 `BIOME_NONE` = 封闭湖）。
2. 对每个封闭湖，计算入湖流量：

```text
Q_in = Σ q[v]，其中 v 是陆地贴片且 parent[v] 属于该湖分量
```

3. 找垭口：
   - `s` = 与该湖相邻的陆地贴片中 `elev` 最低者；
   - `u` = `s` 的非湖邻居中 `elev` 最低者。
4. 出口路径：
   - 湖岸中点 → `s` → `u`；
   - 从 `u` 开始沿既有 `parent` 链继续。
5. 如果 `u` 的链又回到本湖：
   - 判为内流湖；
   - 不画出口，不改 `Q`。
6. 否则：
   - 把 `Q_in` 加到 `u` 及其所有下游节点；
   - 强制“湖岸 → s → u”以及下游路径为河段；
   - 记录到 `_river_lake_outlets`，供测试/HUD 使用。
7. 处理顺序：
   - 按湖泊**垭口高程**（出口 `s` 的 `elev`）从高到低处理，单级传递；
   - 不使用湖底贴片的 `_tile_elev` 排序（湖面一期统一按 `SEA_LEVEL` 处理）；
   - 不做多级湖链水量平衡（二期）。

### 8.5 内流湖与湖链

- 内流湖（出口路径回到本湖）：只收水，不出水；
- 湖链（出口进入另一个湖）：一期允许视觉出口，但不继续为下游湖计算新的 `Q_in`；
- 完整湖面蓄水/蒸发/水位：二期。

---

## 9. 河流渲染

### 9.1 ribbon 几何

每个河段生成一条贴球面的 ribbon：

- 端点 `A = center[from]`，`B = center[to]`；几何半径 `RIVER_LIFT = 1.0`（贴地）；
- 如果是入海口，`B = normalize(A + B)`（岸线中点）；
- 沿大圆插值 3 个采样点（`t = 0, 0.5, 1`）；**任何合并/平滑后的更长段必须按 §9.7.4 重新细分，不能直接两端连线**；
- 每个采样点生成两个顶点，位置相同；
- `NORMAL` 存该点的侧向单位向量；
- `UV.x = 0 / 1` 表示左右侧；
- `UV.y = t` 表示纵向，方便二期做流动纹理；
- 每两个相邻采样点之间接两个三角形（共 6 个索引）。

由于宽度在 vertex shader 里展开，mesh 在对象空间的三角形面积接近 0，这是**有意为之**；`cull_disabled` 保证不会被背面剔除。

### 9.2 方头与汇流

- 线段两端沿切向延长半个宽度；
- 汇流处多段自然重叠，不出现缺口；
- 入海口不向水面延长；
- 中心保持不透明，避免透明叠加在汇流点发黑；
- 边缘用 fragment 的 `fwidth` 做约 1px 抗锯齿。

### 9.3 屏幕最小宽度 + 视线深度偏移 shader 草案

```glsl
shader_type spatial;
// 移动端 GL Compatibility：保留 depth test，只关 depth write。
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;

uniform vec4 river_color : source_color = vec4(0.29, 0.43, 0.62, 1.0);
uniform float base_half_width = 0.00125;
uniform float min_width_px = 1.2;
uniform float edge_softness_px = 1.0;

// 沿视线向相机推近的世界单位：只改深度，不改屏幕投影。
// 移动端初值 0.004；若设备是 16-bit 深度且远看仍闪，按 §9.7.6 走备选。
uniform float depth_bias = 0.004;
// 调试：0=视线偏移（默认），1=径向抬升（对照），2=不偏移（复现 z-fighting）。
uniform int depth_mode = 0;

// 平台/版本例外时，用这个 uniform 兜底：
// uniform float viewport_height = 720.0;

void vertex() {
    vec3 side = normalize(NORMAL);

    // 宽度展开：仍在模型空间；MODELVIEW_MATRIX 只用来算当前深度下
    // 1 像素对应的世界尺寸。
    vec4 view_pos = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
    float depth = max(-view_pos.z, 1e-4);
    float px_world = 2.0 * depth
            / (PROJECTION_MATRIX[1][1] * VIEWPORT_SIZE.y);
    float half_w = max(base_half_width, 0.5 * min_width_px * px_world);
    VERTEX += side * (UV.x * 2.0 - 1.0) * half_w;

    // 深度避让：沿“相机→顶点”的视线推近。透视下屏幕投影严格不变，
    // 掠射角也不会像径向抬升那样把深度差压到 0。
    // 前提：星球节点在世界原点且无旋转/缩放（当前架构：相机绕星球转）。
    // 若以后给星球加变换，改用 world_vertex_coords，或把相机变换到模型空间。
    if (depth_mode == 0) {
        vec3 to_cam = normalize(CAMERA_POSITION_WORLD - VERTEX);
        VERTEX += to_cam * depth_bias;
    } else if (depth_mode == 1) {
        // 对照方案：径向抬升；limb 会浮空，不推荐作为主方案。
        VERTEX += normalize(VERTEX) * depth_bias;
    }
}

void fragment() {
    float edge = abs(UV.x * 2.0 - 1.0);
    float aa = max(fwidth(UV.x * 2.0), 1e-5) * edge_softness_px;
    ALBEDO = river_color.rgb;
    ALPHA = river_color.a * (1.0 - smoothstep(1.0 - aa, 1.0, edge));
}
```

说明：

- `PROJECTION_MATRIX[1][1] = 1 / tan(fov_y / 2)`，所以 `px_world` 是当前深度下 1 像素对应的世界单位；
- 使用 view-space 深度而不是欧氏距离，画面边缘的宽度更稳定；
- Godot 4.7 文档确认 `VIEWPORT_SIZE` 在 vertex 阶段可用；如果目标平台/版本例外，回退到 uniform `viewport_height`（窗口固定，代价很小）；
- 颜色 `source_color` 会做 sRGB→线性转换，实际颜色以截图为准调；
- 若近看抗锯齿导致边缘太软，可以把 `edge_softness_px` 调到 0.5 或 0；
- 河流几何半径是 **1.0**，不是 `1.0025`；深度避让由 `depth_bias` 完成，原因见 §9.7；
- 移动端 GL Compatibility 的深度格式要先确认：24-bit 下 0.004 足够；16-bit 下远看可能不够，走 §9.7.6 的备选。

### 9.4 材质与渲染顺序（已拍板）

- `render_mode unshaded, cull_disabled, depth_draw_never, blend_mix`；
- **河流几何半径：`1.0`**，与地表共面；不做径向抬升，深度避让全部交给 vertex 的视线偏移；
- 移动端 GL Compatibility 初值：`RIVER_DEPTH_BIAS = 0.004`（可调范围 0.0025–0.005；16-bit 深度见 §9.7.6）；
- 丘陵半径仍为 `1.005`；
- 河流层不写深度，只测深度；
- 由于三角形在对象空间接近零面积，必须给 `MeshInstance3D` 设置覆盖整球的 `custom_aabb`（建议 `AABB(Vector3.ONE * -1.01, Vector3.ONE * 2.02)`），并设 `cast_shadow = OFF`，避免边缘视锥裁剪闪烁。

#### 图层顺序（低 → 高）

| 顺序 | 层 | 半径/深度 | 深度行为 | `render_priority` |
|---:|---|---|---|---:|
| 0 | 地表 | 1.0 | 不透明，写深度 | — |
| 1 | 低丘（SmallHills/LargeHills） | 1.005 | 测深度，不写深度 | 0 |
| 2 | **河流** | 1.0 + 视线偏移 0.004 | 测深度，不写深度 | **1** |
| 3 | **高山（Mountainous/Impassable）** | 1.005 | 测深度，不写深度 | **2** |
| 4 | 选中环 | 1.0 + 视线偏移 0.006 | 测深度，不写深度 | 5（最终；本期暂不调整） |
| 5 | 太阳 | 相机 quad | 按现有 | 10 |
| 6 | 大气光晕 | 1.06 | 按现有 | 20 |

**关键决策：**

- **河流压住低丘**：河流 priority 高于低丘，画在低丘之后；
- **高山压住河流**：高山 priority 高于河流，画在河流之后；
- 这就必须把现有的一整块丘陵 mesh 按 `TerrainLevel` 拆成**低丘**和**高山**两组（两个 surface 或两个 `MeshInstance3D`），分别用两个材质实例设置 priority。只在 shader 里改颜色/透明度做不到“部分压住、部分被压”；
- 选中环最终需要在河流之上（priority 5），但**本期先不改选中环**；如果河流暂时盖住选中环，先接受，后面再处理；
- 河流和低丘/高山的 AABB 都覆盖整球，透明排序距离几乎一样，**不要依赖隐式距离排序**，必须显式 priority。

### 9.5 颜色与抗锯齿

- 初版颜色：灰蓝 `RGB(0.29, 0.43, 0.62)`；
- 参考图有轻微暗边，但一期先不做；
- 若透明边缘在汇流点出现暗缝，优先把中心 alpha 提到 1，边缘只留 1px 过渡；
- 完全不要圆头/圆角，保持方头。

### 9.6 性能

- 河段数估计：数千到一万级；
- 每段 3 个采样点 × 2 顶点 = 6 顶点，总顶点数约 6 万，单 draw call；
- mesh 构建在生成结束后同步完成，预计几毫秒；
- 真正需要关注的是水文阶段的堆操作，见 §12.3。

### 9.7 与地表穿插/破面的成因与规避（实现重点）

#### 9.7.1 先分清四类现象

| 现象 | 典型表现 | 根因 | 优先排查 |
|---|---|---|---|
| **z-fighting** | 河线随视角闪烁、成段消失/出现，limb 最明显 | 河面与地表深度差太小；深度精度不够；掠射角下深度差被压缩 | 深度偏移量、深度缓冲位数 |
| **几何穿插** | 河线中段被地表“咬掉”，像被裁断；断点随几何走 | 长线段弦切下沉超过偏移量 | 是否有未细分的长段 |
| **层序错误** | 河盖住高山、低丘盖住河、选中环被河盖住 | 透明队列按距离排序，顺序翻转 | `render_priority` / 丘陵拆分 |
| **视锥/退化** | 整层河或某几段突然消失，和深度无关 | 对象空间三角形接近零面积，自动 AABB 被裁掉；或两侧顶点符号写反导致零宽 | `custom_aabb`、`cull_disabled`、`NORMAL/UV.x` 约定 |

#### 9.7.2 本项目的高风险根因

**① 长线段弦切下沉（最像“破面”的主因）**

单位球上，两个采样点用直线连成的 ribbon，三角形内部会落到球面以内：

```text
sag = R · (1 − cos(θ/2)) ≈ R · θ² / 8
```

| 段长 | 圆心角 | 弦切 sag | 相对 0.004 偏移 |
|---:|---:|---:|---:|
| 1 个贴片边（约 1°–1.1°） | 0.017–0.019 rad | 约 4e-5–5e-5 | 可忽略 |
| 5 个贴片边合并（约 5°） | 0.087 rad | 约 9.5e-4 | 仍安全 |
| 10° 单段 | 0.1745 rad | 约 **3.8e-3** | 接近偏移，limb 会危险 |
| 20° 单段 | 0.349 rad | 约 **1.5e-2** | 大面积穿模 |

如果以前把多个贴片中心用一条长直线连起来、只在两端采样，中段被地表吃掉是几何必然。**任何合并/平滑后的段都必须重新按圆心角细分，不能直接两端连线。**

**② 径向抬升在 limb 的深度差衰减**

径向抬升的深度领先量 ≈ `lift · cos(法线, 视线)`；limb 处夹角接近 90°，深度差趋近 0，远看仍会 z-fighting。抬升越大，limb 浮空越明显——`HILLS_OFFSET = 0.005` 的注释已经写明“过大 limb 会浮空”。所以河流**不用径向抬升作为主方案**。

**③ 共面深度冲突**

24-bit 深度、默认 `near=0.05` 时，深度精度约 `z² / (near · 2^24)`：

- z=2.05 → 约 `5.0e-6`；
- z=10.0 → 约 `1.2e-4`。

`0.004` 的视线偏移在 z=10 时约是精度的 33 倍，z=2 时约 800 倍，中心区域足够。**移动端要确认实际深度格式**：24-bit 下 0.004 足够；16-bit 下 z=10 的精度约 `0.03`，0.004 不够，必须走 §9.7.6 的备选。

**④ 网格划分不一致**

河带是细长三角形，地表是 Goldberg 扇形三角形；两者三角化不同，在贴片顶点/边附近深度顺序可能翻转。解决办法不是继续加抬升，而是用视线偏移给河带一个稳定的深度领先，并让河带自身细分到 sag 远小于偏移。

**⑤ 透明层排序**

河流、低丘、高山、选中环、大气都是透明层。河流和丘陵的 AABB 都覆盖整球，按距离排序几乎分不出先后；**必须显式 `render_priority`**，否则会出现“有时河盖山、有时山切河”。

**⑥ 零面积对象空间三角形**

河带宽度在 vertex shader 里展开，mesh 在对象空间的三角形面积接近 0，自动 AABB 可能是一条线/一个点，导致整层或局部被视锥裁掉。必须设置覆盖整球的 `custom_aabb`，并保留 `cull_disabled`。

**⑦ 两侧顶点符号写反**

同一个采样点的两个顶点：**位置相同、`NORMAL` 相同（都是侧向单位向量）、`UV.x = 0/1`**；shader 只用 `UV.x` 决定左右。不要既让 `NORMAL` 相反、又乘一次 `UV.x` 符号，否则会零宽/双倍宽。

#### 9.7.3 推荐方案：视线深度偏移（decal 模式）

`selection_ring.gdshader` 已经验证过同一套手法：几何与地表共面、零视差，vertex 沿 `CAMERA_POSITION_WORLD - VERTEX` 推近，z-fighting 由深度偏移解决。

河流采用同样的做法：

1. 河流几何放在**半径 1.0**，与地表共面，不做径向抬升；
2. 在宽度展开之后，沿视线推近 `RIVER_DEPTH_BIAS`；
3. **保留 depth test**，只开 `depth_draw_never`；
4. 长段按 §9.7.4 自适应细分；
5. 图层按 §9.4 的优先级表：河流高于低丘、低于高山。

性质：

- 沿“相机→顶点”的视线移动，透视投影的屏幕位置严格不变，不会像径向抬升那样在 limb 浮空/错位；
- 深度领先量基本恒定（只随视线与相机 forward 的夹角余弦轻微缩小），不会在掠射角被压到 0；
- 深度测试仍然保留，星球背面的河、未来前景物体仍能正确遮挡它；
- 河流看起来是“画在球面上”，不是“浮在球面上”。

移动端初值 `RIVER_DEPTH_BIAS = 0.004`；若 24-bit 深度下仍闪，可加到 0.005；若确认是 16-bit，见 §9.7.6。

#### 9.7.4 自适应细分

1. 每个贴片中心线边：至少 **3 个采样点**（`t=0, 0.5, 1`）；
2. 任何合并/平滑后的段：
   ```text
   n = max(2, ceil(θ / RIVER_MAX_ARC_DEG))
   RIVER_MAX_ARC_DEG = 2.5°
   ```
   每个子段不超过 2.5°；
3. 不要在合并后直接用两端点连一条长三角形；
4. 宽度方向不需要细分：半宽 0.00125，横向 sag 约 `7.8e-7`，可忽略；
5. 二期做 Chaikin/样条平滑后，同样按 2.5° 重新采样。

数量级：2.5° 子段 sag ≈ `2.4e-4`，约为 0.004 偏移的 1/16，安全；10° 单段 sag ≈ `3.8e-3`，接近偏移，limb 危险。

#### 9.7.5 丘陵拆分：河压低丘、高山压河

“河流压住低丘、但被高山压住”不能只靠一个丘陵材质完成，必须按 `TerrainLevel` 拆成两组：

- **低丘**：`SMALL_HILLS`、`LARGE_HILLS` → `render_priority = 0`；
- **高山**：`MOUNTAINOUS`、`IMPASSABLE` → `render_priority = 2`；
- 河流：`render_priority = 1`。

实现建议（保持一次 RNG 遍历、同种子逐位一致）：

- 修改 `_build_hills_meshes(world_seed)`：仍然只遍历一次 `_terrain`，但把 quad 分别追加到 `low` / `high` 两组数组；
- 返回两组 `ArrayMesh`（或一个带两个 surface 的 mesh）；
- 低丘/高山各用一个 `ShaderMaterial`（同 shader、同 atlas，只差 `render_priority`）；
- 如果用一个 `MeshInstance3D` + 两个 surface，必须用 `set_surface_override_material()`，不要用 `material_override`（它会覆盖所有 surface）；
- 如果拆成两个 `MeshInstance3D`，清理旧层时要两个都 `queue_free()`；
- 现有 `tools/test_planet_hills.gd` 假定“一个 surface 装所有丘陵”，拆分后要同步改成汇总两个 surface/两个实例再断言。

选中环：最终应在河流之上（priority 5），但**本期先不改**；河流暂时盖住选中环可以接受，后面再处理。

#### 9.7.6 移动端 GL Compatibility 注意

- 目标平台是移动端 GL Compatibility；桌面 D3D12 只用于开发预览；
- 先确认实际深度缓冲位数（24/32-bit 还是 16-bit）：
  - 24-bit：`depth_bias=0.004` 在 z=10 约有 33 倍精度余量；
  - 16-bit：z=10 精度约 0.03，0.004 不够。备选顺序：
    1. 加大 `depth_bias` 到 0.01–0.02（可能和丘陵深度关系冲突，需要重新调图层/深度）；
    2. 用 `depth_test_disabled` + 前半球 discard（§9.7.7）；
    3. 把河流烘进地表 shader / mask（无几何，无 z-fighting，但近看线宽/接缝难保证）。
- 移动端 GPU 对 `VIEWPORT_SIZE` 在 vertex 阶段的支持要先在目标机验证；若不可用，回退 uniform `viewport_height`；
- 透明层顺序在移动端同样依赖显式 `render_priority`，不要依赖距离排序；
- 如果移动端帧率吃紧，河流仍是一个 draw call；丘陵拆成两个 draw call，但总量很小（原来 1 个，现在 2 个）。

#### 9.7.7 调试与验收

shader 保留 `depth_mode`：

- `0`：视线偏移（默认）；
- `1`：径向抬升（对照，看 limb 浮空）；
- `2`：不偏移（复现 z-fighting，确认问题类别）。

截图矩阵：

| 条件 | 检查 |
|---|---|
| dist=1.15，对准河段中心 | 线宽、方头、汇流无缺口、无闪烁 |
| dist=2.05，默认视角 | 细线可见、分支形态自然 |
| dist=10.0，默认视角 | 屏幕最小宽度生效、没有整段消失 |
| dist=10.0，压到 limb（pitch 接近 ±77°） | 河不浮空、不被地表咬断、不闪 |
| 缓慢旋转 360° | 河线连续，不出现随视角翻转的断点 |
| 缩放 1.15 ↔ 10.0 | 不出现某一档突然大面积消失 |
| 有低丘/高山的区域 | 河盖住低丘，高山盖住河 |

像素级检查（可选）：选一条已知河段，读回帧缓冲，统计河流颜色像素数/连续性；旋转几度重复，若像素数骤降 >20%，说明有遮挡或裁剪问题。

已知限制：`min_width_px` 是在球面切向展开的，limb 处如果河流正好沿边缘走，切向宽度会被透视压缩，可能不足 1px。这不是 z-fighting，本期接受，二期可改屏幕空间侧向扩展。

实现自检：

- [ ] 河带顶点半径是 1.0（不是 1.0025）；
- [ ] mesh 数组显式写 `ARRAY_NORMAL`（侧向单位向量）和 `ARRAY_TEX_UV`，不依赖零面积三角形的自动法线；
- [ ] 每个贴片边至少 3 采样；合并段按 2.5° 重新细分；
- [ ] 同一采样点两侧顶点 `NORMAL` 相同，`UV.x=0/1`；
- [ ] `custom_aabb` 覆盖整球，`cull_disabled`，`cast_shadow=OFF`；
- [ ] 低丘 priority 0、河流 1、高山 2（选中环最终 5）；
- [ ] 保留 depth test，只开 `depth_draw_never`；
- [ ] `VIEWPORT_SIZE` 在 vertex 阶段非 0；
- [ ] 确认移动端深度缓冲位数；16-bit 走 §9.7.6 备选；
- [ ] 星球节点仍在原点、无旋转/缩放（否则视线偏移的模型空间假设失效）。

#### 9.7.8 备选方案

1. **加大视线偏移**：0.005（仍和丘陵同量级，先试）；
2. **径向抬升 + 视线偏移组合**：`RIVER_LIFT=1.001~1.0025` + `depth_bias=0.004`；多一层保险，但 limb 会有一点浮空；
3. **`depth_test_disabled` + 前半球 discard**：
   ```glsl
   vec3 n = normalize(VERTEX);
   vec3 v = normalize(CAMERA_POSITION_WORLD - VERTEX);
   if (dot(n, v) <= 0.0) discard;
   ```
   彻底消除 z-fighting，但河会盖住丘陵/前景；必须严格排在低丘之后、高山之前，作为应急/调试；
4. **烘进地表 shader / 高分辨率 cubemap mask**：无几何、无 z-fighting，但线宽/接缝近看难保证，二期/三期评估；
5. **depth prepass / stencil**：最稳但最复杂，一期不做。

#### 9.7.9 一句话

**河带贴地（半径 1.0），沿视线推近 0.004 做零视差 decal；长段按 2.5° 细分；低丘 priority 0 → 河流 1 → 高山 2，做到“河压低丘、高山压河”。**

---

## 10. 数据与接入

### 10.1 新增成员（`planet.gd`）

```gdscript
# 图
var _tile_neighbors := PackedInt32Array()     # N×6，-1 填充
var _tile_neighbor_count := PackedByteArray()

# 水文
var _tile_runoff := PackedFloat32Array()      # R
var _tile_flow := PackedInt32Array()          # parent
var _tile_filled_elev := PackedFloat32Array() # 填洼后高程
var _tile_discharge := PackedFloat32Array()   # Q
var _tile_is_river := PackedByteArray()       # 1 = 该节点的下游边是河

# 河段（给渲染和测试）
# 每 3 个一组：from, to, kind
# kind: 0 = 内陆段, 1 = 入海口, 2 = 湖泊出口
var _river_edges := PackedInt32Array()
var _river_edge_q := PackedFloat32Array()

# 湖泊
var _water_comp_id := PackedInt32Array()
var _water_comp_closed := PackedByteArray()
var _river_lake_outlets := PackedInt32Array()

# 统计
var _river_stats := {}
```

### 10.2 生成阶段

在 `_build_goldberg_mesh_async()` 中新增 **⑤d 水文**：

- 位置：`⑤b0 小水域剔除` 之后、`⑤c 网格写入` 之前；
- 进度区间：约 `93.0% ~ 94.5%`；
- 顺序：
  1. 建贴片邻接；
  2. 计算产流 `R`；
  3. priority-flood；
  4. 倒序汇流；
  5. 封闭湖单出口；
  6. 最终河段判定 + 统计。
- 每个重循环使用 `_slice_yield`，批大小参考现有 `SLICE_CHECK_STRIDE`。

### 10.3 生命周期

- 每次生成开始时清空上述数组；
- `_on_generate_requested()` 在 `_build_goldberg_mesh_async()` 返回后调用 `_build_river_mesh()`；
- 二次生成时先 `queue_free()` 旧的 `_river_instance`，再建新的；
- 河流层与丘陵层并列加入场景；但渲染优先级有依赖：低丘 0 → 河流 1 → 高山 2。丘陵必须先按 TerrainLevel 拆成低丘/高山两组，再把河流插在中间。

### 10.4 HUD / 日志

一期建议：

- 生成日志：河段数、河道贴片占比、最大 Q、入海口数、湖泊出口数、填洼最大深度；
- 可选 HUD：选中贴片时多一行“水系：Q=... / 河段”，方便 review；
- 不做独立的河流调试面板。

### 10.5 函数拆分

建议在 `planet.gd` 内拆成小函数，避免继续把主协程撑大：

```text
_build_tile_neighbors()
_compute_runoff()
_priority_flood()
_accumulate_discharge()
_resolve_lake_outlets()
_select_river_edges()
_build_river_mesh()
```

一期先不新建独立脚本；如果 `planet.gd` 继续膨胀，二期再把水文内核抽成 `river_network.gd`。

---

## 11. 参数初值

| 参数 | 初值 | 作用 |
|---|---:|---|
| `PET_MIN` | 0.08 | 蒸散下限 |
| `PET_MAX` | 0.72 | 蒸散上限 |
| `PET_EXP` | 1.3 | 高温区蒸发曲线 |
| `OROGRAPHIC` | 0.5 | 山地增雨 |
| `SNOW_FADE_LO` | 0.08 | 冻结温度以下多少开始积雪 |
| `SNOW_FADE_HI` | 0.04 | 冻结温度以上多少完全无雪 |
| `SLOPE_NORM` | 0.08 | 坡度归一化 |
| `RUNOFF_FLAT` | 0.7 | 平地产流系数 |
| `RUNOFF_STEEP` | 1.15 | 陡坡产流系数 |
| `RIVER_MIN_Q` | 6.0 | 河道起始流量，先试 4~10 |
| `RIVER_DENSITY` | 1.0 | 全局密度旋钮 |
| `RIVER_WIDTH` | 0.0025 | 固定世界宽度 |
| `RIVER_HALF_WIDTH` | 0.00125 | shader 用 |
| `RIVER_MIN_WIDTH_PX` | 1.2 | 屏幕最小宽度 |
| `RIVER_LIFT` | 1.0 | 几何半径（主方案贴地；备选 1.001–1.0025） |
| `RIVER_DEPTH_BIAS` | 0.004 | 沿视线向相机推近的世界单位（移动端初值） |
| `RIVER_MAX_ARC_DEG` | 2.5 | 每个子段的最大圆心角（自适应细分） |
| `RIVER_COLOR` | `#4A6E9E` | 一期蓝色 |

说明：

- 这些值都是“首版可运行”的起点，不是最终美术定稿；
- `RIVER_MIN_Q` 和 `RIVER_DENSITY` 是 review 后最可能调的两个；
- 颜色在 GL Compatibility + `source_color` 下需要按截图校准；
- `RIVER_DEPTH_BIAS` 先按移动端 24-bit 深度取 0.004；若目标机是 16-bit，按 §9.7.6 走备选；
- `RIVER_LIFT` 主方案恒为 1.0，仅作为 shader `depth_mode=1` 的对照/备选参数。

### 11.1 实施回填（2026-10-23，GL Compatibility 实测）

> **说明**：本节保留一期基线（`Qc=4.0`、密度 7.3%）的实测记录；A 方案已替换阈值与选边逻辑，当前参数与实测见 §18。

一期已落地。实际常量与上表“首版起点”有几处按截图/日志校准：

| 常量 | 实际值 | 说明 |
|---|---:|---|
| `RIVER_BASE_HALF_WIDTH` | 0.0018 | 世界半宽；近看固定宽度 |
| `RIVER_MIN_WIDTH_PX` | 2.2 | 屏幕下限；默认视角稳定可见 |
| `RIVER_COLOR` | `RGB(0.20, 0.48, 0.78)` | 比初版更饱和的蓝 |
| `RIVER_MIN_Q` | 0.6 | 产流阈值 |
| `RIVER_DENSITY` | 0.15 | 目标密度；`Qc = 0.6 / 0.15 = 4.0` |
| `OROGRAPHIC` | 0.8 | 山地增雨 |
| `PET_MIN` / `PET_MAX` / `PET_EXP` | 0.05 / 0.65 / 1.4 | 潜在蒸散 |
| `SNOW_FADE_LO` / `SNOW_FADE_HI` | 0.05 / 0.05 | 积雪过渡 |
| `SLOPE_NORM` | 0.25 | 坡度归一化 |
| `RUNOFF_FLAT` / `RUNOFF_STEEP` | 0.25 / 0.85 | 产流系数 |
| `RIVER_FILL_EPS` | `1e-6` | priority-flood 严格下降 |
| `RIVER_DEPTH_BIAS` | 0.004 | 视线偏移（未变） |
| `RIVER_MAX_ARC_DEG` | 2.5 | 子段最大圆心角（未变） |

**宽度/颜色为什么改**：初版 `1.2px + RGB(0.29,0.43,0.62)` 在 2000×1125 截图中基本看不见；临时把颜色改成洋红、宽度 4px 后，几何/shader/图层全部正常（洋红河段清楚可见）。最终取 2.2px + 更饱和的蓝，默认 `dist=2.33` 和近景都清楚；宽度仍是“世界固定宽度 + 屏幕下限”的组合，不是按流量变化。

**实测数据**（headless，`LEVEL=6`，`coverage=0.3`）：

| 种子/气候 | 河段 | 陆地密度 | 入海口 | 最大 Q | 填洼最大深度 | mesh |
|---|---:|---:|---:|---:|---:|---|
| 4242 / rain 1 / temp 1 | 531 | 7.3% | 32 | 79.27 | 0.1443 | 1593 采样点 / 2124 三角形 |
| 20261021 / rain 0 / temp 0 | 118 | 1.8% | 11 | 28.42 | 0.1219 | 354 采样点 / 472 三角形 |

30% 完整生成在开发机（AMD 780M / GL Compatibility）约 740–780 ms，河流层约 50 ms；移动端需要单独 profile 堆操作与 mesh 构建。

**图层验证**：低丘 0 → 河流 1 → 高山 2 的 priority 回归已通过；近景截图中河流连续压在低丘/平原上。湿润种子 4242 的 531 条河段里 **跨高山 0 条**——高山是分水岭，河网自然绕开，所以这组种子没有“高山压河”的视觉样本；该行为由 priority 回归保证，若后续种子出现跨山河段，priority 2 会让高山后画并盖住河流。

**测试**：

- `tools/test_planet_rivers.gd`：邻接 N×6（5/6 邻居、恰 12 个五边形、严格对称）、河段端点/邻接、parent 链全部入水且无环、阈值一致、ribbon 采样数/半径/单位法线/UV、图层 priority 0/1/2、shader 参数、`custom_aabb`、水文重算确定性。
- `tools/test_planet_hills.gd`：已按低丘/高山拆分更新（数量、半径、UV 落格、确定性）。
- 暂缓：气候响应对比（rainfall ±1 的河段数）、封闭湖单出口、GUT 集成；这些在二期/后续 review 补。

---

## 12. 验证计划

### 12.1 GUT 单元/管线测试

新增 `tools/test_planet_rivers.gd`（一期已落地；GUT 集成后续再补），沿用 `tools/test_planet_hills.gd` 的方式：在场景树里跑完整生成管线，然后检查数组。

建议用例：

1. **网络非空**
   - 常态种子（seed 4242，coverage 0.3，rainfall 0，temperature 0）；
   - `_river_edges.size() > 0`；
   - 河道贴片占陆地比例在 `8%~25%`（先宽区间，review 后收紧）。

2. **流向不变量**
   - 每个陆地贴片最多一个 `parent`；
   - 跟随 `parent` 链，最多 `N` 步必到水面；
   - 无环；
   - `Q` 沿链单调不减。

3. **河段只出现在陆地**
   - `from` 一定是陆地；
   - `to` 可以是陆地（内陆段）或水（入海口）；
   - 水面节点自身不作为 `from`。

4. **河口在岸线**
   - 入海段的 `to` 是水；
   - 渲染端点 `normalize(A+B)` 到岸线的距离在容差内。

5. **气候响应**
   - 同种子下，`rainfall = +1` 的河段数 > `rainfall = -1`；
   - 同种子下，`temperature = -1` 的冰盖区河段数减少。

6. **确定性**
   - 同种子、同参数生成两次；
   - `_river_edges` 逐位一致。

7. **湖泊出口**
   - 每个封闭湖 0 或 1 个出口；
   - 出口不指回本湖；
   - 出口段与下游河段连续。

8. **mesh 几何**
   - 顶点无 NaN；
   - 顶点半径在 `[0.999, 1.001]`（主方案贴地 1.0；若用备选抬升，按 `RIVER_LIFT` 参数化）；
   - 索引数 = 河段数 × 每段三角形数；
   - `UV.x` 只有 0/1 两种侧向值；
   - 每个子段圆心角 ≤ `RIVER_MAX_ARC_DEG`（2.5°）。

### 12.2 视觉验收

用 `tools/capture_final.gd` 的方式截图，至少三档：

| dist | 检查点 |
|---:|---|
| 1.15 | 近看宽度统一、方头、汇流无缺口、无 z-fighting |
| 2.05 | 默认视角能看到细线、分支形态像树根/血管 |
| 10.0 | 屏幕最小宽度生效、没有完全消失、没有明显闪烁 |
| 10.0 + limb（pitch≈±77°） | 河不浮空、不被地表咬断、不闪 |

另外检查：

- 河流不穿过海面/湖面；
- 河口贴岸，不伸进水里；
- **河流盖住低丘（SmallHills/LargeHills）**；
- **高山（Mountainous/Impassable）盖住河流**；
- 选中环本期允许被河流盖住，后面再处理；
- 缓慢旋转 360°，河线连续，不出现随视角翻转的断点；
- 没有明显的透明叠加暗缝；
- 河网密度与参考图同量级，不出现“每格都有河”或“整片大陆没有河”。

### 12.3 性能

记录 `[gen] ⑤d水文` 的耗时和帧数：

- 目标：单帧切片内不超预算；
- 总墙钟尽量 < 150ms（40962 贴片，常态覆盖率）；
- 如果堆操作过慢：
  - 先把邻接/产流/汇流分片；
  - 再考虑 bucket queue 或把堆换成 `PackedFloat64Array` 编码 key+index；
  - 最后才考虑抽独立脚本/多线程。

### 12.4 回归

跑现有全套：

- `test_coverage`
- `test_planet_texture`
- `test_planet_hills`
- `test_tile_hud`
- `test_selection_smoke`
- `test_selection_chain`
- `test_starfield`
- `test_region_cap`

要求全绿，且既有截图行为不变。

---

## 13. 风险与缓解

| 风险 | 影响 | 缓解 |
|---|---|---|
| GDScript 最小堆慢 | 生成卡顿 | 分帧；typed array；必要时 bucket queue |
| 远看细线消失/闪烁 | 默认视角看不到河 | 屏幕最小宽度 + 1px AA |
| 汇流点透明叠加发黑 | 视觉脏 | 中心不透明；边缘只留 1px 过渡 |
| z-fighting | 河线闪烁、成段消失，limb 最明显 | 河带贴地 1.0 + 视线偏移 `RIVER_DEPTH_BIAS=0.004`；保留 depth test；移动端确认深度位数 |
| 长段弦切下沉 | 河线中段被地表咬断 | 每贴片边至少 3 采样；合并段按 2.5° 重新细分 |
| 径向抬升 limb 浮空 | 河线离开地表 | 主方案不做径向抬升；`RIVER_LIFT=1.0` |
| 层序错误 | 河盖高山、低丘盖河、选中环被河盖 | 丘陵按 TerrainLevel 拆低丘/高山；低丘 0 → 河流 1 → 高山 2；选中环最终 5 |
| 零面积三角形被裁剪 | 整层/局部河突然消失 | `custom_aabb` 覆盖 1.01 半径 + `cull_disabled` |
| 16-bit 深度不够 | 远看 limb 仍闪 | 确认深度格式；加大 bias 或走 `depth_test_disabled` + 前半球 discard |
| priority-flood 填平干洼地 | 河穿过没有湖的平地 | 一期接受；记录 `fill_depth`，二期生成湿地/湖 |
| 湖泊出口路径回到本湖 | 出口成环 | 检测链是否回到本湖，回到则判内流湖、不画 |
| 100% 陆地无水面种子 | 河网为空 | 最低点虚拟出海口 + 警告 |
| 中心线穿过贴片内部 | 不如参考图贴格边 | 二期切 corner graph，水文内核不动 |
| `VIEWPORT_SIZE` 在 vertex 不可用 | shader 编译失败 | 回退 uniform `viewport_height` |
| `source_color` 颜色空间偏差 | 蓝色偏亮/偏暗 | 以截图为准确认，必要时改用 raw vec3 |
| 零面积三角形被裁剪 | 河流消失 | `cull_disabled` + `custom_aabb` 覆盖整球 |

---

## 14. 实施顺序

0. **小段渲染验证（先做）**
   - 丘陵按 `TerrainLevel` 拆低丘/高山，设 priority 0 / 2；
   - 用一小段河（少量真实贴片中心）建 ribbon，河流 priority 1；
   - 验证“河压低丘、高山压河”、贴地+视线偏移、移动端 GL Compatibility 的 shader 编译；
   - 三档距离 + limb 截图，确认没有 z-fighting/穿模后再铺全量。

1. **只算数据，不渲染**
   - 建贴片邻接；
   - 产流；
   - priority-flood；
   - 汇流；
   - 河段判定；
   - 打印统计。

2. **先写不变量测试**
   - 无渲染也能验证拓扑；
   - 先把“无环、必到水面、Q 单调、同种子一致”锁死。

3. **加湖泊单出口**
   - 记录水体连通域；
   - 封闭湖单出口；
   - 补出口测试。

4. **河流 mesh + shader**
   - ribbon 几何；
   - 屏幕最小宽度；
   - 材质/层序；
   - 三档截图。

5. **调参**
   - `RIVER_SOURCE_QC` / `RIVER_TREE_MIN_EDGES` / `RIVER_BRANCH_MIN_EDGES`（A 方案，见 §18）；
   - 宽度、颜色、AA；
   - 对照 `temp/river.png`。

6. **收尾**
   - 全套回归；
   - 更新本文档的“实现记录”；
   - 再评估二期 corner graph / 河宽/流动。

---

## 15. 二期及以后

按优先级从高到低：

1. **贴片边界走线**：corner graph，参考图那种 120° 折线。
2. **河宽随流量变化**：`width ∝ sqrt(Q)` 或 Strahler 分级。
3. **湖泊完整水量平衡**：湖面蓄水、蒸发、水位、湖链级联。
4. **河道蜿蜒/平滑**：垂直噪声偏移、Chaikin 平滑、避免每格折线。
5. **三角洲/分叉**：入海口分流，允许非树结构。
6. **水面渲染**：流动方向、泡沫、反光、深浅色。
7. **玩法接入**：淡水、贸易、移动、建城、渡口。
8. **性能 LOD**：远看合并河段/切贴图，近看保留几何。

---

## 16. Review 时重点确认（已拍板项 + 剩余问题）

已拍板：

1. **河流压住低丘（SmallHills/LargeHills），但被高山（Mountainous/Impassable）压住**；丘陵层必须拆成低丘/高山两组。
2. **目标平台是移动端 GL Compatibility**；桌面 D3D12 只用于开发预览。
3. 选中环最终应在河流之上，但**本期先不改**；河流暂时盖住选中环可以接受。
4. 河流渲染采用“贴地 1.0 + 视线深度偏移 0.004”的 decal 方案；不把径向抬升作为主方案。
5. 长段必须按 2.5° 自适应细分。

剩余问题：

1. 常态密度目标是否就是 **10%~20% 陆地贴片带河**？还是希望更密/更疏？
2. 河流颜色/宽度初值是否按参考图的灰蓝、约 0.13 贴片间距？
3. 一期是否需要把“水系 Q/河段”加进选中贴片 HUD，还是只打日志？
4. 100% 覆盖率且整球陆地时，是否接受“最低点虚拟出海口”？
5. 湖泊单出口只做单级是否可接受？还是希望一期就做湖链级联？
6. 移动端目标机的深度缓冲实际是 24-bit 还是 16-bit？需要实测确认，16-bit 走 §9.7.6 备选。

---

## 17. 一句话总结

**一期不追求画得像，先把“降雨 − 蒸发 → 产流 → priority-flood → 汇流 → 阈值 → 河段”这条数据链跑通，用独立 mesh 画固定宽度方头蓝线；河带贴地 1.0，沿视线推近 0.004 做零视差 decal，长段按 2.5° 细分；低丘 priority 0 → 河流 1 → 高山 2，做到“河压低丘、高山压河”；水面只做终点，封闭湖给一个单出口；二期再换贴片边界走线、河宽和流动效果。**

---

## 18. 河网密度与小短线优化（A 方案，2026-10-23）

### 18.1 问题与基线

用户反馈两件事：

1. 特别短的河流不少，需要过滤阈值；
2. 即使降雨拉到最高一档，河网仍不够密，且大多数河很短，没有“水网密布 + 绵延不绝”的感觉。

诊断口径：种子 `4242`、`coverage=0.3`、`LEVEL=6`、40,962 贴片、7,291 个陆地贴片。只读诊断脚本不改产品代码。

一期基线（`Qc=4.0`）：

| 场景 | 河段 | 密度 | 入海口 | 叶枝 p50 | 干流 p50 | ≤2 段叶枝 | 最短叶枝 |
|---|---:|---:|---:|---:|---:|---:|---:|
| rain 1 / temp 1 | 531 | 7.3% | 32 | 4 | 8 | 33.3% | 1 |
| rain 1 / temp 0 | 611 | 8.4% | 36 | 4 | 8 | 33.3% | 1 |
| rain 0 / temp 0 | 342 | 4.7% | 18 | 6 | 16 | — | 1 |

流量分布（rain 1 / temp 1）：`p50=0.28`、`p90=2.27`、`max=79.27`；`Qc=4.0` 高于 p90，只保留流量最大的约 7% 陆地贴片。`RIVER_MIN_Q / RIVER_DENSITY = 0.6 / 0.15 = 4.0` 中的 `0.15` **不是目标密度**，只是除数。

### 18.2 根因

1. **阈值过高，密度被卡死**：`Qc=4` 位于流量分布尾部；`Qc=6/4/2/1` 对应密度约 `5.5% / 7.3% / 10.8% / 18.2%`。密度不足的第一原因是阈值，不是降雨。
2. **单一阈值把密度和长度绑死**：`Qc=1` 密度可达 18.2%，但入海口从 32 增至 97、叶枝 p50 降到 2、≤2 段叶枝占 56.6%。新增水量主要来自“离海近、汇水面积小”的海岸盆地，所以单纯降阈值只会制造更多小短线。
3. **海岸线碎、盆地小，是“短”的地理根源**：当前 7,291 个陆地贴片对应 32 个入海口，树大小/干流 p50 都只有 8 段。覆盖率不是解：`coverage=0.3` 与 `1.0` 的密度都约 8%，但 `1.0` 的入海口增至 172 个；更多面积只是成倍放大盆地数量，不改变长度分布。
4. **短枝有两个来源，必须两级过滤**：`Qc=4` 的 60 条叶枝中，树大小 1–4 段的小树有 9 条、其中 8 条 ≤2 段；树大小 20+ 段的大树有 37 条、其中 11 条 ≤2 段。只删小树会留下大树的短支流，只剪短枝会留下大量小树。
5. **降雨/温度是次要放大因素**：湿/热产流均值 `0.112`，湿/温 `0.152`，干/温 `0.058`；最高雨 + 最高温是最不利组合（PET 高）。最高雨确实把密度从 4.7% 拉到 8.4%，但 `Qc=4` 仍是瓶颈；继续加雨不能替代阈值与过滤。
6. **priority-flood 父指针树偏“灌木”**：最大树 65 段、最长干流 36 段；中位数树 8 段、干流 8 段。填洼生成树在平地/噪声处容易分叉，这是“树很大但不绵延”的深层原因；D8/D-infinity 留到二期。
7. **渲染放大短感**：每段独立 ribbon + 方头 + 固定 2.2px，默认视距下一个贴片只有几个像素；1–2 段叶枝就是 5–10px 的小 dash。数据过滤优先，连续 polyline / 宽度分级留到后续。
8. **湖泊不是当前主因**：`coverage=0.3` 只有 2 个水域分量（大洋 + 一个湖），所以封闭湖单出口不是 7.3% 的主因；`coverage=1.0` 水域分量增多后才更重要。

### 18.3 A 方案：低阈值候选 + 两级过滤

```text
1) 候选：Qc = RIVER_SOURCE_QC = 1.0
2) 整树过滤：以入海口为根统计树边数，删除 < Tmin 的整棵树
   Tmin = RIVER_TREE_MIN_EDGES = 8
3) 叶枝过滤：从每个叶子沿下游走到第一个汇流点/入海口，
   删除长度 < Lmin 的整条叶枝
   Lmin = RIVER_BRANCH_MIN_EDGES = 4
4) 交替执行 2/3 直到稳定：
   剪枝后缩到 < Tmin 的树在下一轮删除；
   最终保证保留树 >= Tmin、保留叶枝 >= Lmin。
```

为什么整树过滤便宜：`Qc=1` 候选 1,330 段 / 97 棵树；只保留 ≥8 段的树后为 34 棵 / 1,153 段。删掉 63 棵小树只损失 13.3% 河段——长尾分布让小树“数量多、总长度占比小”。

只影响最终渲染边集，不改 `_river_parent`、`_river_flow`、产流/汇流主流程，也不改 shader/mesh 格式。过滤后可继续用 `_collect_river_edges` 的父指针校验：每条保留边仍能沿 parent 到水面。

### 18.4 实测结果（交替过滤后）

`湿/热` = `rain=1,temp=1`；`湿/温` = `rain=1,temp=0`；`干` = `rain=0,temp=0`。

| 方案 | Qc / Tmin / Lmin | 湿/热 密度 | 湿/温 密度 | 干 密度 | 湿/热 入海口 | 湿/热 枝长 p50 | 湿/热 干流 p50 | 最短枝 |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| 一期现状 | 4 / — / — | 7.3% | 8.4% | 4.7% | 32 | 4 | 8 | 1 |
| **A 均衡（采用）** | **1 / 8 / 4** | **11.1%** | **12.8%** | **8.4%** | **27** | **8** | **13** | **4** |
| B 更密 | 1 / 8 / 3 | 12.9% | 15.5% | 9.1% | 29 | 5 | 13 | 3 |
| C 更绵长 | 1 / 8 / 5 | 9.8% | 10.6% | 7.8% | 26 | 8 | 12 | 5 |
| D 少海口长干流 | 1 / 10 / 4 | 10.1% | 12.0% | 7.9% | 18 | 7 | 21 | 4 |

A 相对一期现状（湿/热）：

- 密度 `7.3% → 11.1%`（+52%）；
- 入海口 `32 → 27`（没有变多，反而更整合）；
- 叶枝 p50 `4 → 8`（+100%）；
- 干流 p50 `8 → 13`（+63%）；
- 最短叶枝 `1 → 4`，1–3 段小短线不再渲染。

**注意**：A 把干气候密度从 4.7% 拉到 8.4%，接近一期湿/热的 7.3%。若后续觉得干湿对比不够明显，可改用 `Qc=1.5`（湿/热 9.1%、湿/温 10.5%、干 7.1%），或给干气候单独提高 `Tmin`。当前以“最高降雨要密”为优先，采用 A。

### 18.5 代码落点（planet.gd，已实现）

- 常量：
  - `RIVER_SOURCE_QC := 1.0`
  - `RIVER_TREE_MIN_EDGES := 8`
  - `RIVER_BRANCH_MIN_EDGES := 4`
  - `RIVER_FILTER_MAX_PASSES := 64`（安全上限）
  - 移除误导性的 `RIVER_MIN_Q / RIVER_DENSITY` 除法。
- `_compute_river_edges()`：
  - 继续用 priority-flood 得到 `parent / order / flow`；
  - 用 `Qc` 收集候选边并建立 `selected` mask；
  - 调用 `_filter_river_selection(parent, order, selected)`；
  - 用最终 mask 生成 `_river_edges`；
  - 统计候选/整树删除/短枝删除/最终边数、入海口、最短枝、枝长 p50、干流 p50。
- 新增函数：
  - `_remove_small_trees(parent, order, selected, tmin)`
  - `_prune_short_branches(parent, selected, lmin)`
  - `_filter_river_selection(parent, order, selected)`
  - `_river_child_counts(parent, selected)`
  - `_river_selection_stats(parent, order, selected)`
  - `_collect_edges_from_selection(parent, selected)`
- 复杂度：整树统计 `O(N)`；短枝剪枝按叶路径迭代，当前候选几千条边，量级很小；最终 mesh 只为过滤后的边构建。
- 不改 `planet_rivers.gdshader`、固定宽度、方头、蓝色、图层 priority。

### 18.6 验收

`tools/test_planet_rivers.gd` 增加：

- `candidate_tiles > 0`，最终 `edge_n < candidate_tiles`；
- `tree_pruned_tiles + branch_pruned_tiles == candidate_tiles - edge_n`；
- 最终每条边仍满足 `flow >= threshold`，且 parent 链全部入水、无环；
- `branch_min >= RIVER_BRANCH_MIN_EDGES`；
- `tree_min >= RIVER_TREE_MIN_EDGES`；
- 湿/热密度在 `10.5%–12.0%`，入海口约 `25–30`，枝长 p50 `>= 7`，干流 p50 `>= 12`；
- 干气候密度低于湿/热（气候响应仍保留）。

**落地验证（2026-10-23）**：`test_planet_rivers` PASS——湿/热候选 1,330 → 812 条，密度 11.1%，入海口 27，最短枝 4，树最小 8；干/温 613 条 / 8.4%，气候响应断言通过。`test_planet_hills` 与其余可 headless 运行的现有回归通过。截图 `final_0/1/2/river` 已复看：默认视距明显更绵延，近景 1–3 段小短线消失，固定宽度/方头/图层关系未变。

视觉验收沿用 §12.2：默认视距、近景、远视图；重点看 1–2 段小短线是否消失、汇流处是否连续、河网是否仍压在低丘上/被高山压住。

### 18.7 暂不做

- D8/D-infinity 流向重算：可能让干流更集中，但改动大于本期；
- 湖泊单出口：`coverage=0.3` 不是主因，二期补；
- 连续 polyline / 圆角连接：本期保留每段方头风格；
- 河宽/透明度分级：本期仍固定 2.2px；
- 海岸线平滑/填小海湾：会改变地图，最后再评估；
- 用覆盖率/更多陆地解决密度：实测不是解，反而增加入海口数量。


## 19. 河流生成性能结论与优化路线（2026-10-23）

### 19.1 结论

只讨论河流网络生成，不涉及地形/气候/渲染管线的其它优化：

1. **河流渲染与 mesh 构建不是瓶颈**：`_build_river_mesh_from_edges()` 约 **2.3 ms**，当前 812 条河段、2,436 个采样点、3,248 个三角形。
2. **成本集中在 `_compute_river_edges()`**，约 **65.5 ms**。其中 priority-flood 约 **36.4 ms（55.6%）**，A 方案过滤约 **13.3 ms（20.3%）**，统计约 **5.2 ms（7.9%）**。
3. **当前没有达到最佳性能状态**。已有优化（预分配 mesh、批量计时、typed/Packed 数组、单 mesh/单 draw call）主要解决的是“不要无谓扩容”和“渲染不要多次 draw”，但没有解决 priority-flood 的 GDScript 堆开销、A 过滤的全量数组扫描，以及统计的无效开销。
4. **A 方案行为保持不变**：`Qc=1.0`、`Tmin=8`、`Lmin=4`、交替过滤、812 条河段/11.1% 密度是后续性能改动的回归基线；不改 shader、固定 2.2 px 宽度、方头、图层 priority。

### 19.2 实测拆解

口径：桌面 headless，`LEVEL=6`、`coverage=0.3`、seed `4242`、`rain=1/temp=1`、7,291 个陆地贴片；最终 812 条河段。

| 子阶段 | 耗时 | 占 `_compute_river_edges` |
|---|---:|---:|
| 产流 injection | 7.2 ms | 11.0% |
| **priority-flood** | **36.4 ms** | **55.6%** |
| 倒序汇流 | 0.55 ms | 0.8% |
| 候选收集 | 1.7 ms | 2.6% |
| **A 方案过滤** | **13.3 ms** | **20.3%** |
| 最终边提取 | 0.8 ms | 1.2% |
| **统计** | **5.2 ms** | **7.9%** |
| **合计** | **65.5 ms** | **100%** |
| mesh 构建 | 2.3 ms | — |

说明：

- 这些是墙钟时间，包含分帧等待；手机端会整体放大，但比例基本不变，仍需在目标设备上复测。
- 过滤前候选 **1,330** 段，A 方案 3 轮过滤后 **812** 段；候选只有 1,330，但过滤/统计仍在使用 `total=40,962` 大小的数组。
- `_build_river_mesh_from_edges()` 已经是 append + 现有数组写入，继续抠只能省约 0.5–1 ms，优先级最低。

### 19.3 优化候选（按收益/成本排序）

> 本节是 2026-10-23 优化前的评估记录；实际落地结果见 §19.6 与 §19.7。
> priority-flood 最终采用**精确 bucket queue**，不是 radix heap。

#### A. priority-flood（36.4 ms，最大头）

评估时的实现：

- 两个 `Packed*Array` 分别存 key/tile；
- 每次 push/pop 都是 GDScript 函数调用；
- 每次 pop 都 `resize(n)`；
- 约 7,291 个陆地 + 约 5,000 个水面种子。

优化步骤：

1. **低风险**：按 `total` 预分配 heap 数组；维护 `heap_size` 代替每次 `resize`；把 push/pop 内联到 flood 循环，减少函数调用和数组访问。
2. **中风险**：用 radix heap / 单调 bucket priority queue 替换二叉堆。priority-flood 的 pop key 单调不减，适合 O(1) 均摊的桶队列；保留浮点 key 的精确排序，并用 tile 索引做 tie-break，避免改变河网方向或确定性。
3. **可选**：所有 `SEA_LEVEL` 水面种子先用 FIFO/同 key 桶处理，再进入主堆，减少种子阶段的堆操作。

预期：`36 ms → 15–20 ms`（radix heap 理想情况）；只做预分配+内联则约 `28–32 ms`。

#### B. A 方案过滤与统计（18.5 ms，第二大头）

当前问题：

- `_remove_small_trees()`、`_prune_short_branches()`、`_river_selection_stats()` 每次分配 `total` 大小的数组；
- 短枝剪枝每轮扫描全量，3 轮过滤后还要再统计；
- 实际候选只有约 1,330 段，数组规模与工作量不匹配。

优化步骤：

1. 一次性建立 candidate-local 结构：
   - `cand_tiles`：候选贴片列表；
   - `local_parent`：候选内部父索引；
   - `local_order`：全局 `order` 过滤成候选顺序；
   - `selected/size/root/child/branch_len`：全部长度 C；
   - 最终把 local 结果映射回全局 tile id 生成 edges。
2. 每轮过滤从 `O(total)` 降到 `O(C)`；候选少时收益最大。
3. `_river_selection_stats()` 改为基于最终 selected 的紧凑数组；移动端 release 可用 `OS.is_debug_build()` 或独立开关跳过 p50/trunk 统计。

预期：过滤 `13.3 → 3–5 ms`，统计 `5.2 → 1–2 ms`。

#### C. injection / 候选收集（约 9 ms）

- 维护 `generated_ids`（约 12,289 个已生成贴片），injection、候选收集、统计只遍历生成区，不再每次扫 40,962。
- 预期 injection `7.2 → 4–5 ms`，候选收集 `1.7 → 约 1 ms`。

#### D. mesh 构建（2.3 ms）

- 按最终采样点数精确 `resize` 顶点/索引数组，避免 append 扩容；
- 预期 `2.3 → 1.5–2 ms`，只作为收尾，不改 mesh 格式/shader。

#### E. 异步 / 线程（可选）

- 河流计算依赖的地形数组生成后是只读的，可把 `_compute_river_edges()` 放到 `WorkerThreadPool`，或与丘陵 mesh 构建并行；
- 不减少 CPU 总时间，但能减少主线程卡顿、缩短墙钟时间；
- 应在 A–D 完成后再评估，避免过早引入线程复杂度。

### 19.4 实施顺序与验收

建议按以下顺序：

1. priority-flood 预分配 + 内联 + 去掉 pop 的 `resize`；
2. A 过滤/统计 candidate-local 化；
3. release 跳过统计；
4. injection 使用 `generated_ids`；
5. 如仍不够，再上 radix heap；
6. mesh 精确预分配收尾。

预计河流生成整体从 **65 ms 降到 30–40 ms**（桌面量级），A 方案输出与视觉不变。

验收必须保持：

- `test_planet_rivers.gd` 全 PASS；
- 湿/热仍为候选 `1,330` → 最终 `812` 条，密度 `11.1%`，入海口 `27`，最短枝 `4`；
- `tree_min=8`、`branch_min=4`、交替过滤轮数行为不变；
- mesh 仍为 `2,436` 采样点 / `3,248` 三角形；
- parent 链全部入水、无环；固定宽度/方头/图层 priority 不变。

### 19.5 暂不做

- 不量化 flood key：会改变填洼高度和河网方向；
- 不改 shader/mesh 格式/宽度/颜色/图层；
- 不为了性能降低 A 方案阈值或改变河网密度；
- D8/D-infinity、连续 polyline、湖单出口仍留到后续阶段。

### 19.6 实施结果（2026-10-23）

已按 19.4 落地前四项，未改 A 方案参数、shader 或 mesh 格式：

1. **priority-flood（该版二叉堆随后被 §19.7 的 bucket queue 取代）**
   - heap 数组按 `total` 预分配，用 `_river_heap_size` 维护逻辑长度，pop 不再 `resize`；
   - 水面种子 key 全为 `SEA_LEVEL`，按 tile 升序直接铺入堆，省掉种子逐次 push；
   - 主循环内联 push/pop；
   - 未生成贴片在 `visited` 初始化时直接标记，邻居循环少一次 `_generated[u]` 查询；
   - 内联 push 的 key 从 `filled` 回读，保证 float32 舍入与堆内 key 完全一致，避免同 key 的 tie-break 偏移。
2. **A 过滤/统计 candidate-local 化**
   - 新增 `_build_river_candidate_graph()`：候选贴片、local parent、local order；
   - `_filter_river_selection()`、`_remove_small_trees()`、`_prune_short_branches()`、`_river_selection_stats()` 全部只操作长度 C 的数组；
   - `_collect_edges_from_selection()` 通过 `cand_tiles` 映射回全局边。
3. **generated_ids**
   - 生成收尾时构建 `_generated_ids`；
   - injection、候选收集、最大填洼深度统计只遍历生成区。
4. **旧堆删除**
   - 删除不再使用的 `_river_heap_pop()`；`_river_heap_push()` 暂留给防御性水面分支，随后在 §19.7 中随二叉堆一起删除。

同口径实测（桌面 headless，seed `4242`、`coverage=0.3`、rain/temp `1`）：

| 指标 | 优化前 | 优化后 |
|---|---:|---:|
| `_compute_river_edges` | 65.5 ms | **42.9 ms** |
| `_build_river_mesh_from_edges` | 2.3 ms | 2.3 ms |
| 河流层合计 | 67.8 ms | **约 45.2 ms** |

约 **33%** 的河流生成耗时下降。priority-flood 仍是最大剩余热点；随后在 §19.7 中实测确认：4-ary/tile-only 堆无收益，最终改用精确 bucket queue。

验收保持不变：

- `test_planet_rivers` PASS；
- 湿/热候选 `1,330` → 最终 `812` 条，密度 `11.1%`，入海口 `27`，最短枝 `4`，枝长 p50 `8`，干流 p50 `13`；
- mesh `2,436` 采样点 / `3,248` 三角形；
- parent 链全部入水、无环；
- `test_planet_hills` PASS。

### 19.7 priority-flood 精确 bucket queue 实施结果（2026-10-23）

只替换 priority-flood 的堆，不改 A 方案参数、shader、mesh 格式、2.2 px 宽度、方头或图层 priority。

#### 实现

1. 新增 `RIVER_FLOOD_BUCKETS = 4096`。
2. injection 循环顺便统计 `max_land_elev`，用
   `[SEA_LEVEL, max_land_elev]` 建立桶范围；超出范围的高度夹到最后一桶。
3. **水面种子批处理**：所有水面种子 key 都是 `SEA_LEVEL`，先按 tile 升序全部处理，把它们的陆地邻居推入桶，再开始桶队列。
   - 不能把约 5,000 个种子直接塞进 bucket 0：实测会退化成每次 pop 扫描全部种子，耗时约 **918 ms**。
4. 每个桶用 `head/tail/next` 链表保存 tile；pop 时从当前桶开始扫描，按 `(filled[tile], tile)` 精确取最小。
   - 没有量化 key，填洼高度和河网方向不变。
   - `filled` 单调不减，新节点不会进入当前桶之前的桶；这是正确性的关键。
5. 删除 `_river_heap_keys/_river_heap_tiles/_river_heap_size` 和 `_river_heap_push()`；不再保留二叉堆。

内存开销：4096 个桶的 `head/tail` 约 32 KB；`next` 按 `total` 预分配，40,962 贴片约 160 KB。实测最大桶大小：默认场景 21，`coverage=1.0` 场景 27，种子 7 场景 10。

#### 实测

同一口径（桌面 headless，seed `4242`、`coverage=0.3`、rain/temp `1`，7 次平均）：

| 指标 | §19.6 二叉堆 | §19.7 bucket queue |
|---|---:|---:|
| `_compute_river_edges` | 42.9 ms | **21.2 ms** |
| `_build_river_mesh_from_edges` | 2.3 ms | **2.1 ms** |
| 河流层合计 | 45.2 ms | **约 23.3 ms** |

`_compute_river_edges` 约下降 **51%**，河流层合计约下降 **48%**。

只测 flood 的临时微基准：

| 方案 | 平均耗时 |
|---|---:|
| 二叉堆 | 31–32.6 ms |
| tile-only 堆 | 32.2–33.2 ms |
| 4-ary 堆 | 32.9–33.2 ms |
| **bucket queue 4096** | **15.2–15.3 ms** |
| FIFO 下界（仅测速，顺序不正确） | 11.3–11.6 ms |

结论：4-ary/tile-only 无收益；bucket queue 已接近 FIFO 下界。

#### 精确性验收

额外用 4 个场景逐位比较 bucket queue 与二叉堆的 `order`/`parent`：

| 场景 | 生成贴片 | 最大桶 | parent | order |
|---|---:|---:|---|---|
| wet low | 12,289 | 21 | 一致 | 一致 |
| dry | 12,289 | 21 | 一致 | 一致 |
| seed 7 wet | 12,289 | 10 | 一致 | 一致 |
| coverage 1.0 | 40,962 | 27 | 一致 | 一致 |

`test_planet_rivers` 保持候选 `1,330` → 整树 `-203` / 短枝 `-315` → 最终 `812` 条，密度 `11.1%`，入海口 `27`，最短枝 `4`，`branch_p50=8`，`trunk_p50=13`，`tree_min=8`；mesh 仍为 `2,436` 采样点 / `3,248` 三角形；`test_planet_hills` PASS。

后续如果地形高度范围或平坦区分布发生较大变化，导致单桶元素异常增多，可提高桶数或在桶内加小型堆；当前场景不需要。

---

## 20. 河流渲染第二阶段：河宽分级 + 链式 ribbon（2026-10-23 已实施，见 §20.14）

> 前置：§18（A 方案）与 §19（生成性能）已落地，812 条河段 / 24 ms 河流层。
> 本轮**只动渲染**：水文、选边、图层（低丘 0 → 河流 1 → 高山 2）、depth_bias 全部不改。
> 落地范围收敛为**只做河宽**（配色仍沿用一期亮蓝），实际参数与踩坑记录见 **§20.14**。

### 20.1 参考图 vs 现状：先量化差距

口径：`temp/river.png` 为 2461×1910，星球直径 ≈ 2461 px → 1 个世界单位 ≈ 1230 px；
当前截图 `final_river.png`（dist 1.15 近景）与 `final_1.png`（默认视角）。

| 维度 | 参考图实测 | 当前实现 | 差距 |
|---|---|---|---|
| 干流核心宽度 | ≈ 24 px = **0.98% 星球直径** | 统一屏幕下限 2.2 px | 干流偏细约 4–5× |
| 支流核心宽度 | ≈ 5–8 px = 0.2%–0.33% | 同样是 2.2 px | 支流偏粗约 2× |
| 干/支宽度比 | **≈ 3–4×** | **1×** | 完全没有流量分级 |
| 核心色（实测中位） | **(73, 82, 100) = #495264** | (50, 123, 199) = #327BC7 | 过饱和、过亮 |
| 与陆地亮度关系 | 比陆地（112,101,56）**略暗**（≈0.85×） | 比陆地明显更亮 | 观感反转 |
| 边缘 | 3–4 px 软过渡（源图放大伪影，换算 ≈1 px） | 1 px AA | 可接受 |
| 拐点 | 连续，无分节 | 每段独立方头，拐点外凸小方块 | 明显"串珠/台阶" |
| 汇流 | 支流细、干流粗，宽度自然跳级 | 等宽叠加，看不出汇水 | 缺少层级 |
| 上游端头 | 渐细、接近消失 | 等宽硬截断 | 像被切断 |

几个关键实测（用像素扫描得到，可复现）：

- 参考图行 `y=800`：河道核心 `x∈[1112,1136]` 共 24 px，色值恒为 `(73,82,100)`；
  两侧各有 3–4 px 从 `(80,85,91)` 渐变到陆地 —— 是**线性混合**，不是描边。
- 当前截图里河色实测 `(50,123,199)`，与 uniform `(0.20,0.48,0.78)` **逐位相同**
  → 本工程 GL Compatibility 管线下「uniform 值 = 屏幕值」，可直接按参考图色值填。
- 陆地色：参考图 `(112,101,56)`，本工程 `(97,88,48)` —— 调色板本就接近，
  所以参考图的河色可以直接搬过来，不需要为我们的地表重新配色。

### 20.2 差距归因（按视觉贡献排序）

1. **宽度不随流量分级**（贡献最大）。`RIVER_BASE_HALF_WIDTH=0.0018` 对干流、源头一视同仁，
   再加上 `min_width_px=2.2` 兜底，远看所有河都是同一根线 → 没有主次，读不出"干流汇水"。
2. **每段独立 ribbon + 方头延长**。相邻两段在同一节点各自沿自己的切线外扩半宽，
   在拐点外侧留缺口、在转向处留下两个凸出的小方块 → 正是截图里那种"台阶/串珠"。
3. **颜色策略反了**。现在是"高饱和亮蓝"，参考图是"比地表略暗的去饱和灰蓝"。
   前者像在图上画的记号，后者像地表上的水。
4. **上游端头硬截断**。等宽方头让支流末端像被切断的短线，破坏"叶脉/树根"感。
5. **汇流处没有宽度台阶**。参考图支流汇入时宽度跳一级，是河网层级的主要视觉线索。
6. **边缘锐度单一**。参考图（去掉放大伪影后）约 1 px 柔边；我们现在也是 1 px，
   但配上亮色 + 等宽几何就显得硬。等颜色和宽度改对后，这一条会自然消失。

### 20.3 目标与非目标

**目标**

1. 干流 / 支流有 **3–4× 的宽度差**，且下游只增不减，汇流处出现自然台阶。
2. 河线在拐点处**连续无缝**：无外凸小方块、无台阶、无分节感。
3. 河色改为参考图的暗灰蓝，整体**只比地表略暗**，不抢地表信息。
4. 上游端头**渐细并轻微淡出**，支流末端不再是硬截断。
5. 上述改动**不增加 draw call**，移动端 GL Compatibility 上帧率不变差。

**非目标**

- 不做流动动画、水面反光、泡沫、贴图波纹（属后续阶段，UV.y 已预留）；
- 不做河道蜿蜒/平滑（是否加一次 Chaikin 见 §20.13 Q3，本轮默认不加）；
- 不做湖泊出口、三角洲、分叉（非树结构）；
- 不恢复"每段独立方头"的像素风硬边；
- 不动水文、选边、密度、图层顺序与 `depth_bias`。

### 20.4 架构决策：宽度搬到 CPU 烘焙，shader 只做最小像素补偿与上色

**为什么不继续在 shader 里展开宽度**：

- 拐点要 miter：左右两侧的偏移方向不同、长度也不同。当前顶点布局里
  `NORMAL` 只能承载**一个**侧向方向，`UV.x` 只有 ±1 一个标量，表达不了 miter；
- 端点要渐细：宽度变成沿链变化的量，而 shader 侧不知道"这是第几个采样点"；
- 方头延长要跟宽度联动：几何侧延长量必须等于该端半宽。

所以把 `half_w` 从 shader 搬到几何侧，**shader 只保留两件事**：
① 远视角下的"最小屏幕宽度"补偿；② 边缘 AA 与 alpha。

**顶点布局（一条 ribbon 每个采样点 2 个顶点）**

| 通道 | 内容 | 用途 |
|---|---|---|
| `ARRAY_VERTEX` | 偏移后**重新归一化**到球面的点 | 半径恒为 1.0，贴地不变 |
| `ARRAY_NORMAL` | 单位侧向向量（左顶点 `-side`，右顶点 `+side`） | 最小像素补偿方向 |
| `ARRAY_TEX_UV` | `(0/1, s)` | x = 侧别 + AA；y = 沿链弧长归一（留给流动动画） |
| `ARRAY_TEX_UV2` | `(half_w, w01)` | x = 烘焙半宽（世界单位）；y = 宽度归一值（调试用） |
| `ARRAY_COLOR` | `(alpha, 0, 0, 1)` | 端点渐隐，乘进最终 alpha |

**收益**：几何不再是零面积三角形 → 去掉 `custom_aabb` 兜底、AABB 真实、
以后想开阴影/深度写也不用重做。代价是 mesh 构建时多算一遍偏移（仍在 2–4 ms 量级）。

shader 草案（完整替换现有 `planet_rivers.gdshader`）：

```glsl
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;

uniform vec4 river_color : source_color = vec4(0.286, 0.322, 0.392, 1.0);
uniform float min_width_px = 1.8;        // 远视角兜底；近景不生效
uniform float edge_softness_px = 0.8;
uniform float depth_bias = 0.004;        // 与现状一致，不动
uniform float bank_darken = 0.0;         // 可选：岸线压暗（默认关）

varying float v_alpha;
varying float v_w01;

void vertex() {
    // 只在「窄河 + 远视角」时生效：烘焙宽度已经够宽就直接用几何
    vec4 view_pos = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
    float depth = max(-view_pos.z, 1e-4);
    float px_world = 2.0 * depth / (PROJECTION_MATRIX[1][1] * VIEWPORT_SIZE.y);
    float extra = max(0.0, 0.5 * min_width_px * px_world - UV2.x);
    VERTEX += NORMAL * (UV.x * 2.0 - 1.0) * extra;

    v_alpha = COLOR.r;
    v_w01 = UV2.y;
    VERTEX += normalize(CAMERA_POSITION_WORLD - VERTEX) * depth_bias;
}

void fragment() {
    float edge = abs(UV.x * 2.0 - 1.0);
    float aa = max(fwidth(UV.x), 1e-5) * edge_softness_px;
    float cov = 1.0 - smoothstep(1.0 - aa, 1.0, edge);
    vec3 col = river_color.rgb;
    if (bank_darken > 0.0) {
        // 岸线附近压暗，给河一点"湿岸"厚度
        col *= 1.0 - bank_darken * smoothstep(0.55, 1.0, edge);
    }
    ALBEDO = col;
    ALPHA = river_color.a * v_alpha * cov;
}
```

注意：宽度烘焙后，`min_width_px` 只对**细河**起作用（干流在远视角仍按几何宽度走），
所以远看不再是"一片同宽的线"，而是"干流粗、支流细、极细的兜到 1.8 px"。

### 20.5 分支链（branch chain）+ miter 接头 —— 消掉"串珠"

**邻接**：在候选图（§18.5 的 candidate-local 结构）上补三件事，O(E)：

```
child_count[v]   # 该节点有几条上游河段（0 = 源头，≥2 = 汇合点）
first_child[v]   # 链表头
next_sibling[v]  # 链表下一项
```

**分链规则**（每条河段恰好属于一条链，不做重复几何）：

1. 从每个**源头**（`child_count == 0`）起一条链，沿 `parent` 往下游走；
2. 走到**汇合点**（`child_count >= 2`）就**包含该点并停止**；
3. 每个汇合点再起一条**下游链**（以它为首节点），继续走到下一个汇合点或水面；
4. 水面是终点，沿用 §8.2 的"岸线中点截断"。

于是链与链只在**汇合点这一个节点**上重叠，且该节点的宽度取自 `Q`（同一个值），
两侧偏移点完全相同 → 天然无缝，既不会漏缝也不会重复叠色。

**miter 计算**（内部节点，前后方向已知）：

```
d_in  = 前一采样点 → p 的切向（单位，投影到 p 的切平面）
d_out = p → 后一采样点 的切向
m     = normalize(d_in + d_out)                 # 角平分方向
cos_h = dot(m, d_out)                           # = cos(转角/2)
len   = half_w / max(cos_h, RIVER_MITER_MIN_COS) # 钳制，防止尖角爆长
side  = normalize(cross(p, m))
左顶点 = normalize(p - side * len)，右顶点 = normalize(p + side * len)
```

- `RIVER_MITER_MIN_COS = 0.4`（转角 > 约 132° 的尖角被截短，宁可留小缺口也不爆刺）；
- 本工程走线是贴片中心线，相邻段转角多在 60° 以内，`len ≈ 1.15 × half_w`，不会触发钳制；
- **汇合点**是特例：该点没有单一"前方向"，改用
  `m = normalize(dir(最宽上游支流 → p) + dir(p → parent))` 作为统一角平分方向，
  让上下游两条链在这一节点使用**同一组偏移点**，接头完全对齐。

**端点处理**：

- 下游端（入海口）：沿用现状，截到 `normalize(a + b)` 的岸线中点，不做方头延长；
- 下游端（汇合点）：不延长（由下游链覆盖）；
- 上游端（源头）：最上游 1 段内 `half_w` 从 `0.3 ×` 渐增到 `1 ×`，同时 `COLOR.r` 从 `0.4` 渐到 `1.0`
  → 支流末端变成"逐渐消失的细尖"，而不是硬方头。

**采样**：每个节点边仍按 `RIVER_MAX_ARC_DEG = 2.5°` 细分（沿用 §9.7.4 的防弦切下沉结论），
节点处用 miter 偏移点，段内按 `t` 线性插值 `half_w`。

### 20.6 河宽映射：流量 → 宽度

在 `_compute_river_edges()` 末尾（过滤之后、建 mesh 之前）为每个河网节点算半宽：

```
q_ref = P90(_river_flow[v] for v in river_nodes)      # 本次生成实测，非硬编码
u     = clamp(Q[v] / q_ref, 0, 1)
w01   = pow(u, RIVER_WIDTH_EXP)                        # 初值 0.5 → 支流段更细
half  = lerp(RIVER_HALF_MIN, RIVER_HALF_MAX, w01)
```

- `Q` 沿下游单调不减（§7.3 不变量）→ `half` 也单调不减，**不会出现下游变细**；
- 汇流处 `Q` 跳一级 → 宽度台阶，正是参考图的层级感；
- `RIVER_HALF_MIN = 0.0022`（≈0.22% 直径，对应参考图支流）、
  `RIVER_HALF_MAX = 0.0095`（≈0.95% 直径，对应参考图干流）；
- 实现时打印半宽直方图（p10/p50/p90/max）核对：目标 p50 ≈ 0.0035、p90 ≈ 0.0060；
  若 p50 偏高说明支流整体过粗，调 `RIVER_WIDTH_EXP`（0.4–0.8）或 `q_ref` 分位。

### 20.7 颜色、边缘、远视角

- **核心色**：`(0.286, 0.322, 0.392)` = `#495264`，alpha **固定 1.0**
  ——alpha < 1 会让汇流重叠处出现暗缝（§9.2 已踩过）；
- **边缘**：`edge_softness_px = 0.8`，比现状略柔；`fwidth` AA 在 GL Compatibility 可用，不加额外成本；
- **岸线压暗**：`bank_darken` 默认 **0**（参考图没有暗边），留作现场可调旋钮；
- **远视角**：`min_width_px` 从 2.2 降到 1.8。因为干流现在有真实宽度，
  兜底只需要照顾最细的支流，避免"远看一片同宽"；
- **不做**：流动纹理、反光、泡沫。`UV.y = 弧长归一` 已经写入顶点，后续加动画不用改几何。

### 20.8 参数表（初值，截图后调）

| 参数 | 初值 | 说明 |
|---|---:|---|
| `RIVER_HALF_MIN` | 0.0022 | 最细河半宽（世界单位，球半径 1） |
| `RIVER_HALF_MAX` | 0.0095 | 最粗干流半宽 |
| `RIVER_WIDTH_EXP` | 0.5 | 流量→宽度曲线指数 |
| `RIVER_WIDTH_Q_REF_PCT` | 0.90 | `q_ref` 取河流节点流量分位 |
| `RIVER_MITER_MIN_COS` | 0.4 | miter 钳制（尖角截短） |
| `RIVER_TIP_TAPER` | 0.3 | 上游端头起始宽度比例 |
| `RIVER_TIP_ALPHA` | 0.4 | 上游端头起始 alpha |
| `RIVER_MIN_WIDTH_PX` | 1.8 | 屏幕最小宽度（原 2.2） |
| `RIVER_EDGE_SOFTNESS_PX` | 0.8 | 边缘 AA 宽度 |
| `RIVER_COLOR` | `#495264` | 参考图实测核心色 |
| `RIVER_BANK_DARKEN` | 0.0 | 岸线压暗（默认关） |
| `RIVER_DEPTH_BIAS` | 0.004 | **不变** |
| `RIVER_MAX_ARC_DEG` | 2.5 | **不变** |

### 20.9 数据结构与代码落点

**`planet.gd` 新增成员**

```gdscript
var _river_child_count := PackedInt32Array()   # 长度 total
var _river_first_child := PackedInt32Array()
var _river_next_sibling := PackedInt32Array()
var _river_half_width := PackedFloat32Array()  # 长度 total，0 = 非河网
var _river_branch_nodes := PackedInt32Array()  # 扁平节点串
var _river_branch_offsets := PackedInt32Array() # CSR 偏移，长度 = 链数 + 1
var _river_branch_n := 0
var _render_stats: Dictionary = {}             # 链数/顶点数/宽度分位，给测试和日志
```

**新增/改写的函数**

| 函数 | 职责 |
|---|---|
| `_compute_river_widths()` | 由 `_river_flow` 算 `_river_half_width`，打直方图 |
| `_build_river_branches()` | 建 children 邻接 + 分链，产出 CSR |
| `_build_river_mesh_from_branches()` | 替换 `_build_river_mesh_from_edges()`：miter + taper + 逐顶点属性 |
| `_build_river_layer()` | 改调新 mesh 函数；不再设 `custom_aabb`；其余（材质/priority/阴影）不变 |

**保持不变**：`_river_edges`（测试、HUD、`tools/capture_final.gd` 都依赖它）、
`_river_parent` / `_river_flow` / `_river_stats`、shader 的 `depth_bias` 与图层 priority。

### 20.10 分阶段实施（每阶段出截图再进下一阶段）

| 阶段 | 内容 | 预期观感变化 | 验收 |
|---|---|---|---|
| **R1 河宽分级** | 加 `UV2.x` 烘焙半宽（几何仍按现有一边一段展开，宽度按端点插值），shader 改为"最小像素补偿" | 干流明显变粗、支流变细，出现层级 | 近景 vs `final_river.png`；宽直方图 p50/p90 |
| **R2 链式 ribbon + miter** | `_build_river_branches()` + 新 mesh 函数，拐点 miter、汇合点共用偏移 | 串珠/台阶消失，线条连续 | 近景放大 4× 检查拐点；顶点/三角形数与链数吻合 |
| **R3 端头 + 配色** | 上游 taper/渐隐、颜色 `#495264`、AA 0.8、"远视角 1.8 px" | 从"记号笔"变成"水脉" | 与 `temp/river.png` 同尺度并排 |
| **R4 回归 + 文档** | 测试、三档截图、移动端帧时间、回填本节数据 | — | 全套回归绿 |

每阶段都保留上一版截图（`user://final_*.png`），方便回退比较。

### 20.11 测试与验收

**`tools/test_planet_rivers.gd` 需要改的断言**（现在按"逐边 n+1 采样"重算 mesh，会失效）：

- mesh：顶点数 = 链采样数 × 2（按 `_river_branch_nodes` 重算），索引 = 采样数 × 6；
- 顶点半径仍为 `1.0 ± 1e-5`（偏移后必须重新归一化）；
- `NORMAL` 为单位向量；`UV.x ∈ {0,1}`；`UV2.x ∈ [RIVER_HALF_MIN, RIVER_HALF_MAX]`；
- 新断言：
  - **宽度单调**：对每条河段 `half_width[to] >= half_width[from] - 1e-6`；
  - **链完整性**：每条河段恰好出现在一条链里（用计数数组核对，无重复、无遗漏）；
  - **链内一致**：链首是源头或汇合点，链尾是水面或汇合点；
  - **无 NaN**：全部顶点 `is_finite()`；
- 原有的 parent 链、无环、阈值、密度、确定性、图层 priority 断言全部保留。

**视觉验收**

1. 三档截图：dist 1.15 / 2.33 / 10.0（沿用 `tools/capture_final.gd`）；
2. 新增"参考同尺度"一档：把星球直径控制在 ≈ 1000 px，然后**数值核对**干流半宽
   是否落在星球直径的 0.45%–0.5%（参考图 0.49%）；
3. 近景放大 4× 检查：拐点无台阶、汇流无缺口、上游端头是渐细不是断口、无 z-fighting；
4. 干/湿两种气候各看一次，确认窄河在干旱区不会糊成一片。

**回归**：`test_planet_hills`、`test_planet_texture`、`test_selection_*`、`test_starfield`、
`test_region_cap`、`test_tile_hud`、`test_plugin_uid_fix` 全绿。

**性能**：桌面 `_build_river_mesh_from_branches` 目标 ≤ 4 ms（现在 2.1 ms）；
移动端关注**填充率**——变粗的干流会增加 overdraw，但支流变细、总覆盖面积基本持平，
预计帧时间不升；生成期顶点数预计 4–6 k（现在 4.9 k）。

### 20.12 风险与缓解

| 风险 | 表现 | 缓解 |
|---|---|---|
| miter 在尖角处爆长 | 拐点出现长刺 | `RIVER_MITER_MIN_COS` 钳制 + 超阈值退化 bevel |
| 干流过粗 | 近景像河堤/公路 | `RIVER_HALF_MAX` 上限 + 近景截图复核；必要时按 dist 做宽度缩放（本轮不做） |
| 暗色河在深色地形上不可见 | 森林/基岩区河网"消失" | 保留 `bank_darken` 与 `river_color` 现场可调；必要时一提亮档 |
| alpha 重叠发暗 | 汇合点出现暗斑 | 核心 alpha 锁 1.0，透明度只出现在 AA 边缘 |
| 链式构建复杂度 | 分链错误 → 漏段/重段 | 测试里用"计数数组核对每条河段恰好一次" |
| 顶点数上升 | 移动端 mesh 构建变慢 | 链共享节点，实际顶点数基本持平；实测 > 6 k 再优化 |
| 过度模仿参考图的软边 | 河线发虚 | 参考图软边是放大伪影，按 0.8 px AA 收，不回退到 3 px |

### 20.13 开始实现前需要拍板

1. **配色**：直接用参考图实测 `#495264`（比地表略暗、去饱和），
   还是保留一点"水蓝"倾向（例如 `(0.26, 0.36, 0.46)`）？我建议先用 `#495264` 出图，再微调。
2. **干流宽度**：参考图是 ≈1% 星球直径（近景会比较粗），是否接受？
   还是压到 0.7% 左右更"克制"？
3. **折线感**：保持贴片中心的硬折线（更接近参考图的 120° 地格感），
   还是加一次 Chaikin 平滑（更自然但会弱化地格感）？我建议**先不加**。
4. **上游端头**：渐细 + 淡出（我建议），还是"细线直接断开"？
5. **是否要岸线压暗**（`bank_darken`）：参考图没有，我建议默认关，只留旋钮。

确认后按 §20.10 的 R1 → R4 顺序落地，每阶段出对比截图再继续。

### 20.14 实施结果（2026-10-23，已落地，未提交）

**范围收敛**：与需求方确认后，本轮**只做河宽**，配色沿用一期
`RIVER_COLOR = (0.20, 0.48, 0.78)` 不动（§20.6/20.7 里关于 `#495264`、
`bank_darken`、Chaikin 平滑的部分一律推迟）。取舍理由：先把"粗细"这个
几何问题解决干净，配色是独立旋钮，混在一起改没法判断哪一步起了作用。

**最终参数（与 §20.8 初值不同的以这里为准）**

| 参数 | 最终值 | 相对 §20.8 初值的调整原因 |
|---|---:|---|
| `RIVER_HALF_MIN` | 0.0016 | 0.0022 太粗，细支流没有"毛细"感 |
| `RIVER_HALF_MAX` | 0.0060 | 0.0095 近景像蓝色高速公路；0.006 实测更稳 |
| `RIVER_WIDTH_EXP` | **0.80** | 初值 0.5 时 p50=0.0035，离 max 只有 1.7×，全网看着一样粗；0.8 把 p50 压到 0.0028，干/支比 2.3× → **3.0×**（参考图 3–4×） |
| `RIVER_WIDTH_Q_PCT` | 0.90 | 不变 |
| `RIVER_MITER_MAX_RATIO` | 1.4 | 替换 `RIVER_MITER_MIN_COS`：直接钳"偏移长度 ≤ 1.4×半宽"，比钳 cos 更好推理 |
| `RIVER_TIP_TAPER` | 0.35 | 0.3 略尖，0.35 收得住又不像断线 |
| `RIVER_TIP_ALPHA` | 0.45 | 0.4 有点糊 |
| `RIVER_MIN_WIDTH_PX` | 1.6 | 干流已有真实宽度，兜底只照顾细支流 |
| `RIVER_MAX_WIDTH_PX` | **28** | 初值 16 太小：dist 1.15 时几乎所有河道都被夹到同一宽度，直接复现"统一粗细" |
| `RIVER_DEPTH_BIAS` | 0.004 | 不变 |

**分支链实测**（`LEVEL=6`、`coverage=0.3`、seed 4242、rain/temp=1）：
812 条河段 → **115 条分支链** → 927 采样点 / 1,624 三角形，单 surface 单
draw call；半宽 p50 = 0.0028、p90 = 0.006、max = 0.006，干/支比 **3.0×**。

#### 踩坑记录：`PROJECTION_MATRIX * VIEWPORT_SIZE` 在 GL Compatibility 下不可信

这是本轮最难查的一个 bug，现象是"换了宽度之后河流整个消失"。

- 用 `StandardMaterial3D`（洋红）覆盖河流材质 → 河道清晰可见 ⇒ 几何没问题；
- 换成只有 `ALBEDO = vec3(1,0,0)` 的极简 `ShaderMaterial` → 也能看见 ⇒
  材质槽、实例、AABB、图层都没问题；
- 换回项目 shader → **一个像素都不出**（逐变体数像素：极简 5,234 px / 项目 0 px）；
- 逐步加特征二分定位：问题出在
  `px_world = 2·depth / (PROJECTION_MATRIX[1][1] · VIEWPORT_SIZE.y)` 这一行。

把该式的结果编码进颜色回读到 CPU 后确认：算出的 `px_world` 比实际小约
**26 倍**（同场景 CPU 侧真值 0.0033，shader 算出 0.00012）。后果是
`half_hi = 0.5·max_width_px·px_world` 远小于已烘焙半宽，
`clamp()` 把**每一条**河道都压成 ~1 像素 —— 淡水色细线在暗地表上等于消失。

> 一期之所以没暴露：那时 shader 用 `max(base_half_width, 0.5·min_width_px·px_world)`，
> 只有**下限**，`px_world` 偏小最多让细河不够粗，不会把河压没。
> 本轮引入**上限**后，同一个偏差变成"把所有河压成 0"。

**修法**：像素换算不再由 shader 反推，改由 CPU 直接给焦距（§20.14.1）。
`focal_px = 0.5 · 视口高 / tan(fov/2)`，口径与 `orbit_camera.gd::_drag_gain`
和选中环的 `px_per_world` 完全一致；`planet.gd::_update_river_camera_params()`
在建层时写一次，并挂 `viewport.size_changed` 重算。

#### 20.14.1 shader 侧宽度合成顺序（重要）

```
px_world = depth / focal_px
want     = max(UV2.x, 0.5·min_width_px·px_world)        # ① 下限：远景细河别消失
if max_width_px > 0:                                    # ② 软封顶
    half_hi = 0.5·max_width_px·px_world
    knee    = 0.6·half_hi
    if want > knee:
        want = knee + (half_hi-knee)·(1 - exp(-(want-knee)/(half_hi-knee)))
VERTEX += side · (UV.x*2-1) · (want - UV2.x)            # ③ 差额补偿
```

② 必须是**软膝（exp 渐近）而不是 `clamp`**：`clamp` 会把所有超过上限的河道
压成**同一个宽度**，近景干流/支流全变一样粗——又回到需求方最不能接受的
"统一粗细"。exp 形式在 `UV2.x` 上严格单调，次序永不反转，所以也不会出现
"这里粗、那里细、过一会又变粗"。

③ 的差额可正可负：远景细河补宽（正），近景干流限宽（负）。

#### 20.14.2 验收核对（§20.11 的逐条结果）

| 验收项 | 结果 |
|---|---|
| 半宽 ∈ `[HALF_MIN, HALF_MAX]` | ✅ 0.0016–0.0060 |
| 下游半宽单调不减（无"粗—细—粗"） | ✅ 逐边断言通过 |
| 干/支比 ≥ 2.5× | ✅ 3.0× |
| 每条河段被分支链覆盖恰好 1 次 | ✅ 812/812 |
| 源头端渐细渐隐 | ✅ `TIP_TAPER`/`TIP_ALPHA` 仅对 `child_count < 2` 的链头生效 |
| 汇合点无缝/无尖刺 | ✅ 共享角平分方向 + miter 钳 1.4×；孤立图层截图无断口 |
| 单 surface 单 draw call | ✅ 1 surface / 1,624 三角形 |
| 确定性（同种子逐位一致） | ✅ |
| 回归 | ✅ `test_planet_rivers` PASS；hills/texture/selection_smoke/starfield/region_cap/tile_hud/uid 全 PASS |

**出图**：dist 1.15 / 2.33 / 10.0 + 干流近景四张已复看；孤立图层（隐藏地表）
确认 ribbon 无断口、miter 外角干净。

**仍未做**：配色（仍是原亮蓝）、Chaikin 平滑、岸线压暗、流动纹理。
按需求方要求**代码保持未提交**，可整体回滚。

