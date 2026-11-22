// pia — окно в терминале. Сам разговор, помощники и сторож живут в фоновой службе (daemon.mjs → core.mjs),
// которая работает и без открытого терминала; окно подключается к ней по HTTP (server.json) и показывает тот же
// общий разговор, что и Raycast. Закрыть окно (Ctrl+D) — работа продолжается в фоне.
import fs from "node:fs";
import readline from "node:readline";
import { LiveArea, MdStream, clipEnd, detectTheme, footerRows, userCardRows } from "./render.mjs";
import { Editor } from "./input.mjs";
import { clipboardImage, stashImage } from "./attachments.mjs";
import { APP } from "./shared.mjs";
import { connect, request, openStream, startService, stopService, restartService, lockHolder, serviceLoaded, health, SERVER_FILE, PLIST } from "./client.mjs";
import { readServerFile } from "./server.mjs";

const dim = (s) => `\x1b[2m${s}\x1b[0m`;
const args = process.argv.slice(2);
const tty = !!process.stdout.isTTY;
const errSay = (s) => process.stderr.write((process.stderr.isTTY ? dim(s) : s) + "\n");

// ── Команды без окна ──
// pia login [провайдер] — подключить провайдера моделей; pia --models — какие модели у ролей и есть ли доступ
if (args[0] === "login" || args[0] === "--login") { await import("./login.mjs"); await new Promise(() => {}); }
if (args[0] === "--models") { process.argv.splice(2, 1, "--status"); await import("./login.mjs"); await new Promise(() => {}); }
if (args[0] === "/usage") { const { printUsage } = await import("./usage.mjs"); printUsage(); process.exit(0); }
if (["--status", "--start", "--stop", "--restart"].includes(args[0])) {
  const cmd = args[0];
  if (cmd === "--stop") { const r = await stopService(); console.log(r.ok ? "Служба pia остановлена (до следующего запуска pia или входа в систему)." : `Не вышло: ${r.out.trim()}`); process.exit(0); }
  if (cmd === "--restart") { const r = await restartService(); if (!r.ok) console.log(`Не вышло: ${r.out.trim()}`); }
  if (cmd === "--start") await startService();
  if (cmd !== "--status") { try { await connect(errSay, { timeoutMs: 120_000 }); } catch (e) { console.log(e.message); process.exit(1); } }
  const conn = readServerFile(SERVER_FILE), up = await health(conn), h = await lockHolder();
  console.log(`Служба launchd: ${fs.existsSync(PLIST) ? ((await serviceLoaded()) ? "загружена" : "не загружена") : "не установлена"} (${PLIST})`);
  console.log(`Процесс: ${h ? `${h.pid}${h.daemon ? " (служба)" : " (старое окно pia)"}` : "нет"}`);
  console.log(`Связь: ${up ? `есть, 127.0.0.1:${conn.port}` : "нет"} · ${SERVER_FILE}`);
  if (up) {
    const s = await request(conn, "GET", "/api/state");
    console.log(`Сейчас: ${s.busy ? "отвечает" : "свободен"}; помощников работает: ${s.helpers.filter((x) => x.state === "работает").length}`);
  }
  process.exit(0);
}

const INTERACTIVE = !args.length && process.stdin.isTTY && tty;
if (tty && process.stdin.isTTY) await detectTheme({ keepRaw: INTERACTIVE });

// Пока ждём службу, Ctrl+C / Ctrl+D в окне — выйти (в «сыром» режиме сигнала нет)
let waitKeys = null;
if (INTERACTIVE) {
  readline.emitKeypressEvents(process.stdin);
  process.stdin.setRawMode(true); process.stdin.resume();
  waitKeys = (s, key) => { if (key?.ctrl && (key.name === "c" || key.name === "d")) { try { process.stdin.setRawMode(false); } catch {} process.exit(130); } };
  process.stdin.on("keypress", waitKeys);
}
let conn;
try { conn = await connect(errSay); }
catch (e) { console.log(e.message); process.exit(1); }
if (waitKeys) process.stdin.off("keypress", waitKeys);

// ── Вопрос без окна: pia "текст" или строки из файла/программы ──
// Ответ печатается текстом; помощники продолжают в фоне, их отчёты придут в общий разговор.
async function askOnce(text) {
  let sent = null, sawBusy = false, helpersRunning = 0, finish;
  const items = [], printedSeqs = new Set();
  const done = new Promise((r) => (finish = r));
  let ready; const hello = new Promise((r) => (ready = r));
  const flush = () => { for (const it of items) if (sent != null && it.seq > sent && it.role === "assistant" && !printedSeqs.has(it.seq)) { printedSeqs.add(it.seq); console.log(it.text); } };
  const st = openStream(conn, { client: "cli", tail: 0 }, (ev) => {
    if (ev.type === "hello") { helpersRunning = ev.helpers.filter((h) => h.state === "работает").length; ready(); }
    else if (ev.type === "item") { items.push(ev.item); flush(); }
    else if (ev.type === "helpers") helpersRunning = ev.helpers.filter((h) => h.state === "работает").length;
    else if (ev.type === "live") { if (ev.live.busy) sawBusy = true; else if (sent != null && sawBusy) finish(); }
  }, () => { ready(); finish(); });
  await hello;
  const onSig = () => { request(conn, "POST", "/api/stop", {}).catch(() => {}); };
  process.on("SIGINT", onSig);
  try { sent = (await request(conn, "POST", "/api/send", { text, source: "cli" }, 60_000)).seq; }
  catch (e) { console.log("Ошибка: " + e.message); st.close(); return; }
  flush();
  const s = await request(conn, "GET", "/api/state").catch(() => null);
  if (s && !s.busy && !sawBusy) setTimeout(finish, 3000);   // ход уже закончился до подключения
  await done;
  flush(); st.close(); process.off("SIGINT", onSig);
  if (helpersRunning) errSay(`Помощники работают в фоне (${helpersRunning}) — отчёт придёт в общий разговор (pia или Raycast).`);
}

if (args[0] === "/compact") {
  errSay("сжимаю разговор…");
  try { console.log((await request(conn, "POST", "/api/compact", {}, 15 * 60_000)).text); } catch (e) { console.log("Не вышло: " + e.message); }
  process.exit(0);
}
if (args.length) { await askOnce(args.join(" ")); process.exit(0); }
if (!INTERACTIVE) {
  const rl = readline.createInterface({ input: process.stdin });
  for await (const line of rl) if (line.trim()) await askOnce(line);
  process.exit(0);
}

// ── Окно ─────────────────────────────────────────────────
// Всё, что ушло вверх, печатается один раз; внизу живая область — дописываемый абзац ответа,
// строка активности, помощники и поле ввода (всегда доступно, как в fx).
const cols = () => Math.max(20, (process.stdout.columns || 80) - 1);
const area = new LiveArea((s) => process.stdout.write(s));
let commitQ = [];        // ряды, которые надо напечатать навсегда
let printed = false;     // уже что-то напечатано (между блоками — одна пустая строка)
let editor = null;       // поле ввода
let helpersOpen = false; // список помощников раскрыт (↓ в пустом поле или ⌃X), как у fx
let live = { busy: false, stopping: false, label: "думаю", startedAt: 0, key: null, text: "", toolRunning: false };
let helpers = [];        // помощники (от службы)
const workers = () => helpers.filter((h) => h.state === "работает").length;   // «N работяг» — только работающие
let offline = null;      // нет связи со службой — текст для строки активности
let cur = null;          // ответ, который сейчас печатается: { key, target, base, shownLen, msg, done }
let cards = [];          // плашки сообщений, пришедших, пока печатается абзац ответа
const renderedKeys = new Set();   // ответы, уже напечатанные из потока (чтобы готовый не напечатать второй раз)
let lastSeq = 0;         // последний полученный номер записи — для переподключения

function block(rows) { if (printed) commitQ.push(""); commitQ.push(...rows); printed = true; }
const cardRows = (it) => [...userCardRows(it.card ?? it.text, cols()), ...(it.notes ?? []).map((n) => dim("  " + clipEnd(n, cols() - 2)))];
const showCards = () => { for (const rows of cards) block(rows); cards = []; };
const newCur = (key, target = "", done = false) => ({ key, target, base: 0, shownLen: 0, msg: null, done });
// Допечатать текущий ответ целиком и закрыть его
function finishCur() {
  if (cur) {
    if (cur.msg) commitQ.push(...cur.msg.step(cur.target.slice(cur.base), true).commit);
    else if (cur.target.trim()) { block([]); commitQ.push(...new MdStream(cols()).step(cur.target, true).commit); }
    if (cur.key) renderedKeys.add(cur.key);
    cur = null;
  }
  showCards();
}
// Как у fx: плавно (пейсер), абзац перерисовывается, пока дописывается, переносы по словам
function view() {
  let rows = [];
  if (cur) {
    if (!cur.msg && cur.shownLen < cur.target.length) { block([]); cur.msg = new MdStream(cols()); }
    if (cur.msg) {
      const back = cur.target.length - cur.shownLen;
      if (back > 0) {
        let n = Math.min(cur.target.length, cur.shownLen + Math.max(2, Math.ceil(back / 6)));
        const cc = cur.target.charCodeAt(n - 1); if (cc >= 0xd800 && cc <= 0xdbff) n++;
        cur.shownLen = n;
      }
      const r = cur.msg.step(cur.target.slice(cur.base, cur.shownLen));
      commitQ.push(...r.commit); rows = r.live;
    }
    if (cur.done && cur.shownLen >= cur.target.length) { finishCur(); rows = []; }
  }
  const streaming = cur?.msg && (cur.shownLen < cur.target.length || live.label === "думаю");
  const status = offline ? { raw: dim(offline) }
    : !live.busy ? null
    : live.stopping ? { raw: dim("останавливаю…") }
    : streaming ? null
    : { label: live.label, startedAt: live.startedAt };
  return { live: rows, status };
}
function draw() {
  const v = view();
  if (!workers()) helpersOpen = false;
  const status = footerRows({ ...(v.status ?? {}), helpers, open: helpersOpen, cols: cols(), key: !editor || editor.idle ? "↓" : "⌃X" });
  const gap = !v.live.length && status.length && printed ? [""] : [];
  const top = [...v.live, ...gap, ...status];
  let rows = top, cursor = null;
  if (editor) {
    const inp = editor.render(cols());
    rows = [...top, ...(top.length || printed ? [""] : []), ...inp.rows];
    cursor = { row: rows.length - inp.rows.length + inp.cursor.row, col: inp.cursor.col };
  }
  const c = commitQ; commitQ = [];
  area.render(c, rows, cursor);
  lastDraw = Date.now();
}
let lastDraw = 0;

// ── События службы ──
function onItem(it, instant = false) {
  lastSeq = Math.max(lastSeq, it.seq);
  if (it.role === "user") {
    const rows = cardRows(it);
    if (cur?.msg) cards.push(rows); else { finishCur(); block(rows); }   // дописка во время ответа — после текущего абзаца
  } else if (it.role === "report") {
    finishCur(); block([dim(clipEnd(`помощник #${it.n ?? "?"} закончил: ${it.title ?? ""}`, cols()))]);
  } else if (it.role === "assistant") {
    if (it.service) { finishCur(); block([it.text]); return; }
    if (it.stream && cur?.key === it.stream) {
      if (it.text.startsWith(cur.target.trimEnd())) cur.target = it.text;
      else { finishCur(); renderedKeys.delete(it.stream); cur = newCur(it.stream, it.text); }
      cur.done = true;
      return;
    }
    if (it.stream && renderedKeys.has(it.stream)) return;
    finishCur();
    cur = newCur(it.stream ?? `seq${it.seq}`, it.text, true);
    if (instant) finishCur();
  }
}
function onLive(l) {
  live = l;
  if (l.key && l.text) {
    if (cur && cur.key !== l.key) finishCur();
    if (!cur) { if (renderedKeys.has(l.key)) return; cur = newCur(l.key); }
    if (!l.text.startsWith(cur.target)) { const k = cur.key; finishCur(); renderedKeys.delete(k); cur = newCur(k); }   // ответ начался заново
    cur.target = l.text;
  } else if (cur && !cur.done) {
    if (l.toolRunning) finishCur();     // пошёл инструмент — текст этого сообщения закончен
    else if (!l.busy) cur.done = true;  // ход закончился — допечатать и закрыть
  }
}
function onEvent(ev) {
  if (ev.type === "hello") {
    for (const it of ev.items) onItem(it, true);
    lastSeq = Math.max(lastSeq, ev.last ?? 0);
    helpers = ev.helpers ?? [];
    onLive(ev.live);
  } else if (ev.type === "item") onItem(ev.item);
  else if (ev.type === "live") onLive(ev.live);
  else if (ev.type === "helpers") helpers = ev.helpers;
  else if (ev.type === "notice") { finishCur(); block([dim(ev.text)]); }
  else return;
  draw();
}
let stream = null, quitting = false;
function attach() {
  stream = openStream(conn, { client: "terminal", ...(lastSeq ? { after: lastSeq } : { tail: 6 }) }, (ev) => { offline = null; onEvent(ev); }, async () => {
    if (quitting) return;
    finishCur();
    live = { ...live, busy: false, stopping: false };
    offline = "нет связи с pia — переподключаюсь…"; draw();
    for (;;) {
      await new Promise((r) => setTimeout(r, 1000));
      if (quitting) return;
      try { conn = await connect((s) => { offline = s; draw(); }, { timeoutMs: 30_000 }); break; } catch {}
    }
    offline = null; draw();
    attach();
  });
}
const post = (path, body, ms) => request(conn, "POST", path, body, ms);
const stop = () => post("/api/stop", {}).catch(() => {});

process.stdout.write("\x1b[?2004h");          // «скобки вставки»: вставка приходит целиком
process.stdout.write("\n");                  // пустая строка после команды «pia»
process.on("exit", () => { try { process.stdout.write("\x1b[?2026l\x1b[?25h\x1b[?2004l"); process.stdin.setRawMode(false); } catch {} });
let quit; const exited = new Promise((r) => (quit = r));
editor = new Editor({
  historyFile: `${APP}/history.json`,
  onChange: draw,
  // Esc сначала сворачивает открытый список помощников, потом останавливает работу
  onEscape: () => { if (helpersOpen) { helpersOpen = false; draw(); } else if (live.busy) stop(); },
  // Как у fx: ↓ в пустом поле (история не листается) раскрывает/сворачивает помощников, ↑ — сворачивает
  onArrow: (dir) => {
    if (dir > 0 && editor.idle && workers()) { helpersOpen = !helpersOpen; draw(); return true; }
    if (dir < 0 && helpersOpen && editor.idle) { helpersOpen = false; draw(); return true; }
    return false;
  },
  onToggle: () => { helpersOpen = !helpersOpen && workers() > 0; draw(); },
  onInterrupt: (hasText) => { if (live.busy) stop(); else if (hasText) { editor.set(""); draw(); } else quit(); },
  // Закрыть окно можно и во время работы: она продолжится в фоне
  onExit: () => quit(),
  // Ctrl+V или ⌘V, когда в буфере только картинка (терминал присылает пустую вставку)
  onImage: async () => {
    const file = await clipboardImage(`${APP}/вложения`);
    if (file) editor.addImage(file);
    draw();
  },
  // Вставили путь к картинке, а файла уже/ещё нет (временный файл CleanShot) — картинка из буфера
  clipboardImage: () => clipboardImage(`${APP}/вложения`),
  // Вставленные картинки — копией в «вложения»: не пропадут до отправки и служба (launchd) их прочтёт
  keepImage: (file) => stashImage(file, `${APP}/вложения`),
  onSubmit: async (text, images, pastes = new Map()) => {
    const line = text.trim();
    if (["/выход", "/exit", "exit"].includes(line)) return quit();
    if (line === "/usage") { const { usageText } = await import("./usage.mjs"); block(usageText().split("\n")); return draw(); }
    if (line === "/compact" && live.busy) { block([dim("Сейчас занят — сожму после ответа, повтори чуть позже.")]); return draw(); }
    if (line === "/compact") { post("/api/compact", {}, 15 * 60_000).catch((e) => { block(["Не вышло: " + e.message]); draw(); }); return; }
    // Сообщение уходит в общий разговор; плашка придёт обратно событием (так же, как сообщения из Raycast)
    try { await post("/api/send", { text, tokens: [...images], pastes: [...pastes], source: "terminal" }, 60_000); }
    catch (e) { block([`Не отправилось: ${e.message}`]); draw(); }
  },
});
attach();
setInterval(() => { if (cur || live.busy || offline || (helpersOpen && Date.now() - lastDraw > 500)) draw(); }, 40).unref();
process.stdin.on("keypress", (s, key) => editor.key(s, key, cols()));
process.stdout.on("resize", () => { area.reflow(process.stdout.columns); area.last = null; draw(); });
process.on("SIGHUP", () => quit());
draw();
await exited;
quitting = true;
stream?.close();
finishCur();
editor = null; draw();
process.exit(0);
