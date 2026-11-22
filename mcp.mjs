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
const clients = [];

// MCP-серверы (например, Yab) отдают схемы с ключами в случайном порядке. Если не упорядочить,
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

async function connect(name, cfg) {
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
  await withTimeout(client.connect(transport), 20000, name);
  clients.push(client);
  const tools = [];
  let cursor;
  do { const page = await withTimeout(client.listTools(cursor ? { cursor } : {}), 15000, name); tools.push(...page.tools); cursor = page.nextCursor; } while (cursor);
  return { client, tools };
}

export async function loadMcp() {
  if (!fs.existsSync(MCP_FILE)) fs.writeFileSync(MCP_FILE, JSON.stringify({ mcpServers: {} }, null, 2));
  let servers = {};
  try { servers = JSON.parse(fs.readFileSync(MCP_FILE, "utf8")).mcpServers ?? {}; } catch {}
  const ok = [], failed = [];
  const results = await Promise.allSettled(Object.entries(servers).filter(([, c]) => !c.disabled).map(async ([name, cfg]) => ({ name, ...(await connect(name, cfg)) })));
  const tools = [];
  for (const r of [...results].sort((a, b) => String(a.value?.name).localeCompare(String(b.value?.name)))) {
    if (r.status === "rejected") { failed.push(String(r.reason?.message ?? r.reason)); continue; }
    const { name, client, tools: list } = r.value;
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
          try { res = await client.callTool({ name: t.name, arguments: args ?? {} }, undefined, { timeout: LIMITS.mcp.def * 1000, signal: ctx?.abortSignal }); }
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
      (ok.length ? ` Сейчас подключены: ${ok.join(", ")}; их умения находи через tool_search.` : "") +
      (failed.length ? ` Не подключились: ${failed.join("; ").slice(0, 300)}.` : ""))],
  });
  return { ext, ok, failed };
}

export async function closeMcp() { await Promise.allSettled(clients.map((c) => c.close())); }
