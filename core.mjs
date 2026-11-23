// pia — ядро: главный разговор, помощники, сторож, сжатие. Живёт в фоновой службе (daemon.mjs),
// окна (терминал — agent.mjs, Raycast) подключаются к нему по HTTP (server.mjs).
import fs from "node:fs";
import { spawn } from "node:child_process";
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import { obj, str, num, opt, lit, union } from "@earendil-works/pi-schema";
import { createRegistry, Harness, AssistantEntry, defineTool, defineExtension, configure, hook, CompactionTask, GenerationTask } from "@earendil-works/pi-durable";
import { createToolSearchExtension } from "@earendil-works/pi-durable/tool-search";
import { loadMcp, closeMcp } from "./mcp.mjs";
import { NodeExecutionEnv } from "@earendil-works/pi-durable/env/node";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { DatabaseSync } from "node:sqlite";
import { STREAM, RETRY, IDLE_MS, MAX_RESTARTS, activity, currentTool, judge, LIMITS } from "./guard.mjs";
import { parseStop, APP, WORKDIR, ROLES, makeModels, Files, Web, Browser, Memory, ensureMemory } from "./shared.mjs";
import { ref } from "./providers.mjs";
import { isLimitError, limitResetAt, mainLimitLine, helperLimitLine, pauseLabel } from "./limit.mjs";
import { buildMessage } from "./attachments.mjs";
import { imageTrimHook, flatContent, imageTokensOf, makePathResolver } from "./image-context.mjs";
import { Feed, publicItem } from "./feed.mjs";
import { killConvTree, TrackedEnv } from "./proctree.mjs";

let harness, Mcp, ToolSearch;   // открываются в openCore()

// ── Характер ─────────────────────────────────────────────
const CHARACTER = `Ты — единственный личный помощник пользователя во всём, одна цельная личность, мужчина (о себе в мужском роде).
Характер: весёлый, живой, человечный, поддерживающий. Говори по-русски, строго по существу, простыми словами, без техтерминов и эмодзи. Отвечай максимально коротко: 1–2 коротких предложения, только суть. Без пояснений причин, вступлений, повторов задачи и предложений «если хочешь…», если пользователь не спросил. Списки — только когда пунктов действительно несколько, по одной строке на пункт. Главное можно выделить **жирным**, ссылки — как есть.
Ты — ОРКЕСТРАТОР. Сам руками ничего не делаешь: у тебя нет файлов, команд, интернета, браузера и подключений (MCP) — это есть только у помощников (helper). Любую работу, даже мелкую проверку или чтение файла, поручай помощникам. Папка по умолчанию: ${WORKDIR}.
У пользователя Mac: сочетания клавиш называй маковские — ⌘ Cmd вместо Ctrl (⌘D, ⌘C, ⌘V), ⌥ Option вместо Alt. Ctrl упоминай только там, где на Mac именно Ctrl (например Ctrl+C в терминале).
Как работаешь: на болтовню и вопросы из головы отвечай сам. Всё остальное — через helper.
Делай именно то, что просит пользователь. Если он ждёт результат (например, готовый ролик) — цель только этот результат: не подменяй её уборкой, записями, отчётами или вопросами. Не задавай лишних вопросов, если ответ можно найти в его файлах — поручи помощнику найти.
Задание помощнику пиши полностью, он не видит разговор: слова пользователя ДОСЛОВНО (цитатой) и полные пути ко всем его картинкам, цель и что считается готовым результатом, папки и пути, где лежат инструкции (пусть сначала прочитает их и следует им), что нельзя трогать. Большую задачу разбей на части, независимые — одновременно.
ОДНА ЗАДАЧА — ОДИН ПОМОЩНИК. Если пользователь продолжает, уточняет или говорит «не работает» по задаче, которую уже делал помощник #N (даже закончивший), — вызывай helper с continue: N: этот помощник помнит, что читал, менял и пробовал. Нового помощника запускай только на новую задачу. Если продолжить нельзя — в задание нового включи отчёт прошлого и что не сработало.
Работа с кодом (правка, сборка, отладка программ и интерфейсов) — model: opus.
Снимки экрана помощникам РАЗРЕШЕНЫ для самопроверки (решение пользователя 2026-11-23; старый запрет «не делать скриншоты, проверяет пользователь» отменён). Запрещено по-прежнему только вмешиваться в его экран: мышь, клавиши, набор в его окна, новые окна Терминала, фокус, буфер обмена.
Проверяй отчёты: не говори пользователю, что сделано, если помощник этого не подтвердил; проверено «на тестовой копии» или не проверено вовсе — так и скажи, это не «готово»; сомнительное — поручи проверить другому помощнику. ОБЯЗАТЕЛЬНО: получив новую задачу, перед запуском помощников — одна короткая фраза, что делаешь (до 10 слов), и в том же ответе сразу запускай помощников, не дожидаясь ответа. У каждого helper заполняй title.
Помощники работают В ФОНЕ: helper сразу возвращает номер помощника (#N), а его отчёт придёт позже отдельным сообщением «[Отчёт помощника #N …]». После запуска — не больше одной короткой фразы или ничего лишнего, и закончи ход — не жди. Пока они работают, ты свободен: отвечай пользователю на любые вопросы как обычно. Не выдумывай результат до отчёта; «как дела?» — helper_list. Если пользователь уточняет или меняет задачу работающего помощника — передай ему через helper_message; если просит остановиться («стоп», «отмена») — helper_stop. Когда пришёл отчёт — проверь его и сообщи пользователю итог или запусти следующий шаг.
Перед оплатой, отправкой от имени пользователя, удалением важного — спроси, если он заранее не разрешил (проверь память).`;
const HELPER = `Ты — исполнитель части задачи для главного помощника. Сделай её сам до конца.
Если в папке задачи есть инструкции (README, AGENTS.md, файлы с описанием процесса) — сначала прочитай их и следуй им. Подключения (MCP, если они настроены) находи через tool_search, только когда они нужны.
Если во время работы придёт сообщение пользователя — оно главнее задания: учти его сразу.
Тебе могут прислать продолжение задачи (уточнение, «не работает») — опирайся на всё, что уже сделал и выяснил в этом разговоре, не начинай заново.
Работа с кодом: сначала прочитай AGENTS.md/README проекта и код вокруг места правки; найди причину, а не симптом. Существующие файлы правь инструментом edit (не write, не sed/python). После правки собери и проверь на настоящем (запуск, лог, снимок экрана), сравни с картинкой пользователя, если она есть. Снимки РАЗРЕШЕНЫ (тихо: screencapture -x, лучше одного окна -l <id>) — старый запрет на скриншоты отменён. По-прежнему нельзя: двигать мышь, нажимать клавиши и набирать в окна пользователя, открывать окна Терминала, забирать фокус, трогать буфер обмена. Не удалось проверить на настоящем — прямо так и напиши. Отчёт по коду — до 10 строк: причина, что изменено (файлы), как проверено.
Остальные отчёты — сжато, до 5 строк: только ответ на задачу (факты, цифры), 1–2 источника короткими ссылками, что не вышло. Без вступлений и пересказа процесса.
Сверяй источники, после действий на сайте проверяй результат. Не плати, не отправляй и не удаляй ничего. По-русски.
Node-скрипты запускай командой \`node\` (она есть в PATH службы) или process.execPath, а не \`pia\`: \`pia\` — это чат.\nЗависания: у каждой команды есть таймаут (bash по умолчанию 120 с, браузер ${LIMITS.browser.def} с). Скрипты Node/Playwright/CDP обязательно завершай (browser.close() или process.exit() и в catch тоже) и запускай с \`timeout N\`. Долгое (ffmpeg, заливка, опрос) — запускай с явным timeout побольше или в фоне (nohup … > лог &) и проверяй короткими командами; опрос — с лимитом времени. Если пришла ошибка про таймаут или сообщение сторожа — не повторяй то же самое, выбери другой путь.`;

// ── Помощники (субагенты) в фоне ──────────────────────────
// helper сразу возвращает номер помощника: главный не ждёт и отвечает пользователю,
// а отчёт приходит в разговор отдельным сообщением, когда помощник закончит.
// Список работающих — в helpers.json, после перезапуска pia они продолжают и отчитываются.
const logErr = (where, e) => fs.appendFileSync(`${APP}/errors.log`, `${new Date().toISOString()} ${where}: ${e?.stack ?? e}\n`);
const ok = (text) => ({ output: [{ type: "text", text }] });
const Helpers = defineExtension({ name: "helpers", tools: [
  defineTool({
    name: "helper",
    description: "Запустить помощника в фоне. Сразу возвращает его номер (#N); отчёт придёт позже отдельным сообщением. Несколько вызовов идут одновременно. Опиши задачу полностью: помощник не видит разговор. continue: N — продолжить ту же задачу тем же помощником #N (он помнит всю свою прошлую работу); тогда в task — только новое: слова пользователя дословно, пути к картинкам. model: opus — любая работа с кодом (правка, сборка, отладка) и если пользователь просит опус; smart (по умолчанию) — всё остальное: браузер, сайты, поиск, файлы, дела.",
    parameters: obj({ title: opt(str({ description: "3–8 слов для пользователя: чем занят помощник (например: «разбираю референс»)" })), task: str(), model: opt(union([lit("smart"), lit("opus")])),
      continue: opt(num({ description: "номер прошлого помощника, если это продолжение его задачи" })) }),
    replay: "safe",
    execute: async (args, api, ctx) => {
      try {
        // Вызов, начатый старой версией (помощник принадлежит вызову) — доводим по-старому
        const legacy = await api.commit(async (tx) => (await tx.scanConversations({ ownerTaskId: api.taskId }, 1)).items[0], ctx);
        if (legacy !== undefined) return await runHelper(args, api, ctx);
        if (Date.now() < mainLimitUntil) return ok(`Лимит модели сейчас исчерпан — помощника не запускаю. ${mainLimitLine(mainLimitUntil)}`);
        if (args.continue != null) {
          const said = await continueHelper(String(api.taskId), args, ctx);
          if (said) return ok(said);
          args = { ...args, task: `${args.task}\n\n(Это продолжение задачи прошлого помощника #${args.continue}, но его разговор недоступен — начни с чтения нужных файлов.)` };
        }
        const rec = await startHelper(String(api.taskId), args, ctx);
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
      try { await conv.submit({ type: "input", whenBusy: "steer", whenIdle: "reject", content: `Сообщение от пользователя (важнее задания; если меняет задачу или просит остановиться — слушайся): ${args.text}` }, context); }
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
async function stopHelpers(n) {
  const list = [...runningHelpers.values()].filter((x) => n == null || x.n === n);
  for (const r of list) { r.stopped = true; r.wake?.(); (await harness.conversation(r.conv, context))?.abort(context).catch(() => {}); killHelperTree(r); }
  return list;
}
const RESUME_GAP_MS = 90_000, RETRY_MS = 15 * 60_000;   // после сброса лимита ждём ещё 1,5 мин; без времени — повтор раз в 15 мин
let mainLimitUntil = 0;             // главная модель на лимите до этого времени — новых помощников не запускаем
let helperNote = () => {};          // служебная строка в ленту (задаётся в openCore)
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
let pendingNotes = [];              // системные заметки для главного (напр. «пользователь всё остановил»)
let pendingReports = [];            // отчёты, которые ещё не отданы главному
let onReport = () => {};
let closing = false;
// Модель помощника по роли (smart по умолчанию; opus — самая мощная модель выбранного провайдера)
// fast (Haiku) помощникам больше не даём (решение пользователя): код — opus, остальное — smart
const helperRole = (m) => (m === "opus" ? ROLES.opus : ROLES.smart);
const helperExtensions = () => [Files, Web, Browser, Memory, Mcp, ToolSearch, CheapCompaction, CacheFix, ImageTrim];
async function startHelper(key, args, ctx) {
  let rec = store.items[key];
  if (!rec) {
    const conv = await harness.createConversation({ ownership: { kind: "ownerless" }, agent: {
      model: ref(helperRole(args.model)), thinkingLevel: helperRole(args.model).thinking, cwd: WORKDIR,
      instructions: HELPER, maxTurns: 80, compaction: COMPACTION,
      extensions: helperExtensions(),
    } }, ctx);
    rec = { n: store.next++, conv: conv.id, model: args.model === "opus" ? "opus" : "smart", title: String(args.title ?? "").trim() || "работает", task: args.task, started: Date.now() };
    store.items[key] = rec; saveStore();
  }
  watchHelper(key, rec);
  return rec;
}
// Продолжение задачи тем же помощником: его разговор (всё, что он читал, менял и пробовал) остаётся,
// новое сообщение уходит туда же. Работает — передаём на ходу; закончил — запускаем его разговор снова.
// Возвращает текст для главного или null, если продолжить нельзя (тогда запустится новый помощник).
const DONE_KEEP = 60;
async function continueHelper(key, args, ctx) {
  const n = Number(args.continue);
  const running = [...runningHelpers.values()].find((x) => x.n === n);
  if (running && !store.items[key]) {
    try {
      const conv = await harness.conversation(running.conv, context);
      await conv.submit({ type: "input", whenBusy: "steer", whenIdle: "reject", content: `Продолжение задачи от пользователя (важнее задания): ${args.task}` }, context);
      return `Помощник #${n} ещё работает — передал ему это на ходу.`;
    } catch (e) { logErr("helper-continue", e); return `Помощник #${n} как раз заканчивает — дождись его отчёта и повтори continue: ${n}.`; }
  }
  let rec = store.items[key];
  if (!rec) {
    const past = store.done?.[n];
    const conv = past && await harness.conversation(past.conv, ctx);
    if (!conv) return null;
    // Модель и уровень размышлений — всегда из текущих настроек (а не те, с которыми помощника когда-то запустили)
    const model = args.model ?? past.model ?? "smart", role = helperRole(model);
    await conv.configure({ instructions: HELPER, extensions: helperExtensions(), model: ref(role), thinkingLevel: role.thinking }, ctx);
    rec = { n, conv: past.conv, model, title: String(args.title ?? "").trim() || past.title, started: Date.now(),
      task: `Продолжение той же задачи. Всё, что ты уже прочитал, изменил и выяснил, — выше в этом разговоре; опирайся на это, не начинай заново.\n\n${args.task}` };
    store.items[key] = rec; saveStore();
  }
  watchHelper(key, rec);
  return `Помощник #${n} «${rec.title}» продолжает в фоне и помнит свою прошлую работу. Отчёт придёт отдельным сообщением.`;
}
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
      // Пауза после лимита переживает перезапуск (wakeAt в helpers.json): задание уже идёт в разговоре, не ставим заново
      if (!rec.wakeAt) settled = await (await conv.submit({ type: "input", content: rec.task, requestId: `helper:${key}` }, context)).wait(context);
      while (!closing && !rec.stopped) {
        if (rec.wakeAt) {   // пауза: ждём сброс лимита и продолжаем с того же места
          await sleepUntil(rec, rec.wakeAt);
          if (closing || rec.stopped) break;
          rec.wakeAt = null; rec.pauseUntil = null; saveStore();
          rec.progress = { id: lastEntryId(rec.conv), at: Date.now() };
          helperNote(`#${rec.n} продолжает`);
          settled = await resumeRun(conv, rec, key);
          continue;
        }
        if (!settled || settled.status === "done") break;
        const detail = await errorText(conv, settled);
        if (isLimitError(detail)) {   // лимит: не отчитываемся, а ставим на паузу
          const at = limitResetAt(detail);
          pauseAt(rec, at);
          killHelperTree(rec);
          helperNote(helperLimitLine(rec.n, at));
          continue;
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
      else text = rec.stopped ? "Остановлен по просьбе." : rec.giveUp ? `Остановлен сторожем: ${rec.giveUp}.` : `Не справился (${settled?.reason ?? settled?.status ?? "?"}).`;
    } catch (e) {
      if (closing) return;            // pia закрывается — продолжит после перезапуска
      logErr("helper-bg", e); text = `Ошибка: ${e?.message ?? e}`;
    }
    runningHelpers.delete(key);
    rememberDone(rec);
    await killHelperTree(rec);   // завершился, ошибка или остановка: осиротевших процессов не оставляем
    pendingReports.push({ key, n: rec.n, title: rec.title, text: `[Отчёт помощника #${rec.n} «${rec.title}»]\n${text.slice(0, 4000)}` });
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
          extensions: [Files, Web, Browser, Memory, Mcp, ToolSearch, CheapCompaction, CacheFix, ImageTrim],
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
    const model = models.getModel(ROLES.compact.provider, ROLES.compact.modelId);
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
    fs.appendFileSync(`${APP}/compaction.log`, `${new Date().toISOString()} сжато ${ROLES.compact.modelId}: вход ${(res.usage?.input ?? 0) + (res.usage?.cacheRead ?? 0) + (res.usage?.cacheWrite ?? 0)} ток., пересказ ${res.usage?.output} ток., $${(res.usage?.cost?.total ?? 0).toFixed(4)}\n`);
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
// В фоне начинаем сжимать с ~60 тыс. токенов, жёсткий предел ~80 тыс., дословно остаются последние ~20 тыс.
// Окно 1 млн: ждать сжатия на 200 тыс., фоновое сжатие с 150 тыс., последние 60 тыс. — дословно
const COMPACTION = { enabled: true, reserveTokens: 800_000, backgroundTokens: 50_000, keepRecentTokens: 60_000 };
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
  for (const ext of [Files, Web, Browser, Memory, Mcp, ToolSearch, Helpers, CheapCompaction, CacheFix, ImageTrim, DebugPayload]) registry.install(ext);
  // Команды помощников идут через TrackedEnv: учёт процессов и метки PIA_CONV/PIA_HELPER в окружении (см. proctree.mjs)
  const env = ({ cwd, conversationId }) => new TrackedEnv({ cwd: cwd ?? WORKDIR }, conversationId);
  harness = await Harness.open(await openNodeSqliteStorage(`${APP}/memory.sqlite`), {
    models, registry, env, settings: { toolExecution: "parallel", stream: STREAM, retry: RETRY },
  }, context);

  // Оркестратор: только память и помощники. Файлы, команды, интернет, браузер и MCP — только у помощников.
  // Модель — роль main из models.json (по умолчанию Opus 5.5, medium); PIA_MAIN_MODEL=haiku|fast — дёшево, для проверочного экземпляра
  const agent = { compaction: COMPACTION, model: ref(ROLES.main), thinkingLevel: ROLES.main.thinking, cwd: WORKDIR, instructions: CHARACTER,
    extensions: [Memory, Helpers, CheapCompaction, CacheFix, ImageTrim, DebugPayload] };
  const mapFile = `${APP}/chats.json`;
  const map = fs.existsSync(mapFile) ? JSON.parse(fs.readFileSync(mapFile, "utf8")) : {};
  let chat = map.main != null ? await harness.conversation(map.main, context) : undefined;
  if (!chat) {
    chat = await harness.createConversation({ ownership: { kind: "ownerless" }, agent }, context);
    map.main = chat.id; fs.writeFileSync(mapFile, JSON.stringify(map, null, 2));
  } else await chat.configure({ ...agent, modelTools: null }, context);   // сбросить ранее загруженные инструменты MCP

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
  const watch = await chat.watch(context);
  watch.start(async (call) => {
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
  });
  harness.resume();

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
          if (isLimitError(detail)) { const at = limitResetAt(detail); mainLimitUntil = at ?? Date.now() + RETRY_MS; feed.addService(mainLimitLine(at)); }
          else feed.addService(`Не получилось ответить (${res.reason ?? res.status}).`);
          continue;
        }
        if (answered.has(res.answer)) continue;
        answered.add(res.answer);
        // Сам ответ попадает в ленту через watch
      }
    } catch (err) {
      logErr("turn", err);
      const msg = String(err?.message ?? err);
      if (isLimitError(msg)) { const at = limitResetAt(msg); mainLimitUntil = at ?? Date.now() + RETRY_MS; feed.addService(mainLimitLine(at)); }
      else feed.addService("Ошибка: " + msg);
    }
    finally {
      await catchUp();   // watch мог отстать — дочитать записи до конца хода, чтобы ответ не потерял ключ потока
      busy = false; stopping = false; queue = []; extra = []; toolRunning = false;
      feed.endTurn(); emitLive(true);
    }
  }
  // Отчёты фоновых помощников отдаём главному, когда он свободен; из helpers.json убираем только после этого
  let flushing = false;
  async function flushReports() {
    if (busy || flushing || !pendingReports.length) return;
    flushing = true;
    try {
      const items = pendingReports; pendingReports = [];
      feed.addReports(items);
      await runTurn(items.map((r) => r.text).join("\n\n"));
      for (const r of items) delete store.items[r.key];
      saveStore();
    } finally { flushing = false; }
    return flushReports();
  }
  onReport = () => { flushReports(); };

  // Сообщение пользователя из любого окна. Возвращает запись ленты (её seq — ответ /api/send).
  async function send({ text = "", images = [], tokens = [], pastes = [], source = "raycast" }) {
    const line = text.trim();
    // Команда остановки — без модели (работает и при исчерпанном лимите)
    const stopCmd = !images.length && !tokens.length ? parseStop(line) : null;
    if (stopCmd) {
      const item = feed.addUser({ text, source });
      const list = await stopHelpers(stopCmd.all ? null : stopCmd.n);
      const wasBusy = busy;
      if (wasBusy) stop();
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
    // Картинки из Raycast — пометками «[картинка N]» в конце текста (как вставка в терминале)
    const tok = new Map(tokens);
    let t = text;
    for (const file of images) {
      let label; let k = tok.size + 1;
      do label = `[картинка ${k++}]`; while (t.includes(label) || tok.has(label));
      tok.set(label, file); t += (t.trim() ? " " : "") + label;
    }
    const m = await buildMessage(t, tok);
    if (pendingNotes.length) {   // системная заметка об остановке — главный увидит её с этим сообщением
      const head = pendingNotes.splice(0).join("\n");
      m.content = typeof m.content === "string" ? `${head}\n\n${m.content}` : [{ type: "text", text: head }, ...m.content];
    }
    let card = m.card;
    for (const [token, full] of pastes) card = card.split(full).join(token);   // большие вставки в терминале — свёрнутыми
    const key = typeof m.content === "string" ? m.content : txt({ content: m.content });
    const item = feed.addUser({ text: m.card, card, notes: m.notes, images: m.files, key, source });
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
  // Помощники, не доработавшие в прошлый раз, продолжают (повторная отправка с тем же requestId не дублирует задачу)
  for (const [key, rec] of Object.entries(store.items)) watchHelper(key, rec);
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
      clearInterval(helpersTimer); clearInterval(watchdogTimer);
      await watch.stop().catch(() => {});
      await harness.close(context);
      await closeMcp();
    },
  };
}
