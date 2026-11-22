// Фоновый разбор памяти: читает новые сообщения и раскладывает важное по заметкам.
// Запускается после каждого разговора и раз в 30 минут, пока Mac работает. Прерванный разбор продолжается.
import fs from "node:fs";
import { execFileSync } from "node:child_process";
import { DatabaseSync } from "node:sqlite";
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import { createRegistry, Harness } from "@earendil-works/pi-durable";
import { NodeExecutionEnv } from "@earendil-works/pi-durable/env/node";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { APP, MEMORY, ROLES, makeModels, Files, ensureMemory } from "./shared.mjs";
import { ref } from "./providers.mjs";

const STATE = `${APP}/memory-state.json`;
const LOCK = `${APP}/memory-worker.lock`;
const LOG = `${APP}/memory-worker.log`;
const log = (m) => fs.appendFileSync(LOG, `${new Date().toISOString()} ${m}\n`);
const CHUNK = 60_000; // символов разговора за один разбор

// один разборщик за раз
try {
  const pid = Number(fs.readFileSync(LOCK, "utf8"));
  if (pid && pid !== process.pid) { try { process.kill(pid, 0); process.exit(0); } catch {} }
} catch {}
fs.writeFileSync(LOCK, String(process.pid));
const cleanup = () => { try { fs.unlinkSync(LOCK); } catch {} };
process.on("exit", cleanup);

const RULES = `Ты ведёшь долгую память личного помощника пользователя. Папка памяти — текущая (${MEMORY}). Работай только в ней, через инструменты.
Структура: обо-мне.md (сводка), люди/, организации/, предпочтения/, факты/, решения/, дела/активные/, дела/завершённые/, дневник/ГГГГ-ММ-ДД.md, вопросы.md, входящие.md.
Формат заметки:
---
id: короткий-id
type: человек|организация|предпочтение|факт|решение|дело
aliases: [синонимы, другие названия, как пользователь может это назвать]
---
- **Суть:** факт; дата когда стало известно (ГГГГ-ММ-ДД).
- Связано: [[id-другой-заметки]]
Правила:
- Записывай только устойчиво важное о пользователе: люди и отношения, предпочтения, факты жизни и работы, решения с причинами, дела и планы, разрешения (что можно делать без спроса). Не записывай болтовню, общие знания, ответы на справочные вопросы.
- Сначала найди существующую заметку (ls, grep -ril) и дополни её, а не создавай дубль. Aliases обязательны: по ним ищут словами.
- Противоречие: замени старый факт новым с пометкой «исправлено ГГГГ-ММ-ДД, раньше: …».
- Временные детали — в дела/активные; сделанное перенеси в дела/завершённые. Примеры обобщай в черты. Пароли, коды, номера карт — никогда.
- Дневник: в дневник/<дата>.md допиши 2–6 строк — что происходило в этот день.
- обо-мне.md: держи сводку до 400 слов — кто пользователь, жизнь и работа, важные люди, текущие дела, когда действовать самому, а когда спрашивать, как с ним общаться.
- вопросы.md: до 5 коротких вопросов к пользователю о том, что неясно, противоречит или устарело и важно для помощи. Убери вопросы, на которые уже есть ответ. Если нет — оставь файл пустым.
- Записи из входящие.md (их сохранил сам помощник) обработай так же, затем очисти входящие.md.
Работай экономно, не перечитывай лишнего. В конце ответь одной строкой, что изменил.`;
const CLEANUP = `\nСегодня ещё и пересмотр: пройдись по всей памяти, объедини дубли, сократи разросшиеся заметки, закрой устаревшие дела, проверь сводку обо-мне.md и вопросы.md.`;

function newMessages(fromId) {
  const map = JSON.parse(fs.readFileSync(`${APP}/chats.json`, "utf8"));
  const db = new DatabaseSync(`${APP}/memory.sqlite`, { readOnly: true });
  const rows = db.prepare("select id, record from entries where conversation_id = ? and id > ? order by id").all(map.main, fromId);
  db.close();
  const out = []; let size = 0; let last = fromId;
  for (const r of rows) {
    const e = JSON.parse(r.record); const m = e.model?.[0];
    let line = "";
    const txt = (c) => typeof c === "string" ? c : (c ?? []).filter((x) => x.type === "text").map((x) => x.text).join(" ");
    if (e.kind === "pi.user") line = `Пользователь: ${txt(m?.content)}`;
    else if (e.kind === "pi.assistant") {
      const calls = (m?.content ?? []).filter((x) => x.type === "toolCall").map((x) => `[${x.name} ${JSON.stringify(x.arguments).slice(0, 150)}]`);
      line = `Помощник: ${txt(m?.content)} ${calls.join(" ")}`.trim();
    } else if (e.kind === "pi.tool-result") line = `  (результат: ${txt(m?.content).slice(0, 200)})`;
    else if (e.kind === "pi.compaction") continue;
    if (line.trim()) { out.push(line); size += line.length; }
    last = r.id;
    if (size > CHUNK) break;
  }
  return { text: out.join("\n"), last };
}

function commit(msg) {
  try {
    execFileSync("git", ["add", "-A"], { cwd: MEMORY, stdio: "ignore" });
    execFileSync("git", ["-c", "user.name=pi-agent", "-c", "user.email=pi@local", "commit", "-qm", msg], { cwd: MEMORY, stdio: "ignore" });
  } catch {}
}

ensureMemory();
const state = fs.existsSync(STATE) ? JSON.parse(fs.readFileSync(STATE, "utf8")) : { lastEntryId: 0 };
const save = () => fs.writeFileSync(STATE, JSON.stringify(state, null, 2));

const registry = createRegistry(); registry.install(Files);
const harness = await Harness.open(await openNodeSqliteStorage(`${APP}/memory-worker.sqlite`), {
  models: await makeModels(), registry, env: () => new NodeExecutionEnv({ cwd: MEMORY }),
}, context);
harness.resume();

async function digest(job) {
  // job: { upTo, requestId, content, convId? } — сохраняется до запуска, чтобы после сбоя продолжить
  let conv = job.convId != null ? await harness.conversation(job.convId, context) : undefined;
  if (!conv) {
    conv = await harness.createConversation({ ownership: { kind: "ownerless" }, agent: { model: ref(ROLES.memory), thinkingLevel: ROLES.memory.thinking, cwd: MEMORY, instructions: RULES, maxTurns: 60 } }, context);
    job.convId = conv.id; state.pending = job; save();
  }
  const res = await (await conv.submit({ type: "input", content: job.content, requestId: job.requestId }, context)).wait(context);
  log(`разбор до #${job.upTo}: ${res.status}${res.reason ? " " + res.reason : ""}`);
  return res.status === "done";
}

try {
  if (state.pending) {
    const ok = await digest(state.pending);
    if (ok) { state.lastEntryId = state.pending.upTo; commit(`разбор до #${state.pending.upTo}`); }
    delete state.pending; save();
  }
  for (let round = 0; round < 10; round++) {
    const { text, last } = newMessages(state.lastEntryId);
    const inbox = fs.readFileSync(`${MEMORY}/входящие.md`, "utf8").trim();
    const today = new Date().toISOString().slice(0, 10);
    const needCleanup = state.lastCleanup !== today && fs.readdirSync(`${MEMORY}/дневник`).length > 0;
    if (!text && !inbox && !needCleanup) break;
    if (!text && !inbox) { state.lastEntryId = last; }
    const content = `Сегодня ${today}.${needCleanup ? CLEANUP : ""}\n\nНовые сообщения разговора:\n${text || "(нет)"}`;
    const job = { upTo: last, requestId: `mem:${last}:${today}:${needCleanup}`, content };
    state.pending = job; save();
    const ok = await digest(job);
    if (ok) { state.lastEntryId = last; if (needCleanup) state.lastCleanup = today; commit(`разбор до #${last}`); }
    delete state.pending; save();
    if (!ok) break;
  }
} catch (e) { log("ошибка: " + (e?.stack ?? e)); }
await harness.close(context);
process.exit(0);
