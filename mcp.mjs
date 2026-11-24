// Подключение MCP-серверов из ~/.pi-agent/mcp.json.
// Их умения не грузятся в каждое сообщение: помощник находит нужные через tool_search.
import fs from "node:fs";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { defineTool, defineExtension, section } from "@earendil-works/pi-durable";
import { APP, HOME, shrinkImage } from "./shared.mjs";
import { LIMITS, guardTool } from "./guard.mjs";

export const MCP_FILE = `${APP}/mcp.json`;

// Есть ли в mcp.json включённый сервер с таким именем (читается один раз при старте)
export function hasMcpServer(name) {
  try { const c = JSON.parse(fs.readFileSync(MCP_FILE, "utf8")).mcpServers?.[name]; return !!c && !c.disabled; } catch { return false; }
}

// MCP-серверы отдают схемы с ключами в случайном порядке. Если не упорядочить,
// при каждом запуске инструменты «меняются», и вся история разговора уходит мимо кэша (платится заново).
function stable(v, key) {
  if (Array.isArray(v)) { const a = v.map((x) => stable(x)); return key === "required" ? [...a].sort() : a; }
  if (v && typeof v === "object") return Object.fromEntries(Object.keys(v).sort().map((k) => [k, stable(v[k], k)]));
  return v;
}
function safe(s) { return s.replace(/[^a-zA-Z0-9_-]/g, "_"); }
function withTimeout(p, ms, what) {
  return Promise.race([p, new Promise((_, rej) => setTimeout(() => rej(new Error(`${what}: нет ответа за ${ms / 1000} с`)), ms))]);
}

const CACHE_FILE = `${APP}/pia/mcp-tools-cache.json`;
const IDLE_DEFAULT_MIN = 10;
const servers_ = new Map();

function readCache() { try { return JSON.parse(fs.readFileSync(CACHE_FILE, "utf8")); } catch { return {}; } }
function writeCache(name, sig, tools) {
  try {
    const all = readCache();
    all[name] = { sig, at: Date.now(), tools };
    fs.mkdirSync(`${APP}/pia`, { recursive: true });
    const tmp = `${CACHE_FILE}.${process.pid}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(all, null, 1));
    fs.renameSync(tmp, CACHE_FILE);
  } catch {}
}
function sigOf(cfg) { return JSON.stringify([cfg.command, cfg.args, cfg.url, cfg.cwd]); }

// Все потомки процесса (npx/обёртки + дети), чтобы остановить дерево целиком.
async function descendants(pid) {
  const { execFile } = await import("node:child_process");
  const out = await new Promise((r) => execFile("ps", ["-A", "-o", "pid=,ppid="], { timeout: 5000 }, (_e, so) => r(String(so ?? ""))));
  const kids = new Map();
  for (const line of out.split("\n")) {
    const [p, pp] = line.trim().split(/\s+/).map(Number);
    if (p && pp) (kids.get(pp) ?? kids.set(pp, []).get(pp)).push(p);
  }
  const res = [], stack = [pid];
  while (stack.length) for (const k of kids.get(stack.pop()) ?? []) { res.push(k); stack.push(k); }
  return res;
}
async function killTree(pid) {
  if (!pid) return;
  let all = [];
  try { all = await descendants(pid); } catch {}
  const list = [...all.reverse(), pid];
  for (const p of list) { try { process.kill(p, "SIGTERM"); } catch {} }
  await new Promise((r) => setTimeout(r, 1500));
  for (const p of list) { try { process.kill(p, 0); process.kill(p, "SIGKILL"); } catch {} }
}

class Server {
  constructor(name, cfg) {
    this.name = name; this.cfg = cfg; this.client = null; this.transport = null;
    this.starting = null; this.active = 0; this.last = 0; this.timer = null;
    this.keepAlive = cfg.keepAlive === true;
    const m = Number(cfg.idleMinutes);
    this.idleMs = (Number.isFinite(m) && m > 0 ? m : IDLE_DEFAULT_MIN) * 60_000;
  }
  async #open() {
    const cfg = this.cfg;
    const client = new Client({ name: "pi-agent", version: "1.0.0" });
    // bearerFile: токен лежит в отдельном файле вне git (например ~/.pi-agent/secrets/server.token), а не в mcp.json.
    const headers = { ...(cfg.headers ?? {}) };
    if (cfg.bearerFile) headers.Authorization = `Bearer ${fs.readFileSync(cfg.bearerFile.replace(/^~(?=\/)/, HOME), "utf8").trim()}`;
    const transport = cfg.url
      ? new StreamableHTTPClientTransport(new URL(cfg.url), { requestInit: { headers } })
      : new StdioClientTransport({
          command: cfg.command, args: cfg.args ?? [], cwd: cfg.cwd,
          env: { ...process.env, PATH: `${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:${process.env.PATH}`, ...(cfg.env ?? {}) },
          stderr: "ignore",
        });
    transport.onclose = () => { if (this.transport === transport) { this.client = null; this.transport = null; } };
    try {
      await withTimeout(client.connect(transport), 20000, this.name);
      const tools = [];
      let cursor;
      do { const page = await withTimeout(client.listTools(cursor ? { cursor } : {}), 15000, this.name); tools.push(...page.tools); cursor = page.nextCursor; } while (cursor);
      this.client = client; this.transport = transport; this.pid = transport.pid ?? null;
      writeCache(this.name, sigOf(cfg), tools);
      return tools;
    } catch (e) {
      await this.#kill(transport, transport.pid ?? null);
      throw e;
    }
  }
  // Запуск; параллельные вызовы ждут один и тот же запуск.
  ensure() {
    if (this.client) return Promise.resolve(this.client);
    if (!this.starting) this.starting = this.#open().then(() => this.client).finally(() => { this.starting = null; });
    return this.starting;
  }
  touch() {
    this.last = Date.now();
    if (this.keepAlive || !this.client) return;
    clearTimeout(this.timer);
    this.timer = setTimeout(() => this.#idleCheck(), this.idleMs + 50);
    this.timer.unref?.();
  }
  #idleCheck() {
    if (!this.client || this.keepAlive) return;
    if (this.active > 0 || this.starting) { this.last = Date.now(); return this.touch(); }
    const left = this.idleMs - (Date.now() - this.last);
    if (left > 0) { this.timer = setTimeout(() => this.#idleCheck(), left + 50); this.timer.unref?.(); return; }
    this.stop();
  }
  async call(fn) {
    const client = await this.ensure();
    this.active++; this.last = Date.now();
    try { return await fn(client); }
    finally { this.active--; this.touch(); }
  }
  async #kill(transport, pid) {
    try { await Promise.race([transport.close(), new Promise((r) => setTimeout(r, 3000))]); } catch {}
    await killTree(pid);
  }
  async stop() {
    clearTimeout(this.timer);
    if (this.starting) { try { await this.starting; } catch {} }
    const { transport, pid } = this;
    this.client = null; this.transport = null;
    if (transport) await this.#kill(transport, pid ?? transport.pid ?? null);
  }
}

export async function loadMcp() {
  if (!fs.existsSync(MCP_FILE)) fs.writeFileSync(MCP_FILE, JSON.stringify({ mcpServers: {} }, null, 2));
  let servers = {};
  try { servers = JSON.parse(fs.readFileSync(MCP_FILE, "utf8")).mcpServers ?? {}; } catch {}
  const ok = [], failed = [];
  const cache = readCache();
  const results = await Promise.allSettled(Object.entries(servers).filter(([, c]) => !c.disabled).map(async ([name, cfg]) => {
    const srv = new Server(name, cfg);
    servers_.set(name, srv);
    const cached = cache[name];
    // Ленивый режим: список умений из кэша, сервер не запускаем.
    if (!srv.keepAlive && cached?.sig === sigOf(cfg) && Array.isArray(cached.tools)) return { name, srv, tools: cached.tools };
    // keepAlive — запускаем и оставляем; иначе кэша нет: один раз запускаем, снимаем список и останавливаем.
    await srv.ensure();
    const tools = readCache()[name]?.tools ?? [];
    if (!srv.keepAlive) await srv.stop();
    return { name, srv, tools };
  }));
  const tools = [];
  for (const r of [...results].sort((a, b) => String(a.value?.name).localeCompare(String(b.value?.name)))) {
    if (r.status === "rejected") { failed.push(String(r.reason?.message ?? r.reason)); continue; }
    const { name, srv, tools: list } = r.value;
    ok.push(`${name} (${list.length})`);
    for (const t of [...list].sort((a, b) => a.name.localeCompare(b.name))) {
      tools.push(guardTool(defineTool({
        name: `mcp__${safe(name)}__${safe(t.name)}`.slice(0, 64),
        description: `[${name}] ${(t.description ?? t.name).slice(0, 500)}`,
        parameters: stable(t.inputSchema ?? { type: "object", properties: {} }),
        deferred: true,
        execute: async (args, _api, ctx) => {
          // Было 300 с; теперь 120 с, и вызов прерывается по «стоп». Ответ не пришёл — понятная ошибка, помощник пробует другой путь.
          let res;
          try { res = await srv.call((client) => client.callTool({ name: t.name, arguments: args ?? {} }, undefined, { timeout: LIMITS.mcp.def * 1000, signal: ctx?.abortSignal })); }
          catch (e) {
            if (/timed out|timeout/i.test(String(e?.message))) throw new Error(`MCP «${name}/${t.name}»: нет ответа за ${LIMITS.mcp.def} с, вызов оборван. Не повторяй то же самое: попробуй другой инструмент/путь или сообщи, что подключение не отвечает.`);
            throw e;
          }
          const output = await Promise.all((res.content ?? []).map(async (c) =>
            c.type === "text" ? { type: "text", text: c.text }
            : c.type === "image" ? { type: "image", ...(await shrinkImage(c.data, c.mimeType)) }
            : { type: "text", text: JSON.stringify(c).slice(0, 4000) }));
          if (!output.length && res.structuredContent) output.push({ type: "text", text: JSON.stringify(res.structuredContent) });
          if (res.isError) throw new Error(output.map((o) => o.text ?? "").join("\n") || "ошибка MCP");
          return { output: output.length ? output : [{ type: "text", text: "(пусто)" }] };
        },
      }), () => LIMITS.mcp.def, "MCP не ответил — пробуй другой путь."));
    }
  }
  const ext = defineExtension({
    name: "mcp",
    tools,
    sections: [section("mcp", () =>
      `Подключения (MCP) — список в ${MCP_FILE} (формат mcpServers: command/args/env или url). Чтобы подключить новое: впиши туда и скажи пользователю перезапустить меня.` +
      (ok.length ? ` Сейчас подключены (ленивые запускаются при первом вызове сами): ${ok.join(", ")}; их умения находи через tool_search.` : "") +
      (failed.length ? ` Не подключились: ${failed.join("; ").slice(0, 300)}.` : ""))],
  });
  return { ext, ok, failed };
}

export async function closeMcp() { await Promise.allSettled([...servers_.values()].map((s) => s.stop())); }
