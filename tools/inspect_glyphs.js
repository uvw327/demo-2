// 解剖 glyphs.tres：统计烘焙进来的字形数量与来源构成，并算出纹理原始数据量。
const fs = require("fs");
const path = require("path");

const tres = fs.readFileSync(path.join(process.cwd(), "assets", "font", "glyphs.tres"), "utf8");

// 1) 收集所有字形码点（cache/0/48/0/glyphs/<码点>/）
const codes = [...tres.matchAll(/cache\/0\/48\/0\/glyphs\/(\d+)\//g)]
  .map((m) => Number(m[1]));
const uniq = [...new Set(codes)].sort((a, b) => a - b);

// 2) 按区段分类
const groups = {
  "ASCII (U+0020-007E)": (c) => c >= 0x20 && c <= 0x7e,
  "Latin 扩展 (U+00A0-024F)": (c) => c >= 0xa0 && c <= 0x24f,
  "CJK 标点 (U+3000-303F)": (c) => c >= 0x3000 && c <= 0x303f,
  "全角英数标点 (U+FF01-FF60)": (c) => c >= 0xff01 && c <= 0xff60,
  "汉字 (U+4E00-9FFF)": (c) => c >= 0x4e00 && c <= 0x9fff,
  "其他": () => true,
};
const buckets = {};
for (const [name, fn] of Object.entries(groups)) {
  buckets[name] = uniq.filter(fn);
  if (name === "其他") buckets[name] = buckets[name].filter(
    (c) => !uniq.some((u) => groups["ASCII (U+0020-007E)"](u) && false)
  );
}
buckets["其他"] = uniq.filter((c) => !Object.entries(groups).slice(0, 5).some(([, fn]) => fn(c)));

// 3) 纹理与体积
const images = [...tres.matchAll(/"format": "(?:\w+)",\s*"height": (\d+),.*?"width": (\d+)/gs)].map(
  (m) => ({ h: Number(m[1]), w: Number(m[2]) })
);
const rawBytes = images.reduce((s, im) => s + im.h * im.w * 4, 0);

console.log(`字形总数: ${uniq.length}`);
for (const [name, list] of Object.entries(buckets)) {
  console.log(`  ${name}: ${list.length}`);
}
console.log(`图集纹理页数: ${images.length} 张`);
console.log(`纹理原始数据量: ${(rawBytes / 1048576).toFixed(2)} MB（${images.length} × ${images[0]?.w}×${images[0]?.h} RGBA8）`);

// 4) 汉字是否多于 chinese.txt（自定义文本之外多烘了哪些字）
const chinese = fs.readFileSync(path.join(process.cwd(), "assets", "chinese.txt"), "utf8").trim();
const chineseSet = new Set([...chinese].map((c) => c.codePointAt(0)));
const hanzi = buckets["汉字 (U+4E00-9FFF)"];
const extraHanzi = hanzi.filter((c) => !chineseSet.has(c));
console.log(`\nchinese.txt 汉字数: ${[...chinese].length}`);
console.log(`烘焙汉字数: ${hanzi.length}`);
console.log(`chinese.txt 之外的额外汉字 ${extraHanzi.length} 个（预览）: ` +
  (extraHanzi.slice(0, 80).map((c) => String.fromCodePoint(c)).join("")));
