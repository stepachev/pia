// /usage — коротко: сколько потрачено сегодня и за месяц
import fs from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { APP } from "./shared.mjs";

export function printUsage() { console.log(usageText()); }
export function usageText() {
  const now = new Date();
  const dayStart = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
  const monthStart = new Date(now.getFullYear(), now.getMonth(), 1).getTime();
  const sum = { day: { $: 0, t: 0 }, month: { $: 0, t: 0 } };
  const add = (ts, cost, tokens) => {
    if (ts >= monthStart) { sum.month.$ += cost; sum.month.t += tokens; }
    if (ts >= dayStart) { sum.day.$ += cost; sum.day.t += tokens; }
  };
  for (const file of ["memory.sqlite", "memory-worker.sqlite"]) {
    const p = `${APP}/${file}`; if (!fs.existsSync(p)) continue;
    const db = new DatabaseSync(p, { readOnly: true });
    for (const r of db.prepare("select record from entries where record like '%\"pi.assistant\"%'").all()) {
      const m = JSON.parse(r.record).model?.[0]; const u = m?.usage; if (!u) continue;
      add(m.timestamp ?? 0, u.cost?.total ?? 0, u.totalTokens ?? 0);
    }
    db.close();
  }
  if (fs.existsSync(`${APP}/compaction.log`)) for (const l of fs.readFileSync(`${APP}/compaction.log`, "utf8").split("\n")) {
    const m = l.match(/^(\S+) сжато.*\$(\d+\.\d+)/); if (m) add(Date.parse(m[1]), Number(m[2]), 0);
  }
  const $ = (x) => x.toFixed(2).replace(".", ",") + " $";
  const t = (x) => x >= 1e6 ? (x / 1e6).toFixed(1).replace(".", ",") + " млн" : Math.round(x / 1000) + " тыс.";
  return `Сегодня: ${$(sum.day.$)} · ${t(sum.day.t)} токенов\nЗа месяц: ${$(sum.month.$)} · ${t(sum.month.t)} токенов`;
}
