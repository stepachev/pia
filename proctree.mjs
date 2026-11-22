// Процессы помощников: учёт, убийство всего дерева и определение «этот запрос идёт из команды помощника».
// Каждая команда помощника запускается средой TrackedEnv: корни (активные дети среды), метки PIA_CONV/PIA_HELPER в окружении
// и «снимок» потомков раз в 2 с (по ppid, с временем старта — чтобы не задеть чужой процесс с тем же pid).
// Служба, окно pia-app и MCP-серверы службы — не потомки команд помощника, их это не касается.
import { execFile } from "node:child_process";
import { NodeExecutionEnv } from "@earendil-works/pi-durable/env/node";

const sh = (cmd, args) => new Promise((res) => execFile(cmd, args, { maxBuffer: 64 << 20, timeout: 10_000, env: { ...process.env, LC_ALL: "C" } }, (e, out) => res(e ? "" : String(out))));
const envs = new Map();   // id разговора → Set(TrackedEnv)
const seen = new Map();   // id разговора → Map("pid|lstart" → pid): все замеченные потомки

export class TrackedEnv extends NodeExecutionEnv {
  constructor(options, convId) {
    super({ ...options, shellEnv: { ...options.shellEnv, PIA_CONV: String(convId), PIA_HELPER: "1" } });
    for (const [id, set] of envs) { for (const e of set) if (!e.activeChildPids.size) set.delete(e); if (!set.size) envs.delete(id); }
    (envs.get(convId) ?? envs.set(convId, new Set()).get(convId)).add(this);
    startSampler();
  }
}
const rootsOf = (id) => new Set([...(envs.get(id) ?? [])].flatMap((e) => [...e.activeChildPids]));

async function table() {
  const out = await sh("ps", ["-axww", "-o", "pid=,ppid=,pgid=,lstart=,command="]);
  const rows = new Map(), kids = new Map();
  for (const line of out.split("\n")) {
    const m = line.match(/^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\w+\s+\w+\s+\d+\s+[\d:]+\s+\d+)\s(.*)$/); if (!m) continue;
    const r = { pid: +m[1], ppid: +m[2], pgid: +m[3], start: m[4], cmd: m[5] };
    rows.set(r.pid, r); (kids.get(r.ppid) ?? kids.set(r.ppid, []).get(r.ppid)).push(r.pid);
  }
  return { rows, kids };
}
const below = (kids, from) => { const all = new Set(), walk = (p) => { for (const k of kids.get(p) ?? []) if (!all.has(k)) { all.add(k); walk(k); } }; for (const p of from) { all.add(p); walk(p); } return all; };

let sampler = null, sampling = false;
function startSampler() {
  if (sampler) return;
  sampler = setInterval(async () => {
    if (sampling) return; sampling = true;
    try {
      const active = [...envs].map(([id]) => [id, rootsOf(id)]).filter(([, r]) => r.size);
      if (!active.length) { for (const id of [...seen.keys()]) if (!envs.has(id)) seen.delete(id); return; }
      const { rows, kids } = await table();
      for (const [id, roots] of active) {
        const m = seen.get(id) ?? seen.set(id, new Map()).get(id);
        for (const p of below(kids, roots)) { const r = rows.get(p); if (r) m.set(`${p}|${r.start}`, p); }
      }
    } finally { sampling = false; }
  }, 2000);
  sampler.unref();
}

async function victims(id) {
  const { rows, kids } = await table();
  const from = new Set(rootsOf(id));
  for (const [key, p] of seen.get(id) ?? []) { const r = rows.get(p); if (r && key === `${p}|${r.start}`) from.add(p); }
  for (const r of rows.values()) if (r.cmd.includes(`PIA_CONV=${id}`)) from.add(r.pid);   // метка видна у части программ (ps -e)
  const all = below(kids, [...from].filter((p) => rows.has(p)));
  for (const r of rows.values()) if (from.has(r.pgid) && r.pgid > 1) all.add(r.pid);   // группа процессов, которую возглавлял наш процесс (даже если родитель уже умер)
  all.delete(process.pid); all.delete(process.ppid);
  return { all, rows };
}
const signal = (pids, sig) => { for (const p of pids) { try { process.kill(p, sig); } catch {} } };
const alive = (p) => { try { process.kill(p, 0); return true; } catch { return false; } };

// SIGTERM всему дереву помощника, через graceMs — SIGKILL выжившим. Возвращает число найденных процессов.
export async function killConvTree(id, graceMs = 3000) {
  const { all } = await victims(id);
  if (all.size) {
    signal(all, "SIGTERM");
    await new Promise((r) => setTimeout(r, graceMs));
    const again = (await victims(id)).all;
    signal([...new Set([...all, ...again])].filter(alive), "SIGKILL");
  }
  seen.delete(id); envs.delete(id);
  return all.size;
}

// Запрос на 127.0.0.1 с порта remotePort идёт из процесса, который сам потомок команды помощника?
export async function isHelperPeer(remotePort, serverPort) {
  if (!remotePort) return false;
  const out = await sh("lsof", ["-nP", "-a", `-iTCP@127.0.0.1:${serverPort}`, "-sTCP:ESTABLISHED", "-Fpn"]);
  let pid = 0, peer = 0;
  for (const l of out.split("\n")) { if (l[0] === "p") pid = +l.slice(1); else if (l[0] === "n" && l.includes(`:${remotePort}->`)) peer = pid; }
  if (!peer || peer === process.pid) return false;
  const { rows, kids } = await table();
  const roots = new Set();
  for (const id of envs.keys()) for (const p of rootsOf(id)) roots.add(p);
  for (const m of seen.values()) for (const p of m.values()) roots.add(p);
  if (below(kids, [...roots].filter((p) => rows.has(p))).has(peer)) return true;
  const env = await sh("ps", ["-eww", "-o", "command=", "-p", String(peer)]);
  return /\bPIA_HELPER=1\b/.test(env);
}
