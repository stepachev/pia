// Вывод в терминал как у fx (vercel-labs/fx):
// перенос только по пробелам (слова не рвутся), без «висячего» последнего слова,
// markdown (жирный, курсив, `код`, ссылки, списки «•», цитаты «│», заголовки, линии),
// живая перерисовка дописываемого абзаца и строка активности «• думаю (5s)».

// Цвета как у fx (theme.zig): светлая и тёмная тема. Тема определяется по фону терминала.
const DARK = { rail: 255, code: 255, link: 75, codeBlock: 250, status: 252 };
const LIGHTP = { rail: 235, code: 235, link: 25, codeBlock: 238, status: 238 };
const C = { ...DARK };
export let LIGHT = false;
export function setTheme(light) { LIGHT = light; Object.assign(C, light ? LIGHTP : DARK); }
const fg = (n) => `\x1b[38;5;${n}m`;
export const rail = () => `${fg(C.rail)}┃\x1b[0m`;
const RESET = "\x1b[0m";

// Фон терминала: спрашиваем у терминала (OSC 11, отвечают Terminal.app, iTerm2, Ghostty…),
// иначе COLORFGBG, иначе тема macOS. PIA_THEME=light|dark — вручную.
export async function detectTheme({ keepRaw = false } = {}) {
  const env = process.env.PIA_THEME;
  if (env === "light" || env === "dark") return setTheme(env === "light");
  const fgbg = process.env.COLORFGBG;
  if (fgbg && /;\d+$/.test(fgbg)) return setTheme(/;(7|15)$/.test(fgbg));
  if (process.stdin.isTTY && process.stdout.isTTY) {
    const rgb = await new Promise((resolve) => {
      let buf = "";
      // Всё, что не ответ терминала (например, уже набранный текст), возвращаем обратно во ввод
      const done = (v) => {
        clearTimeout(t); process.stdin.off("data", on);
        const rest = buf.replace(/\x1b\]11;[^\x07\x1b]*(\x07|\x1b\\)?/, "");
        if (!keepRaw) { try { process.stdin.setRawMode(false); } catch {} }
        process.stdin.pause();
        if (rest) process.stdin.unshift(Buffer.from(rest, "latin1"));
        resolve(v);
      };
      const on = (d) => {
        buf += d.toString("latin1");
        const m = /\]11;rgb:([0-9a-f]+)\/([0-9a-f]+)\/([0-9a-f]+)/i.exec(buf);
        if (m && /(\x07|\x1b\\)/.test(buf.slice(m.index))) done(m.slice(1).map((h) => parseInt(h, 16) / (16 ** h.length - 1)));
      };
      const t = setTimeout(() => done(null), 300);
      try { process.stdin.setRawMode(true); } catch {}
      process.stdin.on("data", on); process.stdin.resume();
      process.stdout.write("\x1b]11;?\x07");
    });
    if (rgb) return setTheme(0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2] > 0.5);
  }
  let dark = false;
  try { dark = (await import("node:child_process")).execFileSync("defaults", ["read", "-g", "AppleInterfaceStyle"], { stdio: ["ignore", "pipe", "ignore"] }).toString().includes("Dark"); } catch {}
  setTheme(!dark);
}

// ── Ширина символов ───────────────────────────────────────
const seg = new Intl.Segmenter();
const wideCp = (c) => c >= 0x1100 && (c <= 0x115f || c === 0x2329 || c === 0x232a || (c >= 0x2e80 && c <= 0xa4cf && c !== 0x303f) ||
  (c >= 0xac00 && c <= 0xd7a3) || (c >= 0xf900 && c <= 0xfaff) || (c >= 0xfe30 && c <= 0xfe6f) || (c >= 0xff00 && c <= 0xff60) ||
  (c >= 0xffe0 && c <= 0xffe6) || (c >= 0x1f300 && c <= 0x1faff) || (c >= 0x20000 && c <= 0x3fffd));
const ZERO = /^(\p{Mn}|\p{Me}|\p{Cf}|[\ufe00-\ufe0f])+$/u;
export function gWidth(g) {
  if (ZERO.test(g)) return 0;
  const c = g.codePointAt(0);
  if (wideCp(c) || /\ufe0f/.test(g)) return 2;
  return 1;
}
export const strWidth = (s) => { let w = 0; for (const { segment } of seg.segment(s)) w += gWidth(segment); return w; };
// Управляющие символы — видимыми, чтобы не попали в терминал (как terminalSafePrompt у fx)
export const safeText = (s) => s.replace(/\t/g, "    ").replace(/[\x00-\x09\x0b-\x1f\x7f-\x9f]/g, (c) => c === "\x1b" ? "\\x1b" : `\\u{${c.charCodeAt(0).toString(16).padStart(4, "0")}}`);

// Клетка = одна графема со стилем
const cellsOf = (text, st = {}) => [...seg.segment(text)].map(({ segment: g }) => ({ g, w: gWidth(g), st }));
const SP = (st = {}) => ({ g: " ", w: 1, st });

// ── Стиль → ANSI ──────────────────────────────────────────
function sgr(st) {
  let s = RESET;
  if (st.bold) s += "\x1b[1m";
  if (st.dim) s += "\x1b[2m";
  if (st.italic) s += "\x1b[3m";
  if (st.strike) s += "\x1b[9m";
  if (st.ul) s += "\x1b[4m";
  if (st.fg) s += fg(st.fg);
  if (st.code) s += fg(C.code);
  if (st.link) s += fg(C.link) + "\x1b[4m";
  return s;
}
const key = (st) => `${st.bold ? 1 : 0}${st.dim ? 1 : 0}${st.italic ? 1 : 0}${st.strike ? 1 : 0}${st.code ? 1 : 0}${st.ul ? 1 : 0}|${st.fg ?? ""}|${st.link ?? ""}`;
const osc8 = (url) => `\x1b]8;;${url}\x1b\\`;
function emit(cells) {
  let out = "", cur = key({}), link = "";
  for (const c of cells) {
    const k = key(c.st);
    if (k !== cur) {
      const l = c.st.link ?? "";
      if (l !== link) { if (link) out += osc8(""); if (l) out += osc8(l); link = l; }
      out += sgr(c.st); cur = k;
    }
    out += c.g;
  }
  if (link) out += osc8("");
  return out + RESET;
}

// ── Строчный markdown → клетки ────────────────────────────
const isWordCh = (ch) => ch !== undefined && /[\p{L}\p{N}]/u.test(ch);
function inline(s, base = {}) {
  const out = [];
  let st = { ...base }, buf = "";
  const flush = () => { if (buf) { out.push(...cellsOf(buf, st)); buf = ""; } };
  let i = 0;
  while (i < s.length) {
    const c = s[i];
    if (c === "\\" && /[\\`*_[\]()#+\-.!~|>]/.test(s[i + 1] ?? "")) { buf += s[i + 1]; i += 2; continue; }
    if (c === "`") {
      let n = 1; while (s[i + n] === "`") n++;
      const ticks = "`".repeat(n), end = s.indexOf(ticks, i + n);
      if (end > i + n) {
        flush();
        let code = s.slice(i + n, end); if (/^ .* $/.test(code)) code = code.slice(1, -1);
        out.push(...cellsOf(code, { ...st, code: true })); i = end + n; continue;
      }
    }
    if (c === "[") {
      const m = /^\[([^\]\n]+)\]\(([^)\s]+)\)/.exec(s.slice(i));
      if (m) { flush(); out.push(...inline(m[1], { ...st, link: m[2] })); i += m[0].length; continue; }
    }
    if (c === "h" && !isWordCh(s[i - 1])) {
      const m = /^https?:\/\/[^\s<>"'«»]*[^\s<>"'«».,;:!?)\]]/.exec(s.slice(i));
      if (m) { flush(); out.push(...cellsOf(m[0], { ...st, link: m[0] })); i += m[0].length; continue; }
    }
    if (c === "*" || c === "_" || c === "~") {
      let run = 1; while (s[i + run] === c) run++;
      const prev = s[i - 1], next = s[i + run];
      if (c === "~") {
        if (run === 2 && (st.strike ? !/\s/.test(prev ?? " ") : (next && !/\s/.test(next) && s.indexOf("~~", i + 2) > 0))) {
          flush(); st = { ...st, strike: !st.strike }; i += 2; continue;
        }
        buf += s.slice(i, i + run); i += run; continue;
      }
      if (c === "_" && isWordCh(prev) && isWordCh(next)) { buf += s.slice(i, i + run); i += run; continue; }
      // *** = жирный + курсив; ** = жирный; * = курсив
      const parts = run >= 3 ? [2, 1] : [run];
      let handled = 0;
      for (const n of parts) {
        const k = n === 2 ? "bold" : "italic";
        if (st[k] && prev !== undefined && !/\s/.test(prev)) { flush(); st = { ...st, [k]: false }; handled += n; continue; }
        const nx = s[i + run];
        if (!st[k] && nx && !/\s/.test(nx) && s.indexOf(c.repeat(n), i + run) > 0) { flush(); st = { ...st, [k]: true }; handled += n; continue; }
      }
      if (handled) { if (handled < run) buf += s.slice(i + handled, i + run); i += run; continue; }
      buf += s.slice(i, i + run); i += run; continue;
    }
    buf += c; i++;
  }
  flush();
  return out;
}

// ── Перенос по словам (как wrapAssistantText у fx) ────────
// Слова не рвутся; тире не уходит в начало строки; однобуквенные предлоги и числа
// держатся со следующим словом; последний ряд абзаца не остаётся с одним словом
// (если от предыдущего ряда не останется одно слово).
const plain = (cells) => cells.map((c) => c.g).join("");
const width = (cells) => cells.reduce((w, c) => w + c.w, 0);
function units(cells) {
  const words = [];
  let cur = null, sep = null;
  for (const c of cells) {
    if (c.g === " ") { if (cur) { words.push(cur); cur = null; } sep = c; continue; }
    if (!cur) { cur = { sep: sep ?? SP(), cells: [] }; sep = null; }
    cur.cells.push(c);
  }
  if (cur) words.push(cur);
  const glueNext = (t) => /^\p{L}{1,2}$/u.test(t) || /^[+\-−±~≈]?\d[\d.,:]*$/.test(t) || /^(№|§)$/.test(t);
  const out = [];
  for (const w of words) {
    const t = plain(w.cells), last = out[out.length - 1];
    if (last && (/^[—–-]{1,2}$/.test(t) || glueNext(last.tail))) {
      last.cells.push(w.sep, ...w.cells); last.words.push(w); last.tail = t; last.w = width(last.cells);
    } else out.push({ sep: w.sep, cells: [...w.cells], words: [w], tail: t, w: width(w.cells) });
  }
  return out;
}
export function wrap(cells, cols, first = [], cont = first, final = true) {
  const avail = (r) => Math.max(1, cols - width(r === 0 ? first : cont));
  const rows = [[]];      // ряды из юнитов
  const rowW = [0];
  const put = (u) => {
    let r = rows.length - 1;
    const need = rows[r].length ? rowW[r] + 1 + u.w : u.w;
    if (need <= avail(r)) { rows[r].push(u); rowW[r] = need; return; }
    if (rows[r].length && u.w <= avail(r + 1)) { rows.push([u]); rowW.push(u.w); return; }
    if (u.words.length > 1) { for (const w of u.words) put({ sep: w.sep, cells: w.cells, words: [w], w: width(w.cells) }); return; }
    if (rows[r].length) { rows.push([]); rowW.push(0); r++; }
    // Слово длиннее строки (длинная ссылка) — режем по символам
    let chunk = [], cw = 0;
    for (const c of u.cells) {
      if (cw + c.w > avail(r) && chunk.length) {
        rows[r].push({ sep: u.sep, cells: chunk, words: [], w: cw }); rowW[r] = cw;
        rows.push([]); rowW.push(0); r++; chunk = []; cw = 0;
      }
      chunk.push(c); cw += c.w;
    }
    rows[r].push({ sep: u.sep, cells: chunk, words: [], w: cw }); rowW[r] = cw;
  };
  for (const u of units(cells)) put(u);
  // Не оставлять одно слово в последнем ряду
  const n = rows.length;
  if (final && n >= 2 && rows[n - 1].length === 1 && rows[n - 2].length >= 3) {
    const mv = rows[n - 2][rows[n - 2].length - 1], last = rows[n - 1][0];
    if (mv.w + 1 + last.w <= avail(n - 1)) { rows[n - 2].pop(); rows[n - 1].unshift(mv); }
  }
  return rows.map((r, i) => {
    const out = [...(i === 0 ? first : cont)];
    r.forEach((u, j) => { if (j) out.push(u.sep); out.push(...u.cells); });
    return emit(out);
  });
}

// ── Строка markdown → ряды ────────────────────────────────
const dimCells = (t) => cellsOf(t, { dim: true });
const spaces = (n) => cellsOf(" ".repeat(n));
function hardRows(cells, cols, prefix) {
  const rows = []; let cur = [], w = 0; const av = Math.max(1, cols - width(prefix));
  for (const c of cells) { if (w + c.w > av && cur.length) { rows.push(emit([...prefix, ...cur])); cur = []; w = 0; } cur.push(c); w += c.w; }
  rows.push(emit([...prefix, ...cur]));
  return rows;
}
// Заголовки как у fx: у каждого уровня свой стиль (1 — жирный с подчёркиванием, 2 — жирный, 3 — подчёркнутый…)
const HEADING = [{ bold: true, ul: true }, { bold: true }, { ul: true }, { bold: true, dim: true }, { dim: true, ul: true }, { dim: true }];
// Блок кода как у fx: сверху линия с названием языка «─ js ────», снизу линия, ``` не показываются
const CODE_RULE = 48;
const fenceRows = (lang, cols) => {
  const w = Math.max(6, Math.min(cols, CODE_RULE));
  const label = lang ? clipEnd(safeText(lang), Math.max(1, w - 4)) : "";
  return [emit(dimCells(label ? `─ ${label} ` + "─".repeat(Math.max(1, w - strWidth(label) - 3)) : "─".repeat(w)))];
};
// Нумерация как у fx: номера выровнены по правому краю (« 1.», «10.»), продолжение пункта — под текстом
const olMark = (m) => " ".repeat(Math.max(0, 3 - m.length)) + m;
// Открытые нумерованные пункты (как open_ordered_items у fx): строка с отступом не меньше колонки текста
// пункта сдвигается вместе с его выровненным номером; остальные пункты закрываются.
function olShiftFor(state, lead) {
  const ol = state.ol ?? (state.ol = []);
  while (ol.length && lead < ol[ol.length - 1].col) ol.pop();
  return ol.length ? ol[ol.length - 1].shift : 0;
}
// state: { fence, ol }. Возвращает ряды или null (строку не показывать).
export function mdLine(raw, cols, state, final) {
  const line = raw.replace(/\t/g, "    ").replace(/\r$/, "");
  let m;
  if ((m = /^\s*(```|~~~)\s*([^`\s]*)/.exec(line))) return fenceRows(state.fence ? "" : m[2], cols);
  if (state.fence) return hardRows(cellsOf(safeText(line), { fg: C.codeBlock }), cols, []);
  const s = safeText(line);
  if (!s.trim()) return [""];
  if ((m = /^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$/.exec(s))) { state.ol = []; return wrap(inline(m[2], HEADING[m[1].length - 1]), cols, [], [], final); }
  if (/^\s{0,3}([-*_])(\s*\1){2,}\s*$/.test(s)) { state.ol = []; return [emit(dimCells("─".repeat(Math.min(60, cols))))]; }
  // Вложенное в нумерованный пункт сдвигается вместе с выровненным номером
  const lead = /^ */.exec(s)[0].length;
  const shift = olShiftFor(state, lead);
  if ((m = /^(\s*)((?:>\s?)+)(.*)$/.exec(s))) {
    const depth = (m[2].match(/>/g) ?? []).length;
    const pre = [...spaces(m[1].length + shift), ...Array.from({ length: depth }, () => dimCells("│ ")).flat()];
    return wrap(inline(m[3]), cols, pre, pre, final);
  }
  if ((m = /^(\s*)(?:[-*+•])\s+(?:\[([ xX])\]\s+)?(.*)$/.exec(s))) {
    const ind = spaces(m[1].length + shift);
    const mark = m[2] === undefined ? dimCells("• ") : m[2] === " " ? dimCells("☐ ") : cellsOf("✓ ", { fg: C.status });
    return wrap(inline(m[3]), cols, [...ind, ...mark], [...ind, ...spaces(2)], final);
  }
  if ((m = /^(\s*)(\d{1,9}[.)])\s+(.*)$/.exec(s))) {
    const mk = olMark(m[2]);
    const ind = spaces(m[1].length + shift), mark = dimCells(mk + " ");
    state.ol.push({ col: m[1].length + m[2].length + 1, shift: shift + mk.length - m[2].length });
    return wrap(inline(m[3]), cols, [...ind, ...mark], [...ind, ...spaces(mk.length + 1)], final);
  }
  return wrap(inline(s.slice(lead)), cols, spaces(lead + shift), spaces(lead + shift), final);
}

// ── Таблицы как у fx: рамка ┌┬┐ с колонками по ширине; не влезает — «Заголовок: значение» по строкам ──
const isTableLine = (l) => /^\s{0,3}\|/.test(l);
const isTableSep = (l) => /^\s*\|?(\s*:?-+:?\s*\|)+\s*:?-*:?\s*\|?\s*$/.test(l) && l.includes("-");
const tableCells = (l) => {
  let t = l.trim(); if (t.startsWith("|")) t = t.slice(1); if (t.endsWith("|") && !t.endsWith("\\|")) t = t.slice(0, -1);
  return t.split(/(?<!\\)\|/).map((c) => c.trim().replace(/\\\|/g, "|"));
};
export function tableRows(lines, cols) {
  const header = lines.length > 1 && isTableSep(lines[1]);
  const raw = lines.filter((l) => !isTableSep(l)).map((l) => tableCells(safeText(l)));
  if (!raw.length) return [];
  const n = Math.max(...raw.map((r) => r.length));
  const cells = raw.map((r, i) => Array.from({ length: n }, (_, j) => inline(r[j] ?? "", header && i === 0 ? { bold: true } : {})));
  const widths = Array.from({ length: n }, (_, j) => Math.max(1, ...cells.map((r) => width(r[j]))));
  const B = (t) => dimCells(t);
  if (widths.reduce((a, b) => a + b, 0) + 3 * n + 1 <= cols) {
    const border = (l, mid, r) => emit(B(l + widths.map((w) => "─".repeat(w + 2)).join(mid) + r));
    const out = [border("┌", "┬", "┐")];
    cells.forEach((r, i) => {
      const row = [...B("│")];
      r.forEach((c, j) => row.push(SP(), ...c, ...spaces(widths[j] - width(c) + 1), ...B("│")));
      out.push(emit(row));
      if (header && i === 0 && cells.length > 1) out.push(border("├", "┼", "┤"));
    });
    out.push(border("└", "┴", "┘"));
    return out;
  }
  // Узко: каждая строка таблицы — пункты «Заголовок: значение», между строками линия
  const head = header ? cells[0] : null, body = header ? cells.slice(1) : cells;
  const out = [];
  body.forEach((r, i) => {
    if (i) out.push(emit(B("─".repeat(Math.min(cols, 24)))));
    r.forEach((c, j) => {
      const label = head ? [...head[j].map((x) => ({ ...x, st: { ...x.st, bold: false, dim: true } })), ...dimCells(": ")] : [];
      out.push(...wrap([...label, ...c], cols, [], spaces(2), true));
    });
  });
  return out;
}

// ── Потоковый ответ ───────────────────────────────────────
// Как у fx, текст ответа идёт с отступом в 2 колонки (gutter) — вровень с текстом в плашке «┃ ».
const GUTTER = 2;
const gut = (rows) => rows.map((r) => (r ? " ".repeat(GUTTER) + r : r));
// Ряд уже не изменится, если в нём не осталось видимых знаков разметки (они бывают только у незакрытой)
const settled = (row) => !/[`*~[]|(^|[^\p{L}\p{N}])_|_($|[^\p{L}\p{N}])/u.test(row.replace(ANSI, ""));
// step(text, final) → { commit: ряды, которые уже не изменятся, live: ряды, которые ещё перерисуются }
export class MdStream {
  constructor(cols) { this.cols = cols; this.pos = 0; this.state = { fence: false, ol: [] }; this.frozen = 0; this.started = false; this.blank = false; this.hasRows = false; this.table = []; }
  get inner() { return Math.max(4, this.cols - GUTTER); }
  // Пустая строка между блоками; commit — ряды печатаются навсегда
  lead(commit) {
    const pre = this.blank ? [""] : [];
    if (commit) { this.blank = false; this.started = true; }
    return pre;
  }
  rowsFor(line, final, commit) {
    const fence = /^\s*(```|~~~)/.test(line);
    if (!this.state.fence && !fence && !line.trim()) { if (commit && this.started) this.blank = true; return []; }
    const st = commit ? this.state : { ...this.state, ol: [...(this.state.ol ?? [])] };
    const rows = mdLine(line, this.inner, st, final) ?? [];
    if (fence && commit) this.state.fence = !this.state.fence;
    return [...this.lead(commit), ...gut(rows)];
  }
  // Таблица копится, пока не кончится, и печатается целиком (ширина колонок известна только в конце)
  tableOut(lines, commit) {
    if (!lines.length) return [];
    const rows = [...this.lead(commit), ...gut(tableRows(lines, this.inner))];
    if (commit) this.table = [];
    return rows;
  }
  step(text, final = false) {
    const commit = [];
    let nl;
    while ((nl = text.indexOf("\n", this.pos)) >= 0) {
      const line = text.slice(this.pos, nl);
      if (!this.state.fence && isTableLine(line)) {
        this.table.push(line);
        if (this.table.length >= 12) commit.push(...this.tableOut(this.table, true));   // длинную не держим в живой области
      } else {
        commit.push(...this.tableOut(this.table, true));
        commit.push(...this.rowsFor(line, true, true).slice(this.frozen));
      }
      this.frozen = 0; this.pos = nl + 1;
    }
    const tail = text.slice(this.pos);
    let live = [];
    const tailTable = !this.state.fence && isTableLine(tail);
    if (this.table.length || tailTable) {
      if (tailTable || !tail.trim()) {
        if (final) { if (tail.trim()) this.table.push(tail); commit.push(...this.tableOut(this.table, true)); this.pos = text.length; }
        else live = this.tableOut(tail.trim() ? [...this.table, tail] : this.table, false);
        if (commit.length) this.hasRows = true;
        return { commit, live };
      }
      commit.push(...this.tableOut(this.table, true));   // началась обычная строка — таблица кончилась
    }
    live = tail ? this.rowsFor(tail, final, final) : [];
    if (final) { commit.push(...live.slice(this.frozen)); this.frozen = 0; this.pos = text.length; live = []; }
    else {
      live = live.slice(this.frozen);
      // Начало длинного абзаца уходит вверх заранее — но только если в абзаце нет незакрытых **, `, [ссылки:
      // иначе после закрытия ряды поменяются, а напечатанное уже не исправить (терялся текст)
      if (live.length > 4) {
        const k = live.length - 2;
        if (live.length > 24 || live.every(settled)) { commit.push(...live.slice(0, k)); this.frozen += k; live = live.slice(k); }
      }
    }
    if (commit.length) this.hasRows = true;
    return { commit, live };
  }
}

// ── Нижняя «живая» область экрана ─────────────────────────
// Ряды не шире экрана, поэтому число строк известно точно. cur — на каком ряду области стоит курсор.
const ANSI = /\x1b\[[0-9;?]*[ -\/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)/g;
export const visWidth = (s) => strWidth(s.replace(ANSI, ""));
export class LiveArea {
  constructor(write) { this.write = write; this.rows = 0; this.cur = 0; this.last = null; this.widths = []; this.col = 0; }
  erase() {
    let out = "";
    if (this.cur > 0) out += `\x1b[${this.cur}A`;
    if (this.rows > 0) out += "\r\x1b[J";
    if (out) this.write(out);
    this.rows = 0; this.cur = 0; this.last = null; this.widths = []; this.col = 0;
  }
  // Окно сузили: терминал сам переносит уже нарисованные ряды (reflow), и их становится больше.
  // Пересчитываем, на сколько строк подняться, чтобы стереть старую область целиком.
  reflow(termCols) {
    if (!termCols || !this.rows) return;
    let up = 0;
    for (let j = 0; j < this.cur; j++) up += Math.max(1, Math.ceil((this.widths[j] ?? 0) / termCols));
    up += Math.floor(Math.max(0, this.col - 1) / termCols);
    this.cur = up; this.last = null;
  }
  // commit — ряды, которые печатаются навсегда (уходят вверх); live — перерисовываемые;
  // cursor — { row, col } внутри live, куда поставить курсор (поле ввода)
  render(commit, live, cursor = null) {
    const frame = live.join("\n") + (cursor ? `@${cursor.row},${cursor.col}` : "");
    if (!commit.length && frame === this.last) return;
    // Как у fx: кадр целиком (synchronized update), курсор спрятан, пока рисуем, —
    // не прыгает по экрану и мигает в поле ввода как обычно
    let out = "\x1b[?2026h\x1b[?25l";
    if (this.cur > 0) out += `\x1b[${this.cur}A`;
    if (this.rows > 0 || commit.length || live.length) out += "\r\x1b[J";
    for (const r of commit) out += r + "\n";
    out += live.join("\n");
    let cur = Math.max(0, live.length - 1);
    this.widths = live.map(visWidth);
    let col = this.widths[cur] ?? 0;
    if (cursor && live.length) {
      const up = live.length - 1 - cursor.row;
      if (up > 0) out += `\x1b[${up}A`;
      out += "\r" + (cursor.col > 0 ? `\x1b[${cursor.col}C` : "");
      cur = cursor.row; col = cursor.col;
    }
    out += "\x1b[?2026l\x1b[?25h";
    this.write(out);
    this.rows = live.length; this.cur = cur; this.col = col; this.last = frame;
  }
}

// ── Время как у fx: 45s, 2m 05s, 1h 02m ──────────────────
export function fmtDur(ms) {
  const s = Math.max(0, Math.floor(ms / 1000));
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m ${String(s % 60).padStart(2, "0")}s`;
  return `${Math.floor(m / 60)}h ${String(m % 60).padStart(2, "0")}m`;
}
const plural = (n, one, few, many) => {
  const a = n % 10, b = n % 100;
  return a === 1 && b !== 11 ? one : a >= 2 && a <= 4 && (b < 12 || b > 14) ? few : many;
};
const blinkOn = () => Math.floor(Date.now() / 500) % 2 === 0;
const dotCell = () => `${blinkOn() ? fg(C.status) + "•" + RESET : " "} `;
const dimS = (s) => `\x1b[2m${s}${RESET}`;

// ── Строка активности, как у fx: «• думаю (12s)», точка мигает раз в секунду ──
// typed — то, что пользователь набирает (показываем хвост, если не влезает). Ряд никогда не шире cols.
export const clipEnd = (s, w) => { const g = [...seg.segment(s)].map((x) => x.segment); let out = "", ww = 0; for (const x of g) { if (ww + gWidth(x) > w) break; out += x; ww += gWidth(x); } return out; };
const clipStart = (s, w) => { const g = [...seg.segment(s)].map((x) => x.segment); let out = "", ww = 0; for (let i = g.length - 1; i >= 0; i--) { if (ww + gWidth(g[i]) > w) break; out = g[i] + out; ww += gWidth(g[i]); } return out; };
const clipDots = (s, w) => strWidth(s) <= w ? s : w <= 1 ? clipEnd(s, w) : clipEnd(s, w - 1) + "…";
export function statusRow(label, startedAt, cols, typed = "") {
  const dur = fmtDur(Date.now() - startedAt);
  const dot = dotCell();
  let text = `${label} (${dur})`;
  if (!typed) return dot + fg(C.status) + clipEnd(text, cols - 2) + RESET;
  typed = safeText(typed);
  // Когда набирают текст — он важнее метки: метка сжимается до «• (12s)», затем текст обрезается слева
  if (2 + strWidth(text) + 4 + strWidth(typed) > cols) text = `(${dur})`;
  const room = Math.max(1, cols - 2 - strWidth(text) - 4);
  const shown = strWidth(typed) > room ? "…" + clipStart(typed, room - 1) : typed;
  return `${dot}${fg(C.status)}${text}${RESET}  ${rail()} ${shown}`;
}

// ── Фоновые помощники — «работяги», как список агентов у fx (↓ в пустом поле, ⌃X) ──
// Свёрнуто — одна серая строка «2 работяги» (без точки, времени и подсказки); пока главный сам занят —
// то же справа в его строке активности: «• думаю (5s)      2 работяги».
// Развёрнуто — под ней столбик: короткая задача (2–3 слова) и серым справа время работы («12 с», «3 мин», «1 ч 05 мин»);
// без номеров и состояний. Застрявший шаг (сторож, doing.stuck) — жёлтым. Готовые («готов») не показываются.
// helpers: [{ n, title, state: "работает" | "готов", since, doing? }]
export const workersWord = (n) => `${n} ${plural(n, "работяга", "работяги", "работяг")}`;
export function helpersSummary(helpers) {
  const k = helpers.filter((h) => h.state === "работает" || h.state === "пауза").length;
  return k ? workersWord(k) : "";
}
// Время работы коротко: «12 с», «3 мин», «1 ч 05 мин»
export function workTime(ms) {
  const s = Math.max(0, Math.floor(ms / 1000));
  if (s < 60) return `${s} с`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m} мин`;
  return `${Math.floor(m / 60)} ч ${String(m % 60).padStart(2, "0")} мин`;
}
// Короткое название задачи: часть после «:», если есть; 2 слова (3 — если среди первых двух предлог/союз);
// слова не режутся, предлог/союз/знак в конце не остаётся. Так же, как shortTitle в pia.app.
const STOP = new Set(["в", "во", "на", "по", "для", "и", "или", "с", "со", "к", "ко", "о", "об", "обо", "от", "до", "из", "за",
  "без", "при", "через", "а", "но", "что", "как", "под", "над", "у", "про", "чтобы", "же", "ли", "не",
  "the", "a", "an", "of", "to", "in", "on", "for", "and", "or", "with"]);
const isEdge = (ch) => /[\p{P}\p{S}]/u.test(ch) && ch !== "#" && ch !== "@";
const trimBy = (str, pred) => { const a = [...str]; while (a.length && pred(a[0])) a.shift(); while (a.length && pred(a[a.length - 1])) a.pop(); return a.join(""); };
export function shortTitle(title) {
  let t = String(title ?? "").trim();
  const c = t.indexOf(":");
  if (c >= 0) { const after = t.slice(c + 1).trim(); if (/[\p{L}\p{N}]/u.test(after)) t = after; }
  const isStop = (w) => { const core = trimBy(w, isEdge).toLowerCase(); return !core || STOP.has(core); };
  const out = [];
  for (const w of t.split(/\s+/).filter(Boolean)) {
    if (out.length >= 3) break;
    if (out.length === 2 && !isStop(out[1]) && !isStop(out[0])) break;
    if (!out.length && !trimBy(w, isEdge)) continue;          // «+», «—» в начале
    out.push(w);
    if (/[,;.—]$/.test(w)) break;                              // конец фразы
  }
  while (out.length > 1 && isStop(out[out.length - 1])) out.pop();
  let r = trimBy(out.join(" "), (ch) => /\s/.test(ch) || (isEdge(ch) && !"»)\"".includes(ch)));
  if (r.endsWith("»") && !r.includes("«")) r = r.slice(0, -1);
  if (r.startsWith("«") && !r.includes("»")) r = r.slice(1);
  return r || "задача";
}
const working = (helpers) => helpers.filter((h) => h.state === "работает" || h.state === "пауза");   // пауза после лимита — тоже в списке
// Свёрнутая строка: «2 работяги» серым, в ширину окна
function summaryLine(helpers, cols) {
  return "  " + fg(C.status) + clipEnd(helpersSummary(helpers), Math.max(1, cols - 2)) + RESET;
}
// label/startedAt — своя активность главного (или null); raw — готовая строка (например «останавливаю…»);
// key — клавиша раскрытия (↓ или ⌃X); в строке больше не показывается, оставлен для совместимости
export function footerRows({ label = null, startedAt = 0, raw = null, helpers = [], open = false, cols, key = "↓" }) {
  const rows = [];
  const list = working(helpers);
  const own = raw ?? (label !== null ? statusRow(label, startedAt, cols) : null);
  if (own !== null) {
    if (!list.length) return [own];
    // Свёрнуто — справа в строке активности главного, если влезает
    const note = helpersSummary(list), w = visWidth(own);
    if (!open && w + 3 + strWidth(note) <= cols) rows.push(own + " ".repeat(cols - w - strWidth(note)) + fg(C.status) + note + RESET);
    else rows.push(own, summaryLine(list, cols));
  } else if (list.length) rows.push(summaryLine(list, cols));
  if (open && list.length) rows.push(...helperListRows(list, cols));
  return rows;
}
const LIST_MAX = 8;
const YELLOW = "\x1b[33m";
export function helperListRows(helpers, cols) {
  const now = Date.now();
  const list = working(helpers);
  const more = list.length > LIST_MAX ? list.length - (LIST_MAX - 1) : 0;
  const shown = more ? list.slice(0, LIST_MAX - 1) : list;
  const name = (h) => h.state === "пауза" ? safeText(`#${h.n} — ${h.label}`) : safeText(shortTitle(h.title));
  const time = (h) => (h.state !== "пауза" && h.since ? workTime(now - h.since) : "");
  // «  ├ вставка скриншотов   3 мин»; узко — время убирается, название обрезается «…»
  let tW = Math.max(0, ...shown.map((h) => strWidth(time(h))));
  if (cols - 4 - (tW ? 2 + tW : 0) < 8) tW = 0;
  const nameW = Math.max(1, Math.min(cols - 4 - (tW ? 2 + tW : 0), Math.max(...shown.map((h) => strWidth(name(h))))));
  const rows = shown.map((h, i) => {
    const last = i === shown.length - 1 && !more;
    const stuck = !!h.doing?.stuck;        // сторож: шаг идёт слишком долго — жёлтым
    const title = clipDots(name(h), nameW);
    let r = dimS(`  ${last ? "└" : "├"} `) + (stuck ? YELLOW + title + RESET : title);
    const d = tW ? time(h) : "";
    if (d) r += " ".repeat(Math.max(0, nameW - strWidth(title))) + "  " + (stuck ? YELLOW + d.padStart(tW) + RESET : dimS(d.padStart(tW)));
    return r;
  });
  if (more) rows.push(dimS(`  └ … и ещё ${more}`));
  return rows;
}

// ── Сообщение пользователя: «┃ » + жирный, перенос по словам ──
// Захваченный контекст <context source="…">…</context> → одна серая строка (модели уходит полный текст)
const CTX_RE = /<context\b([^>]*)>([\s\S]*?)<\/context>/g;
export function foldContext(raw) {
  const ctx = [];
  let hasImg = false;
  const text = safeText(raw).replace(CTX_RE, (m, attrs, body) => {
    const src = /source="([^"]*)"/.exec(attrs)?.[1];
    const line = /^\s*Контекст:[^\n]*/m.exec(body)?.[0]?.trim();
    let label = line ? line.replace(/\s+—\s+https?:\/\/\S+\s*$/, "") : src ? `Контекст: ${src}` : "Контекст";
    if (/\.(png|jpe?g|webp|heic)\b|\[картинка \d+\]/i.test(body)) label += " · снимок";
    ctx.push(label); return "\u0000CTX" + (ctx.length - 1) + "\u0000";
  });
  if (!ctx.length) return { text, ctx, hasImg };
  const clean = text.split("\n").filter((l) => !/^\s*\[(?:картинка \d+\][^\n]*(?:context-|\.png|\.jpe?g)[^\n]*|снимок убран из контекста:[^\]]*\])\s*$/.test(l)).join("\n").replace(/\n{3,}/g, "\n\n");
  return { text: clean, ctx, hasImg: true };
}
export const isCtxNote = (n) => /context-[^\s]*\.(png|jpe?g|webp)/i.test(n) || /^\[снимок убран/.test(n);

// ── Сообщение пользователя: «┃ » + жирный, перенос по словам ──
export function userCardRows(raw, cols) {
  const rail = [{ g: "┃", w: 1, st: { fg: C.rail } }, SP()];
  const f = foldContext(raw);
  return f.text.split("\n").flatMap((l) => {
    const mk = /^\u0000CTX(\d+)\u0000$/.exec(l.trim());
    if (mk) return [dimS("  " + clipDots(f.ctx[+mk[1]], cols - 2))];
    if (!l.trim()) return [emit(rail)];
    const ind = Math.min(/^ */.exec(l)[0].length, Math.floor(cols / 3));   // отступы (код, JSON) сохраняем
    const pre = [...rail, ...spaces(ind)];
    return wrap(cellsOf(l.trimStart(), { bold: true }), cols, pre, pre, true);
  });
}
