// 从游戏源码的字符串字面量中提取用到过的汉字字符，去重后按 Unicode 码点排序，
// 用于 font_baker 插件的自定义字符集，烘焙只含实际所需字形的字体子集。
// 输出：assets/chinese.txt，UTF-8 无 BOM，行尾 LF，文件末尾带一个换行。
const fs = require("fs");
const path = require("path");

const SRC_FILES = [
  "main.gd",
  "orbit_camera.gd",
  "planet.gd",
  "world_menu.gd",
  "Main.tscn",
  "planet.tscn",
  "project.godot",
  "export_presets.cfg",
];

// CJK 统一表意文字（汉字本体）
const CJK = /[\u4E00-\u9FFF]/g;
// 全角中文标点（排版同样需要）
const CJK_PUNCT = /[\u3001\u3002\u300A\u300B\u300C\u300D\uFF01\uFF08\uFF09\uFF0C\uFF1A\uFF1B\uFF1F\uFF05]/g;
const FULLWIDTH_SPACE = "\u3000";

// 去掉行内 # 注释（# 在字符串字面量内部时不截断）
function stripComment(line) {
  let out = "";
  let inStr = false;
  for (const ch of line) {
    if (ch === '"') inStr = !inStr;
    if (ch === "#" && !inStr) break;
    out += ch;
  }
  return out;
}

const cjk = new Set();
const punct = new Set();

for (const name of SRC_FILES) {
  const p = path.join(process.cwd(), name);
  if (!fs.existsSync(p)) continue;
  const lines = fs.readFileSync(p, "utf-8").split(/\r?\n/);
  for (const line of lines) {
    const code = stripComment(line);
    const strRe = /"((?:[^"\\]|\\.)*)"/g;
    let m;
    while ((m = strRe.exec(code)) !== null) {
      const text = m[1];
      for (const c of text.match(CJK) || []) cjk.add(c);
      for (const c of text.match(CJK_PUNCT) || []) punct.add(c);
    }
  }
}

cjk.delete(FULLWIDTH_SPACE);
punct.delete(FULLWIDTH_SPACE);

const result =
  [...cjk].sort().join("") +
  [...punct].sort().join("") +
  "\n";

const out = path.join(process.cwd(), "assets", "chinese.txt");
fs.mkdirSync(path.dirname(out), { recursive: true });
// 用 writeFileSync('utf8') 即无 BOM 的 UTF-8；显式用 '\n' 保证 LF 行尾
fs.writeFileSync(out, result, "utf8");

console.log(
  `汉字 ${cjk.size} 个，标点 ${punct.size} 个，共 ${cjk.size + punct.size} 字符 -> ${out}`
);
