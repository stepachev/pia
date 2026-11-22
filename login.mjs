// pia login — подключить провайдера моделей (как /login в pi): вход по подписке (OAuth) или API-ключ,
// плюс выбор, на каком провайдере работает pia (пишет ~/.pi-agent/models.json). Доступ — в ~/.pi/agent/auth.json (600).
//   pia login                — меню провайдеров
//   pia login openai         — сразу этот провайдер
//   pia login local          — локальная модель (Ollama, LM Studio, любой OpenAI-совместимый адрес)
//   pia login --status       — какие модели у ролей и есть ли доступ (без запросов к моделям)
//   pia login --check        — код выхода 0, если у главной модели есть доступ (для установщика)
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";
import readline from "node:readline/promises";
import { Writable } from "node:stream";
import { execFile } from "node:child_process";
import { AUTH_FILE, MODELS_FILE, PRESETS, ROLE_NAMES, ROLE_TITLES, DEFAULT_PROVIDER, credentials, readConfig, resolveRoles, loadProvider, buildModels, builtinProviderIds } from "./providers.mjs";

const APP = process.env.PIA_HOME || `${os.homedir()}/.pi-agent`;
const b = (s) => `\x1b[1m${s}\x1b[0m`, dim = (s) => `\x1b[2m${s}\x1b[0m`;

// Популярные — первыми; «другой» — весь список pi-ai
const POPULAR = [
  ["anthropic", "Anthropic (Claude) — подписка Claude Pro/Max или API-ключ"],
  ["openai", "OpenAI — вход с подпиской ChatGPT или API-ключ"],
  ["openai-codex", "ChatGPT Plus/Pro через Codex — вход"],
  ["google", "Google Gemini — API-ключ (aistudio.google.com)"],
  ["openrouter", "OpenRouter — вход или API-ключ (сотни моделей)"],
  ["github-copilot", "GitHub Copilot — подписка"],
  ["xai", "xAI (Grok) — вход или API-ключ"],
  ["groq", "Groq — API-ключ"],
  ["deepseek", "DeepSeek — API-ключ"],
  ["mistral", "Mistral — API-ключ"],
  ["local", "Локальная модель — Ollama, LM Studio, vLLM (без интернета и оплаты)"],
  ["other", "Другой провайдер (весь список)"],
];
const KEY_HINTS = {
  anthropic: "console.anthropic.com → API Keys", openai: "platform.openai.com/api-keys", google: "aistudio.google.com/apikey",
  openrouter: "openrouter.ai/keys", xai: "console.x.ai", groq: "console.groq.com/keys", deepseek: "platform.deepseek.com/api_keys", mistral: "console.mistral.ai/api-keys",
};

// ── Ввод с клавиатуры: обычный и скрытый (для ключей) ──
let muted = false;
const out = new Writable({ write(chunk, enc, cb) { if (!muted) process.stdout.write(chunk, enc); cb(); } });
const rl = readline.createInterface({ input: process.stdin, output: out, terminal: !!process.stdin.isTTY });
const ask = async (q, opts = {}) => {
  if (!opts.secret) return (await rl.question(q, opts.signal ? { signal: opts.signal } : undefined)).trim();
  process.stdout.write(q); muted = true;
  try { return (await rl.question("", opts.signal ? { signal: opts.signal } : undefined)).trim(); }
  finally { muted = false; process.stdout.write("\n"); }
};
const choose = async (title, items) => {   // items: [[id, текст]] → id
  console.log(`\n${b(title)}`);
  items.forEach(([, t], i) => console.log(`  ${String(i + 1).padStart(2)}. ${t}`));
  for (;;) {
    const a = await ask(`Номер (1–${items.length}): `);
    const n = Number.parseInt(a, 10);
    if (n >= 1 && n <= items.length) return items[n - 1][0];
    const byId = items.find(([id]) => id === a); if (byId) return byId[0];
    console.log("Не понял, введи номер из списка.");
  }
};
const yes = async (q, def = true) => { const a = (await ask(`${q} ${def ? "[Д/н]" : "[д/Н]"} `)).toLowerCase(); return a ? /^(д|y|да|yes)/.test(a) : def; };
const openUrl = (url) => { if (process.platform === "darwin") execFile("open", [url], () => {}); };

// Постоянный id установки (OpenAI просит одинаковый при каждом входе)
function deviceId() {
  const f = `${APP}/install-id`;
  try { return fs.readFileSync(f, "utf8").trim(); } catch {}
  const id = crypto.randomUUID(); try { fs.writeFileSync(f, id, { mode: 0o600 }); } catch {}
  return id;
}

// ── models.json ──
function writeConfig(next) {
  fs.mkdirSync(path.dirname(MODELS_FILE), { recursive: true });
  if (fs.existsSync(MODELS_FILE)) fs.copyFileSync(MODELS_FILE, `${MODELS_FILE}.bak`);
  fs.writeFileSync(MODELS_FILE, JSON.stringify(next, null, 2) + "\n", { mode: 0o600 });   // может содержать apiKey своего адреса
  console.log(`Записал ${MODELS_FILE}${fs.existsSync(`${MODELS_FILE}.bak`) ? ` (прежний — ${path.basename(MODELS_FILE)}.bak)` : ""}.`);
}
const rolesLine = (roles) => ROLE_NAMES.filter((r) => r !== "compact").map((r) => `${ROLE_TITLES[r]}: ${roles[r].provider}/${roles[r].modelId}`).join("\n  ");

async function status({ quiet } = {}) {
  const { config, exists, error } = readConfig();
  let roles;
  try { roles = resolveRoles(error ? {} : config); } catch (e) { console.log(`Ошибка конфига: ${e.message}`); return false; }
  const { models, problems } = await buildModels(roles, error ? {} : config);
  const ok = {};
  for (const id of new Set(ROLE_NAMES.map((r) => roles[r].provider))) { try { ok[id] = !!(await models.checkAuth(id)); } catch { ok[id] = false; } }
  if (!quiet) {
    console.log(`${b("Модели pia")} ${dim(exists ? `(${MODELS_FILE})` : "(по умолчанию — models.json нет)")}`);
    if (error) console.log(`  ! ${error}`);
    for (const r of ROLE_NAMES) console.log(`  ${ROLE_TITLES[r].padEnd(22)} ${roles[r].provider}/${roles[r].modelId} ${dim(`размышления: ${roles[r].thinking}`)}`);
    console.log(`${b("Доступ")} ${dim(`(${AUTH_FILE})`)}`);
    for (const [id, v] of Object.entries(ok)) console.log(`  ${id.padEnd(22)} ${v ? "есть" : "НЕТ — выполни: pia login " + id}`);
    for (const p of problems) console.log(`  ! ${p}`);
  }
  return ok[roles.main.provider] && !problems.length;
}

// ── Вход к встроенному провайдеру ──
async function loginBuiltin(id) {
  const provider = await loadProvider(id);
  const methods = [];
  if (provider.auth.oauth) methods.push(["oauth", `Вход через браузер (${provider.auth.oauth.name ?? "подписка"})`]);
  if (provider.auth.apiKey) methods.push(["api_key", `API-ключ${KEY_HINTS[id] ? ` (взять: ${KEY_HINTS[id]})` : ""}`]);
  if (!methods.length) throw new Error(`у «${id}» нет входа через pia — настрой переменные окружения (см. README pi-ai)`);
  const type = methods.length === 1 ? methods[0][0] : await choose(`${provider.name}: как подключить?`, methods);
  const { createModels } = await import("@earendil-works/pi-ai");
  const models = createModels({ credentials });
  models.setProvider(provider);
  const ac = new AbortController();
  const onSig = () => { ac.abort(); console.log("\nОтменено."); process.exit(130); };
  process.once("SIGINT", onSig);
  await models.login(id, type, {
    signal: ac.signal,
    prompt: async (p) => {
      if (p.type === "select") return choose(p.message, p.options.map((o) => [o.id, o.label + (o.description ? dim(` — ${o.description}`) : "")]));
      const label = p.type === "manual_code" ? `${p.message}${dim(" (или дождись входа в браузере)")}` : p.message;
      try { return await ask(`${label}${p.placeholder ? dim(` (${p.placeholder})`) : ""}: `, { secret: p.type === "secret", signal: p.signal }); }
      catch (e) { if (p.signal?.aborted) { process.stdout.write("\n"); return ""; } throw e; }
    },
    notify: (e) => {
      if (e.type === "auth_url") { console.log(`\nОткрываю браузер для входа. Если не открылся — перейди по ссылке:\n${e.url}`); if (e.instructions) console.log(e.instructions); openUrl(e.url); }
      else if (e.type === "device_code") { console.log(`\nОткрой ${e.verificationUri} и введи код: ${b(e.userCode)}`); openUrl(e.verificationUri); }
      else if (e.type === "info") { console.log(e.message); for (const l of e.links ?? []) console.log(`  ${l.label ?? "Ссылка"}: ${l.url}`); }
      else if (e.type === "progress") console.log(dim(e.message));
    },
  }, { getDeviceId: deviceId });
  process.off("SIGINT", onSig);
  console.log(`\nГотово: доступ к ${provider.name} сохранён в ${AUTH_FILE} (права 600).`);
  return provider;
}

// ── Сделать провайдера основным для pia ──
async function useProvider(id, provider) {
  const { config } = readConfig();
  const current = (() => { try { return resolveRoles(config); } catch { return undefined; } })();
  if (current && ROLE_NAMES.every((r) => current[r].provider === id)) { console.log(`pia и так работает на ${provider.name}.`); return false; }
  let roles;
  if (PRESETS[id]) {
    roles = resolveRoles({ provider: id });
    console.log(`\nГотовый набор моделей для ${provider.name}:\n  ${rolesLine(roles)}`);
    if (!(await yes(`Переключить pia на ${provider.name}?`))) return false;
    if (id === DEFAULT_PROVIDER && !config.providers) {   // прежнее поведение — файл не нужен
      if (fs.existsSync(MODELS_FILE)) { fs.renameSync(MODELS_FILE, `${MODELS_FILE}.bak`); console.log(`Вернул модели по умолчанию (прежний конфиг — ${path.basename(MODELS_FILE)}.bak).`); }
      return true;
    }
    writeConfig({ ...(config.providers ? { providers: config.providers } : {}), provider: id });
    return true;
  }
  const list = provider.getModels().map((m) => m.id);
  if (!(await yes(`Переключить pia на ${provider.name}?`))) return false;
  console.log(`\nМодели ${provider.name} (${list.length}): ${list.slice(0, 60).join(", ")}${list.length > 60 ? " …" : ""}`);
  const pick = async (q, def) => { for (;;) { const a = (await ask(`${q}${def ? dim(` [${def}]`) : ""}: `)) || def; if (a && list.includes(a)) return a; console.log("Нет такой модели в списке."); } };
  const main = await pick("Главная модель (оркестратор)");
  const fast = await pick("Быстрая и дешёвая модель (fast, память)", main);
  const opus = await pick("Самая мощная (opus)", main);
  writeConfig({ ...(config.providers ? { providers: config.providers } : {}), provider: id, roles: { main, smart: main, fast, opus, memory: fast } });
  return true;
}

// ── Локальная модель ──
async function loginLocal() {
  const kind = await choose("Где работает модель?", [
    ["ollama", "Ollama (http://localhost:11434/v1)"], ["lmstudio", "LM Studio (http://localhost:1234/v1)"], ["custom", "Другой OpenAI-совместимый адрес (vLLM, llama.cpp, прокси)"],
  ]);
  let baseUrl = kind === "ollama" ? "http://localhost:11434/v1" : kind === "lmstudio" ? "http://localhost:1234/v1" : "";
  if (kind === "custom") baseUrl = (await ask("Адрес API (например http://localhost:8000/v1): ")).replace(/\/+$/, "");
  const id = kind === "custom" ? ((await ask("Короткое имя провайдера [local]: ")) || "local").replace(/[^a-z0-9-]/gi, "-").toLowerCase() : kind;
  let apiKey = "";
  if (kind === "custom" && !/localhost|127\.0\.0\.1/.test(baseUrl)) apiKey = await ask("API-ключ (пусто, если не нужен): ", { secret: true });
  let found = [];
  try {
    const r = await fetch(`${baseUrl}/models`, { signal: AbortSignal.timeout(4000), headers: apiKey ? { Authorization: `Bearer ${apiKey}` } : {} });
    found = ((await r.json())?.data ?? []).map((m) => m.id).filter(Boolean);
  } catch { console.log(dim(`Не достучался до ${baseUrl}/models — проверь, что сервер запущен. Модель можно вписать вручную.`)); }
  let model;
  if (found.length) model = await choose("Какую модель использовать?", found.map((m) => [m, m]));
  else model = await ask(`Имя модели${kind === "ollama" ? " (как в «ollama list», например qwen3:14b)" : ""}: `);
  if (!model) throw new Error("не указана модель");
  const vision = await yes("Модель понимает картинки (скриншоты)?", false);
  const reasoning = await yes("Это «размышляющая» модель (reasoning)?", false);
  const ctx = Number.parseInt(await ask(`Размер контекста в токенах ${dim("[32768]")}: `), 10) || 32768;
  const { config } = readConfig();
  const entry = { name: kind === "ollama" ? "Ollama" : kind === "lmstudio" ? "LM Studio" : id, baseUrl, api: "openai-completions",
    ...(apiKey ? { apiKey } : {}), models: [{ id: model, input: vision ? ["text", "image"] : ["text"], reasoning, contextWindow: ctx }] };
  const providers = { ...(config.providers ?? {}), [id]: entry };
  console.log(`\npia будет работать на ${id}/${model} во всех ролях.`);
  console.log(dim("Подсказка: маленьким локальным моделям тяжело управлять инструментами и браузером — для этого лучше облачная модель."));
  if (!(await yes("Записать?"))) return false;
  writeConfig({ providers, provider: id, roles: { main: model } });
  return true;
}

async function main() {
  const args = process.argv.slice(2).filter((a) => a !== "login");
  if (args[0] === "--status" || args[0] === "status") { await status(); return 0; }
  if (args[0] === "--check") return (await status({ quiet: true })) ? 0 : 1;
  if (args[0] === "--help" || args[0] === "-h") { console.log(fs.readFileSync(new URL(import.meta.url), "utf8").split("\n").slice(0, 8).join("\n")); return 0; }
  let id = args[0];
  if (!id) id = await choose("Подключить pia к провайдеру моделей", POPULAR);
  if (id === "other") id = await choose("Все провайдеры pi", builtinProviderIds().map((p) => [p, p + (PRESETS[p] ? "" : dim(" — модели выберешь сам"))]));
  let changed;
  if (id === "local" || id === "ollama" || id === "lmstudio") changed = await loginLocal();
  else {
    if (!builtinProviderIds().includes(id)) throw new Error(`нет провайдера «${id}». Список: pia login → «Другой провайдер»`);
    const provider = await loginBuiltin(id);
    changed = await useProvider(id, provider);
  }
  console.log(changed ? `\nЧтобы применить, перезапусти pia: ${b("pia --restart")} (работающие помощники прервутся).` : "\nГотово. Можно запускать pia.");
  console.log(dim("Посмотреть модели и доступ: pia login --status"));
  return 0;
}

main().then((code) => { rl.close(); process.exit(code); }, (e) => { rl.close(); console.error(`Ошибка: ${e?.message ?? e}`); process.exit(1); });
