from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
import urllib.request
import zlib
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable

from fontTools import subset

# 固定使用 Source Han Sans 2.005R，避免上游分支变化导致产物不可复现。
SOURCE_FONT_URL = (
    "https://cdn.jsdelivr.net/gh/adobe-fonts/source-han-sans@2.005R/"
    "OTF/SimplifiedChinese/SourceHanSansSC-Regular.otf"
)
SOURCE_FONT_SHA256 = "f1d8611151880c6c336aabeac4640ef434fa13cbfbf1ffe82d0a71b2a5637256"

# 思源黑体的 OFL 协议包含保留字体名 “Source”。
# 子集属于修改版，必须换一个不含保留名的内部字体名。
DEFAULT_FONT_FAMILY = "Game UI Han Sans"
DEFAULT_FONT_FAMILY_ZH = "游戏界面黑体"
DEFAULT_OUTPUT_NAME = "game-ui-han-sans-3500.otf"

# 这些是正文一定会用到的字符，缺失时直接报错。
ASCII_RANGE = (0x20, 0x7E)
EXTRA_REQUIRED_SYMBOLS = "×÷±°℃€£¥©®™№§¶•…—–“”‘’【】《》「」『』〈〉〔〕"
EXTRA_OPTIONAL_SYMBOLS = "★☆♥♡♦♣♠♤●○◎◇◆□■△▲▽▼→←↑↓↔↕※"

# 这些是常见标点和符号，字体没有时只警告，不影响 3500 个常用字。
OPTIONAL_RANGES = (
    (0x00A0, 0x00FF),  # Latin-1 补充
    (0x2010, 0x2027),  # 连字符、引号、项目符号、省略号
    (0x2030, 0x205E),  # 千分号、角分符、角括号等
    (0x2190, 0x2193),  # 四个方向箭头
    (0x3000, 0x303F),  # 中文标点
    (0xFF00, 0xFFEF),  # 全角字符
)

SCAN_SUFFIXES = {".gd", ".tscn", ".tres", ".json", ".csv", ".txt", ".md", ".cfg", ".godot"}
SCAN_SKIP_DIRS = {".git", ".godot", ".cache", ".venv", "__pycache__", "addons", "tests", "tools"}


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="从思源黑体 Source Han Sans SC Regular 裁剪 3500 常用字子集。",
    )
    parser.add_argument(
        "--project-root",
        type=Path,
        help="Godot 工程根目录，默认从当前目录向上查找 project.godot。",
    )
    parser.add_argument(
        "--source-font",
        type=Path,
        help="源字体 .otf 路径。默认使用 .cache/SourceHanSansSC-Regular.otf。",
    )
    parser.add_argument(
        "--download",
        action="store_true",
        help="源字体不存在时，从固定 URL 下载并校验 SHA256。",
    )
    parser.add_argument(
        "--output",
        type=Path,
        help=f"输出字体路径，默认 assets/font/{DEFAULT_OUTPUT_NAME}。",
    )
    parser.add_argument(
        "--report",
        type=Path,
        help="体积与字符覆盖报告路径，默认与输出字体同名 .report.json。",
    )
    parser.add_argument(
        "--charset",
        type=Path,
        help="完整字符集清单输出路径，默认与输出字体同名 .charset.txt。",
    )
    parser.add_argument(
        "--common-count",
        type=int,
        default=3500,
        help="从一级常用字表取前多少个字，默认 3500。",
    )
    parser.add_argument(
        "--extra-text",
        type=Path,
        action="append",
        default=[],
        help="额外读取的文本文件，可重复指定；assets/chinese.txt 会自动读取。",
    )
    parser.add_argument(
        "--scan",
        action="store_true",
        help="扫描工程内 .gd/.tscn/.json 等文本，把游戏实际用字加入字符集。",
    )
    parser.add_argument(
        "--font-family",
        default=DEFAULT_FONT_FAMILY,
        help=f"子集内部英文字体名，默认 {DEFAULT_FONT_FAMILY!r}。",
    )
    parser.add_argument(
        "--font-family-zh",
        default=DEFAULT_FONT_FAMILY_ZH,
        help=f"子集内部中文字体名，默认 {DEFAULT_FONT_FAMILY_ZH!r}。",
    )
    parser.add_argument(
        "--no-legal-copy",
        action="store_true",
        help="不复制 OFL 许可证和字体说明到输出目录。",
    )
    return parser.parse_args(argv)


def find_project_root(explicit: Path | None) -> Path:
    if explicit is not None:
        root = explicit.resolve()
        if not (root / "project.godot").exists():
            raise SystemExit(f"错误：{root} 下没有 project.godot")
        return root

    current = Path.cwd().resolve()
    for candidate in (current, *current.parents):
        if (candidate / "project.godot").exists():
            return candidate

    # 允许从工具目录外的任意位置运行，此时使用当前目录。
    return current


def tool_root() -> Path:
    return Path(__file__).resolve().parents[2]


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def deflate_size(data: bytes) -> int:
    compressor = zlib.compressobj(9, zlib.DEFLATED, -15)
    return len(compressor.compress(data) + compressor.flush())


def ensure_source_font(args: argparse.Namespace, project_root: Path) -> Path:
    if args.source_font is not None:
        source = args.source_font.resolve()
        if not source.exists():
            raise SystemExit(f"错误：源字体不存在：{source}")
        return source

    source = tool_root() / ".cache" / "SourceHanSansSC-Regular.otf"
    if source.exists():
        return source

    if not args.download:
        raise SystemExit(
            "错误：未找到源字体。请加 --download，或用 --source-font 指定 "
            "SourceHanSansSC-Regular.otf。"
        )

    source.parent.mkdir(parents=True, exist_ok=True)
    print(f"下载源字体：{SOURCE_FONT_URL}")
    try:
        urllib.request.urlretrieve(SOURCE_FONT_URL, source)
    except Exception as exc:  # noqa: BLE001 - 需要把网络错误转成可读提示
        raise SystemExit(f"错误：下载源字体失败：{exc}") from exc

    actual = sha256_file(source)
    if actual != SOURCE_FONT_SHA256:
        source.unlink(missing_ok=True)
        raise SystemExit(
            "错误：源字体 SHA256 校验失败。\n"
            f"期望：{SOURCE_FONT_SHA256}\n实际：{actual}"
        )
    return source


def read_common_chars(path: Path, count: int) -> list[str]:
    if not path.exists():
        raise SystemExit(f"错误：找不到常用字表：{path}")
    text = path.read_text(encoding="utf-8-sig")
    chars = [char for char in text if not char.isspace()]
    if len(chars) < count:
        raise SystemExit(f"错误：常用字表只有 {len(chars)} 个字，少于要求的 {count}")
    return chars[:count]


def read_extra_text_files(
    project_root: Path,
    args: argparse.Namespace,
) -> tuple[str, str]:
    required_parts: list[str] = []
    scanned_parts: list[str] = []

    auto_chinese = project_root / "assets" / "chinese.txt"
    if auto_chinese.exists():
        required_parts.append(auto_chinese.read_text(encoding="utf-8-sig"))

    for extra in args.extra_text:
        path = extra if extra.is_absolute() else project_root / extra
        if not path.exists():
            raise SystemExit(f"错误：额外文本不存在：{path}")
        required_parts.append(path.read_text(encoding="utf-8-sig"))

    if args.scan:
        for path in project_root.rglob("*"):
            if not path.is_file() or path.suffix.lower() not in SCAN_SUFFIXES:
                continue
            if any(part in SCAN_SKIP_DIRS for part in path.parts):
                continue
            # 跳过生成物和字体目录，避免把旧 MSDF 字体或构建产物扫进来。
            if "assets" in path.parts and "font" in path.parts:
                continue
            try:
                scanned_parts.append(path.read_text(encoding="utf-8-sig"))
            except UnicodeDecodeError:
                continue

    return "".join(required_parts), "".join(scanned_parts)


def codepoints_from_text(text: str) -> set[int]:
    return {ord(char) for char in text if not char.isspace()}


def range_codepoints(start: int, end: int) -> set[int]:
    return set(range(start, end + 1))


def collect_codepoints(
    common_chars: Iterable[str],
    extra_text: str,
    scanned_text: str,
) -> tuple[set[int], set[int]]:
    required = {ord(char) for char in common_chars}
    required.update(range_codepoints(*ASCII_RANGE))
    required.update(ord(char) for char in EXTRA_REQUIRED_SYMBOLS)
    required.update(codepoints_from_text(extra_text))

    optional: set[int] = set(ord(char) for char in EXTRA_OPTIONAL_SYMBOLS)
    for start, end in OPTIONAL_RANGES:
        optional.update(range_codepoints(start, end))
    # --scan 会扫到注释里的 emoji 等字符，这些只作为可选项，不阻塞生成。
    optional.update(codepoints_from_text(scanned_text))
    optional -= required

    return required, optional


def write_charset(path: Path, codepoints: set[int]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    text = "".join(chr(codepoint) for codepoint in sorted(codepoints))
    path.write_text(text, encoding="utf-8")


def set_name_record(font, name_id: int, english: str, chinese: str | None = None) -> None:
    for record in font["name"].names:
        if record.nameID != name_id:
            continue
        value = chinese if chinese is not None and record.langID == 0x0804 else english
        record.string = value.encode(record.getEncoding())


def rename_font(font, family: str, family_zh: str) -> None:
    """按 OFL 保留字体名要求，把修改版改成新的内部字体名。"""
    set_name_record(font, 1, family, family_zh)
    set_name_record(font, 2, "Regular", "常规")
    set_name_record(font, 3, f"1.000;GAME;{family.replace(' ', '')}-Regular;SUBSET")
    set_name_record(font, 4, f"{family} Regular", f"{family_zh} 常规")
    set_name_record(font, 5, "Version 1.000; subset")
    set_name_record(font, 6, f"{family.replace(' ', '')}-Regular")

    # 子集化后中文字体名可能被丢弃，这里补回 2052 中文记录。
    font["name"].setName(family_zh, 1, 3, 1, 0x0804)
    font["name"].setName("常规", 2, 3, 1, 0x0804)
    font["name"].setName(f"{family_zh} 常规", 4, 3, 1, 0x0804)

    # CFF 字体还会在 CFF 表里保存 PostScript 名称，必须同步改掉。
    if "CFF " in font:
        cff = font["CFF "].cff
        cff.fontNames[0] = f"{family.replace(' ', '')}-Regular"
        top = cff.topDictIndex[0]
        top.FullName = f"{family} Regular"
        top.FamilyName = family
        top.Weight = "Regular"

    font["head"].fontRevision = 1.0


def subset_font(
    source: Path,
    output: Path,
    codepoints: set[int],
    family: str,
    family_zh: str,
) -> dict:
    options = subset.Options()
    options.layout_features = ["kern"]
    options.name_IDs = [0, 1, 2, 3, 4, 5, 6, 13, 14]
    options.drop_tables = sorted(set(options.drop_tables) | {"DSIG"})
    options.hinting = False
    options.notdef_glyph = True
    options.recommended_glyphs = False
    options.prune_unicode_ranges = True
    options.recalc_timestamp = False

    font = subset.load_font(str(source), options)
    subsetter = subset.Subsetter(options=options)
    subsetter.populate(unicodes=sorted(codepoints))
    subsetter.subset(font)

    rename_font(font, family, family_zh)

    cmap = font.getBestCmap() or {}
    missing = sorted(codepoints - set(cmap))

    output.parent.mkdir(parents=True, exist_ok=True)
    subset.save_font(font, str(output), options)

    glyph_count = len(font.getGlyphOrder())
    font.close()
    return {
        "glyphs": glyph_count,
        "cmap": len(cmap),
        "missing": missing,
    }


def display_path(path: Path, project_root: Path) -> str:
    try:
        return path.resolve().relative_to(project_root.resolve()).as_posix()
    except ValueError:
        return str(path.resolve())


def make_report(
    source: Path,
    output: Path,
    charset: Path,
    required: set[int],
    optional: set[int],
    codepoints: set[int],
    subset_info: dict,
    family: str,
    project_root: Path,
) -> dict:
    output_bytes = output.read_bytes()
    source_bytes = source.stat().st_size
    cjk_required = {
        codepoint
        for codepoint in required
        if 0x3400 <= codepoint <= 0x4DBF or 0x4E00 <= codepoint <= 0x9FFF
    }
    missing_required = sorted(set(subset_info["missing"]) & required)
    missing_optional = sorted(set(subset_info["missing"]) & optional)

    return {
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "source": {
            "path": display_path(source, project_root),
            "bytes": source_bytes,
            "sha256": sha256_file(source),
        },
        "output": {
            "path": display_path(output, project_root),
            "bytes": len(output_bytes),
            "deflateBytes": deflate_size(output_bytes),
            "sha256": sha256_file(output),
        },
        "font": {
            "family": family,
            "style": "Regular",
            "glyphs": subset_info["glyphs"],
            "cmap": subset_info["cmap"],
        },
        "charset": {
            "path": display_path(charset, project_root),
            "required": len(required),
            "optional": len(optional),
            "requested": len(codepoints),
            "cjkRequired": len(cjk_required),
        },
        "missingRequired": [f"U+{codepoint:04X}" for codepoint in missing_required],
        "missingOptional": [f"U+{codepoint:04X}" for codepoint in missing_optional],
    }


def copy_legal_files(output: Path) -> None:
    for name in ("LICENSE-SourceHanSans.txt", "NOTICE.md"):
        source = tool_root() / "data" / name
        if not source.exists():
            print(f"警告：找不到 {name}，未复制。", file=sys.stderr)
            continue
        destination = output.parent / name
        shutil.copyfile(source, destination)
        print(f"法律文件：{destination}")


def main(argv: list[str] | None = None) -> None:
    args = parse_args(argv)
    project_root = find_project_root(args.project_root)
    source = ensure_source_font(args, project_root)

    output = args.output or project_root / "assets" / "font" / DEFAULT_OUTPUT_NAME
    output = output if output.is_absolute() else project_root / output
    report_path = args.report or output.with_suffix(".report.json")
    report_path = report_path if report_path.is_absolute() else project_root / report_path
    charset_path = args.charset or output.with_suffix(".charset.txt")
    charset_path = charset_path if charset_path.is_absolute() else project_root / charset_path

    common_path = tool_root() / "data" / "level-1.txt"
    common_chars = read_common_chars(common_path, args.common_count)
    extra_text, scanned_text = read_extra_text_files(project_root, args)
    required, optional = collect_codepoints(common_chars, extra_text, scanned_text)
    codepoints = required | optional

    print(f"工程根目录：{project_root}")
    print(f"源字体：{source}（{source.stat().st_size:,} B）")
    print(
        f"字符集：常用字 {len(common_chars)}，必选 {len(required)}，"
        f"可选 {len(optional)}，合计 {len(codepoints)}"
    )

    subset_info = subset_font(
        source=source,
        output=output,
        codepoints=codepoints,
        family=args.font_family,
        family_zh=args.font_family_zh,
    )

    missing_required = sorted(set(subset_info["missing"]) & required)
    if missing_required:
        chars = "".join(chr(codepoint) for codepoint in missing_required[:100])
        raise SystemExit(
            f"错误：子集缺少 {len(missing_required)} 个必选字符：{chars}"
        )

    write_charset(charset_path, codepoints)
    report = make_report(
        source=source,
        output=output,
        charset=charset_path,
        required=required,
        optional=optional,
        codepoints=codepoints,
        subset_info=subset_info,
        family=args.font_family,
        project_root=project_root,
    )
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    if not args.no_legal_copy:
        copy_legal_files(output)

    print(f"输出字体：{output}")
    print(
        f"体积：{report['output']['bytes']:,} B，"
        f"deflate 后约 {report['output']['deflateBytes']:,} B"
    )
    print(f"字形数：{report['font']['glyphs']}，cmap：{report['font']['cmap']}")
    print(f"字符集清单：{charset_path}")
    print(f"报告：{report_path}")
    if report["missingOptional"]:
        print(f"提示：可选字符中有 {len(report['missingOptional'])} 个字体未覆盖。")


if __name__ == "__main__":
    main()
