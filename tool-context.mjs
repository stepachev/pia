// Ответы инструментов в контексте модели (как image-context.mjs для картинок). История в memory.sqlite не меняется —
// только то, что уходит модели (хук GenerationTask.beforeRequest).
// 1) Большой ответ (> TOOL_CAP символов) — начало и конец, полный текст в файл (у read — подсказка про offset).
// 2) Старые ответы — короткая пометка: целиком остаются последние ~TOOL_KEEP символов ответов (и не меньше 3 ответов).
//    Граница сдвигается, только когда кэш подсказок остыл или старых нетронутых ответов набралось > TOOL_EXTRA —
//    иначе каждый сдвиг перезаписывал бы весь кэш.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

export const TOOL_CAP = Number(process.env.PIA_TOOL_CAP) || 12_000;      // символов в одном ответе (~3–4 тыс. токенов)
export const TOOL_KEEP = Number(process.env.PIA_TOOL_KEEP) || 60_000;    // символов свежих ответов целиком (~15–20 тыс. токенов)
export const TOOL_EXTRA = Number(process.env.PIA_TOOL_EXTRA) || 90_000;  // сколько старых можно держать, пока кэш тёплый
const STUB = 300;
const COLD_MS = 4.5 * 60_000;
const DIR = path.join(os.tmpdir(), "pia-tool-out");

const textOf = (m) => m.content.filter((b) => b?.type === "text").map((b) => b.text).join("\n");
const rest = (m) => m.content.filter((b) => b?.type !== "text");
const fileOf = (m) => path.join(DIR, `${String(m.toolCallId ?? "x").replace(/[^\w.-]/g, "_")}.txt`);

export function capResult(m, call) {
  const t = textOf(m);
  if (t.length <= TOOL_CAP) return m;
  const name = m.toolName ?? call?.name;
  let text;
  if (name === "read") {
    const head = t.slice(0, TOOL_CAP), shown = head.split("\n").length - 1, from = Number(call?.arguments?.offset) || 1;
    text = `${head}\n[… ответ обрезан: показано ~${shown} строк. Дальше — read с offset=${from + shown} и limit, или grep по файлу]`;
  } else {
    const file = fileOf(m);
    try { if (!fs.existsSync(file)) { fs.mkdirSync(DIR, { recursive: true }); fs.writeFileSync(file, t); } } catch {}
    text = `${t.slice(0, TOOL_CAP - 2000)}\n[… вывод обрезан: всего ${t.length} симв. Полностью — в файле ${file}; ищи нужное grep/rg или read с offset/limit, не читай целиком]\n…\n${t.slice(-1500)}`;
  }
  return { ...m, content: [{ type: "text", text }, ...rest(m)] };
}

export function stubResult(m, call) {
  const t = textOf(m);
  if (t.length <= STUB * 2) return m;
  const name = m.toolName ?? call?.name ?? "инструмента";
  const file = fileOf(m), saved = fs.existsSync(file) ? ` Полный вывод: ${file}.` : "";
  const args = call ? ` ${JSON.stringify(call.arguments ?? {}).slice(0, 200)}` : "";
  return { ...m, content: [{ type: "text", text: `${t.slice(0, STUB)}\n[… старый вывод ${name} убран из контекста (${t.length} симв.).${saved} Нужен снова — повтори вызов${args}]` }, ...rest(m)] };
}

export function toolTrimHook({ log = () => {}, onError = () => {} } = {}) {
  const state = new Map();   // разговор → { cut, first, count, at }
  return {
    beforeRequest: ({ messages }, api) => {
      try {
        const trs = [];
        messages.forEach((m, i) => { if (m?.role === "toolResult" && Array.isArray(m.content)) trs.push(i); });
        if (!trs.length) return undefined;
        const calls = new Map();
        for (const m of messages) if (m?.role === "assistant" && Array.isArray(m.content)) for (const b of m.content) if (b?.type === "toolCall") calls.set(b.id, b);
        const sizes = trs.map((i) => Math.min(textOf(messages[i]).length, TOOL_CAP));
        // want — сколько первых ответов убрать: с конца оставляем не меньше 3 и пока влезает в TOOL_KEEP
        let want = trs.length, sum = 0;
        while (want > 0 && (trs.length - want < 3 || sum + sizes[want - 1] <= TOOL_KEEP)) { sum += sizes[want - 1]; want--; }
        const conv = String(api?.conversationId ?? "?"), now = Date.now();
        const first = messages[trs[0]].toolCallId, prev = state.get(conv);
        const cold = !prev || prev.first !== first || trs.length < prev.count || now - prev.at > COLD_MS;   // кэш остыл или было сжатие
        let cut = cold ? want : Math.min(prev.cut, want);
        if (!cold) { let extra = 0; for (let k = cut; k < want; k++) extra += sizes[k]; if (extra > TOOL_EXTRA) cut = want; }
        state.set(conv, { cut, first, count: trs.length, at: now });
        if (cut && cut !== prev?.cut) log(`ответы инструментов (разговор ${conv}): старых убрано ${cut} из ${trs.length}${cold ? " (кэш остыл)" : ""}`);
        const out = messages.slice(); let changed = false;
        trs.forEach((i, k) => {
          const m = messages[i], call = calls.get(m.toolCallId);
          const r = k < cut ? stubResult(m, call) : capResult(m, call);
          if (r !== m) { out[i] = r; changed = true; }
        });
        return changed ? { messages: out } : undefined;
      } catch (e) { onError(e); return undefined; }
    },
  };
}
