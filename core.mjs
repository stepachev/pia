// pia — ядро: главный разговор, помощники, сторож, сжатие. Живёт в фоновой службе (daemon.mjs),
// окна (терминал — agent.mjs, окно pia) подключаются к нему по HTTP (server.mjs).
import fs from "node:fs";
import { spawn } from "node:child_process";
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import { obj, str, num, opt, lit, union } from "@earendil-works/pi-schema";
import { createRegistry, Harness, AssistantEntry, defineTool, defineExtension, section, configure, hook, CompactionTask, GenerationTask } from "@earendil-works/pi-durable";
import { createToolSearchExtension } from "@earendil-works/pi-durable/tool-search";
import { loadMcp, closeMcp, hasMcpServer } from "./mcp.mjs";
import { NodeExecutionEnv } from "@earendil-works/pi-durable/env/node";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { DatabaseSync } from "node:sqlite";
import { STREAM, RETRY, IDLE_MS, MAX_RESTARTS, activity, currentTool, judge, LIMITS } from "./guard.mjs";
import { parseStop, APP, WORKDIR, MEMORY, ROLES, makeModels, Files, Web, Browser, Memory, ensureMemory } from "./shared.mjs";
import { ref } from "./providers.mjs";
import { isLimitError, limitResetAt, mainLimitLine, helperLimitLine, pauseLabel } from "./limit.mjs";
import { buildMessage } from "./attachments.mjs";
import { imageTrimHook, flatContent, imageTokensOf, makePathResolver } from "./image-context.mjs";
import { toolTrimHook } from "./tool-context.mjs";
import { Feed, publicItem } from "./feed.mjs";
import { killConvTree, TrackedEnv } from "./proctree.mjs";

// Браузер Yab — необязательное дополнение: его подсказки и инструмент включаются, только если в mcp.json есть сервер yab-browser
const YAB = hasMcpServer("yab-browser");
const BROWSER = YAB ? [Browser] : [];
let harness, Mcp, ToolSearch;   // открываются в openCore()

// ── Характер ─────────────────────────────────────────────
const CHARACTER = `Ты — личный помощник пользователя на его Mac. Кто ты и как говоришь — в SOUL.md ниже.
Работаешь сам: файлы и команды, интернет, ${YAB ? "браузер Yab (пользователь в нём вошёл во все сайты), " : ""}подключения (MCP — через tool_search), память. Папка по умолчанию: ${WORKDIR}.
Клавиши называй маковские: ⌘ вместо Ctrl, ⌥ вместо Alt (Ctrl — только где на Mac именно Ctrl, например в терминале).
Если в папке задачи есть инструкции (README, AGENTS.md) — сначала прочитай их. Существующие файлы правь инструментом edit.
Проверяй результат на настоящем. Что видно глазами (вёрстка, кадры, вид окна) — проверь снимком сам: ${YAB ? "сайт — снимок своей вкладки Yab, программа — одного" : "программа — снимок одного"} окна (screencapture -x -o -l <id>), не весь экран; 1–2 снимка нужного места, до 5–6 на задачу. Не проверил — так и скажи.
Не вмешивайся в экран пользователя: мышь, клавиши и набор в его окна, новые окна Терминала, фокус, буфер обмена.
Экономь контекст: большие выводы не печатай целиком — ищи нужное (grep, jq, read с offset/limit). Длинные ответы инструментов система обрезает, старые убирает — нужен снова, повтори вызов.
Долгие команды — с timeout или в фоне (nohup … > лог &); после ошибки таймаута не повторяй то же самое.
Помощник (helper) — только если пользователь просит в фоне или параллельно, или работа очень долгая (ролик, большая заливка); задание пиши полностью, он не видит разговор.
Перед публикацией, оплатой, отправкой от имени пользователя, удалением важного — спроси, если он заранее не разрешил.`;
// Душа (SOUL.md в рабочей папке, по мотивам soul.md): характер главного; он может её дописывать
const Soul = defineExtension({ name: "soul", sections: [section("soul", () => {
  try { return fs.readFileSync(`${WORKDIR}/SOUL.md`, "utf8").trim() + `\n(файл: ${WORKDIR}/SOUL.md)`; } catch { return ""; }
})] });
const HELPER = `Ты — исполнитель части задачи для главного помощника. Сделай её сам до конца.
Если в папке задачи есть инструкции (README, AGENTS.md, файлы с описанием процесса) — сначала прочитай их и следуй им. Подключения (MCP, если они настроены) находи через tool_search, только когда они нужны.
Если во время работы придёт сообщение пользователя — оно главнее задания: учти его сразу.
Работа с кодом: сначала прочитай AGENTS.md/README проекта и код вокруг места правки; найди причину, а не симптом. Существующие файлы правь инструментом edit (не write, не sed/python). После правки собери и проверь на настоящем (запуск, лог, код страницы, DOM). Что видно глазами (вёрстка, кадры, обрезка, вид окна) — проверь снимком сам, не перекладывай на пользователя. Снимки экономно: ${YAB ? "сайт — снимок своей вкладки Yab (tool_search «yab screenshot»), программа — одного" : "программа — снимок одного"} окна (screencapture -x -o -l <id окна>), не весь экран; сначала найди место текстом (DOM, код) и прокрути к нему, потом 1–2 снимка; не снимай каждый шаг прокрутки; не больше 5–6 снимков на задачу. Нельзя: двигать мышь, нажимать клавиши и набирать в окна пользователя, открывать окна Терминала, забирать фокус, трогать буфер обмена. Не удалось проверить на настоящем — прямо так и напиши.
Если в задании есть «Готово, когда» — отчёт начинай с них: по строке на пункт, ✅ + как проверено (команда/что показала), ❔ не проверено (почему), ❌ не сделано. ✅ ставь, только если сам проверил и видел результат; «должно работать» — это ❔. Отчёт по коду — до 10 строк: причина, что изменено (файлы), как проверено.
Остальные отчёты — сжато, до 5 строк: только ответ на задачу (факты, цифры), 1–2 источника короткими ссылками, что не вышло. Без вступлений и пересказа процесса.
Сверяй источники, после действий на сайте проверяй результат. Не плати, не отправляй и не удаляй ничего. По-русски.
Node-скрипты запускай командой \`node\` (она есть в PATH службы) или process.execPath, а не \`pia\`: \`pia\` — это чат.\nЗависания: у каждой команды есть таймаут (bash по умолчанию 120 с${YAB ? `, браузер ${LIMITS.browser.def} с` : ""}). Скрипты Node/Playwright/CDP обязательно завершай (browser.close() или process.exit() и в catch тоже) и запускай с \`timeout N\`. Долгое (ffmpeg, заливка, опрос) — запускай с явным timeout побольше или в фоне (nohup … > лог &) и проверяй короткими командами; опрос — с лимитом времени. Если пришла ошибка про таймаут или сообщение сторожа — не повторяй то же самое, выбери другой путь.`;

// ── Помощники (субагенты) в фоне ──────────────────────────
// helper сразу возвращает номер помощника: главный не ждёт и отвечает пользователю,
// а отчёт приходит в разговор отдельным сообщением, когда помощник закончит.
// Список работающих — в helpers.json, после перезапуска pia они продолжают и отчитываются.
const logErr = (where, e) => fs.appendFileSync(`${APP}/errors.log`, `${new Date().toISOString()} ${where}: ${e?.stack ?? e}\n`);
const ok = (text) => ({ output: [{ type: "text", text }] });
const Helpers = defineExtension({ name: "helpers", tools: [
  defineTool({
    name: "helper",
    description: "Запустить помощника в фоне. Сразу возвращает его номер (#N); отчёт придёт позже отдельным сообщением. Несколько вызовов идут одновременно. Опиши задачу полностью: помощник не видит разговор (если это доработка — добавь короткий отчёт прошлого помощника). model: smart (по умолчанию; код, браузер, сайты, всё обычное), fast (дёшево, только простое без браузера) или opus (самая мощная и дорогая — только если пользователь прямо попросил опус).",
    parameters: obj({ title: opt(str({ description: "3–8 слов для пользователя: чем занят помощник (например: «разбираю референс»)" })), task: str(),
      done: opt(str({ description: "Критерии готовности — только если помощник что-то меняет (код, сайт, файлы); для справок не заполняй. 1–5 пунктов списком, каждый проверяем текстом" })), model: opt(union([lit("fast"), lit("smart"), lit("opus")])) }),
    replay: "safe",
    execute: async (args, api, ctx) => {
      try {
        // Вызов, начатый старой версией (помощник принадлежит вызову) — доводим по-старому
        const legacy = await api.commit(async (tx) => (await tx.scanConversations({ ownerTaskId: api.taskId }, 1)).items[0], ctx);
        if (legacy !== undefined) return await runHelper(args, api, ctx);
        if (Date.now() < mainLimitUntil) return ok(`Лимит модели сейчас исчерпан — помощника не запускаю. ${mainLimitLine(mainLimitUntil)}`);
        const rec = await startHelper(String(api.taskId), { ...args, task: withQuote("Задание от главного помощника (его разъяснение):", args.task)
          + (String(args.done ?? "").trim() ? `\n\nГотово, когда:\n${String(args.done).trim()}\nВ отчёте — по каждому пункту: ✅ как проверено / ❔ не проверено / ❌ не сделано.` : "") }, ctx);
        return ok(`Помощник #${rec.n} «${rec.title}» запущен в фоне. Отчёт придёт отдельным сообщением.`);
      } catch (e) { logErr("helper", e); throw e; }
    },
  }),
  defineTool({
    name: "helper_list",
    description: "Какие помощники сейчас работают и сколько времени.",
    parameters: obj({}),
    execute: async () => ok(runningHelpers.size
      ? [...runningHelpers.values()].map((r) => r.wakeAt ? `#${r.n} «${r.title}» — ${pauseLabel(r.pauseUntil)}` : `#${r.n} «${r.title}» — ${Math.round((Date.now() - r.started) / 60000)} мин`).join("\n")
      : "Сейчас никто не работает."),
  }),
  defineTool({
    name: "helper_message",
    description: "Передать работающему помощнику уточнение или изменение задачи (он учтёт после текущего шага).",
    parameters: obj({ n: num({ description: "номер помощника" }), text: str() }),
    execute: async (args) => {
      const r = [...runningHelpers.values()].find((x) => x.n === args.n);
      if (!r) return ok(`Помощник #${args.n} уже не работает.`);
      const conv = await harness.conversation(r.conv, context);
      try { await conv.submit({ type: "input", whenBusy: "steer", whenIdle: "reject", content: `Новое сообщение по твоей задаче (важнее задания; если меняет задачу или просит остановиться — слушайся).\n${withQuote("Пояснение главного помощника:", args.text)}` }, context); }
      catch (e) { return ok(`Не удалось передать: ${e?.message ?? e}`); }
      return ok(`Передал помощнику #${r.n}.`);
    },
  }),
  defineTool({
    name: "helper_stop",
    description: "Остановить помощника (или всех, если n не указан).",
    parameters: obj({ n: opt(num()) }),
    execute: async (args) => {
      const list = await stopHelpers(args.n);
      return ok(list.length ? `Остановил: ${list.map((r) => "#" + r.n).join(", ")}.` : "Некого останавливать.");
    },
  }),
] });
// Остановить помощника n (или всех) — и инструмент helper_stop, и команда «стоп» без модели
// Убить все процессы помощника (SIGTERM, через 3 с SIGKILL); не ждём — «стоп» отвечает сразу
const killHelperTree = (r) => killConvTree(r.conv).catch((e) => logErr("kill-tree", e));
async function stopHelpers(n, why = "user") {
  const list = [...runningHelpers.values()].filter((x) => n == null || x.n === n);
  for (const r of list) { r.stopped = true; r.stopWhy ??= why; r.wake?.(); (await harness.conversation(r.conv, context))?.abort(context).catch(() => {}); killHelperTree(r); }
  return list;
}
const RESUME_GAP_MS = 90_000, RETRY_MS = 15 * 60_000;   // после сброса лимита ждём ещё 1,5 мин; без времени — повтор раз в 15 мин
let mainLimitUntil = 0;             // главная модель на лимите до этого времени — новых помощников не запускаем
let helperNote = () => {};          // служебная строка в ленту (задаётся в openCore)
let stopMain = () => {};            // прервать ход главного (задаётся в openCore)
// Лимит кончился (у главного или любого помощника) — останавливаем ВСЁ: всех помощников с их процессами и ход главного.
// Ничего не продолжается само после сброса — только когда напишет пользователь.
async function haltOnLimit(at) {
  const fresh = Date.now() >= mainLimitUntil;
  mainLimitUntil = Math.max(mainLimitUntil, at ?? Date.now() + RETRY_MS);
  const list = await stopHelpers(null, "limit");
  stopMain();
  if (fresh || list.length) helperNote(`${mainLimitLine(at)} Всё остановил${list.length ? ` (${list.map((r) => "#" + r.n).join(", ")})` : ""}. Сам ничего не продолжу — напишите, когда нужно.`);
}
// Текст ошибки модели для распознавания лимита: итог записи и ошибка из истории разговора (errorMessage провайдера)
async function errorText(conv, settled) {
  let extra = "";
  try {
    const page = await conv?.entries({}, 3, undefined, context);
    const hit = (page?.items ?? []).map((e) => safe(e)).find((x) => x.includes("errorMessage"));
    extra = hit ?? "";
  } catch (e) { logErr("error-text", e); }
  return `${safe({ reason: settled?.reason, error: settled?.error })} ${extra}`;
}
const safe = (v) => { try { return JSON.stringify(v) ?? ""; } catch { return ""; } };
// Ждём до времени at (или пока помощника не остановят)
function sleepUntil(rec, at) {
  return new Promise((resolve) => {
    const done = () => { clearTimeout(t); rec.wake = null; resolve(); };
    const t = setTimeout(done, Math.max(0, at - Date.now()));
    rec.wake = done;
  });
}
// Пауза помощника после лимита: сброс (если известен) + 1,5 мин; иначе повтор через 15 мин. Сохраняем в helpers.json.
function pauseAt(rec, at) {
  rec.wakeAt = at ? at + RESUME_GAP_MS : Date.now() + RETRY_MS;
  rec.pauseUntil = at ?? rec.wakeAt;
  saveStore();
}
// Продолжить разговор помощника с того же места (Pi Durable: continue). Если не вышло — повтор задания с пометкой.
async function resumeRun(conv, rec, key) {
  try {
    const first = await (await conv.submit({ type: "continue" }, context)).wait(context);
    if (first.status === "done" || first.reason !== "nothing_to_answer") return first;
  } catch (e) { logErr("helper-resume", e); }
  return (await (await conv.submit({ type: "input", content: `Продолжи с места остановки: лимит модели кончился, задание не завершено. Исходное задание:\n${rec.task}\n\nТо, что уже сделано, — в истории этого разговора выше; продолжай с него, не начиная заново.`, requestId: `helper:${key}:resume${Date.now()}` }, context)).wait(context));
}
const HELPERS_FILE = `${APP}/helpers.json`;
const store = (() => { try { return JSON.parse(fs.readFileSync(HELPERS_FILE, "utf8")); } catch { return { next: 1, items: {} }; } })();
const RUNTIME_KEYS = new Set(["progress", "wakeNote", "restarts", "giveUp", "wake"]);   // служебное сторожа — в файл не пишем
const saveStore = () => fs.writeFileSync(HELPERS_FILE, JSON.stringify(store, (k, v) => (RUNTIME_KEYS.has(k) ? undefined : v), 2));
const runningHelpers = new Map();   // ключ → запись работающего помощника
// Точные слова пользователя: его последнее сообщение в текущем ходе главного (null — ход запущен отчётом помощника).
// Код сам кладёт их цитатой в задание помощника и в helper_message — главный добавляет только своё разъяснение (решение пользователя 2026-11-24).
let userQuote = null;
const withQuote = (head, body) => userQuote
  ? `Слова пользователя дословно:\n«${userQuote.text}»${userQuote.files.length ? `\nЕго картинки: ${userQuote.files.join(", ")}` : ""}\n\n${head}\n${body}`
  : body;
let pendingNotes = [];              // системные заметки для главного (напр. «пользователь всё остановил»)
let pendingReports = [];            // отчёты, которые ещё не отданы главному
let onReport = () => {};
let closing = false;
// Модель помощника по роли (smart по умолчанию; opus — самая мощная модель выбранного провайдера)
// smart — по умолчанию (в т.ч. код); fast — простое без браузера; opus — только по прямой просьбе пользователя
const helperRole = (m) => (m === "opus" ? ROLES.opus : m === "fast" ? ROLES.fast : ROLES.smart);
const helperModelName = (m) => (m === "opus" || m === "fast" ? m : "smart");
const helperExtensions = () => [Files, Web, ...BROWSER, Memory, Mcp, ToolSearch, CheapCompaction, CacheFix, ImageTrim, ToolTrim];
async function startHelper(key, args, ctx) {
  let rec = store.items[key];
  if (!rec) {
    const conv = await harness.createConversation({ ownership: { kind: "ownerless" }, agent: {
      model: ref(helperRole(args.model)), thinkingLevel: helperRole(args.model).thinking, cwd: WORKDIR,
      instructions: HELPER, maxTurns: 80, compaction: COMPACTION,
      extensions: helperExtensions(),
    } }, ctx);
    rec = { n: store.next++, conv: conv.id, model: helperModelName(args.model), title: String(args.title ?? "").trim() || "работает", task: args.task, started: Date.now() };
    store.items[key] = rec; saveStore();
  }
  watchHelper(key, rec);
  return rec;
}
const DONE_KEEP = 60;   // сколько закончивших помощников помнить (номер → разговор), для отладки
function rememberDone(rec) {
  store.done ??= {};
  store.done[rec.n] = { conv: rec.conv, title: rec.title, model: rec.model, at: Date.now() };
  const ns = Object.keys(store.done).map(Number).sort((a, b) => a - b);
  for (const x of ns.slice(0, Math.max(0, ns.length - DONE_KEEP))) delete store.done[x];
  saveStore();
}
function watchHelper(key, rec) {
  if (runningHelpers.has(key)) return;
  runningHelpers.set(key, rec);
  (async () => {
    let text, settled = null;
    try {
      const conv = await harness.conversation(rec.conv, context);
      if (!conv) throw new Error("разговор помощника не найден");
      settled = await (await conv.submit({ type: "input", content: rec.task, requestId: `helper:${key}` }, context)).wait(context);
      while (!closing && !rec.stopped) {
        if (!settled || settled.status === "done") break;
        const detail = await errorText(conv, settled);
        if (isLimitError(detail)) {   // лимит: останавливаем всё, без пауз и автопродолжения
          rec.stopped = true; rec.stopWhy = "limit";
          await haltOnLimit(limitResetAt(detail));
          break;
        }
        if (rec.wakeNote) {   // сторож прервал зависший шаг — сообщаем помощнику и даём продолжить (не больше MAX_RESTARTS раз)
          const note = rec.wakeNote; rec.wakeNote = null; rec.restarts = (rec.restarts ?? 0) + 1;
          settled = await (await conv.submit({ type: "input", content: note, requestId: `helper:${key}:wd${rec.restarts}` }, context)).wait(context);
          continue;
        }
        break;
      }
      if (closing) return;            // pia закрывается — продолжит после перезапуска
      if (settled?.status === "done") {
        const e = await conv.commit((tx) => tx.entry(AssistantEntry, settled.answer), context);
        text = (e?.model?.[0]?.content ?? []).filter((c) => c.type === "text").map((c) => c.text).join("").trim() || "(пустой отчёт)";
      }
      else text = rec.stopped ? (rec.stopWhy === "limit" ? "Остановлен: кончился лимит модели. Задача не доделана." : "Остановлен по просьбе.") : rec.giveUp ? `Остановлен сторожем: ${rec.giveUp}.` : `Не справился (${settled?.reason ?? settled?.status ?? "?"}).`;
    } catch (e) {
      if (closing) return;            // pia закрывается — продолжит после перезапуска
      logErr("helper-bg", e); text = `Ошибка: ${e?.message ?? e}`;
    }
    runningHelpers.delete(key);
    rememberDone(rec);
    await killHelperTree(rec);   // завершился, ошибка или остановка: осиротевших процессов не оставляем
    pendingReports.push({ key, n: rec.n, title: rec.title, stopped: !!rec.stopped, text: `[Отчёт помощника #${rec.n} «${rec.title}»]\n${text.slice(0, 4000)}` });
    onReport();
  })();
}
// Старый вариант: главный ждёт помощника (только для вызовов, начатых до перехода на фон)
async function runHelper(args, api, ctx) {
      const child = await api.commit(async (tx) => {
        const existing = (await tx.scanConversations({ ownerTaskId: api.taskId }, 1)).items[0];
        if (existing !== undefined) return existing.id;
        const created = await tx.createConversation({ ownership: { kind: "task", taskId: api.taskId } });
        await configure(tx, created.id, {
          // По умолчанию — smart (в т.ч. вся работа в браузере); fast только по явному fast
          model: ref(helperRole(args.model)), thinkingLevel: helperRole(args.model).thinking,
          instructions: HELPER, maxTurns: 80, compaction: COMPACTION,
          extensions: [Files, Web, ...BROWSER, Memory, Mcp, ToolSearch, CheapCompaction, CacheFix, ImageTrim],
        });
        return created.id;
      }, ctx);
      await api.details({ conversationId: child }, ctx);
      const conv = await api.conversation(child, ctx);
      activeHelpers.add(child); helperTitles.set(api.taskId, String(args.title ?? "").trim() || "работает");
      let settled;
      try { settled = await (await conv.submit({ type: "input", content: args.task, requestId: `helper:${api.taskId}` }, ctx)).wait(ctx); }
      finally { activeHelpers.delete(child); helperTitles.delete(api.taskId); }
      if (settled.status !== "done") return { output: [{ type: "text", text: `Помощник не справился (${settled.reason ?? settled.status}).` }] };
      const e = await api.commit((tx) => tx.entry(AssistantEntry, settled.answer), ctx);
      const answer = (e?.model?.[0]?.content ?? []).filter((c) => c.type === "text").map((c) => c.text).join("");
      return { output: [{ type: "text", text: (answer || "(пустой отчёт)").slice(0, 4000) }] };
}
// Помощники, которые сейчас работают: им пересылаются сообщения пользователя на ходу
const activeHelpers = new Set();
const helperTitles = new Map();   // чем занят каждый помощник — для строки статуса
// Чем занят помощник сейчас: текущий инструмент и сколько секунд (или «думает» — запрос к модели)
const DOING = { bash: "команда", browser: "браузер", web_search: "поиск", fetch_page: "страница", read: "чтение", write: "запись", edit: "правка", tool_search: "умение" };
function doingOf(rec) {
  const now = Date.now(), t = currentTool(rec.conv, now);
  if (t) return { label: DOING[t.name] ?? (t.name.startsWith("mcp__") ? "MCP" : t.name), since: t.since, stuck: t.over || t.ms > 150_000 };
  const at = rec.progress?.at ?? rec.started;
  return { label: "думает", since: at, stuck: now - at > 120_000 };
}
// Для экрана: работающие помощники и закончившие, чей отчёт ещё ждёт главного
const helperItems = () => [
  ...[...runningHelpers.values()].map((r) => r.wakeAt
    ? { n: r.n, title: r.title, state: "пауза", label: pauseLabel(r.pauseUntil), since: r.started }
    : { n: r.n, title: r.title, state: "работает", since: r.started, doing: doingOf(r) }),
  ...[...helperTitles.values()].map((t) => ({ n: null, title: t, state: "работает", since: 0 })),
  ...pendingReports.map((r) => ({ n: r.n, title: r.title, state: "готов", since: 0 })),
].sort((a, b) => (a.n ?? 1e9) - (b.n ?? 1e9));

// ── Сторож: помощник долго без шагов → прервать зависший вызов и сообщить ему ──
// Шаг = новая запись в разговоре помощника (читаем memory.sqlite только на чтение) или начало/конец вызова инструмента.
// Идёт вызов инструмента — его держит собственный таймаут; сторож рвёт его, только если вызов пережил лимит с запасом.
// Вызова нет, а шагов нет IDLE_MS — завис запрос к модели: прерываем и пишем помощнику, чтобы продолжал.
let watchDb;
function lastEntryId(conv) {
  try { watchDb ??= new DatabaseSync(`${APP}/memory.sqlite`, { readOnly: true }); return watchDb.prepare("select max(id) m from entries where conversation_id = ?").get(Number(conv))?.m ?? 0; }
  catch { return null; }
}
async function watchdogTick() {
  const now = Date.now();
  for (const [key, rec] of runningHelpers) {
    if (rec.wakeAt) continue;   // на паузе после лимита — не зависший
    try {
      const id = lastEntryId(rec.conv), act = activity.get(String(rec.conv));
      if (id != null && id !== rec.progress?.id) rec.progress = { id, at: now };
      rec.progress ??= { id, at: now };
      const progressAt = Math.max(rec.progress.at, act?.lastAt ?? 0);
      const tools = [...(act?.tools.values() ?? [])];
      const v = judge({ now, tools, lastProgressAt: progressAt, restarts: rec.restarts ?? 0 });
      if (v.action === "none") continue;
      logErr("watchdog", `#${rec.n} «${rec.title}»: ${v.action} — ${v.why}`);
      if (v.action === "cancelTool") { v.tool.cancel?.(`Вызов «${v.tool.name}» завис и оборван сторожем (${v.why}). Попробуй другой путь.`); rec.progress.at = now; }
      else if (v.action === "abortRun") {
        rec.wakeNote = `[Сторож] ${v.why}. Текущий шаг прерван. Продолжай задание с учётом уже сделанного; если предыдущий путь не работал — выбери другой, команды запускай с timeout.`;
        rec.progress.at = now;
        (await harness.conversation(rec.conv, context))?.abort(context).catch(() => {});
      } else if (v.action === "giveUp") {
        rec.giveUp = v.why; rec.progress.at = now;
        (await harness.conversation(rec.conv, context))?.abort(context).catch(() => {});
      }
    } catch (e) { logErr("watchdog", e); }
  }
}
// Сторож запускается в openCore()

// ── Сжатие разговора (пересказ пишет модель роли compact; по умолчанию Haiku 5.5) ─────────────
// Защита от зацикливания: не больше 2 автосжатий за 10 минут в одном разговоре.
// При окне в 1 млн токенов пропустить сжатие безопасно; частое сжатие стирает память о задаче.
const compactTimes = new Map();
const GUARD_WINDOW = 10 * 60_000, GUARD_MAX = 2;
const models = await makeModels();
// Старые сообщения подписаны только именем картинки — полный путь ищем в ленте и папках со снимками
const resolvePath = makePathResolver({ feedFile: `${APP}/feed.jsonl`, dirs: [`${APP}/вложения`, `${WORKDIR}/mac-images`] });
// Текст для пересказа: картинки — пометками «[картинка N] (полный путь)», чтобы путь пережил сжатие
const flat = (c) => flatContent(c, resolvePath);
// Оценка токенов картинок по их настоящему размеру (⌈w/28⌉×⌈h/28⌉; pi-ai считает любую картинку за ~1371)
const imagesCost = (messages, modelId = ROLES.main.modelId) => {
  let n = 0, tokens = 0;
  for (const m of messages) if (Array.isArray(m?.content)) for (const b of m.content) if (b?.type === "image") { n++; tokens += imageTokensOf(b, modelId); }
  return { n, tokens };
};
const CheapCompaction = defineExtension({ name: "cheap-compaction", hooks: [hook(CompactionTask, {
  beforeCompact: async ({ reason, entries, messages, instructions }) => {
    const now = Date.now(), conv = entries?.[0]?.conversationId ?? "?";
    const recent = (compactTimes.get(conv) ?? []).filter((t) => now - t < GUARD_WINDOW);
    if (reason === "threshold" && recent.length >= GUARD_MAX) {
      fs.appendFileSync(`${APP}/compaction.log`, `${new Date().toISOString()} ВНИМАНИЕ: сжатие пропущено — уже ${recent.length} за 10 мин (разговор ${conv}, ${messages.length} сообщ.). Вероятно, большая несжимаемая часть контекста.\n`);
      compactTimes.set(conv, recent);
      return { decline: true };
    }
    recent.push(now); compactTimes.set(conv, recent);
    const pics = imagesCost(messages);
    fs.appendFileSync(`${APP}/compaction.log`, `${new Date().toISOString()} сжатие (${reason}): ${messages.length} сообщений${pics.n ? `, картинок ${pics.n} ≈ ${pics.tokens} ток. по размеру` : ""}\n`);
    const log = messages.map((m) => {
      const who = m.role === "user" ? "Пользователь" : m.role === "assistant" ? "Помощник" : m.role === "toolResult" ? "  (результат)" : m.role;
      const t = flat(m.content); return `${who}: ${m.role === "toolResult" ? t.slice(0, 1500) : t}`;
    }).join("\n");
    const model = models.getModel(ROLES.smart.provider, ROLES.smart.modelId);   // Sonnet: Haiku терял детали
    if (!model) return undefined;   // нет такой модели — сожмёт основная модель
    const res = await models.completeSimple(model, {
      systemPrompt: "Ты сжимаешь историю разговора личного помощника с пользователем, чтобы помощник продолжил без потерь сути.",
      messages: [{ role: "user", timestamp: Date.now(), content: `Сделай пересказ этой части разговора (на русском, до 1500 слов). Структура:
1) ТЕКУЩАЯ ЗАДАЧА — последние просьбы пользователя ДОСЛОВНО (цитатами) и что он считает готовым результатом.
2) Сделано — что именно и подтверждено ли.
3) Не сделано / в работе / обещано.
4) Решения и правила пользователя (чего не делать, как делать).
5) Факты: имена, цифры, ссылки, пути к файлам и папкам, команды.
Если в начале есть предыдущий пересказ — сохрани из него всё ещё актуальное. Без воды.${instructions ? "\nОсобо: " + instructions : ""}\n\n${log.slice(-400000)}` }],
    }, { maxTokens: 8000 });
    if (res.stopReason === "error") return undefined; // не вышло — сожмёт основная модель
    const summary = flat(res.content).trim();
    fs.appendFileSync(`${APP}/compaction.log`, `${new Date().toISOString()} сжато ${ROLES.smart.modelId}: вход ${(res.usage?.input ?? 0) + (res.usage?.cacheRead ?? 0) + (res.usage?.cacheWrite ?? 0)} ток., пересказ ${res.usage?.output} ток., $${(res.usage?.cost?.total ?? 0).toFixed(4)}\n`);
    return summary ? { summary } : undefined;
  },
})] });

// ── Картинки: в запрос к модели — только в последних IMAGE_KEEP сообщениях с картинками ──
// Скриншоты лежат в истории целиком и раньше ехали в каждом запросе до сжатия разговора.
// Перед каждым запросом (история в memory.sqlite не меняется) в более старых сообщениях пользователя
// и результатах инструментов картинка заменяется пометкой «[снимок убран из контекста: полный путь]».
// Ступенька: убираем, только когда сверх IMAGE_KEEP накопилось ≥ IMAGE_STEP сообщений с картинками, и сразу
// пачкой (кратно IMAGE_STEP) — граница сдвигается раз в IMAGE_STEP новых снимков, а не каждый ход, и кэш
// подсказок перезаписывается редко. В запросе остаётся от IMAGE_KEEP до IMAGE_KEEP+IMAGE_STEP−1 сообщений с картинками.
const ImageTrim = defineExtension({ name: "image-trim", hooks: [hook(GenerationTask, imageTrimHook({
  resolve: resolvePath, cwd: WORKDIR, modelId: ROLES.main.modelId,
  log: (line) => fs.appendFileSync(`${APP}/compaction.log`, `${new Date().toISOString()} ${line}\n`),
  onError: (e) => logErr("image-trim", e),
}))] });
// Ответы инструментов: большие — обрезаются (полностью в файл), старые — пометкой (tool-context.mjs)
const ToolTrim = defineExtension({ name: "tool-trim", hooks: [hook(GenerationTask, toolTrimHook({
  log: (line) => fs.appendFileSync(`${APP}/compaction.log`, `${new Date().toISOString()} ${line}\n`),
  onError: (e) => logErr("tool-trim", e),
}))] });

// ── Кэш: метка перед сменой инструментов ────────────────
// Когда меняются инструменты (подключили MCP, загрузили умение через tool_search), pi кладёт метку кэша
// на системное сообщение с новыми инструментами — на нём Anthropic кэш не пишет и не находит прошлый,
// и весь разговор оплачивается заново. Ставим вторую метку прямо перед этим сообщением,
// а лишнюю метку со служебной строки «You are Claude Code» (она крошечная) снимаем — всего меток не больше 4.
const CACHEABLE = new Set(["text", "image", "tool_result", "tool_use", "document"]);
const CacheFix = defineExtension({ name: "cache-fix", hooks: [hook(GenerationTask, {
  beforeProviderRequest: ({ model, payload }) => {
    if (model.api !== "anthropic-messages" || !Array.isArray(payload?.messages)) return undefined;
    const p = payload, msgs = p.messages;
    const isChange = (m) => m.role === "system" && Array.isArray(m.content) && m.content.some((b) => b.type === "tool_addition" || b.type === "tool_removal");
    let k = -1; for (let i = msgs.length - 1; i >= 0; i--) if (isChange(msgs[i])) { k = i; break; }
    if (k <= 0) return undefined;
    let target = null;
    for (let j = k - 1; j >= 0 && !target; j--) {
      const m = msgs[j]; if (m.role === "system") continue;
      if (typeof m.content === "string") { if (!m.content.trim()) continue; m.content = [{ type: "text", text: m.content }]; }
      const last = m.content?.[m.content.length - 1];
      if (last && CACHEABLE.has(last.type)) target = last;
    }
    if (!target || target.cache_control) return undefined;
    const sys = Array.isArray(p.system) ? p.system : [];
    if (sys.length > 1 && sys[0].cache_control && sys[1].cache_control) delete sys[0].cache_control;
    const count = (v) => JSON.stringify(v ?? null).split('"cache_control"').length - 1;
    if (count(p.system) + count(p.tools) + count(p.messages) >= 4) return undefined;
    target.cache_control = { type: "ephemeral" };
    return { payload: p };
  },
})] });

// ── Отладка: PIA_DEBUG_PAYLOAD=папка — сохранять тело каждого запроса к модели ──
const DebugPayload = defineExtension({ name: "debug-payload", hooks: [hook(GenerationTask, {
  beforeProviderRequest: ({ payload }) => {
    const dir = process.env.PIA_DEBUG_PAYLOAD; if (!dir) return undefined;
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(`${dir}/${Date.now()}.json`, JSON.stringify(payload));
    return undefined;
  },
})] });

// ── Ядро ────────────────────────────────────────────────
// Сжатие: окно у моделей 1 млн, но держим разговор небольшим — дешевле и модель внимательнее.
// Помощники (окно 1 млн): фоновое сжатие с 150 тыс., жёсткий предел 200 тыс., последние 60 тыс. — дословно
const COMPACTION = { enabled: true, reserveTokens: 800_000, backgroundTokens: 50_000, keepRecentTokens: 60_000 };
// Главный работает сам; контекст держат мелким обрезка и уборка ответов инструментов (tool-context.mjs), сжатие — запасное:
// фоновое с ~120 тыс., жёсткий предел ~160 тыс., дословно остаются последние ~40 тыс. (окно 1 млн)
const MAIN_COMPACTION = { enabled: true, reserveTokens: 840_000, backgroundTokens: 40_000, keepRecentTokens: 40_000 };

// ── Новый разговор после перерыва ──
// Кэш подсказок живёт минуты: после перерыва первое сообщение заново оплачивает весь контекст главного
// (утром ~127 тыс. токенов Opus ≈ 3% пятичасового лимита). Поэтому после долгой тишины главный начинает новый разговор.
// Долгая память (заметки) общая; разбор памяти дочитывает и старый разговор (chats.json: previous);
// к первому сообщению нового прикладываются обо-мне.md и короткий пересказ прошлого (модель роли compact).
// PIA_IDLE_RESET_MIN — минуты тишины (по умолчанию 10: кэш всё равно уже протух; 0 — выключить).
// Прошлые разговоры не удаляются: главный ищет в них подробности инструментами past_search / past_read (ответ ограничен по размеру).
const IDLE_RESET_MS = Number(process.env.PIA_IDLE_RESET_MIN ?? 10) * 60_000;
const PAST_MAX = 4000;   // символов в ответе past_search / past_read — чтобы не раздувать контекст
function pastConvs() {
  try { return (JSON.parse(fs.readFileSync(`${APP}/chats.json`, "utf8")).previous ?? []).map(Number).filter(Number.isFinite); } catch { return []; }
}
let pastDb;
function pastRows(sql, ...args) {
  if (!pastDb) {
    pastDb = new DatabaseSync(`${APP}/memory.sqlite`, { readOnly: true });
    pastDb.function("low", { deterministic: true }, (t) => String(t ?? "").toLowerCase().replace(/ё/g, "е"));   // lower() в SQLite не знает кириллицу
  }
  return pastDb.prepare(sql).all(...args);
}
const pastDate = (ts) => ts ? new Date(ts).toLocaleString("ru-RU", { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" }) : "";
function pastLine(r, max = 400) {
  const e = JSON.parse(r.record), m = e.model?.[0];
  const who = e.kind === "pi.user" ? "Пользователь" : e.kind === "pi.assistant" ? "Главный" : e.kind === "pi.tool-result" ? "  (результат)" : null;
  if (!who) return null;
  const t = flat(m?.content).replace(/\s+/g, " ").trim();
  return t ? `#${r.id} ${pastDate(m?.timestamp)} ${who}: ${t.slice(0, max)}${t.length > max ? "…" : ""}` : null;
}
const Past = defineExtension({ name: "past", tools: [
  defineTool({
    name: "past_search",
    description: "Поиск по прошлым разговорам с пользователем (после перерыва разговор начинается заново). Для подробностей недавних задач: пути, ссылки, отчёты помощников, что пробовали. Слова через пробел; находки — свежие сначала, с номером #id для past_read.",
    parameters: obj({ query: str() }), replay: "safe",
    execute: async ({ query }) => {
      const convs = pastConvs();
      const words = String(query).toLowerCase().replace(/ё/g, "е").split(/[\s,]+/).filter((w) => w.length > 1).map((w) => w.length > 5 ? w.slice(0, -2) : w).slice(0, 8);
      if (!convs.length || !words.length) return ok("Прошлых разговоров нет или пустой запрос.");
      const where = words.map(() => "instr(low(record), ?) > 0").join(" or ");
      const rows = pastRows(`select id, record from entries where conversation_id in (${convs.map(() => "?").join(",")})
        and json_extract(record,'$.kind') in ('pi.user','pi.assistant','pi.tool-result') and (${where}) order by id desc limit 300`, ...convs, ...words);
      const scored = rows.map((r) => { const low = r.record.toLowerCase().replace(/ё/g, "е"); return { r, s: words.filter((w) => low.includes(w)).length }; })
        .sort((a, b) => b.s - a.s || b.r.id - a.r.id);
      const out = []; let size = 0;
      for (const { r } of scored) { const l = pastLine(r, 300); if (!l) continue; if (size + l.length > PAST_MAX) break; out.push(l); size += l.length; }
      return ok(out.length ? out.join("\n") : "Ничего не нашлось.");
    },
  }),
  defineTool({
    name: "past_read",
    description: "Прочитать кусок прошлого разговора вокруг записи #id из past_search (несколько сообщений до и после).",
    parameters: obj({ id: num() }), replay: "safe",
    execute: async ({ id }) => {
      const convs = pastConvs();
      const conv = pastRows("select conversation_id c from entries where id = ?", Number(id))[0]?.c;
      if (conv == null || !convs.includes(Number(conv))) return ok("Запись не найдена в прошлых разговорах.");
      const kinds = "json_extract(record,'$.kind') in ('pi.user','pi.assistant','pi.tool-result')";
      const before = pastRows(`select id, record from entries where conversation_id = ? and id < ? and ${kinds} order by id desc limit 5`, conv, Number(id)).reverse();
      const after = pastRows(`select id, record from entries where conversation_id = ? and id >= ? and ${kinds} order by id limit 7`, conv, Number(id));
      const out = []; let size = 0;
      for (const r of [...before, ...after]) { const l = pastLine(r, r.id === Number(id) ? 1500 : 500); if (!l) continue; if (size + l.length > PAST_MAX) break; out.push(l); size += l.length; }
      return ok(out.join("\n") || "Пусто.");
    },
  }),
] });
async function handoffSummary(conv) {
  const lines = []; let size = 0, cursor, prior = "";
  outer: do {
    const page = await conv.entries({ order: "descending" }, 200, cursor, context);
    for (const e of page.items) {
      const m = e.model?.[0];
      if (e.kind === "pi.compaction") { prior = flat(m?.content); break outer; }
      const line = e.kind === "pi.user" ? `Пользователь: ${flat(m?.content)}`
        : e.kind === "pi.assistant" ? `Помощник: ${flat(m?.content)}`
        : e.kind === "pi.tool-result" ? `  (результат: ${flat(m?.content).slice(0, 300)})` : "";
      if (!line.trim()) continue;
      lines.push(line.slice(0, 3000)); size += Math.min(line.length, 3000);
      if (size > 60_000) break outer;
    }
    cursor = page.next;
  } while (cursor);
  if (!lines.length && !prior) return "";
  const model = models.getModel(ROLES.compact.provider, ROLES.compact.modelId);
  if (!model) return "";
  const res = await models.completeSimple(model, {
    systemPrompt: "Ты готовишь короткую передачу дел: личный помощник начинает новый разговор с пользователем и должен знать, на чём остановились.",
    messages: [{ role: "user", timestamp: Date.now(), content: `Сделай выжимку прошлого разговора до 250 слов, по-русски, без воды. Главное — текущая задача, чтобы её можно было продолжить:
- над чем работали последним (просьбы пользователя — коротко цитатой);
- что не доделано или обещано;
- договорённости и решения пользователя из этого разговора;
- нужные факты: пути, ссылки, названия.
Старое и законченное опусти.

${prior ? `Ранний пересказ:\n${prior.slice(0, 15_000)}\n\n` : ""}Последние сообщения:\n${lines.reverse().join("\n")}` }],
  }, { maxTokens: 1500 });
  if (res.stopReason === "error") throw new Error(res.errorMessage ?? "пересказ не удался");
  fs.appendFileSync(`${APP}/compaction.log`, `${new Date().toISOString()} новый разговор после перерыва: пересказ ${ROLES.compact.modelId}, вход ${(res.usage?.input ?? 0) + (res.usage?.cacheRead ?? 0)} ток., $${(res.usage?.cost?.total ?? 0).toFixed(4)}\n`);
  return flat(res.content).trim();
}
const LABELS = { web_search: "ищу в интернете", fetch_page: "читаю страницу", browser: "работаю в браузере", helper: "запускаю помощника", helper_list: "смотрю, кто работает", helper_message: "передаю помощнику", helper_stop: "останавливаю помощника",
  memory_search: "вспоминаю", tool_search: "ищу нужное умение", memory_read: "вспоминаю", remember: "запоминаю", bash: "работаю на компьютере", read: "читаю файл", write: "пишу файл", edit: "правлю файл" };
const txt = (m) => (m?.content ?? []).filter((c) => c.type === "text").map((c) => c.text).join("");
export const STOP_WORDS = ["стоп", "stop", "хватит", "остановись", "отмена"];

// Разбор памяти в фоне после разговора
export function kickMemoryWorker() {
  if (process.env.PIA_HOME) return;   // проверочный экземпляр — память не разбираем
  spawn(process.execPath, [new URL("./memory-worker.mjs", import.meta.url).pathname], { detached: true, stdio: "ignore", env: { ...process.env, NODE_NO_WARNINGS: "1" } }).unref();
}

// Открыть главный разговор и всё вокруг него. Возвращает ядро для server.mjs.
// Пишет в memory.sqlite только этот процесс (pi-durable не умеет писать из двух процессов) — поэтому всё здесь, в службе.
export async function openCore() {
  fs.mkdirSync(WORKDIR, { recursive: true });
  ensureMemory();
  ({ ext: Mcp } = await loadMcp());
  ToolSearch = createToolSearchExtension();
  const registry = createRegistry();
  for (const ext of [Soul, Files, Web, ...BROWSER, Memory, Mcp, ToolSearch, Helpers, Past, CheapCompaction, CacheFix, ImageTrim, ToolTrim, DebugPayload]) registry.install(ext);
  // Команды помощников идут через TrackedEnv: учёт процессов и метки PIA_CONV/PIA_HELPER в окружении (см. proctree.mjs)
  const env = ({ cwd, conversationId }) => new TrackedEnv({ cwd: cwd ?? WORKDIR }, conversationId);
  harness = await Harness.open(await openNodeSqliteStorage(`${APP}/memory.sqlite`), {
    models, registry, env, settings: { toolExecution: "parallel", stream: STREAM, retry: RETRY },
  }, context);

  // Главный: все инструменты сам; помощники — только для фоновой/параллельной работы.
  // Модель — роль main из models.json (по умолчанию Opus 5.5, medium); PIA_MAIN_MODEL=haiku|fast — дёшево, для проверочного экземпляра
  const agent = { compaction: MAIN_COMPACTION, model: ref(ROLES.main), thinkingLevel: ROLES.main.thinking, cwd: WORKDIR, instructions: CHARACTER,
    extensions: [Soul, Files, Web, ...BROWSER, Memory, Mcp, ToolSearch, Helpers, Past, CheapCompaction, CacheFix, ImageTrim, ToolTrim, DebugPayload] };
  const mapFile = `${APP}/chats.json`;
  const map = fs.existsSync(mapFile) ? JSON.parse(fs.readFileSync(mapFile, "utf8")) : {};
  let chat = map.main != null ? await harness.conversation(map.main, context) : undefined;
  if (!chat) {
    chat = await harness.createConversation({ ownership: { kind: "ownerless" }, agent }, context);
    map.main = chat.id; fs.writeFileSync(mapFile, JSON.stringify(map, null, 2));
  } else await chat.configure({ ...agent, modelTools: null }, context);   // сбросить ранее загруженные инструменты MCP
  // Когда главный в последний раз что-то делал — по последней записи разговора
  let lastActive = Date.now();
  let cleanSlate = false;   // разговор ещё пустой (только что начат) — сбрасывать нечего
  try {
    const last = (await chat.entries({ order: "descending" }, 1, undefined, context)).items[0];
    lastActive = last?.model?.at(-1)?.timestamp ?? lastActive;
    cleanSlate = !last;
  } catch (e) { logErr("last-active", e); }

  // ── Лента: при первом запуске — из всей истории, потом догоняем то, что записалось без нас ──
  const feed = new Feed(`${APP}/feed.jsonl`, { imageDir: `${APP}/вложения/история` });
  const scan = async (min) => {
    const all = []; let cursor;
    do {
      const page = await chat.entries({ order: "ascending", minEntryId: min }, 500, cursor, context);
      all.push(...page.items); cursor = page.next;
    } while (cursor);
    return all;
  };
  const catchUp = async () => { try { for (const e of await scan(feed.lastEntry + 1)) feed.entry(e); } catch (e) { logErr("feed", e); } };
  if (!feed.exists) { feed.backfill(await scan(undefined)); feed.rewrite(); }
  else { feed.load(); await catchUp(); }

  // ── Состояние главного: отвечает ли сейчас, чем занят ──
  let busy = false, stopping = false, label = "думаю", startedAt = 0, toolRunning = false, tool = null;
  let queue = [], extra = [];
  const liveState = () => ({ busy, stopping, label, startedAt, toolRunning, tool: toolRunning ? tool : null,
    key: busy && !toolRunning ? feed.live?.key ?? null : null, text: busy && !toolRunning ? feed.live?.text ?? "" : "" });
  let liveTimer = null, liveSent = "";
  const emitLive = (now = false) => {
    const go = () => { liveTimer = null; const s = liveState(), j = JSON.stringify(s); if (j !== liveSent) { liveSent = j; feed.emit({ type: "live", live: s }); } };
    if (now) { if (liveTimer) clearTimeout(liveTimer); go(); } else liveTimer ??= setTimeout(go, 30);
  };
  const notice = (text) => feed.emit({ type: "notice", text });

  // Один постоянный watch: новые записи разговора → лента; pi.live → частичный ответ и строка активности
  const onWatch = async (call) => {
    if (call.kind !== "value") return;
    const v = call.value;
    try {
      for (const e of v.entries ?? []) if (e.id > feed.lastEntry) feed.entry(e);
      const live = v.docs?.["pi.live"] ?? {};
      const running = (live.tools ?? []).filter((t) => t.status !== "done");
      toolRunning = running.length > 0;
      tool = toolRunning ? running[running.length - 1].name ?? null : null;
      if (toolRunning) label = LABELS[tool] ?? "работаю";
      else {
        label = "думаю";
        const partial = txt(live.generation?.message).replace(/^\s+/, "");
        if (busy && partial) feed.setLive(partial);
      }
      emitLive();
    } catch (e) { logErr("watch", e); }
  };
  let watch = await chat.watch(context);
  watch.start(onWatch);
  harness.resume();

  // Новый разговор после перерыва (см. IDLE_RESET_MS): только когда главный свободен и помощники не работают
  let resetting = null;
  // Сброс один раз за перерыв: после него ждём, пока что-то произойдёт (ход главного), и только потом снова считаем тишину
  const idleLong = () => IDLE_RESET_MS > 0 && !cleanSlate && Date.now() - lastActive > IDLE_RESET_MS;
  const canReset = () => !busy && !compacting && !flushing && !runningHelpers.size && !pendingReports.length && !activeHelpers.size;
  function freshStart() {
    resetting ??= (async () => {
      const old = chat;
      try {
        let recap = "";
        try { recap = await handoffSummary(old); } catch (e) { logErr("fresh-start-recap", e); }
        let about = "";
        try { about = fs.readFileSync(`${MEMORY}/обо-мне.md`, "utf8").trim().slice(0, 4000); } catch {}
        if (!canReset()) return;   // пока пересказывали, пользователь написал или пришёл отчёт
        const fresh = await harness.createConversation({ ownership: { kind: "ownerless" }, agent }, context);
        await catchUp();
        await watch.stop().catch(() => {});
        chat = fresh;
        watch = await chat.watch(context);
        watch.start(onWatch);
        const map = fs.existsSync(mapFile) ? JSON.parse(fs.readFileSync(mapFile, "utf8")) : {};
        map.previous = [...(map.previous ?? []), old.id].slice(-1000);
        map.main = fresh.id;
        fs.writeFileSync(mapFile, JSON.stringify(map, null, 2));
        pendingNotes.unshift(`[Система] Это новый разговор: после перерыва прошлый контекст сброшен для экономии лимита. Долгая память на месте (memory_search, memory_read); подробности прошлых разговоров — past_search, past_read.`
          + (about ? `\n\nСводка о пользователе (обо-мне.md):\n${about}` : "")
          + (recap ? `\n\nНа чём остановились в прошлом разговоре:\n${recap}` : ""));
        cleanSlate = true;
        kickMemoryWorker();   // разобрать в память хвост прошлого разговора
      } catch (e) { logErr("fresh-start", e); }
      finally { resetting = null; lastActive = Date.now(); }
    })();
    return resetting;
  }
  const idleTimer = setInterval(() => { if (idleLong() && canReset()) freshStart(); }, 60_000);

  async function stop() {
    if (!busy) return;
    stopping = true; emitLive(true);
    for (const p of extra) p.then((s) => s.abort(context)).catch(() => {});
    await chat.abort(context).catch(() => {});
  }
  // Дописать в работу на ходу: попадёт к модели после текущего шага
  function steer(content) {
    const p = chat.submit({ type: "input", content, whenBusy: "steer" }, context);
    p.catch(() => {});
    extra.push(p); queue.push(p);
    const note = typeof content === "string" ? content : (content ?? []).filter((c) => c.type === "text").map((c) => c.text).join("\n");
    for (const id of activeHelpers) {
      harness.conversation(id, context).then((h) => h?.submit({ type: "input", whenBusy: "steer", whenIdle: "reject",
        content: `Сообщение пользователя во время работы (важнее задания; если оно меняет задачу или просит остановиться — слушайся его): ${note}` }, context))
        .catch(() => {});
    }
  }
  // Один ход главного (как раньше ask() в терминале): основной вопрос + дописки по ходу
  async function runTurn(content) {
    if (resetting) await resetting;
    lastActive = Date.now(); cleanSlate = false;
    busy = true; stopping = false; extra = []; startedAt = Date.now(); label = "думаю"; toolRunning = false;
    emitLive(true);
    const answered = new Set();
    let saidStop = false;
    try {
      queue = [chat.submit({ type: "input", content }, context)];
      while (queue.length) {
        const res = await (await queue.shift()).wait(context);
        if (res.status !== "done") {
          const isStop = stopping || res.reason === "aborted" || res.reason === "withdrawn";
          if (isStop && saidStop) continue;
          if (isStop) saidStop = true;
          if (isStop) { feed.addService("Остановил."); continue; }
          const detail = await errorText(chat, res);
          if (isLimitError(detail)) await haltOnLimit(limitResetAt(detail));
          else feed.addService(`Не получилось ответить (${res.reason ?? res.status}).`);
          continue;
        }
        mainLimitUntil = 0;   // главный ответил — лимит точно не исчерпан
        if (answered.has(res.answer)) continue;
        answered.add(res.answer);
        // Сам ответ попадает в ленту через watch
      }
    } catch (err) {
      logErr("turn", err);
      const msg = String(err?.message ?? err);
      if (isLimitError(msg)) await haltOnLimit(limitResetAt(msg));
      else feed.addService("Ошибка: " + msg);
    }
    finally {
      await catchUp();   // watch мог отстать — дочитать записи до конца хода, чтобы ответ не потерял ключ потока
      busy = false; stopping = false; queue = []; extra = []; toolRunning = false; lastActive = Date.now();
      feed.endTurn(); emitLive(true);
    }
  }
  // Отчёты фоновых помощников отдаём главному, когда он свободен; из helpers.json убираем только после этого
  let flushing = false;
  // Отчёты — в ленту и заметкой к следующему сообщению пользователя, без хода модели
  function parkReports() {
    if (!pendingReports.length) return;
    const items = pendingReports; pendingReports = [];
    feed.addReports(items);
    pendingNotes.push(items.map((r) => r.text).join("\n\n"));
    for (const r of items) delete store.items[r.key];
    saveStore();
  }
  async function flushReports() {
    if (busy || flushing || !pendingReports.length) return;
    // Отчёты «остановлен по просьбе» — без хода модели: в ленту и заметкой главному к следующему сообщению пользователя
    const stopped = pendingReports.filter((r) => r.stopped);
    if (stopped.length) {
      pendingReports = pendingReports.filter((r) => !r.stopped);
      feed.addReports(stopped);
      pendingNotes.push(stopped.map((r) => r.text).join("\n\n"));
      for (const r of stopped) delete store.items[r.key];
      saveStore();
      if (!pendingReports.length) return;
    }
    // Лимит исчерпан — отчёты в ленту и заметкой к следующему сообщению пользователя; сами модель не запускают
    if (Date.now() < mainLimitUntil) { parkReports(); return; }
    flushing = true;
    try {
      const items = pendingReports; pendingReports = [];
      feed.addReports(items);
      userQuote = null;   // ход по отчёту — свежих слов пользователя нет
      await runTurn(items.map((r) => r.text).join("\n\n"));
      for (const r of items) delete store.items[r.key];
      saveStore();
    } finally { flushing = false; }
    return flushReports();
  }
  onReport = () => { flushReports(); };

  // Сообщение пользователя из любого окна. Возвращает запись ленты (её seq — ответ /api/send).
  async function send({ text = "", images = [], tokens = [], pastes = [], source = "app" }) {
    const line = text.trim();
    // Команда остановки — без модели (работает и при исчерпанном лимите)
    // «стоп» с автоконтекстом окна (<context>…</context> + его скриншот context-*.png) — тоже команда остановки
    const own = line.replace(/<context\b[^>]*>[\s\S]*?<\/context>/gi, "").trim();
    const onlyContextImages = images.every((f) => /(^|\/)context-[^/]*$/.test(String(f)));
    const stopCmd = onlyContextImages && !tokens.length ? parseStop(own) : null;
    if (stopCmd) {
      const item = feed.addUser({ text, source });
      const list = await stopHelpers(stopCmd.all ? null : stopCmd.n);
      const wasBusy = busy;
      if (wasBusy) stop();
      if (stopCmd.all) parkReports();   // «стоп» — и уже пришедшие отчёты не запускают главного
      const msg = list.length ? `Остановил: ${list.map((r) => "#" + r.n).join(", ")}.`
        : stopCmd.n != null ? `Помощник #${stopCmd.n} сейчас не работает.` : wasBusy ? "Остановил." : "Сейчас никто не работает.";
      feed.addService(msg);
      if (list.length || wasBusy) {
        // Заметка для главного: увидит при следующем ответе (без запуска модели)
        const note = `[Система] Пользователь написал «${line}» и остановил ${list.length ? "помощников " + list.map((r) => "#" + r.n).join(", ") : "текущий ответ"}. Отчёты об остановке могут прийти — не перезапускай их сам, пока пользователь не попросит.`;
        pendingNotes.push(note);
      }
      return item;
    }
    if (busy && STOP_WORDS.includes(line.toLowerCase()) && !images.length && !tokens.length) {
      const item = feed.addUser({ text, source });
      stop();
      return item;
    }
    if (!busy && ["/compact", "/сжать"].includes(line)) { const item = feed.addUser({ text, source }); compact(); return item; }
    // Картинки из окна pia — пометками «[картинка N]» в конце текста (как вставка в терминале)
    const tok = new Map(tokens);
    let t = text;
    for (const file of images) {
      let label; let k = tok.size + 1;
      do label = `[картинка ${k++}]`; while (t.includes(label) || tok.has(label));
      tok.set(label, file); t += (t.trim() ? " " : "") + label;
    }
    // Долго молчали (Mac спал и таймер не успел) — сначала новый разговор, чтобы заметка о прошлом ушла с этим сообщением
    if (!busy && !resetting && idleLong() && canReset()) freshStart();
    if (resetting) await resetting;
    const m = await buildMessage(t, tok);
    if (pendingNotes.length) {   // системная заметка об остановке — главный увидит её с этим сообщением
      const head = pendingNotes.splice(0).join("\n");
      m.content = typeof m.content === "string" ? `${head}\n\n${m.content}` : [{ type: "text", text: head }, ...m.content];
    }
    let card = m.card;
    for (const [token, full] of pastes) card = card.split(full).join(token);   // большие вставки в терминале — свёрнутыми
    const key = typeof m.content === "string" ? m.content : txt({ content: m.content });
    const item = feed.addUser({ text: m.card, card, notes: m.notes, images: m.files, key, source });
    if (own) userQuote = { text: own.slice(0, 4000), files: m.files ?? [] };
    if (busy) steer(m.content);
    else runTurn(m.content).then(() => flushReports()).catch((e) => logErr("turn", e));
    return item;
  }
  let compacting = null;
  async function compact() {
    if (compacting) return compacting;
    if (busy) return "Сейчас занят — сожму, когда закончу ответ. Попробуй чуть позже.";
    compacting = (async () => {
      busy = true; label = "сжимаю разговор"; startedAt = Date.now(); emitLive(true);
      notice("сжимаю разговор…");
      try {
        const id = await chat.compact(undefined, context);
        const { outcome } = (await harness.waitForTask(id, context)).state;
        const r = outcome?.status === "completed" ? "Готово, разговор сжат." : `Не вышло: ${JSON.stringify(outcome).slice(0, 200)}`;
        notice(r); return r;
      } catch (e) { const r = `Не вышло: ${e?.message ?? e}`; notice(r); return r; }
      finally { busy = false; compacting = null; emitLive(true); flushReports(); }
    })();
    return compacting;
  }

  // Помощники для окон: раз в 0,5 с, если список поменялся
  let helpersSent = "";
  const helpersNow = () => helperItems();
  const helpersTimer = setInterval(() => {
    const h = helpersNow(), j = JSON.stringify(h.map(({ doing, ...x }) => ({ ...x, d: doing && [doing.label, doing.since, doing.stuck] })));
    if (j !== helpersSent) { helpersSent = j; feed.emit({ type: "helpers", helpers: h }); }
  }, 500);
  const watchdogTimer = setInterval(() => { watchdogTick(); }, 15_000);

  helperNote = (t) => feed.addService(t);
  stopMain = () => { stop(); };
  // Помощники, не доработавшие в прошлый раз (перезапуск, сон, пауза на лимите), сами НЕ продолжают (решение пользователя):
  // их разговоры обрываем, процессы убиваем, и сообщаем главному с следующим сообщением пользователя.
  chat.abort(context).catch(() => {});   // недоделанный до перезапуска ход главного сам не продолжается
  const interrupted = Object.entries(store.items);
  if (interrupted.length) {
    for (const [key, rec] of interrupted) {
      delete store.items[key];
      (await harness.conversation(rec.conv, context).catch(() => null))?.abort(context).catch(() => {});
      killHelperTree(rec);
      rememberDone(rec);
    }
    saveStore();
    const ns = interrupted.map(([, r]) => `#${r.n} «${r.title}»`).join(", ");
    feed.addService(`Не доделаны и сами не продолжат: ${ns}. Напишите, если продолжить.`);
    pendingNotes.push(`[Система] Помощники ${ns} были прерваны (перезапуск pia или лимит) и сами не продолжают. Запускай новых помощников на эти задачи, только если пользователь попросит.`);
  }
  flushReports();

  return {
    feed,
    get busy() { return busy; },
    history: (after, limit) => feed.history(after, limit, { busy, toolRunning }),
    hello: (after, tail) => ({
      items: after != null ? feed.history(after, 200).items.filter((x) => !x.partial) : feed.tail(tail),
      last: feed.seq, live: liveState(), helpers: helpersNow(),
    }),
    state: () => ({ busy, live: liveState(), helpers: helpersNow(), last: feed.seq }),
    subscribe: (f) => feed.subscribe(f),
    send, stop, compact,
    // Терминальное окно закрылось — как раньше после выхода из pia: разобрать память
    onStreamClosed: (kind) => { if (kind === "terminal") kickMemoryWorker(); },
    async close() {
      closing = true;
      clearInterval(helpersTimer); clearInterval(watchdogTimer); clearInterval(idleTimer);
      await watch.stop().catch(() => {});
      await harness.close(context);
      await closeMcp();
    },
  };
}
