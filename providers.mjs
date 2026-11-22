// Провайдеры и модели pia: какой провайдер и какая модель у каждой роли.
// Конфиг — ~/.pi-agent/models.json (вне git; PIA_MODELS — другой путь). Нет файла — всё как раньше: Claude (Anthropic).
// Доступ (вход по подписке или API-ключ) — в ~/.pi/agent/auth.json, как у pi (права 600); вход — `pia login`.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const HOME = os.homedir();
const APP = process.env.PIA_HOME || `${HOME}/.pi-agent`;
export const AUTH_FILE = `${HOME}/.pi/agent/auth.json`;
export const MODELS_FILE = process.env.PIA_MODELS || `${APP}/models.json`;

// ── Роли ──────────────────────────────────────────────────
// main — главный (оркестратор); smart/fast/opus — помощники (helper model: smart|fast|opus; opus = самая мощная
// модель выбранного провайдера); memory — фоновый разбор памяти; compact — пересказ при сжатии разговора.
export const ROLE_NAMES = ["main", "smart", "fast", "opus", "memory", "compact"];
export const ROLE_TITLES = { main: "главный (оркестратор)", smart: "помощник smart", fast: "помощник fast", opus: "самый мощный (opus)", memory: "разбор памяти", compact: "сжатие разговора" };
const THINKING = { main: "medium", smart: "medium", fast: "medium", opus: "high", memory: "off", compact: "off" };
// Чего нет в конфиге — берётся у соседней роли
const FALLBACK = { smart: "main", opus: "main", fast: "smart", memory: "fast", compact: "fast" };

// Готовые наборы моделей для популярных провайдеров (id — из каталога pi-ai; свои — в models.json)
export const PRESETS = {
  anthropic: { title: "Anthropic (Claude)", main: "claude-opus-5-5", smart: "claude-sonnet-5-5", fast: "claude-haiku-5-5", opus: "claude-opus-5-5", memory: "claude-haiku-5-5" },
  openai: { title: "OpenAI", main: "gpt-6.1-sol", smart: "gpt-6.1-sol", fast: "gpt-6-luna", opus: "gpt-6-astra", memory: "gpt-6-luna" },
  "openai-codex": { title: "ChatGPT Plus/Pro (Codex)", main: "gpt-6.1-sol", smart: "gpt-6.1-sol", fast: "gpt-6-luna", opus: "gpt-6-astra", memory: "gpt-6-luna" },
  google: { title: "Google Gemini", main: "gemini-pro-latest", smart: "gemini-flash-latest", fast: "gemini-flash-lite-latest", opus: "gemini-pro-latest", memory: "gemini-flash-lite-latest" },
  openrouter: { title: "OpenRouter", main: "anthropic/claude-opus-5.5", smart: "anthropic/claude-sonnet-5.5", fast: "anthropic/claude-haiku-5.5", opus: "anthropic/claude-opus-5.5", memory: "anthropic/claude-haiku-5.5" },
  "github-copilot": { title: "GitHub Copilot", main: "claude-opus-5.5", smart: "claude-sonnet-5.5", fast: "claude-haiku-5.5", opus: "claude-opus-5.5", memory: "claude-haiku-5.5" },
  xai: { title: "xAI (Grok)", main: "grok-4.7", smart: "grok-4.7", fast: "grok-4.3", opus: "grok-4.7", memory: "grok-4.3" },
  groq: { title: "Groq", main: "openai/gpt-oss-120b", smart: "openai/gpt-oss-120b", fast: "openai/gpt-oss-20b", opus: "openai/gpt-oss-120b", memory: "openai/gpt-oss-20b" },
  deepseek: { title: "DeepSeek", main: "deepseek-v4-pro", smart: "deepseek-v4-pro", fast: "deepseek-flash", opus: "deepseek-v4-pro", memory: "deepseek-flash" },
  mistral: { title: "Mistral", main: "mistral-medium-latest", smart: "mistral-medium-latest", fast: "mistral-small-latest", opus: "magistral-medium-latest", memory: "mistral-small-latest" },
};
export const DEFAULT_PROVIDER = "anthropic";

// Встроенные провайдеры pi-ai — по файлам каталога (без загрузки самих каталогов)
let builtinIds;
export function builtinProviderIds() {
  if (builtinIds) return builtinIds;
  try {
    const dir = path.dirname(fileURLToPath(import.meta.resolve("@earendil-works/pi-ai/providers/anthropic")));
    builtinIds = fs.readdirSync(dir).filter((f) => f.endsWith(".models.js")).map((f) => f.slice(0, -".models.js".length)).sort();
  } catch { builtinIds = [DEFAULT_PROVIDER]; }
  return builtinIds;
}

// ── Чтение конфига ────────────────────────────────────────
export function readConfig(file = MODELS_FILE) {
  if (!fs.existsSync(file)) return { config: {}, exists: false };
  try {
    const config = JSON.parse(fs.readFileSync(file, "utf8"));
    if (!config || typeof config !== "object" || Array.isArray(config)) throw new Error("ожидается объект JSON");
    return { config, exists: true };
  } catch (e) {
    return { config: {}, exists: true, error: `${file}: ${e.message} — беру модели по умолчанию (Claude)` };
  }
}

// "модель" | "провайдер/модель" | { provider, model, thinking } → { provider, modelId, thinking? }
function parseEntry(v, defProvider, known) {
  if (!v) return undefined;
  if (typeof v === "object") {
    const provider = String(v.provider ?? defProvider), modelId = String(v.model ?? v.modelId ?? "");
    return modelId ? { provider, modelId, thinking: v.thinking } : undefined;
  }
  const s = String(v).trim(); const i = s.indexOf("/");
  // У OpenRouter/Groq в id модели есть «/» — провайдером считаем только известное имя
  if (i > 0 && known.has(s.slice(0, i))) return { provider: s.slice(0, i), modelId: s.slice(i + 1) };
  return { provider: defProvider, modelId: s };
}

// Конфиг → роли { main: { provider, modelId, thinking }, ... }. Без конфига — ровно прежние модели Claude.
export function resolveRoles(config = {}, env = process.env) {
  const custom = config.providers && typeof config.providers === "object" ? config.providers : {};
  const known = new Set([...builtinProviderIds(), ...Object.keys(custom)]);
  const provider = String(config.provider ?? DEFAULT_PROVIDER);
  const preset = PRESETS[provider] ?? {};
  const src = { ...(config.roles ?? {}) };
  for (const r of ROLE_NAMES) if (src[r] === undefined && config[r] !== undefined) src[r] = config[r];   // роли можно писать и на верхнем уровне
  const roles = {};
  for (const r of ROLE_NAMES) roles[r] = parseEntry(src[r], provider, known) ?? (preset[r] ? { provider, modelId: preset[r] } : undefined);
  if (!roles.main) throw new Error(`для провайдера «${provider}» нет готового набора моделей — укажи в ${MODELS_FILE} хотя бы "main"`);
  for (const r of ["smart", "opus", "fast", "memory", "compact"]) roles[r] ??= { ...roles[FALLBACK[r]], thinking: undefined };
  const thinking = config.thinking && typeof config.thinking === "object" ? config.thinking : {};
  for (const r of ROLE_NAMES) roles[r] = { provider: roles[r].provider, modelId: roles[r].modelId, thinking: roles[r].thinking ?? thinking[r] ?? THINKING[r] };
  // PIA_MAIN_MODEL=fast (или haiku) — главный на быстрой модели, без размышлений (проверочный экземпляр, дёшево)
  if (/^(fast|haiku)$/i.test(env.PIA_MAIN_MODEL ?? "")) roles.main = { ...roles.fast, thinking: "off" };
  return roles;
}

// Загрузить роли для службы: при ошибке конфига — прежние модели и предупреждение
export function loadRoles() {
  const { config, error } = readConfig();
  const warn = (m) => { try { fs.appendFileSync(`${APP}/errors.log`, `${new Date().toISOString()} models: ${m}\n`); } catch {} ; process.stderr.write(`pia: ${m}\n`); };
  if (error) warn(error);
  try { return { roles: resolveRoles(error ? {} : config), config: error ? {} : config }; }
  catch (e) { warn(`${e.message} — беру модели по умолчанию (Claude)`); return { roles: resolveRoles({}), config: {} }; }
}
export const ref = (role) => ({ provider: role.provider, modelId: role.modelId });

// ── Доступ: ~/.pi/agent/auth.json (тот же файл, что у pi; права 600) ──
const loadAuth = () => { try { return JSON.parse(fs.readFileSync(AUTH_FILE, "utf8")); } catch (e) { if (e.code === "ENOENT") return {}; throw e; } };
const saveAuth = (all) => {
  fs.mkdirSync(path.dirname(AUTH_FILE), { recursive: true });
  if (fs.existsSync(AUTH_FILE)) fs.chmodSync(AUTH_FILE, 0o600);
  fs.writeFileSync(AUTH_FILE, JSON.stringify(all, null, 2), { mode: 0o600 });
};
let chain = Promise.resolve();
export const credentials = {
  async read(id) { return loadAuth()[id]; },
  async list() { return Object.entries(loadAuth()).map(([providerId, c]) => ({ providerId, type: c.type })); },
  modify(id, fn) {
    const r = chain.then(async () => {
      const all = loadAuth(); const next = await fn(all[id]);
      if (next) all[id] = next; else delete all[id];
      saveAuth(all);
      return next;
    });
    chain = r.catch(() => {}); return r;
  },
  async delete(id) { const all = loadAuth(); delete all[id]; saveAuth(all); },
};

// ── Провайдеры ────────────────────────────────────────────
// Встроенный: модуль @earendil-works/pi-ai/providers/<id>, фабрика <имя>Provider()
async function builtinProvider(id) {
  const mod = await import(`@earendil-works/pi-ai/providers/${id}`);
  for (const [name, fn] of Object.entries(mod)) {
    if (typeof fn !== "function" || !/Provider$/.test(name)) continue;
    try { const p = fn(); if (p?.id === id) return p; } catch {}
  }
  throw new Error(`в pi-ai нет фабрики провайдера «${id}»`);
}

// Свой адрес (Ollama, LM Studio, vLLM, прокси) — формат как у providers в models.json pi
const isLocal = (u) => /^https?:\/\/(localhost|127\.0\.0\.1|\[::1\]|0\.0\.0\.0)(:|\/|$)/i.test(String(u ?? ""));
const keyCache = new Map();
function resolveKey(v) {
  if (v == null || v === "") return undefined;
  const s = String(v);
  if (s.startsWith("!")) {   // команда (например, из Связки ключей: !security find-generic-password -ws имя)
    if (!keyCache.has(s)) { try { keyCache.set(s, execSync(s.slice(1), { encoding: "utf8", timeout: 10_000, stdio: ["ignore", "pipe", "ignore"] }).trim() || undefined); } catch { keyCache.set(s, undefined); } }
    return keyCache.get(s);
  }
  const m = /^\$\{?([A-Z0-9_]+)\}?$/i.exec(s);
  return m ? process.env[m[1]] || undefined : s;
}
async function customProvider(id, p) {
  const ai = await import("@earendil-works/pi-ai");
  const api = p.api ?? "openai-completions";
  const apiMod = await import(`@earendil-works/pi-ai/api/${api}.lazy`);
  const apiFn = Object.values(apiMod).find((f) => typeof f === "function");
  if (!apiFn) throw new Error(`провайдер «${id}»: неизвестный api «${api}»`);
  const compatDefault = api === "openai-completions" ? { supportsDeveloperRole: false, supportsReasoningEffort: false } : {};
  const models = (Array.isArray(p.models) ? p.models : []).map((m) => (typeof m === "string" ? { id: m } : m)).map((m) => ({
    id: String(m.id), name: m.name ?? String(m.id), api: m.api ?? api, provider: id, baseUrl: m.baseUrl ?? p.baseUrl,
    reasoning: m.reasoning ?? false, input: m.input ?? ["text"],
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, ...(m.cost ?? {}) },
    contextWindow: m.contextWindow ?? 128_000, maxTokens: m.maxTokens ?? 16_384,
    ...(p.headers || m.headers ? { headers: { ...(p.headers ?? {}), ...(m.headers ?? {}) } } : {}),
    compat: { ...compatDefault, ...(p.compat ?? {}), ...(m.compat ?? {}) },
    ...(m.thinkingLevelMap ? { thinkingLevelMap: m.thinkingLevelMap } : {}),
  }));
  if (!models.length) throw new Error(`провайдер «${id}»: в models.json нет списка models`);
  const envVar = p.apiKeyEnv ?? `${id.toUpperCase().replace(/[^A-Z0-9]/g, "_")}_API_KEY`;
  const auth = {
    name: p.name ?? id,
    login: async (interaction) => ({ type: "api_key", key: await interaction.prompt({ type: "secret", message: `API-ключ для ${p.name ?? id} (пусто, если не нужен)` }) }),
    resolve: async ({ credential }) => {
      const key = credential?.key || process.env[envVar] || resolveKey(p.apiKey) || (isLocal(p.baseUrl) ? "local" : undefined);
      return key ? { auth: { apiKey: key }, source: credential?.key ? "stored credential" : "models.json" } : undefined;
    },
  };
  return ai.createProvider({ id, name: p.name ?? id, baseUrl: p.baseUrl, auth: { apiKey: auth }, models, api: apiFn() });
}

export async function loadProvider(id, config = {}) {
  const custom = config.providers?.[id];
  return custom && !builtinProviderIds().includes(id) ? customProvider(id, custom) : builtinProvider(id);
}

// Собрать Models с провайдерами всех ролей (+ Anthropic — для старых разговоров на Claude).
// Уровень размышлений приводится к тому, что умеет модель (у моделей без размышлений — off).
export async function buildModels(roles, config = {}) {
  const { createModels, clampThinkingLevel } = await import("@earendil-works/pi-ai");
  const models = createModels({ credentials });
  const ids = new Set([DEFAULT_PROVIDER, ...ROLE_NAMES.map((r) => roles[r].provider)]);
  const problems = [];
  for (const id of ids) {
    try { models.setProvider(await loadProvider(id, config)); }
    catch (e) { if (id !== DEFAULT_PROVIDER || ROLE_NAMES.some((r) => roles[r].provider === id)) problems.push(`провайдер «${id}»: ${e.message}`); }
  }
  for (const r of ROLE_NAMES) {
    const m = models.getModel(roles[r].provider, roles[r].modelId);
    if (!m) { problems.push(`роль ${r}: нет модели «${roles[r].modelId}» у провайдера «${roles[r].provider}»`); continue; }
    roles[r].thinking = clampThinkingLevel(m, roles[r].thinking);
  }
  return { models, problems };
}
