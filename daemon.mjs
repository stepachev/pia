// pia — фоновая служба: держит главный разговор и помощников, пока Mac включён (даже без открытого терминала).
// Запускается launchd (~/Library/LaunchAgents/com.pi-agent.server.plist) при входе и перезапускается при падении.
// Окна подключаются по HTTP: адрес и ключ — в ~/.pi-agent/server.json (права 600), слушает только 127.0.0.1.
import fs from "node:fs";
import { execFileSync } from "node:child_process";
import { APP, WORKDIR } from "./shared.mjs";
import { createKeepAwake } from "./keep-awake.mjs";
import { createServer, listen, newToken, readServerFile, writeServerFile } from "./server.mjs";

const LOG = `${APP}/daemon.log`;
const log = (s) => { try { fs.appendFileSync(LOG, `${new Date().toISOString()} [${process.pid}] ${s}\n`); } catch {} };
const DEFAULT_PORT = Number(process.env.PIA_PORT) || 47615;
fs.mkdirSync(APP, { recursive: true });

// ── Замок: разговор пишет только один процесс. Пока открыт старый pia (до перехода) — ждём, когда его закроют ──
const LOCK = `${APP}/agent.lock`;
const alive = (pid) => { try { process.kill(pid, 0); return true; } catch (e) { return e.code === "EPERM"; } };
const cmdOf = (pid) => { try { return execFileSync("ps", ["-o", "command=", "-p", String(pid)], { encoding: "utf8", timeout: 3000 }).trim(); } catch { return ""; } };
let waitedSince = 0;
for (;;) {
  let pid = 0; try { pid = Number(fs.readFileSync(LOCK, "utf8")); } catch {}
  if (!pid || pid === process.pid || !alive(pid) || !/node|MacOS\/pia /.test(cmdOf(pid))) break;
  if (!waitedSince) { waitedSince = Date.now(); log(`жду: разговор держит процесс ${pid} (${cmdOf(pid).slice(0, 120)})`); }
  await new Promise((r) => setTimeout(r, 2000));
}
if (waitedSince) log(`дождался (${Math.round((Date.now() - waitedSince) / 1000)} с)`);
fs.writeFileSync(LOCK, String(process.pid));
const releaseLock = () => { try { if (fs.readFileSync(LOCK, "utf8") === String(process.pid)) fs.unlinkSync(LOCK); } catch {} };
process.on("exit", releaseLock);
process.on("exit", () => { try { keepAwake?.stop(); } catch {} });

let core, server, closing = false, keepAwake;

const IMAGES = `${WORKDIR}/mac-images`, IMAGES_KEEP_DAYS = 3;
function cleanImages() {
  const cutoff = Date.now() - IMAGES_KEEP_DAYS * 86400_000;
  let n = 0, bytes = 0;
  let list = []; try { list = fs.readdirSync(IMAGES, { withFileTypes: true }); } catch { return; }
  for (const d of list) {
    if (!d.isFile()) continue;
    const p = `${IMAGES}/${d.name}`;
    try { const st = fs.statSync(p); if (st.mtimeMs < cutoff) { fs.unlinkSync(p); n++; bytes += st.size; } } catch {}
  }
  if (n) log(`картинки: удалено ${n} старше ${IMAGES_KEEP_DAYS} дней (${(bytes / 1048576).toFixed(1)} МБ)`);
}
async function shutdown(code, why) {
  if (closing) return; closing = true;
  log(`останавливаюсь: ${why}`);
  const force = setTimeout(() => { log("не закрылся за 20 с — выхожу принудительно"); process.exit(code); }, 20_000); force.unref();
  try { keepAwake?.stop(); } catch {}
  try { server?.closeStreams(); server?.close(); } catch {}
  try { await core?.close(); } catch (e) { log(`ошибка при закрытии: ${e?.stack ?? e}`); }
  const { kickMemoryWorker } = await import("./core.mjs");
  kickMemoryWorker();
  process.exit(code);
}
process.on("SIGTERM", () => shutdown(0, "SIGTERM"));
process.on("SIGINT", () => shutdown(0, "SIGINT"));
process.on("SIGHUP", () => {});   // закрытие терминала, из которого запускали вручную, не убивает службу
process.on("uncaughtException", (e) => { log(`uncaughtException: ${e?.stack ?? e}`); try { fs.appendFileSync(`${APP}/errors.log`, `${new Date().toISOString()} daemon: ${e?.stack ?? e}\n`); } catch {} });
process.on("unhandledRejection", (e) => { log(`unhandledRejection: ${e?.stack ?? e}`); });

try {
  const t0 = Date.now();
  const { openCore } = await import("./core.mjs");
  core = await openCore();
  const file = `${APP}/server.json`;
  const prev = readServerFile(file);
  const token = prev?.token ?? newToken();
  server = createServer(core, { token });
  const port = await listen(server, [prev?.port, DEFAULT_PORT].filter(Boolean));
  writeServerFile(file, { port, token });
  keepAwake = createKeepAwake({ getState: () => core.state(), log });
  // Память: раз в 30 минут (и при старте) — разбор разговора дочерним процессом pia; отдельной службы нет
  { const { kickMemoryWorker } = await import("./core.mjs"); setTimeout(kickMemoryWorker, 15_000).unref(); setInterval(kickMemoryWorker, 30 * 60_000).unref(); }
  // Картинки из окна pia (снимки контекста, вставки): в разговор они уже вшиты, файлы нужны лишь для показа в старых
  // сообщениях — старше 3 дней удаляем (через минуту после запуска и раз в 6 часов)
  setTimeout(cleanImages, 60_000).unref(); setInterval(cleanImages, 6 * 3600_000).unref();
  keepAwake.start();
  log(`готов: 127.0.0.1:${port}, запуск ${Date.now() - t0} мс`);
} catch (e) {
  log(`не запустился: ${e?.stack ?? e}`);
  try { fs.appendFileSync(`${APP}/errors.log`, `${new Date().toISOString()} daemon start: ${e?.stack ?? e}\n`); } catch {}
  await shutdown(1, "ошибка запуска");
}
