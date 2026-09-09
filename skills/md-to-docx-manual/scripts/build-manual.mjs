#!/usr/bin/env node
// 複数の Markdown を 1 本にまとめ、画像込みの docx を生成する。
// 依存: pandoc（Node は標準モジュールのみ）

import { readFileSync, writeFileSync, mkdtempSync, existsSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join, dirname, resolve, basename, extname } from "node:path";

const args = process.argv.slice(2);
const opts = { title: null, out: null, referenceDoc: null, chapters: false, files: [] };

for (let i = 0; i < args.length; i++) {
  const a = args[i];
  if (a === "--title" || a === "-t") opts.title = args[++i];
  else if (a === "--out" || a === "-o") opts.out = args[++i];
  else if (a === "--reference-doc" || a === "-r") opts.referenceDoc = args[++i];
  else if (a === "--chapters" || a === "-c") opts.chapters = true;
  else if (a === "--help" || a === "-h") { usage(); process.exit(0); }
  else if (a.startsWith("-")) { console.error(`unknown option: ${a}`); usage(); process.exit(1); }
  else opts.files.push(a);
}

function usage() {
  console.log(`usage: build-manual.mjs -t "タイトル" [options] <file1.md> <file2.md> ...

  -t, --title <s>          ドキュメントのタイトル（必須）
  -o, --out <path>         出力先 docx（既定: ./<タイトル>.docx）
  -r, --reference-doc <p>  スタイル指定用の reference docx
  -c, --chapters           各ファイルを1章として扱う（見出しを1段下げ、章見出しを挿入）
`);
}

if (!opts.title || opts.files.length === 0) { usage(); process.exit(1); }

const outPath = resolve(opts.out ?? `${opts.title}.docx`);
const warnings = [];

// --- Markdown を1本に結合する ------------------------------------------------

const FENCE = /^\s{0,3}(`{3,}|~{3,})/;
const IMG_MD = /(!\[[^\]]*\]\()([^)\s]+)((?:\s+"[^"]*")?\))/g;
// docx 書き出しでは生 HTML が捨てられるので、img タグは Markdown 記法に変換してから渡す
const IMG_HTML = /<img\b[^>]*?>/gi;
const ATTR = (name, tag) => (tag.match(new RegExp(`\\b${name}=["']([^"']*)["']`, "i")) ?? [])[1];

// 外部参照・データURI・絶対パスは触らない。それ以外は md のある場所を基準に解決する。
const isExternal = (u) => /^(https?:|data:|mailto:|#|\/)/i.test(u);

// 解決できたら絶対パス、リンク切れなら null を返す。
// null をそのまま pandoc に渡すと変換ごと失敗するので、呼び出し側でプレースホルダに置き換える。
function resolveAsset(url, baseDir) {
  if (isExternal(url)) return url;
  const clean = decodeURI(url.split("#")[0]);
  const abs = resolve(baseDir, clean);
  if (!existsSync(abs)) {
    warnings.push(`画像が見つかりません: ${url}（参照元: ${baseDir}）`);
    return null;
  }
  return abs;
}

const placeholder = (url) => `**⚠ 画像が見つかりません: \`${url}\`**`;

// 章見出しは元の H1 を流用する。流用した行は本文から取り除き、見出しが二重にならないようにする。
function chapterTitle(lines, file) {
  const i = lines.findIndex((l) => /^#\s+\S/.test(l));
  if (i === -1) return { title: basename(file, extname(file)), skipLine: -1 };
  return { title: lines[i].replace(/^#\s+/, "").trim(), skipLine: i };
}

const chunks = [];

for (const file of opts.files) {
  const abs = resolve(file);
  if (!existsSync(abs)) { console.error(`ファイルがありません: ${file}`); process.exit(1); }

  const baseDir = dirname(abs);
  const lines = readFileSync(abs, "utf8").split("\n");
  const out = [];
  let fence = null;

  let skipLine = -1;
  let demote = false;
  if (opts.chapters) {
    const ch = chapterTitle(lines, abs);
    skipLine = ch.skipLine;
    // H1 を章見出しに転用できた場合、以降の ## は章の直下として正しい階層なので触らない。
    // H1 が無くファイル名から章を作った場合だけ、全体を 1 段下げる。
    demote = skipLine === -1;
    out.push(`# ${ch.title}`, "");
  }

  for (const [index, line] of lines.entries()) {
    if (index === skipLine) continue;

    // フェンス内はコードなので一切書き換えない（`# comment` を見出しと誤認しないため）
    const m = line.match(FENCE);
    if (m) {
      if (!fence) {
        fence = m[1][0];
        if (/^\s*(`{3,}|~{3,})\s*mermaid\b/i.test(line)) {
          warnings.push(`Mermaid ブロックがあります（${basename(abs)}）— PNG 化しないとコードのまま出力されます`);
        }
      } else if (line.trimStart().startsWith(fence)) {
        fence = null;
      }
      out.push(line);
      continue;
    }
    if (fence) { out.push(line); continue; }

    let s = line;
    s = s.replace(IMG_MD, (whole, pre, url, post) => {
      const r = resolveAsset(url, baseDir);
      return r === null ? placeholder(url) : pre + r + post;
    });
    s = s.replace(IMG_HTML, (tag) => {
      const url = ATTR("src", tag);
      if (!url) return tag;
      const r = resolveAsset(url, baseDir);
      if (r === null) return placeholder(url);
      const alt = ATTR("alt", tag) ?? "";
      const width = ATTR("width", tag);
      return `![${alt}](${r})${width ? `{width=${/^\d+$/.test(width) ? width + "px" : width}}` : ""}`;
    });

    // --chapters 時は元の見出しを1段下げて、章見出しの下にぶら下げる
    if (demote) s = s.replace(/^(#{1,5})(\s+\S)/, "#$1$2");

    out.push(s);
  }

  chunks.push(out.join("\n").replace(/\s+$/, ""));
}

const work = mkdtempSync(join(tmpdir(), "md-manual-"));
const merged = join(work, "merged.md");
writeFileSync(merged, chunks.join("\n\n") + "\n", "utf8");

// --- docx へ変換 -------------------------------------------------------------

const pandocArgs = [
  merged,
  "--from", "gfm",
  "--to", "docx",
  "--output", outPath,
  "--metadata", `title=${opts.title}`,
];
if (opts.referenceDoc) pandocArgs.push("--reference-doc", resolve(opts.referenceDoc));

try {
  execFileSync("pandoc", pandocArgs, { stdio: ["ignore", "inherit", "inherit"] });
} catch (e) {
  console.error("pandoc の実行に失敗しました。インストール状況を確認してください。");
  process.exit(1);
}

for (const w of [...new Set(warnings)]) console.warn(`warn: ${w}`);
console.log(`\n生成しました: ${outPath}`);
console.log(`結合後の Markdown: ${merged}（確認用）`);
