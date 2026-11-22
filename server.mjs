// HTTP для окон pia (Raycast, терминал): слушает только 127.0.0.1, все запросы — с Authorization: Bearer <token>.
// Протокол (для Raycast):
//   GET  /api/health                         → {"ok": true}
//   GET  /api/history?after=<seq>&limit=<n>  → {"items": [{seq, role: user|assistant|report, text, images, ts}], "busy", "last"}
//   POST /api/send {"text", "images": [абсолютные пути]} → {"ok": true, "seq"}
// Для терминального окна дополнительно: GET /api/stream (поток событий NDJSON), POST /api/stop, POST /api/compact.
// core — объект с history/send/stop/compact/state/subscribe (см. core.mjs); в проверках — подделка.
import http from "node:http";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { APP } from "./shared.mjs";
import { isHelperPeer } from "./proctree.mjs";

const MAX_BODY = 2 * 1024 * 1024;
export const newToken = () => crypto.randomBytes(24).toString("base64url");

function authOk(req, token) {
  const h = String(req.headers.authorization ?? "");
  const m = /^Bearer\s+(.+)$/i.exec(h);
  if (!m) return false;
  const a = Buffer.from(m[1].trim()), b = Buffer.from(token);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}
function reply(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", "content-length": Buffer.byteLength(body) });
  res.end(body);
}
function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0; const chunks = [];
    req.on("data", (c) => { size += c.length; if (size > MAX_BODY) { reject(Object.assign(new Error("слишком большой запрос"), { code: 413 })); req.destroy(); } else chunks.push(c); });
    req.on("end", () => {
      const s = Buffer.concat(chunks).toString("utf8");
      if (!s.trim()) return resolve({});
      try { resolve(JSON.parse(s)); } catch { reject(Object.assign(new Error("тело запроса — не JSON"), { code: 400 })); }
    });
    req.on("error", reject);
  });
}
const bad = (msg) => Object.assign(new Error(msg), { code: 400 });
// Проверка тела /api/send: текст и/или картинки (абсолютные пути к существующим файлам)
export function checkSend(body) {
  if (!body || typeof body !== "object" || Array.isArray(body)) throw bad("нужен JSON-объект");
  const text = body.text == null ? "" : body.text;
  if (typeof text !== "string") throw bad("text — строка");
  const images = body.images == null ? [] : body.images;
  if (!Array.isArray(images) || images.some((p) => typeof p !== "string")) throw bad("images — массив путей");
  for (const p of images) {
    if (!path.isAbsolute(p)) throw bad(`путь к картинке должен быть абсолютным: ${p}`);
    if (!fs.existsSync(p) || !fs.statSync(p).isFile()) throw bad(`нет такого файла: ${p}`);
  }
  const pairs = (v) => (Array.isArray(v) ? v.filter((x) => Array.isArray(x) && x.length === 2 && x.every((y) => typeof y === "string")) : []);
  const tokens = pairs(body.tokens), pastes = pairs(body.pastes);
  if (!text.trim() && !images.length && !tokens.length) throw bad("пустое сообщение");
  return { text, images, tokens, pastes, source: typeof body.source === "string" ? body.source.slice(0, 20) : "raycast" };
}

// Решение: можно ли принять сообщение. В чат как сообщение пользователя идёт только то, что набрал человек
// (окно pia-app, Raycast, интерактивная pia). Возвращает причину отказа или null.
export function sendVerdict(body, { fromHelper = false } = {}) {
  if (body && body.helper) return "из команды помощника";
  if (fromHelper) return "процесс-потомок помощника";
  if (body && body.source === "cli" && body.tty !== true) return "cli без терминала";
  return null;
}
const blockedLog = (text, why) => { try { fs.appendFileSync(`${APP}/daemon.log`, `${new Date().toISOString()} [${process.pid}] заблокировано сообщение не от пользователя: ${String(text ?? "").replace(/\s+/g, " ").slice(0, 60)} (${why})\n`); } catch {} };
export function createServer(core, { token }) {
  const streams = new Set();
  const server = http.createServer(async (req, res) => {
    try {
      const url = new URL(req.url, "http://127.0.0.1");
      if (!url.pathname.startsWith("/api/")) return reply(res, 404, { ok: false, error: "нет такого адреса" });
      if (!authOk(req, token)) return reply(res, 401, { ok: false, error: "нужен Authorization: Bearer <token> из ~/.pi-agent/server.json" });
      const route = `${req.method} ${url.pathname}`;
      if (route === "GET /api/health") return reply(res, 200, { ok: true });
      if (route === "GET /api/history") {
        return reply(res, 200, core.history(Number(url.searchParams.get("after") ?? 0) || 0, Number(url.searchParams.get("limit") ?? 200) || 200));
      }
      if (route === "POST /api/send") {
        const raw = await readBody(req);
        const why = sendVerdict(raw, { fromHelper: await isHelperPeer(req.socket.remotePort, req.socket.localPort).catch(() => false) });
        if (why) { blockedLog(raw?.text, why); return reply(res, 403, { ok: false, error: "сообщение не отправлено — отправлять может только человек в окне или терминале" }); }
        const msg = checkSend(raw);
        const item = await core.send(msg);
        return reply(res, 200, { ok: true, seq: item.seq });
      }
      if (route === "POST /api/stop") { await core.stop(); return reply(res, 200, { ok: true }); }
      if (route === "POST /api/compact") { const text = await core.compact(); return reply(res, 200, { ok: true, text }); }
      if (route === "GET /api/state") return reply(res, 200, core.state());
      if (route === "GET /api/stream") {
        // Поток для терминального окна: строка JSON на событие. Сначала hello (записи после after или последние tail, состояние),
        // потом item / live / helpers / notice; раз в 15 с — ping.
        res.writeHead(200, { "content-type": "application/x-ndjson; charset=utf-8", "cache-control": "no-store", connection: "keep-alive" });
        const send = (ev) => { try { res.write(JSON.stringify(ev) + "\n"); } catch {} };
        const after = url.searchParams.get("after");
        const tail = Number(url.searchParams.get("tail") ?? 8) || 0;
        send({ type: "hello", ...core.hello(after != null ? Number(after) || 0 : null, tail) });
        const off = core.subscribe(send);
        const ping = setInterval(() => send({ type: "ping" }), 15_000);
        const s = { res, kind: url.searchParams.get("client") ?? "" };
        streams.add(s);
        req.socket.setTimeout(0);
        const done = () => { if (!streams.has(s)) return; streams.delete(s); clearInterval(ping); off(); core.onStreamClosed?.(s.kind); };
        res.on("close", done); req.on("close", done);
        return;
      }
      return reply(res, 404, { ok: false, error: "нет такого адреса" });
    } catch (e) {
      const code = typeof e?.code === "number" ? e.code : 500;
      if (!res.headersSent) reply(res, code, { ok: false, error: String(e?.message ?? e) });
      else try { res.end(); } catch {}
    }
  });
  server.closeStreams = () => { for (const s of streams) try { s.res.end(); } catch {} };
  return server;
}

// Слушать только 127.0.0.1: сначала прежний порт, потом обычный, потом любой свободный
export async function listen(server, ports) {
  for (const port of [...ports, 0]) {
    try {
      await new Promise((resolve, reject) => {
        const onErr = (e) => { server.off("listening", onOk); reject(e); };
        const onOk = () => { server.off("error", onErr); resolve(); };
        server.once("error", onErr); server.once("listening", onOk);
        server.listen(port, "127.0.0.1");
      });
      return server.address().port;
    } catch (e) { if (e?.code !== "EADDRINUSE" && e?.code !== "EACCES") throw e; }
  }
  throw new Error("не удалось занять порт");
}

// server.json: {"port", "token"} с правами 600; токен сохраняется между перезапусками
export function readServerFile(file) { try { const o = JSON.parse(fs.readFileSync(file, "utf8")); return typeof o?.port === "number" && typeof o?.token === "string" ? o : null; } catch { return null; } }
export function writeServerFile(file, { port, token }) {
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify({ port, token }, null, 2) + "\n", { mode: 0o600 });
  fs.chmodSync(tmp, 0o600);
  fs.renameSync(tmp, file);
}
