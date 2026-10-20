# 从游戏源码的字符串字面量中提取用到过的汉字字符，去重后按 Unicode 码点排序，
# 用于 font_baker 插件的自定义字符集，烘焙只含实际所需字形的字体子集。
# 输出：assets/chinese.txt，UTF-8 无 BOM，行尾 LF，文件末尾带一个换行。
import re
import pathlib

SRC_FILES = [
    pathlib.Path("main.gd"),
    pathlib.Path("orbit_camera.gd"),
    pathlib.Path("planet.gd"),
    pathlib.Path("tile_hud.gd"),
    pathlib.Path("world_menu.gd"),
    pathlib.Path("Main.tscn"),
    pathlib.Path("planet.tscn"),
    pathlib.Path("project.godot"),
    pathlib.Path("export_presets.cfg"),
]

# CJK 统一表意文字（汉字本体）
CJK = re.compile(r"[\u4E00-\u9FFF]")
# 全角中文标点（排版同样需要；不含全角空格，后面单独剔除）
CJK_PUNCT = re.compile(r"[\u3001\u3002\u300A\u300B\u300C\u300D\uFF01\uFF08\uFF09\uFF0C\uFF1A\uFF1B\uFF1F\uFF05]")


def strip_comment(line: str) -> str:
    """去掉行内 # 注释（源文件不含 # 在字符串里出现的情况，保守起见按引号外处理）。"""
    out = []
    in_str = False
    for ch in line:
        if ch == '"':
            in_str = not in_str
        if ch == "#" and not in_str:
            break
        out.append(ch)
    return "".join(out)


str_re = re.compile(r'"((?:[^"\\]|\\.)*)"')

cjk, punct = set(), set()
for path in SRC_FILES:
    if not path.exists():
        continue
    for line in path.read_text(encoding="utf-8").splitlines():
        code = strip_comment(line)
        for m in str_re.finditer(code):
            text = m.group(1)
            cjk.update(CJK.findall(text))
            punct.update(CJK_PUNCT.findall(text))

# 全角空格等空白一律不要
cjk.discard("\u3000")
punct.discard("\u3000")
# 度符号：HUD 经纬度要用（U+00B0，不在 CJK 区，单独保留）
extra = set()
for path in SRC_FILES:
    if not path.exists():
        continue
    for line in path.read_text(encoding="utf-8").splitlines():
        code = strip_comment(line)
        for m in str_re.finditer(code):
            for ch in m.group(1):
                if ch == "\u00b0":
                    extra.add(ch)

result = "".join(sorted(cjk)) + "".join(sorted(punct)) + "".join(sorted(extra))
out = pathlib.Path("assets/chinese.txt")
out.parent.mkdir(parents=True, exist_ok=True)
out.write_bytes((result + "\n").encode("utf-8"))

print(f"汉字 {len(cjk)} 个，标点 {len(punct)} 个，共 {len(result)} 字符 -> {out}")
