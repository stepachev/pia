// Связь окна (терминал) с фоновой службой pia: server.json, запросы, поток событий, запуск службы.
import fs from "node:fs";
import os from "node:os";
import http from "node:http";
import { spawn, execFile } from "node:child_process";
import { APP } from "./shared.mjs";
import { readServerFile } from "./server.mjs";

export const SERVER_FILE = `${APP}/server.json`;
export const LABEL = "com.pi-agent.server";
export const PLIST = `${os.homedir()}/Library/LaunchAgents/${LABEL}.plist`;
const DOMAIN = `gui/${process.getuid?.() ?? 501}`;
// Проверочный экземпляр (PIA_HOME) служба launchd не трогает — запускает свой процесс
const useLaunchd = () => !process.env.PIA_HOME && fs.existsSync(PLIST);

export function request(conn, method, path, body, timeoutMs = 10_000) {
  return new Promise((resolve, reject) => {
    const data = body === undefined ? null : Buffer.from(JSON.stringify(body));
    const req = http.request({ host: "127.0.0.1", port: conn.port, method, path, timeout: timeoutMs,
      headers: { authorization: `Bearer ${conn.token}`, "content-type": "application/json", ...(data ? { "content-length": data.length } : {}) } }, (res) => {
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => {
        let o; try { o = JSON.parse(Buffer.concat(chunks).toString("utf8")); } catch { o = {}; }
        if (res.statusCode >= 400) reject(new Error(o.error ?? `ошибка ${res.statusCode}`)); else resolve(o);
      });
    });
    req.on("timeout", () => req.destroy(new Error("нет ответа от pia")));
    req.on("error", reject);
    if (data) req.write(data);
    req.end();
  });
}
export async function health(conn) {
  if (!conn) return false;
  try { return (await request(conn, "GET", "/api/health", undefined, 1500)).ok === true; } catch { return false; }
}

// Поток событий: onEvent на каждое, onDrop при обрыве. Возвращает { close }.
export function openStream(conn, query, onEvent, onDrop) {
  let buf = "", dropped = false;
  const drop = (e) => { if (!dropped) { dropped = true; onDrop(e); } };
  const req = http.get({ host: "127.0.0.1", port: conn.port, path: `/api/stream?${new URLSearchParams(query)}`, headers: { authorization: `Bearer ${conn.token}` } }, (res) => {
    if (res.statusCode !== 200) { res.resume(); return drop(new Error(`ошибка ${res.statusCode}`)); }
    res.setEncoding("utf8");
    res.on("data", (s) => {
      buf += s;
      let i;
      while ((i = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, i); buf = buf.slice(i + 1);
        if (line.trim()) { try { onEvent(JSON.parse(line)); } catch {} }
      }
    });
    res.on("end", () => drop());
    res.on("error", drop);
  });
  req.on("error", drop);
  return { close: () => { dropped = true; req.destroy(); } };
}

const run = (cmd, args) => new Promise((resolve) => execFile(cmd, args, { timeout: 15_000 }, (err, stdout, stderr) => resolve({ ok: !err, out: String(stdout) + String(stderr) })));
const alive = (pid) => { try { process.kill(pid, 0); return true; } catch (e) { return e.code === "EPERM"; } };
const cmdOf = async (pid) => (await run("ps", ["-o", "command=", "-p", String(pid)])).out.trim();

// Кто сейчас держит разговор: служба (daemon.mjs) или старый pia в другом окне (до перехода)
export async function lockHolder() {
  let pid = 0; try { pid = Number(fs.readFileSync(`${APP}/agent.lock`, "utf8")); } catch {}
  if (!pid || !alive(pid)) return null;
  const cmd = await cmdOf(pid);
  if (!/node|MacOS\/pia /.test(cmd)) return null;
  return { pid, daemon: /daemon\.mjs/.test(cmd) };
}

export async function serviceLoaded() { return (await run("launchctl", ["print", `${DOMAIN}/${LABEL}`])).ok; }
export async function startService() {
  if (useLaunchd()) {
    if (!(await serviceLoaded())) return run("launchctl", ["bootstrap", DOMAIN, PLIST]);
    return run("launchctl", ["kickstart", `${DOMAIN}/${LABEL}`]);
  }
  // Без launchd (проверочный экземпляр или служба не установлена) — отдельный процесс в фоне
  const out = fs.openSync(`${APP}/daemon.out`, "a");
  spawn(process.execPath, [new URL("./daemon.mjs", import.meta.url).pathname], { detached: true, stdio: ["ignore", out, out], env: { ...process.env, NODE_NO_WARNINGS: "1" } }).unref();
  return { ok: true, out: "" };
}
export async function stopService() {
  if (useLaunchd()) return run("launchctl", ["bootout", `${DOMAIN}/${LABEL}`]);
  const h = await lockHolder();
  if (h?.daemon) { process.kill(h.pid, "SIGTERM"); return { ok: true, out: "" }; }
  return { ok: false, out: "служба не запущена" };
}
export async function restartService() {
  if (useLaunchd() && (await serviceLoaded())) return run("launchctl", ["kickstart", "-k", `${DOMAIN}/${LABEL}`]);
  await stopService();
  for (let i = 0; i < 100 && (await lockHolder())?.daemon; i++) await new Promise((r) => setTimeout(r, 200));
  return startService();
}

// Подключиться к службе; если не запущена — запустить и дождаться. say(text) — показать, чего ждём.
export async function connect(say = () => {}, { timeoutMs = 120_000 } = {}) {
  let conn = readServerFile(SERVER_FILE);
  if (await health(conn)) return conn;
  let t0 = Date.now();
  let started = false, said = "";
  const tell = (s) => { if (s !== said) { said = s; say(s); } };
  while (Date.now() - t0 < timeoutMs) {
    const h = await lockHolder();
    if (h && !h.daemon) tell(`Сейчас pia открыт по-старому в другом окне (процесс ${h.pid}). Закрой его там (Ctrl+D в пустом поле) — это окно подключится само.`);
    else if (!started && !h) { started = true; await startService(); tell("запускаю pia в фоне…"); }
    else if (h?.daemon) tell("pia запускается…");
    await new Promise((r) => setTimeout(r, 500));
    conn = readServerFile(SERVER_FILE);
    if (await health(conn)) return conn;
    if (h && !h.daemon) { started = false; t0 = Date.now(); }   // старое окно: ждём сколько нужно
  }
  throw new Error(`pia не запустился за ${Math.round(timeoutMs / 1000)} с. Журнал: ${APP}/daemon.log`);
}
