# 字体子集工具

用 `uv` 管理依赖，从 **思源黑体 Source Han Sans SC Regular** 裁剪出 3500 个一级常用字，供 Godot 小游戏作为动态字体使用。

## 快速开始

```powershell
cd tools/font_subset
uv run font-subset --download
```

默认行为：

- 源字体下载到 `.cache/SourceHanSansSC-Regular.otf`，并校验 SHA256；
- 输出 `assets/font/game-ui-han-sans-3500.otf`；
- 生成 `assets/font/game-ui-han-sans-3500.charset.txt`；
- 生成 `assets/font/game-ui-han-sans-3500.report.json`；
- 复制 `LICENSE-SourceHanSans.txt` 到 `assets/font/`。

常用参数：

```powershell
# 换输出路径（相对路径按 Godot 工程根目录解析）
uv run font-subset --download --output assets/font/ui_font.otf

# 指定本地源字体
uv run font-subset --source-font D:\fonts\SourceHanSansSC-Regular.otf

# 把工程内实际用字也加入字符集
uv run font-subset --download --scan

# 额外指定文本文件（这些字符是必选，缺失会报错）
uv run font-subset --download --extra-text assets\story.txt
```

## 本次生成结果

在当前工程中执行 `uv run font-subset --download` 的结果：

- 输出字体：`assets/font/game-ui-han-sans-3500.otf`
- 字体文件：801,416 B
- deflate 压缩后：约 694,238 B
- Godot 导入后的 `.fontdata`：约 723,413 B
- 字形数：4,035，cmap 条目：4,042
- 必选字符缺失：0

## 字符集

- `data/level-1.txt`：3500 个一级常用字；
- ASCII 可打印字符；
- 中文标点、全角字符、常用符号；
- 自动读取 `assets/chinese.txt`；
- 加 `--scan` 时扫描工程内的 `.gd`、`.tscn`、`.json` 等文本。

必选字符缺失会直接失败；可选标点缺失只提示。`--scan` 扫到的字符按可选项处理，避免注释里的 emoji 阻断生成；`assets/chinese.txt` 和 `--extra-text` 指定的字符则是必选项。

## 为什么字体内部名不是“思源黑体”

思源黑体的 SIL OFL 1.1 许可证包含保留字体名 **“Source”**。对字体做子集属于修改版，修改版不能继续使用保留名，因此脚本默认把内部名称改为：

- 英文：`Game UI Han Sans`
- 中文：`游戏界面黑体`

文件名和内部名可以改，但请保留 `LICENSE-SourceHanSans.txt`，并在游戏关于页或第三方许可页说明字体来源。

## Godot 导入设置

导入后保持动态字体，不要开启 MSDF：

- `multichannel_signed_distance_field=false`
- `compress=true`
- 如果希望缺字时固定显示方框、不依赖平台字体，可把 `allow_system_fallback` 设为 `false`

然后在脚本里把原来的 `glyphs.tres` 替换成新字体：

```gdscript
const UI_FONT := preload("res://assets/font/game-ui-han-sans-3500.otf")
```

注意：本工具只生成字体，不会自动修改 `world_menu.gd`、`tile_hud.gd` 或导出过滤。切换前旧 `glyphs.tres` 仍在使用。

## 源字体

- 项目：<https://github.com/adobe-fonts/source-han-sans>
- 版本：`2.005R`
- 文件：`OTF/SimplifiedChinese/SourceHanSansSC-Regular.otf`
- 许可证：SIL Open Font License 1.1
- SHA256：`f1d8611151880c6c336aabeac4640ef434fa13cbfbf1ffe82d0a71b2a5637256`

## 数据来源

`data/level-1.txt` 来自《通用规范汉字表》一级字表（3500 字）：

<https://github.com/shengdoushi/common-standard-chinese-characters-table>

该表是中华人民共和国教育部、国家语言文字工作委员会发布的规范字表，本项目只使用其中的字表数据。
