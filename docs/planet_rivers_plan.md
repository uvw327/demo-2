# 星球河流系统规划（一期）：球面水文网络 + 固定宽度河线

> 状态：**已拍板，进入实现（先做小段验证）**
> 参考图：`temp/river.png`
> 主要关联文件：`planet.gd`、`planet_surface.gdshader`、`planet_hills.gdshader`
> 一期结论：**先算水网数据，再用独立河流 mesh + 独立 shader 画固定宽度线带**；一期走贴片中心线，二期可切换为贴片边界线。
> 渲染决策：**河流压住低丘（SmallHills/LargeHills），但被高山（Mountainous/Impassable）压住**；目标平台是**移动端 GL Compatibility**；选中环最终应在河流之上，本期先不改选中环，河流暂时盖住它也可接受。

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
   - `RIVER_MIN_Q` / `RIVER_DENSITY`；
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
