// Защита от зависаний: таймауты инструментов, учёт «чем занят помощник» и решения сторожа.
// Без зависимостей от pi — чтобы проверять в tests/guard.test.mjs.

// Секунды. Явно заданный помощником timeout можно увеличить до MAX (ffmpeg, заливка видео и т.п.).
export const LIMITS = {
  bash: { def: 120, max: 3600 },      // терминальные команды
  browser: { def: 60, max: 300, killMarginSec: 15 },     // yab exec (раньше 90 / 600); +15 с и SIGKILL
  mcp: { def: 120, max: 120 },        // вызов MCP (раньше 300)
  web: { def: 20, max: 20 },          // поиск и чтение страницы
};
export const GRACE_MS = 20_000;       // запас сверх таймаута инструмента, потом сторож рвёт вызов сам
export const IDLE_MS = 4 * 60_000;    // сторож: столько помощник ничего не делает (нет ни шагов, ни инструмента) → прервать запрос
export const MAX_RESTARTS = 2;        // сколько раз сторож будит одного помощника
export const STREAM = { timeoutMs: 120_000, maxRetries: 2 };                       // запрос к модели (внутри одной попытки)
export const RETRY = { enabled: true, maxRetries: 5, baseDelayMs: 2000, maxAgentDelayMs: 60_000 };   // повторы попыток генерации

export const clampSec = (v, { def, max }) => {
  const n = Number(v);
  return Number.isFinite(n) && n > 0 ? Math.min(n, max) : def;
};

export class ToolTimeout extends Error {}

// ── Что сейчас делает каждый разговор (помощник): ключ — id разговора ──
export const activity = new Map();   // id → { tools: Map(callId → {name, since, limitMs, cancel}), lastAt }
const slot = (conv) => { const k = String(conv); let a = activity.get(k); if (!a) activity.set(k, a = { tools: new Map(), lastAt: Date.now() }); return a; };
export function trackStart(conv, callId, name, limitMs, cancel, now = Date.now()) {
  const a = slot(conv); a.tools.set(callId, { name, since: now, limitMs, cancel }); a.lastAt = now;
  return () => { a.tools.delete(callId); a.lastAt = Date.now(); };
}
// Самый старый из идущих сейчас вызовов — его и показываем в списке
export function currentTool(conv, now = Date.now()) {
  const a = activity.get(String(conv)); if (!a?.tools.size) return null;
  const t = [...a.tools.values()].sort((x, y) => x.since - y.since)[0], name = t.name;
  return { name, since: t.since, ms: now - t.since, over: now - t.since > t.limitMs + GRACE_MS };
}

// Обернуть инструмент: таймаут (с запасом), учёт активности, понятная ошибка.
// limitSec(args) — сколько секунд даём вызову; сам инструмент должен укладываться в это (kill — на его стороне),
// а обёртка — страховка: если инструмент не вернулся, вызов обрывается ошибкой, и помощник пробует другой путь.
export function guardTool(tool, limitSec, hint = "", { graceMs = GRACE_MS } = {}) {
  return {
    ...tool,
    execute: async (args, api, ctx) => {
      const sec = limitSec(args), limitMs = sec * 1000;
      let cancel; const cancelled = new Promise((_, rej) => { cancel = (why) => rej(new ToolTimeout(why)); });
      let timer; const late = new Promise((_, rej) => { timer = setTimeout(() => rej(new ToolTimeout(`«${tool.name}» не вернулся за ${sec} с и остановлен сторожем.${hint ? " " + hint : ""}`)), limitMs + graceMs); });
      const done = trackStart(api.conversationId, api.callId ?? String(Math.random()), tool.name, limitMs, cancel);
      const run = Promise.resolve().then(() => tool.execute(args, api, ctx));
      run.catch(() => {});
      try { return await Promise.race([run, cancelled, late]); }
      finally { clearTimeout(timer); done(); }
    },
  };
}

// ── Решение сторожа для одного помощника ──
// st: { now, tools:[{name, since, limitMs}], lastProgressAt, restarts }
// → { action: "none" | "cancelTool" | "abortRun" | "giveUp", why }
export function judge({ now, tools = [], lastProgressAt, restarts = 0 }, idleMs = IDLE_MS) {
  const over = tools.find((t) => now - t.since > t.limitMs + 2 * GRACE_MS);
  if (over) return { action: "cancelTool", why: `«${over.name}» идёт уже ${Math.round((now - over.since) / 1000)} с при лимите ${Math.round(over.limitMs / 1000)} с`, tool: over };
  if (tools.length) return { action: "none" };
  if (now - lastProgressAt > idleMs) {
    const why = `помощник ${Math.round((now - lastProgressAt) / 60_000)} мин не делал шагов (завис запрос к модели или ответ не пришёл)`;
    return restarts >= MAX_RESTARTS ? { action: "giveUp", why } : { action: "abortRun", why };
  }
  return { action: "none" };
}
