// Картинки в контексте модели: сколько они стоят и какие из них отправлять.
// Скриншоты хранятся в истории (memory.sqlite) целиком и раньше уходили модели в КАЖДОМ запросе,
// пока разговор не сожмётся. Теперь перед запросом (хук beforeRequest) настоящие картинки остаются
// только в последних IMAGE_KEEP сообщениях с картинками, в более старых — пометка с полным путём к файлу.
// Сама история не меняется — только то, что уходит модели.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

// Сколько последних сообщений с картинками отправлять модели с самими картинками (PIA_IMAGE_KEEP — переопределить)
export const IMAGE_KEEP = Math.max(1, Number(process.env.PIA_IMAGE_KEEP) || 3);
// «Ступенька»: старые картинки убираются пачками по IMAGE_STEP, чтобы начало запроса (кэш подсказок)
// менялось не на каждом ходу, а раз в IMAGE_STEP новых сообщений с картинками
export const IMAGE_STEP = Math.max(1, Number(process.env.PIA_IMAGE_STEP) || 3);
export const IMAGE_FALLBACK_TOKENS = 800;   // размер картинки не прочитался

const EXT = "png|jpe?g|gif|webp|heic|heif|tiff?|bmp";
// «[картинка 1] (имя или полный путь)» — так картинка подписана в тексте сообщения для модели
const LABEL_RE = new RegExp(String.raw`\[картинка (\d+)\] \(([^\n]+?\.(?:${EXT}))\)`, "gi");
const home = (p) => (p.startsWith("~/") ? path.join(os.homedir(), p.slice(2)) : p);

// ── Размер картинки по заголовку (без декодирования): PNG, JPEG, GIF, WebP → { w, h } | null ──
export function imageSize(b) {
  if (!b || b.length < 24) return null;
  if (b.readUInt32BE(0) === 0x89504e47 && b.toString("ascii", 12, 16) === "IHDR") return { w: b.readUInt32BE(16), h: b.readUInt32BE(20) };
  if (b.toString("ascii", 0, 3) === "GIF") return { w: b.readUInt16LE(6), h: b.readUInt16LE(8) };
  if (b.toString("ascii", 0, 4) === "RIFF" && b.toString("ascii", 8, 12) === "WEBP" && b.length >= 30) {
    const kind = b.toString("ascii", 12, 16);
    if (kind === "VP8 ") return { w: b.readUInt16LE(26) & 0x3fff, h: b.readUInt16LE(28) & 0x3fff };
    if (kind === "VP8L") return { w: 1 + (((b[22] & 0x3f) << 8) | b[21]), h: 1 + (((b[24] & 0x0f) << 10) | (b[23] << 2) | ((b[22] & 0xc0) >> 6)) };
    if (kind === "VP8X") return { w: 1 + b.readUIntLE(24, 3), h: 1 + b.readUIntLE(27, 3) };
    return null;
  }
  if (b[0] === 0xff && b[1] === 0xd8) {
    let i = 2;
    while (i + 9 < b.length) {
      if (b[i] !== 0xff) { i++; continue; }
      const m = b[i + 1];
      if (m === 0xff) { i++; continue; }
      if (m === 0xd8 || m === 0x01 || (m >= 0xd0 && m <= 0xd7)) { i += 2; continue; }
      const len = b.readUInt16BE(i + 2);
      if (m >= 0xc0 && m <= 0xcf && m !== 0xc4 && m !== 0xc8 && m !== 0xcc) return { w: b.readUInt16BE(i + 7), h: b.readUInt16BE(i + 5) };
      i += 2 + len;
    }
  }
  return null;
}
// Из файла: читаем только начало (у JPEG с большими метаданными — до 32 МБ)
export function imageSizeFile(file) {
  let fd;
  try {
    fd = fs.openSync(file, "r");
    const head = Buffer.alloc(65536), n = fs.readSync(fd, head, 0, head.length, 0);
    const s = imageSize(head.subarray(0, n));
    if (s || n < head.length) return s;
    const size = fs.fstatSync(fd).size;
    if (size > 32 * 1024 * 1024) return null;
    const all = Buffer.alloc(size); fs.readSync(fd, all, 0, size, 0);
    return imageSize(all);
  } catch { return null; } finally { if (fd != null) try { fs.closeSync(fd); } catch {} }
}
// Из base64 картинки в сообщении
export function imageSizeB64(data) {
  if (typeof data !== "string" || !data) return null;
  return imageSize(Buffer.from(data.slice(0, 65536), "base64")) ?? (data.length > 65536 ? imageSize(Buffer.from(data, "base64")) : null);
}

// ── Токены картинки (документация Anthropic): ⌈w/28⌉×⌈h/28⌉; длинная сторона уменьшается до 1568 px
// и не больше 1568 токенов; у Claude 4.7 и новее — до 2576 px и 4784 токенов ──
export function imageLimits(modelId = "") {
  const m = /claude-(?:opus|sonnet|haiku)-(\d+)(?:-(\d{1,2})(?!\d))?/.exec(String(modelId)) ?? /claude-(\d+)(?:-(\d{1,2})(?!\d))?/.exec(String(modelId));
  const v = m ? Number(m[1]) + Number(m[2] ?? 0) / 10 : 0;
  return v >= 4.7 ? { side: 2576, tokens: 4784 } : { side: 1568, tokens: 1568 };
}
export function imageTokens(w, h, modelId) {
  if (!(w > 0 && h > 0)) return IMAGE_FALLBACK_TOKENS;
  const lim = imageLimits(modelId);
  const big = Math.max(w, h);
  if (big > lim.side) { const s = lim.side / big; w = Math.max(1, Math.round(w * s)); h = Math.max(1, Math.round(h * s)); }
  let t = Math.ceil(w / 28) * Math.ceil(h / 28);
  while (t > lim.tokens) {
    const s = Math.sqrt(lim.tokens / t) * 0.999;
    w = Math.max(1, Math.floor(w * s)); h = Math.max(1, Math.floor(h * s));
    t = Math.ceil(w / 28) * Math.ceil(h / 28);
  }
  return t;
}
// Блок картинки { type: "image", data } или путь к файлу → оценка токенов (не прочиталось — ~800)
export function imageTokensOf(src, modelId) {
  const s = typeof src === "string" ? imageSizeFile(src) : imageSizeB64(src?.data);
  return s ? imageTokens(s.w, s.h, modelId) : IMAGE_FALLBACK_TOKENS;
}

// ── Полный путь по имени файла (старые сообщения подписаны только именем) ──
// Ищем в ленте (feed.jsonl хранит полные пути вложений) и в папках со снимками. Новые сообщения
// подписаны полным путём — для них поиск не нужен.
export function makePathResolver({ feedFile, dirs = [] } = {}) {
  let map = null, builtAt = 0;
  const walk = (dir, depth) => {
    let list; try { list = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
    for (const d of list) {
      const p = path.join(dir, d.name);
      if (d.isDirectory()) { if (depth > 0) walk(p, depth - 1); }
      else if (new RegExp(String.raw`\.(?:${EXT})$`, "i").test(d.name)) map.set(d.name, p);
    }
  };
  const build = () => {
    map = new Map(); builtAt = Date.now();
    for (const d of dirs) walk(d, 3);
    try {
      for (const m of fs.readFileSync(feedFile, "utf8").matchAll(/"images":(\[[^\]]*\])/g)) {
        try { for (const f of JSON.parse(m[1])) if (typeof f === "string" && f.startsWith("/")) map.set(path.basename(f), f); } catch {}
      }
    } catch {}
  };
  return (name) => {
    if (!name) return null;
    name = home(String(name));
    if (name.startsWith("/")) return name;
    if (!map || (!map.has(name) && Date.now() - builtAt > 60_000)) build();
    return map.get(name) ?? null;
  };
}

// «[картинка N] (имя)» → «[картинка N] (полный путь)», если путь известен
export function resolveLabels(text, resolve) {
  if (!resolve || typeof text !== "string") return text;
  return text.replace(LABEL_RE, (all, n, name) => { const p = resolve(name); return p ? `[картинка ${n}] (${p})` : all; });
}
const labelsOf = (m) => {
  const text = typeof m.content === "string" ? m.content : (m.content ?? []).filter((b) => b?.type === "text").map((b) => b.text).join("\n");
  return [...text.matchAll(LABEL_RE)].map((x) => x[2]);
};

// Текст сообщения для пересказа при сжатии: картинки — пометками с полным путём
export function flatContent(c, resolve) {
  if (typeof c === "string") return resolveLabels(c, resolve);
  const list = c ?? [];
  const labelled = list.some((x) => x?.type === "text" && new RegExp(LABEL_RE.source, "i").test(x.text));
  return list.map((x) => x.type === "text" ? resolveLabels(x.text, resolve)
    : x.type === "toolCall" ? `[${x.name} ${JSON.stringify(x.arguments).slice(0, 200)}]`
    : x.type === "image" && !labelled ? "[картинка]" : "").join(" ");
}

// Сколько сообщений с картинками убрать: только целыми ступеньками по step сверх keep
export function dropCount(count, keep = IMAGE_KEEP, step = IMAGE_STEP) {
  const extra = count - keep;
  return extra >= step ? Math.floor(extra / step) * step : 0;
}
export const trimMarker = (where) => `[снимок убран из контекста: ${where}]`;

// Сообщения для запроса к модели → те же, но в старых сообщениях с картинками картинки заменены пометками.
// Сообщения с картинками — от пользователя и результаты инструментов (у помощников: read картинки, снимки браузера).
// Исходные объекты не меняются. Возвращает { messages, dropped (сообщений), images, removed (блоки картинок) }.
export function trimImages(messages, { keep = IMAGE_KEEP, step = IMAGE_STEP, drop: fixed, resolve, cwd = process.cwd() } = {}) {
  const withImg = [];
  messages.forEach((m, i) => {
    if ((m?.role === "user" || m?.role === "toolResult") && Array.isArray(m.content) && m.content.some((b) => b?.type === "image")) withImg.push(i);
  });
  const drop = fixed != null ? Math.min(fixed, withImg.length) : dropCount(withImg.length, keep, step);
  if (!drop) return { messages, dropped: 0, images: 0, removed: [] };
  const calls = new Map();
  for (const m of messages) if (m?.role === "assistant" && Array.isArray(m.content)) for (const b of m.content) if (b?.type === "toolCall") calls.set(b.id, b);
  const out = messages.slice(), removed = [];
  for (const i of withImg.slice(0, drop)) {
    const m = messages[i];
    let where;
    if (m.role === "user") {
      const names = labelsOf(m);
      where = (k) => { const n = names[k]; if (!n) return "картинка из сообщения, файл неизвестен"; const full = home(n); return (full.startsWith("/") ? full : resolve?.(n)) ?? `${n} (полный путь не найден)`; };
    } else {
      const call = calls.get(m.toolCallId), p = call?.arguments?.path ?? call?.arguments?.file_path;
      const name = m.toolName ?? call?.name ?? "инструмента";
      where = () => (typeof p === "string" && p ? path.resolve(cwd, home(p)) : `снимок от ${name}, файла нет`);
    }
    let k = 0;
    out[i] = { ...m, content: m.content.map((b) => {
      if (b?.type !== "image") return b;
      removed.push(b);
      return { type: "text", text: trimMarker(where(k++)) };
    }) };
  }
  return { messages: out, dropped: drop, images: removed.length, removed };
}

// Хук GenerationTask.beforeRequest (подключается в core.mjs как расширение image-trim): перед каждым запросом
// к модели — trimImages. В журнал (log) пишет строку, когда граница сдвинулась: сколько снимков убрано и ≈ токенов.
// Граница двигается, только когда кэш подсказок и так остыл (запросов в этом разговоре не было CACHE_COLD_MS)
// или сверх keep накопилось больше IMAGE_MAX_EXTRA сообщений с картинками. Иначе сдвиг меняет начало запроса и
// весь разговор (~100 тыс. токенов) пишется в кэш заново — в разы дороже, чем держать пару старых снимков в кэше.
const CACHE_COLD_MS = 4.5 * 60_000;
export const IMAGE_MAX_EXTRA = Math.max(1, Number(process.env.PIA_IMAGE_MAX_EXTRA) || 15);
export function imageTrimHook({ resolve, cwd, modelId, keep = IMAGE_KEEP, step = IMAGE_STEP, log = () => {}, onError = () => {} } = {}) {
  const logged = new Map();   // разговор → сколько сообщений убрано в последний записанный раз
  const state = new Map();    // разговор → { drop, count, at }: текущая граница и время последнего запроса
  return {
    beforeRequest: ({ messages }, api) => {
      try {
        const conv = String(api?.conversationId ?? "?"), now = Date.now();
        const count = messages.filter((m) => (m?.role === "user" || m?.role === "toolResult") && Array.isArray(m.content) && m.content.some((b) => b?.type === "image")).length;
        const prev = state.get(conv);
        const cold = !prev || count < prev.count || now - prev.at > CACHE_COLD_MS;   // нет истории, сжатие или кэш остыл
        let drop = cold ? dropCount(count, keep, step) : prev.drop;
        if (count - drop > keep + IMAGE_MAX_EXTRA) drop = dropCount(count, keep, step);
        state.set(conv, { drop, count, at: now });
        const r = trimImages(messages, { keep, step, drop, resolve, cwd });
        if (!r.dropped) { logged.delete(conv); return undefined; }
        if (logged.get(conv) !== r.dropped) {
          logged.set(conv, r.dropped);
          const saved = r.removed.reduce((a, b) => a + imageTokensOf(b, modelId), 0);
          log(`картинки (разговор ${conv}): в запросе убрано ${r.images} шт. из ${r.dropped} старых сообщений, ≈ ${saved} ток.${cold ? " (кэш остыл)" : ""}`);
        }
        return { messages: r.messages };
      } catch (e) { onError(e); return undefined; }
    },
  };
}
