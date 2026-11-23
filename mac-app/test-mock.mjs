#!/usr/bin/env node
// Мок службы pia для проверки pia.app (настоящий разговор не трогает).
// node test-mock.mjs --config /tmp/pia-mock/server.json   → затем PIA_SERVER_JSON=/tmp/pia-mock/server.json
// Есть /api/history (partial как у службы), /api/send, /api/state с помощниками.
import http from "node:http";
import fs from "node:fs";
const args = process.argv.slice(2);
const cfg = args.includes("--config") ? args[args.indexOf("--config") + 1] : "/tmp/pia-mock/server.json";
const img = args.includes("--image") ? args[args.indexOf("--image") + 1] : null;
const token = "mock-" + Math.random().toString(36).slice(2);
let seq = 0, busy = false, live = null;
const items = [];
const add = (role, text, images = [], extra = {}) => { const it = { seq: ++seq, role, text, images, ts: new Date().toISOString(), ...extra }; items.push(it); return it; };
for (let i = 1; i <= 30; i++) { add("user", `старый вопрос ${i}`); add("assistant", `старый ответ ${i}`); }
add("user", "Сделай нативное окно как Raycast AI Chat [картинка 1]", img ? [img] : []);
add("assistant", "Готово. Что внутри:\n\n## Окно\n- **Liquid Glass** фон, без кнопок\n- лента как в iMessage\n  - мои сообщения справа\n  - ответы слева\n1. Enter — отправить\n2. ⇧Enter — новая строка\n\n| Клавиша | Что делает |\n|---|---|\n| Esc | скрыть окно |\n| ⌘↑ | раньше |\n\n> Цитата: всё нейтральное, `код` серый.\n\n```swift\nlet pia = PiaPanel()\npia.show()\n```\nПодробнее — [Raycast](https://raycast.com).");
add("report", "[Отчёт помощника #72 «смотрю ui-sdk.dev»]\n**1. Что это.** UI SDK — библиотека поведений для интерфейсов.\n**2. Зачем.** Клавиатурная навигация, фокус, меню.\n**3. Итог.** Можно взять идеи для pia.\n**4.** Ещё строка.\n**5.** И ещё одна строка отчёта.", [], { n: 72, title: "смотрю ui-sdk.dev" });
add("user", "проверь путь /Users/stpchv/.pi-agent/pia/mac-images/2026-11-23_13-29-57-482.png и ссылку https://example.com/очень/длинная/ссылка/без/пробелов/abcdefghijklmnopqrstuvwxyz0123456789");
add("assistant", "Длинный путь: /Users/stpchv/.pi-agent/mac-app/Sources/PiaChat/MessageText.swift и ссылка https://example.com/очень/длинная/ссылка/без/пробелов/abcdefghijklmnopqrstuvwxyz0123456789, а ещё `inline_code_очень_длинное_имя_функции_без_пробелов()`.\n\n```\nlet очень_длинная_строка_кода = someFunction(argumentOne, argumentTwo, argumentThree, argumentFour)\n```\n\n| Колонка один | Колонка два | Колонка три |\n|---|---|---|\n| значение первое длинное | значение второе длинное | третье |");
add("user", '<context source="Yab · Raycast AI Chat — обзор">\nКонтекст: Yab — «Raycast AI Chat — обзор» — https://raycast.com\n</context>\n\nчто думаешь про этот дизайн?');
add("assistant", "Минималистично: стекло, крупные отступы и *ничего лишнего*.");
if (args.includes("--long")) add("assistant", "Текущие 5 часов: лимит 62% использован, сброс в 18:40.\n\n" + Array.from({length: 14}, (_, i) => `- **Пункт ${i + 1}.** Довольно длинное описание, которое переносится на вторую строку окна чата и проверяет высоту списка.`).join("\n") + "\n\nПоследняя строка ответа — ПОСЛЕДНЯЯ.");
// --helpers N — сколько работающих помощников показать (по умолчанию 2); длинные и короткие названия
const helperCount = args.includes("--helpers") ? Number(args[args.indexOf("--helpers") + 1]) : 2;
const helperPool = [
  { n: 82, title: "окно pia: поле ввода растёт вверх", ago: 12e3 },
  { n: 73, title: "нативное окно pia на SwiftUI", ago: 14 * 60e3 },
  { n: 74, title: "захват окна по двум Shift + Raycast", ago: 65 * 60e3 },
  { n: 79, title: "проверка", ago: 3 * 60e3 + 20e3 },
  { n: null, title: "отчёт о работе сервера за неделю", ago: 0 },
  { n: 85, title: "смотрю ui-sdk.dev", ago: 40e3 },
];
const helpers = helperPool.slice(0, helperCount).map(({ ago, ...h }) => ({ ...h, state: "работает", since: ago ? Date.now() - ago : 0, doing: { label: "думает", since: Date.now() - 5e3, stuck: false } }));
if (helperCount > 0) helpers.push({ n: 70, title: "готовый — в окне не показывается", state: "готов", since: 0 });
function reply(t) {
  busy = true;
  const full = args.includes("--stream-long")
    ? "Длинный потоковый ответ:\n\n" + Array.from({length: 40}, (_, i) => `- **Пункт ${i + 1}.** Описание, которое переносится на вторую строку окна чата и проверяет прилипание к низу.`).join("\n") + "\n\nПоследняя строка потока — КОНЕЦ."
    : `Получил: «${t.slice(-80)}».\n\n- пункт **один**\n- пункт два\n\nГотово.`;
  setTimeout(() => { live = { text: "" }; const w = full.split(/(\s+)/); let i = 0;
    const iv = setInterval(() => { i += (args.includes("--stream-long") ? 12 : 3); live.text = w.slice(0, i).join(""); if (i >= w.length) { clearInterval(iv); add("assistant", full); live = null; busy = false; } }, args.includes("--stream-long") ? 300 : 250); }, 1500);
}
const server = http.createServer((req, res) => {
  const send = (c, o) => { res.writeHead(c, { "content-type": "application/json" }); res.end(JSON.stringify(o)); };
  if (req.headers.authorization !== `Bearer ${token}`) return send(401, { ok: false, error: "unauthorized" });
  const url = new URL(req.url, "http://x");
  if (url.pathname === "/api/health") return send(200, { ok: true });
  if (url.pathname === "/api/state") return send(200, { busy, helpers, last: seq });
  if (url.pathname === "/api/history") {
    const after = Number(url.searchParams.get("after") ?? 0), limit = Number(url.searchParams.get("limit") ?? 200);
    const list = items.filter((i) => i.seq > after).slice(-limit);
    if (busy && live) list.push({ seq: seq + 1, role: "assistant", text: live.text, images: [], ts: new Date().toISOString(), partial: true });
    return send(200, { items: list, busy, last: seq });
  }
  if (req.method === "POST" && url.pathname === "/api/send") {
    let b = ""; req.on("data", (c) => (b += c)); req.on("end", () => {
      const { text = "", images = [] } = JSON.parse(b || "{}");
      for (const p of images) if (!fs.existsSync(p)) return send(400, { ok: false, error: `нет такого файла: ${p}` });
      const it = add("user", text + images.map((_, i) => ` [картинка ${i + 1}]`).join(""), images);
      console.log("send:", JSON.stringify({ text, images })); reply(text); send(200, { ok: true, seq: it.seq });
    }); return;
  }
  send(404, { ok: false, error: "нет такого адреса" });
});
server.listen(0, "127.0.0.1", () => { fs.writeFileSync(cfg, JSON.stringify({ port: server.address().port, token })); console.log("mock on", server.address().port, cfg); });
process.on("SIGTERM", () => process.exit(0));
