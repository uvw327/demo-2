// 校验 assets/chinese.txt 与 ASCII 可打印字符都已烘焙进 assets/font/glyphs.tres，
// 防止菜单里出现豆腐块（缺字形）。脚本仅对照 .tres 文本中的 cache 字形键。
const fs = require("fs");
const path = require("path");

const tres = fs.readFileSync(path.join(process.cwd(), "assets", "font", "glyphs.tres"), "utf8");
const chars = fs.readFileSync(path.join(process.cwd(), "assets", "chinese.txt"), "utf8").trim();

const targets = [...chars];
// 菜单还会用到 ASCII 数字与字母（SpinBox 种子、30%/50% 选项等）
for (let c = 0x20; c <= 0x7e; c++) targets.push(String.fromCodePoint(c));

const missing = [];
for (const ch of targets) {
  const cp = ch.codePointAt(0);
  const re = new RegExp(`cache/0/48/0/glyphs/${cp}/`);
  if (!re.test(tres)) missing.push(`${ch} U+${cp.toString(16).toUpperCase()}`);
}

if (missing.length === 0) {
  console.log(`通过：${targets.length} 个字符在 glyphs.tres 中均有烘焙字形。`);
} else {
  console.log(`缺失 ${missing.length} 个字形，需要重新烘焙：`);
  missing.forEach((m) => console.log("  " + m));
  process.exitCode = 1;
}
