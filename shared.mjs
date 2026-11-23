// Общие части: доступ к моделям (провайдер и модели ролей — providers.mjs), папки, инструменты
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFile, spawn } from "node:child_process";
import { promisify } from "node:util";
import { loadRoles, buildModels, ref } from "./providers.mjs";
import { obj, str, num, opt } from "@earendil-works/pi-schema";
import { defineTool, defineExtension, section } from "@earendil-works/pi-durable";
import { createReadTool, createWriteTool, createEditTool, createBashTool } from "@earendil-works/pi-durable/tools";
import { LIMITS, clampSec, guardTool } from "./guard.mjs";

const run = promisify(execFile);
export const HOME = os.homedir();
// PIA_HOME — другая папка данных (для проверок: своя база, свой server.json; код тот же)
export const APP = process.env.PIA_HOME || `${HOME}/.pi-agent`;
export const WORKDIR = `${APP}/pia`;
export const MEMORY = `${WORKDIR}/память`;
// Модели ролей: из ~/.pi-agent/models.json, без него — прежние Claude (Opus 5.5 / Sonnet 5.5 / Haiku 5.5).
// ROLES.<роль> = { provider, modelId, thinking }; SONNET/OPUS/HAIKU — прежние имена (smart / opus / fast).
export const { roles: ROLES, config: MODELS_CONFIG } = loadRoles();
export const SONNET = ref(ROLES.smart);
export const OPUS = ref(ROLES.opus);
export const HAIKU = ref(ROLES.fast);
export const NODE_BIN = process.execPath;

// ── Доступ к моделям через вход pi (~/.pi/agent/auth.json) ──
// Async: провайдеры подгружаются только нужные. Неполадки (нет модели, неизвестный провайдер) — в errors.log.
export async function makeModels() {
  const { models, problems } = await buildModels(ROLES, MODELS_CONFIG);
  for (const p of problems) {
    try { fs.appendFileSync(`${APP}/errors.log`, `${new Date().toISOString()} models: ${p}\n`); } catch {}
    process.stderr.write(`pia: ${p}\n`);
  }
  return models;
}

// ── Картинки: уменьшаем до 1024 px по большей стороне — иначе каждая по мегабайту едет в каждый запрос ──
export const IMAGE_MAX = 1024;
let photon;
const photonImages = async () => (photon ??= (await import("@earendil-works/pi-durable/images/node")).createNodePhotonImages());
export const smallImages = {
  prepare: async (bytes, mimeType, limits) =>
    (await photonImages()).prepare(bytes, mimeType, { ...limits, maxWidth: Math.min(limits.maxWidth, IMAGE_MAX), maxHeight: Math.min(limits.maxHeight, IMAGE_MAX) }),
};
// Уменьшить картинку из base64 (для подключений MCP); если не вышло — отдаём как есть
export async function shrinkImage(data, mimeType) {
  try {
    const r = await smallImages.prepare(Buffer.from(data, "base64"), mimeType, { maxWidth: IMAGE_MAX, maxHeight: IMAGE_MAX, maxBytes: 4.5 * 1024 * 1024 });
    return r ? { data: r.data, mimeType: r.mimeType } : { data, mimeType };
  } catch { return { data, mimeType }; }
}

const text = (t) => ({ output: [{ type: "text", text: t }] });
const short = (t, description, parameters) => ({ ...t, description, parameters });

// ── Файлы и команды ───────────────────────────────────────
// Команда без timeout раньше могла висеть вечно (так завис помощник #44: node-скрипт с открытым CDP не выходил 8 минут).
// Теперь по умолчанию 120 с, потолок 3600 с; по таймауту дерево процессов убивается, помощник получает понятную ошибку.
const BASH_HINT = "Команда остановлена по таймауту (процессы убиты). Не повторяй так же: найди причину (скрипт не завершается? закрой соединения / process.exit), поставь timeout поменьше и логи, либо другой путь. Если операция легитимно долгая (ffmpeg, заливка) — запусти с явным большим timeout (до 3600 с) или в фоне: `nohup … > /tmp/x.log 2>&1 &` и проверяй лог короткими командами.";
function bashTool() {
  const base = createBashTool();
  return guardTool({
    ...base,
    description: "Выполнить команду в терминале. timeout — секунды: по умолчанию 120, максимум 3600 (долгое — укажи явно или запусти в фоне).",
    parameters: obj({ command: str(), timeout: opt(num()) }),
    execute: async (args, api, ctx) => {
      const timeout = clampSec(args.timeout, LIMITS.bash);
      try { return await base.execute({ ...args, timeout }, api, ctx); }
      catch (e) {
        if (/timed out after/i.test(String(e?.message))) throw new Error(`Команда не завершилась за ${timeout} с. ${BASH_HINT}`);
        throw e;
      }
    },
  }, (a) => clampSec(a.timeout, LIMITS.bash));
}
export const Files = defineExtension({ name: "files", tools: [
  short(createReadTool({ images: smallImages }), "Прочитать файл.", obj({ path: str(), offset: opt(num()), limit: opt(num()) })),
  short(createWriteTool(), "Записать файл целиком (новый файл или полная перезапись).", obj({ path: str(), content: str() })),
  { ...createEditTool(), description: "Точечная правка файла: каждый edits[].oldText — точный уникальный фрагмент файла, заменяется на newText. Для правок существующего кода — всегда edit, а не write или sed/python в bash." },
  bashTool(),
] });

// ── Интернет (бесплатно, DuckDuckGo) ──────────────────────
const UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 Safari/605.1.15";
const decode = (s) => s.replace(/<[^>]+>/g, "").replace(/&amp;/g, "&").replace(/&quot;/g, '"').replace(/&#x27;|&#39;/g, "'").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&nbsp;/g, " ").replace(/\s+/g, " ").trim();
export const Web = defineExtension({ name: "web", tools: [
  defineTool({
    name: "web_search", description: "Поиск в интернете.", parameters: obj({ query: str() }), replay: "safe",
    execute: async ({ query }) => {
      const r = await fetch("https://lite.duckduckgo.com/lite/", { signal: AbortSignal.timeout(LIMITS.web.def * 1000), method: "POST", headers: { "User-Agent": UA, "Content-Type": "application/x-www-form-urlencoded" }, body: new URLSearchParams({ q: query, kl: "ru-ru" }) });
      const html = await r.text();
      const links = [...html.matchAll(/<a[^>]+href="([^"]+)"[^>]*class='result-link'>([\s\S]*?)<\/a>/g)];
      const snips = [...html.matchAll(/class='result-snippet'>([\s\S]*?)<\/td>/g)].map((m) => decode(m[1]));
      const out = links.slice(0, 8).map((m, i) => {
        let url = m[1]; const u = url.match(/uddg=([^&]+)/); if (u) url = decodeURIComponent(u[1]);
        return `${i + 1}. ${decode(m[2])}\n${url}\n${snips[i] ?? ""}`;
      }).join("\n\n");
      return text(out || "Ничего не найдено.");
    },
  }),
  defineTool({
    name: "fetch_page", description: "Открыть страницу по ссылке (без входа в аккаунты).", parameters: obj({ url: str() }), replay: "safe",
    execute: async ({ url }) => {
      const r = await fetch(url, { headers: { "User-Agent": UA }, signal: AbortSignal.timeout(LIMITS.web.def * 1000) });
      return text(decode((await r.text()).replace(/<(script|style|noscript)[\s\S]*?<\/\1>/gi, " ")).slice(0, 15000));
    },
  }),
] });

// ── Браузер Yab (сам управляет вкладками) ─────────────────
const YAB_GUIDE = `Скрипт JavaScript для браузера Yab пользователя (он вошёл во все сайты). Синхронные функции:
open(url) → вкладка t (t.id сохраняй; в следующем вызове tab(id)); t.snapshot() дерево с ref (e12); t.find("текст") → ref или null;
t.click(ref) t.type(ref, text, submit?) t.choose(ref, value) t.press(keys) t.scroll(ref?, dy) t.navigate(url|"back") t.wait(for?)
t.text() статья; t.fetch(url) с куками; t.show() отдать вкладку пользователю; t.close(); tabs() все вкладки; return результат.
Правила: сначала snapshot, refs не угадывай; после действий проверь результат; закрывай свои вкладки; чужие вкладки не трогай без просьбы.
Не отправляй, не плати, не удаляй без явного разрешения. Код 3 / needs_user = нужен человек (вход, капча, подтверждение в Yab) — скажи пользователю.`;
// yab exec сам завершается по --timeout; сверх этого стоит жёсткий таймер (+15 с, SIGKILL) и остановка по Esc/«стоп».
const browserLimit = (a) => clampSec(a.timeout, LIMITS.browser);
export const Browser = defineExtension({ name: "browser", tools: [
  guardTool(defineTool({
    name: "browser", description: YAB_GUIDE + `\ntimeout — секунды (по умолчанию ${LIMITS.browser.def}, максимум ${LIMITS.browser.max}); дольше не жди — раздели на шаги.`, parameters: obj({ script: str(), timeout: opt(num()) }),
    execute: async ({ script, timeout }, _api, ctx) => new Promise((resolve) => {
      const sec = browserLimit({ timeout });
      const p = spawn("yab", ["exec", "-", "--timeout", String(sec), "--output-limit", "12000"], { env: { ...process.env, PATH: `${HOME}/.local/bin:/usr/local/bin:/opt/homebrew/bin:${process.env.PATH}` } });
      let out = "", finished = false;
      const finish = (t) => { if (finished) return; finished = true; clearTimeout(hard); ctx?.abortSignal?.removeEventListener?.("abort", onAbort); resolve(text(t)); };
      const hard = setTimeout(() => { try { p.kill("SIGKILL"); } catch {} finish(`Ошибка: браузер не ответил за ${sec} с, yab остановлен. Попробуй другой путь: меньше действий за вызов, другой селектор/вкладка, snapshot, либо сообщи, что нужен пользователь.${out.trim() ? "\nВывод до остановки:\n" + out.trim() : ""}`); }, (sec + LIMITS.browser.killMarginSec) * 1000);
      const onAbort = () => { try { p.kill("SIGKILL"); } catch {} finish("Остановлено."); };
      ctx?.abortSignal?.addEventListener?.("abort", onAbort, { once: true });
      p.stdout.on("data", (d) => (out += d)); p.stderr.on("data", (d) => (out += d));
      p.on("close", (code) => finish((code === 3 ? "НУЖЕН ПОЛЬЗОВАТЕЛЬ: " : code ? `Ошибка (${code}): ` : "") + out.trim()));
      p.on("error", (e) => finish("Yab недоступен: " + e.message));
      p.stdin.on("error", () => {}); p.stdin.end(script);
    }),
  }), browserLimit, "Попробуй другой путь."),
] });

// ── Долгая память ─────────────────────────────────────────
export const MEMORY_DIRS = ["люди", "организации", "предпочтения", "факты", "решения", "дела/активные", "дела/завершённые", "дневник"];
export function ensureMemory() {
  for (const d of MEMORY_DIRS) fs.mkdirSync(`${MEMORY}/${d}`, { recursive: true });
  for (const [f, body] of [["обо-мне.md", "---\nid: обо-мне\ntype: профиль\n---\n"], ["вопросы.md", ""], ["входящие.md", ""]])
    if (!fs.existsSync(`${MEMORY}/${f}`)) fs.writeFileSync(`${MEMORY}/${f}`, body);
  if (!fs.existsSync(`${MEMORY}/.git`)) {
    try { execFileSyncQuiet("git", ["init", "-q"], MEMORY); execFileSyncQuiet("git", ["add", "-A"], MEMORY); execFileSyncQuiet("git", ["-c", "user.name=pi-agent", "-c", "user.email=pi@local", "commit", "-qm", "начало"], MEMORY); } catch {}
  }
}
import { execFileSync } from "node:child_process";
function execFileSyncQuiet(cmd, args, cwd) { return execFileSync(cmd, args, { cwd, stdio: "ignore" }); }

function walk(dir, base = dir) {
  let out = [];
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (e.name.startsWith(".")) continue;
    const p = path.join(dir, e.name);
    if (e.isDirectory()) out = out.concat(walk(p, base)); else if (e.name.endsWith(".md")) out.push(path.relative(base, p));
  }
  return out;
}
const norm = (s) => s.toLowerCase().replace(/ё/g, "е");

export const Memory = defineExtension({
  name: "memory",
  sections: [
    // Только короткое оглавление и открытые вопросы — сама память подгружается по запросу.
    section("memory", () => {
      const files = walk(MEMORY).filter((f) => !/^(дневник|входящие|вопросы)/.test(f)).map((f) => f.replace(/\.md$/, ""));
      const q = fs.readFileSync(`${MEMORY}/вопросы.md`, "utf8").trim().slice(0, 600);
      return `Долгая память — заметки. Ищи в ней (memory_search), когда речь о людях, прошлом, планах, предпочтениях; не выдумывай. Новое важное сохраняй через remember.
Есть заметки: ${files.join(", ").slice(0, 900) || "пока пусто"}.` + (q ? `\nОткрытые вопросы к пользователю (задай к месту, по одному, не навязчиво):\n${q}` : "");
    }),
  ],
  tools: [
    defineTool({
      name: "memory_search", description: "Поиск по долгой памяти (по словам и синонимам). Несколько слов через пробел — ищется любое.",
      parameters: obj({ query: str() }), replay: "safe",
      execute: async ({ query }) => {
        const words = norm(query).split(/[\s,]+/).filter((w) => w.length > 1).map((w) => w.length > 5 ? w.slice(0, -2) : w);
        const hits = [];
        for (const f of walk(MEMORY)) {
          const body = fs.readFileSync(`${MEMORY}/${f}`, "utf8"); const low = norm(f + "\n" + body);
          const score = words.reduce((s, w) => s + (low.split(w).length - 1) + (norm(f).includes(w) ? 5 : 0), 0);
          if (!score) continue;
          const lines = body.split("\n").filter((l) => words.some((w) => norm(l).includes(w))).slice(0, 4);
          hits.push({ f, score, lines });
        }
        hits.sort((a, b) => b.score - a.score);
        return text(hits.slice(0, 8).map((h) => `## ${h.f}\n${h.lines.join("\n")}`).join("\n\n") || "Ничего не найдено в памяти.");
      },
    }),
    defineTool({
      name: "memory_read", description: "Прочитать заметку памяти целиком (путь как в поиске).", parameters: obj({ file: str() }), replay: "safe",
      execute: async ({ file }) => {
        const p = path.resolve(MEMORY, file.endsWith(".md") ? file : file + ".md");
        if (!p.startsWith(MEMORY) || !fs.existsSync(p)) return text("Нет такой заметки.");
        return text(fs.readFileSync(p, "utf8").slice(0, 20000));
      },
    }),
    defineTool({
      name: "remember", description: "Сохранить важное о пользователе в долгую память (факт, предпочтение, человек, решение, дело, разрешение). Коротко, с датами.",
      parameters: obj({ note: str() }), replay: "safe",
      execute: async ({ note }) => {
        fs.appendFileSync(`${MEMORY}/входящие.md`, `- ${new Date().toLocaleString("sv-SE").slice(0, 16)} ${note.replace(/\n/g, " ")}\n`);
        return text("Сохранено.");
      },
    }),
  ],
});

export function dateLine() {
  return new Date().toLocaleString("ru-RU", { weekday: "long", day: "numeric", month: "long", year: "numeric", hour: "2-digit", minute: "2-digit" });
}

// Команда остановки без модели: «стоп», «стой», «отмена», «хватит», «останови всё/всех», «stop», «/stop»; «стоп 263», «стоп #263», «/stop 263».
// Возвращает {all:true} | {n:число} | null (не команда: «стоп-кадр сделай» и т.п.)
export function parseStop(text) {
  const t = String(text ?? "").toLowerCase().replace(/ё/g, "е").replace(/[.!?…,;:"«»()]+/g, " ").replace(/\s+/g, " ").trim();
  if (!t) return null;
  const m = /^\/?(?:стоп|стой|отмена|отмени|хватит|stop|cancel|останови(?:сь)?(?: (?:все|всех|всё|помощников|всё это))?|остановить (?:все|всех|всё))(?: (?:#|№)?(\d+))?$/.exec(t.replace(/(?<=\s)(#|№)\s+(?=\d)/g, "$1"));
  if (!m) return null;
  return m[1] ? { n: Number(m[1]) } : { all: true };
}
