// Лимит модели: распознать, достать время сброса из ответа провайдера, сказать по-человечески.
// Не лимит (оставляем как было): overloaded_error / 529 и прочие ошибки.

const LIMIT_RE = /\b429\b|rate_limit_error|rate.?limit|usage limit|quota|limit reached/i;

export const isLimitError = (v) => LIMIT_RE.test(typeof v === "string" ? v : safeStr(v));
const safeStr = (v) => { try { return JSON.stringify(v) ?? ""; } catch { return String(v ?? ""); } };

const WD = ["воскресенья", "понедельника", "вторника", "среды", "четверга", "пятницы", "субботы"];   // после «до»
const pad = (n) => String(n).padStart(2, "0");
const hm = (d) => `${pad(d.getHours())}:${pad(d.getMinutes())}`;
const dayStart = (d) => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();

// Время для человека: «19:40» (сегодня), «среды 15:00» (в ближайшие дни), «25.11 15:00» (дальше)
export function whenText(ms, now = Date.now()) {
  const d = new Date(ms);
  const days = Math.round((dayStart(d) - dayStart(new Date(now))) / 864e5);
  if (days === 0) return hm(d);
  if (days > 0 && days < 7) return `${WD[d.getDay()]} ${hm(d)}`;
  return `${pad(d.getDate())}.${pad(d.getMonth() + 1)} ${hm(d)}`;
}

// Время сброса из текста ошибки (или из записи ответа): заголовки anthropic-ratelimit-*-reset,
// retry-after(-ms), «resets at …», поле resetsAt, «usage limit reached|<epoch>». null — если не нашли.
const MAX_AHEAD = 8 * 864e5;
function parseWhen(v, now) {
  const s = String(v ?? "").trim();
  if (/^\d{10,13}$/.test(s)) { const n = Number(s); return n < 1e12 ? n * 1000 : n; }
  let m = s.match(/^(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$/i);          // «19:40», «7pm»
  if (m) {
    let h = Number(m[1]); const mi = Number(m[2] ?? 0), ap = m[3]?.toLowerCase();
    if (ap === "pm" && h < 12) h += 12; if (ap === "am" && h === 12) h = 0;
    if (h > 23 || mi > 59) return null;
    const d = new Date(now); d.setHours(h, mi, 0, 0);
    if (d.getTime() <= now) d.setDate(d.getDate() + 1);
    return d.getTime();
  }
  if (/^\d{4}-\d{2}-\d{2}T/.test(s) || /^\w{3},/.test(s)) { const t = Date.parse(s); return Number.isNaN(t) ? null : t; }
  return null;
}
export function limitResetAt(text, now = Date.now()) {
  const s = String(text ?? "");
  const cands = [];
  let m;
  if ((m = s.match(/retry-after-ms\W{1,6}(\d+(?:\.\d+)?)/i))) cands.push(now + Number(m[1]));
  else if ((m = s.match(/retry-after\W{1,6}(\d+(?:\.\d+)?)\b/i))) cands.push(now + Number(m[1]) * 1000);
  else if ((m = s.match(/retry-after\W{1,6}([A-Za-z]{3},[^"',}]+)/i))) cands.push(parseWhen(m[1], now));
  // pi-ai: «Server requested 13018s retry delay (max: 60s). 429 …»
  for (const r of s.matchAll(/requested\s+(\d+(?:\.\d+)?)\s*s\s+retry delay/gi)) cands.push(now + Number(r[1]) * 1000);
  for (const r of s.matchAll(/anthropic-ratelimit-[\w-]*?reset\W{1,6}([^\s"',}]+)/gi)) cands.push(parseWhen(r[1], now));
  for (const r of s.matchAll(/resets?(?:\s*at)?\W{1,6}([^\s"',}]+)/gi)) cands.push(parseWhen(r[1], now));   // «resets at …», resetsAt
  if ((m = s.match(/limit reached\W{1,4}(\d{10,13})/i))) cands.push(parseWhen(m[1], now));
  const ok = cands.filter((t) => t != null && t > now && t - now <= MAX_AHEAD);
  return ok.length ? Math.max(...ok) : null;   // блокирует самое позднее окно
}

// Фразы. at — время сброса (мс) или null.
export const mainLimitLine = (at, now = Date.now()) => (at ? `Я устал, отдохну до ${whenText(at, now)}.` : "Я устал.");
export const helperLimitLine = (n, at, now = Date.now()) => `#${n}: ${at ? `я устал, отдохну до ${whenText(at, now)}.` : "я устал."}`;
export const pauseLabel = (at, now = Date.now()) => `пауза до ${whenText(at, now)} (устал)`;
