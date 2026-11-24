// Картинки в сообщении: путь к файлу (перетащили в терминал, скопировали путь CleanShot)
// или «[картинка N]» из буфера обмена (Ctrl+V). Для модели уменьшаем до 1000 px по длинной стороне (sips,
// во временный файл, оригинал не трогаем): скриншот 2560×1600 → 1000×625 ≈ 828 токенов вместо ~2000–4800.
// В тексте для модели картинка подписана полным путём: «[картинка N] (/полный/путь.png)» — путь переживает
// сжатие разговора и пометку «снимок убран из контекста» (image-context.mjs).
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { imageSizeFile } from "./image-context.mjs";
const run = promisify(execFile);

const EXT = "png|jpe?g|gif|webp|heic|heif|tiff?|bmp";
// '…', "…", file://…, или путь с экранированными пробелами (\ ) — так вставляет Terminal при перетаскивании
const PATH_RE = new RegExp(String.raw`'((?:~|/)[^']+\.(?:${EXT}))'|"((?:~|/)[^"]+\.(?:${EXT}))"|(file://(?:localhost)?/[^\s'"]+?\.(?:${EXT}))(?=$|[\s,.;:!?)\]'"])|((?:~|/)(?:\\.|[^\s\\])+?\.(?:${EXT}))(?=$|[\s,.;:!?)\]])`, "gi");
const END_RE = new RegExp(String.raw`\.(?:${EXT})(?=$|[\s,.;:!?)\]'"])`, "gi");
const MAX = 1000;   // длинная сторона картинки для модели, px
const isFile = (p) => { try { return fs.statSync(p).isFile(); } catch { return false; } };
const home = (p) => (p.startsWith("~") ? path.join(os.homedir(), p.slice(1)) : p);

// Пути к картинкам в тексте: [{ match, file, index }] в порядке появления.
// Понимает '…' и "…", \ -экранирование, file://…(%20), а также путь с пробелами без экранирования
// (CleanShot: «/var/folders/…/CleanShot 2026-11-20 at 16.45.06.png»).
export function findImagePaths(text) {
  const out = [];
  for (const m of text.matchAll(PATH_RE)) {
    let p;
    if (m[3]) { try { p = decodeURIComponent(m[3].replace(/^file:\/\/(?:localhost)?/i, "")); } catch { continue; } }
    else p = home(m[1] ?? m[2] ?? m[4].replace(/\\(.)/g, "$1"));
    if (isFile(p)) out.push({ match: m[0], file: p, index: m.index });
  }
  if (text.length <= 20000) {
    const inside = (i) => out.some((o) => i >= o.index && i < o.index + o.match.length);
    let tried = 0;
    for (let i = 0; i < text.length && tried < 60; i++) {
      if (!(text[i] === "/" || (text[i] === "~" && text[i + 1] === "/"))) continue;
      if (i > 0 && !/[\s'"(]/.test(text[i - 1])) continue;
      if (inside(i)) continue;
      tried++;
      let eol = text.indexOf("\n", i); if (eol < 0) eol = text.length;
      const line = text.slice(i, eol);
      END_RE.lastIndex = 0;
      for (let e; (e = END_RE.exec(line)); ) {
        const cand = line.slice(0, e.index + e[0].length);
        if (!/\s/.test(cand)) continue;          // без пробелов уже разобрано выше
        if (isFile(home(cand))) { out.push({ match: cand, file: home(cand), index: i }); i += cand.length - 1; break; }
      }
    }
  }
  return out.sort((a, b) => a.index - b.index);
}

async function dims(file) {
  const s = imageSizeFile(file);            // PNG/JPEG/GIF/WebP — по заголовку, без sips
  if (s) return [s.w, s.h];
  const { stdout } = await run("sips", ["-g", "pixelWidth", "-g", "pixelHeight", file], { timeout: 30_000 });
  return [Number(/pixelWidth: (\d+)/.exec(stdout)?.[1] ?? 0), Number(/pixelHeight: (\d+)/.exec(stdout)?.[1] ?? 0)];
}
export async function loadImage(file) {
  const ext = path.extname(file).slice(1).toLowerCase();
  let [w, h] = await dims(file);
  const keepPng = ext === "png" || ext === "gif";
  const direct = { png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg", gif: "image/gif", webp: "image/webp" }[ext];
  const src = file, mime = direct;
  if (!direct || Math.max(w, h) > MAX) {
    const out = path.join(os.tmpdir(), `pia-img-${process.pid}-${Date.now()}-${Math.random().toString(36).slice(2, 7)}.${keepPng ? "png" : "jpg"}`);
    const a = ["-s", "format", keepPng ? "png" : "jpeg"];
    if (!keepPng) a.push("-s", "formatOptions", "85");
    if (Math.max(w, h) > MAX) a.push("-Z", String(MAX));
    try {
      await run("sips", [...a, file, "--out", out], { timeout: 30_000 });
      [w, h] = await dims(out);
      const data = fs.readFileSync(out).toString("base64");
      return { type: "image", data, mimeType: keepPng ? "image/png" : "image/jpeg", w, h };
    } finally { fs.rmSync(out, { force: true }); }
  }
  const data = fs.readFileSync(src).toString("base64");
  return { type: "image", data, mimeType: mime, w, h };
}

// Вставка целиком — один путь к картинке (как вставляет Terminal из буфера CleanShot / Finder)?
// Возвращает путь (раскрыт ~, file:// и \-экранирование сняты), даже если файла нет, иначе null.
export function imagePathOf(text) {
  let t = String(text ?? "").trim();
  if (/^'[^']*'$|^"[^"]*"$/.test(t)) t = t.slice(1, -1);
  if (/^file:\/\//i.test(t)) { try { t = decodeURIComponent(t.replace(/^file:\/\/(?:localhost)?/i, "")); } catch { return null; } }
  else t = t.replace(/\\(.)/g, "$1");
  t = home(t);
  const ends = t.match(new RegExp(String.raw`\.(?:${EXT})(?=$|\s)`, "gi")) ?? [];
  return t.startsWith("/") && !t.includes("\n") && ends.length === 1 && new RegExp(String.raw`\.(?:${EXT})$`, "i").test(t) ? t : null;
}

// Копия вставленной картинки в папку вложений: временные файлы (CleanShot удаляет снимок, когда закрывают
// его окошко) не пропадут до отправки, и фоновая служба (launchd) прочтёт файл, даже если он лежит
// в папке, куда ей нет доступа (Рабочий стол, Загрузки, Документы). Не вышло — остаётся исходный путь.
export function stashImage(file, dir) {
  try {
    const root = path.join(dir, "вставки");
    if (file.startsWith(dir + path.sep)) return file;
    const sub = path.join(root, new Date().toISOString().replace(/[:.]/g, "-") + "-" + Math.random().toString(36).slice(2, 6));
    fs.mkdirSync(sub, { recursive: true });
    const out = path.join(sub, path.basename(file));
    fs.copyFileSync(file, out);
    return out;
  } catch { return file; }
}

// Картинка из буфера обмена → файл (или null, если там не картинка).
// Если в буфере файл-картинка (CleanShot, «Скопировать» в Finder) — берём сам файл (в Finder
// вместе с ним лежит значок файла, его прикреплять нельзя); иначе — картинку (PNG) из буфера.
export async function clipboardImage(dir) {
  fs.mkdirSync(dir, { recursive: true });
  try {
    const { stdout } = await run("osascript", ["-e", "POSIX path of (the clipboard as «class furl»)"], { timeout: 5000 });
    const p = stdout.trim();
    if (p && imagePathOf(p) && isFile(p)) return p;
  } catch {}
  const file = path.join(dir, `буфер-${new Date().toISOString().replace(/[:.]/g, "-")}.png`);
  const script = `set f to open for access POSIX file ${JSON.stringify(file)} with write permission
try
  write (the clipboard as «class PNGf») to f
  close access f
on error
  close access f
  error "нет картинки"
end try`;
  try { await run("osascript", ["-e", script], { timeout: 10000 }); } catch { fs.rmSync(file, { force: true }); return null; }
  return fs.statSync(file).size > 0 ? file : (fs.rmSync(file, { force: true }), null);
}

// Текст сообщения → содержимое для модели, текст карточки и подписи к картинкам.
// Картинки нумеруются в порядке появления в тексте (и пометки «[картинка N]» из поля ввода, и пути).
export async function buildMessage(text, tokens = new Map()) {
  const found = [];
  for (const [token, file] of tokens) { const index = text.indexOf(token); if (index >= 0) found.push({ match: token, file, index }); }
  for (const f of findImagePaths(text)) if (!found.some((x) => f.index < x.index + x.match.length && x.index < f.index + f.match.length)) found.push(f);
  found.sort((a, b) => a.index - b.index);
  if (!found.length) return { content: text, card: text, notes: [], files: [] };
  let modelText = "", card = "", at = 0;
  const images = [], notes = [], files = [];   // files — пути прикреплённых картинок (для истории)
  let n = 0;
  for (const f of found) {
    n++;
    const label = `[картинка ${n}]`;
    const before = text.slice(at, f.index); at = f.index + f.match.length;
    modelText += before; card += before;
    try {
      const img = await loadImage(f.file);
      images.push(img); files.push(f.file);
      modelText += `${label} (${f.file})`; card += label;
      notes.push(`${label} ${path.basename(f.file)} · ${img.w}×${img.h}`);
    } catch (e) {
      modelText += f.match; card += f.match;
      notes.push(`${label} не открылась: ${String(e?.message ?? e).slice(0, 80)}`);
    }
  }
  modelText += text.slice(at); card += text.slice(at);
  if (!images.length) return { content: text, card, notes, files };
  return { content: [{ type: "text", text: modelText }, ...images.map(({ type, data, mimeType }) => ({ type, data, mimeType }))], card, notes, files };
}
