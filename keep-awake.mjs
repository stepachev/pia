// Не давать Mac уснуть, пока идёт работа (главный разговор отвечает или работает помощник).
// caffeinate -i: запрет сна системы по бездействию (экран гаснуть может); -w <pid службы>: сам умирает, если служба упала.
// Выключить: PIA_KEEP_AWAKE=0 в окружении службы.
import { spawn } from "node:child_process";

export const hasWork = (st) => !!(st && (st.busy || (st.helpers ?? []).some((h) => h.state === "работает")));

export function createKeepAwake({ getState, spawnFn = (pid) => spawn("/usr/bin/caffeinate", ["-i", "-w", String(pid)], { stdio: "ignore" }),
  pid = process.pid, delayMs = 30_000, pollMs = 3_000, log = () => {}, enabled = process.env.PIA_KEEP_AWAKE !== "0",
  setT = setTimeout, clearT = clearTimeout, setI = setInterval, clearI = clearInterval } = {}) {
  let child = null, offTimer = null, poll = null;
  const on = () => {
    if (offTimer) { clearT(offTimer); offTimer = null; }
    if (child) return;
    try {
      const c = spawnFn(pid);
      child = c;
      c.on?.("exit", () => { if (child === c) { child = null; log("не спать: выкл (caffeinate завершился)"); } });
      c.on?.("error", () => { if (child === c) child = null; });
      c.unref?.();
      log("не спать: вкл");
    } catch (e) { child = null; log(`не спать: не удалось запустить: ${e?.message ?? e}`); }
  };
  const kill = () => {
    if (offTimer) { clearT(offTimer); offTimer = null; }
    if (!child) return;
    const c = child; child = null;
    try { c.kill("SIGTERM"); } catch {}
    log("не спать: выкл");
  };
  const check = () => {
    let work = false; try { work = hasWork(getState()); } catch {}
    if (work) on();
    else if (child && !offTimer) offTimer = setT(() => { offTimer = null; kill(); }, delayMs);
  };
  return {
    start() { if (!enabled || poll) return; poll = setI(check, pollMs); poll.unref?.(); check(); },
    check, stop() { if (poll) { clearI(poll); poll = null; } kill(); },
    get active() { return !!child; }, get pending() { return !!offTimer; },
  };
}
