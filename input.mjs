// Строка ввода вместо readline (у readline баг: вставка длиннее строки экрана дублируется).
// Как у fx: «┃ » на каждой строке, перенос по ширине, многострочная вставка — одно сообщение,
// Option+Enter — новая строка, ↑/↓ — история, Ctrl+V — картинка из буфера обмена.
// ↓ в пустом поле (не в истории) и ⌃X — показать/скрыть список помощников (решает onArrow/onToggle).
import fs from "node:fs";
import { findImagePaths, imagePathOf } from "./attachments.mjs";
import { gWidth, strWidth, rail, safeText, clipEnd } from "./render.mjs";

// Большая вставка сворачивается в один токен, как в pi
const PASTE_LINES = 4, PASTE_CHARS = 800;
const plural = (n, one, few, many) => {
  const a = n % 10, b = n % 100;
  return a === 1 && b !== 11 ? one : a >= 2 && a <= 4 && (b < 12 || b > 14) ? few : many;
};

const seg = new Intl.Segmenter();
const graphemes = (s) => [...seg.segment(s)].map((x) => x.segment);
const isWordG = (g) => /[\p{L}\p{N}_]/u.test(g);

export class Editor {
  // clipboardImage — картинка из буфера обмена в файл (или null); keepImage — куда положить вставленную картинку
  // (окно pia копирует её в папку вложений, чтобы файл не пропал до отправки). В проверках — подделки.
  constructor({ historyFile, onSubmit, onInterrupt, onEscape, onExit, onImage, onChange, onArrow = () => false, onToggle = () => {},
    clipboardImage = null, keepImage = (f) => f, waitMs = 600 }) {
    Object.assign(this, { historyFile, onSubmit, onInterrupt, onEscape, onExit, onImage, onChange, onArrow, onToggle, clipboardImage, keepImage, waitMs });
    this.queue = null;                // клавиши, пришедшие, пока разбирается вставка (ждём файл / буфер обмена)
    this.burst = null;                // символы, пришедшие одной пачкой без «скобок вставки» (см. settleBurst)
    this.g = []; this.pos = 0;
    this.pasting = false; this.pasteBuf = "";
    this.submitTimer = null;
    this.images = new Map();          // внутренняя пометка «[картинка N]» (один элемент в строке) → путь к файлу
    this.imageN = 0;                  // на экране и при отправке номера идут по порядку в тексте (см. label)
    this.pastes = new Map();          // «[вставка #N …]» → полный текст
    this.pasteN = 0;
    try { this.history = JSON.parse(fs.readFileSync(historyFile, "utf8")); } catch { this.history = []; }
    this.hIndex = this.history.length; this.draft = null;
  }
  get text() { return this.g.join(""); }
  // Поле пустое и не листаем историю — тогда ↓ раскрывает список помощников (как у fx)
  get idle() { return !this.g.length && this.hIndex === this.history.length; }
  set(text) { this.g = graphemes(text); this.pos = this.g.length; }
  insert(text) {
    const add = graphemes(text);
    this.g.splice(this.pos, 0, ...add); this.pos += add.length;
  }
  // Вставка из буфера: переводы строк сохраняем, «┃ » из скопированного вывода pia убираем
  insertPaste(raw) {
    let t = raw.replace(/\r\n?/g, "\n");
    const lines = t.split("\n");
    const railed = lines.filter((l) => l.trim()).length && lines.filter((l) => l.trim()).every((l) => /^\s*┃ ?/.test(l));
    if (railed) t = lines.map((l) => l.replace(/^\s*┃ ?/, "")).join("\n");
    t = t.replace(/[\x00-\x08\x0b-\x1f\x7f]/g, "").replace(/\t/g, "    ");
    // ⌘V, когда в буфере только картинка: терминал присылает пустую вставку — берём картинку из буфера сами
    if (!t.trim()) return t ? this.insert(t) : this.onImage?.();
    // Вставили путь к картинке, а файла нет (CleanShot кладёт в буфер путь к своему временному файлу, который
    // ещё пишется или уже удалён, когда закрыли окошко снимка): ждём файл, потом — картинка из самого буфера
    const lone = imagePathOf(t);
    if (lone && !findImagePaths(t).length) return this.pasteMissing(t, lone);
    // Пути к картинкам (в т.ч. file://, с пробелами) → пометки «[картинка N]»; размер считаем уже с пометками
    const imgs = findImagePaths(t);
    if (imgs.length) {
      let short = "", at = 0;
      for (const f of imgs) { short += t.slice(at, f.index) + "[картинка 1]"; at = f.index + f.match.length; }
      short += t.slice(at);
      // строки, где одни пометки (список скриншотов), «большой» вставкой не считаются
      const rest = short.replace(/\[картинка 1\]/g, "");
      if (!(rest.split("\n").filter((l) => l.trim()).length >= PASTE_LINES || rest.length > PASTE_CHARS)) { this.insertRich(t, imgs); return; }
    }
    const n = t.split("\n").length;
    if (n >= PASTE_LINES || t.length > PASTE_CHARS) {
      this.pasteN++;
      const token = n > 1
        ? `[вставка #${this.pasteN} +${n} ${plural(n, "строка", "строки", "строк")}]`
        : `[вставка #${this.pasteN} ${t.length} ${plural(t.length, "символ", "символа", "символов")}]`;
      this.pastes.set(token, t);
      this.g.splice(this.pos, 0, token); this.pos++;   // один элемент: Backspace стирает целиком
      return;
    }
    this.insert(t);
  }
  async pasteMissing(t, file) {
    const exists = () => { try { return fs.statSync(file).isFile(); } catch { return false; } };
    for (let waited = 0; !exists() && waited < this.waitMs; waited += 100) await new Promise((r) => setTimeout(r, 100));
    if (exists()) return this.insertRich(t, [{ match: t, file, index: 0 }]);
    const clip = await this.clipboardImage?.().catch(() => null);
    if (clip) return this.addImage(clip, false);
    this.insert(t);                   // картинки нет нигде — оставляем текст как есть
  }
  // Текст с картинками: пути превращаются в неделимые пометки, остальное вставляется как есть
  insertRich(t, imgs = findImagePaths(t)) {
    let at = 0;
    for (const f of imgs) {
      if (f.index > at) this.insert(t.slice(at, f.index));
      this.addImage(f.file, false); at = f.index + f.match.length;
    }
    if (at < t.length) this.insert(t.slice(at));
  }
  isImage(ch) { return this.images.has(ch); }
  // Номер на экране — по порядку в строке (после удаления одной из картинок остальные сдвигаются);
  // тот же порядок уходит при отправке, так что «[картинка 2]» в поле = «[картинка 2]» в истории
  labels() {
    const m = new Map();
    for (const ch of this.g) if (this.images.has(ch) && !m.has(ch)) m.set(ch, `[картинка ${m.size + 1}]`);
    return m;
  }
  atom(ch) { return this.pastes.has(ch) || this.images.has(ch); }
  width(ch, lb) { return this.pastes.has(ch) ? strWidth(ch) : this.images.has(ch) ? strWidth(lb?.get(ch) ?? ch) : gWidth(ch); }
  expand(text) {
    for (const [token, full] of this.pastes) text = text.split(token).join(full);
    return text;
  }
  submit() {
    const lb = this.labels();
    const raw = this.g.map((ch) => lb.get(ch) ?? ch).join("");
    if (!raw.trim()) { this.set(""); return; }
    const text = this.expand(raw);
    // В историю — с путями вместо пометок, чтобы при вызове из истории картинки снова прикрепились
    const q = (f) => (/[\s'"\\]/.test(f) ? (f.includes("'") ? `"${f}"` : `'${f}'`) : f);
    const histText = this.expand(this.g.map((ch) => this.images.has(ch) ? q(this.images.get(ch)) : ch).join(""));
    const pastes = new Map([...this.pastes].filter(([t]) => raw.includes(t)));
    this.pastes.clear();
    if (this.history[this.history.length - 1] !== histText) {
      this.history.push(histText); this.history = this.history.slice(-200);
      try { fs.writeFileSync(this.historyFile, JSON.stringify(this.history)); } catch {}
    }
    this.hIndex = this.history.length; this.draft = null;
    const images = new Map([...lb].map(([ch, label]) => [label, this.images.get(ch)]));
    this.set(""); this.images.clear(); this.imageN = 0;
    this.onSubmit(text, images, pastes);
  }
  wordLeft() { let i = this.pos; while (i > 0 && !isWordG(this.g[i - 1])) i--; while (i > 0 && isWordG(this.g[i - 1])) i--; return i; }
  wordRight() { let i = this.pos; while (i < this.g.length && !isWordG(this.g[i])) i++; while (i < this.g.length && isWordG(this.g[i])) i++; return i; }
  // Раскладка как у fx (input/visual_layout.zig): перенос по словам. Слово, которое не влезает
  // в остаток строки, но влезает в целую, переносится целиком; пробелы на краю «висят» за полем,
  // поэтому следующая строка начинается со слова; слово длиннее строки режется по символам.
  // Возвращает ряды и позицию каждого символа (для курсора и ↑/↓ внутри многострочного ввода).
  layout(cols) {
    const W = Math.max(4, cols - 2);
    const g = this.g, n = g.length;
    const brk = (ch) => ch === " " || ch === "\n";
    const lb = this.labels();
    const atom = (ch) => this.atom(ch);
    const wordWidth = (i) => { let w = 0; for (let j = i; j < n && !brk(g[j]) && (j === i || !atom(g[j])); j++) { w += this.width(g[j], lb); if (w > W) break; } return w; };
    const rows = [[]]; const at = []; let r = 0, c = 0, wordStart = true;
    const next = () => { rows.push([]); r++; c = 0; };
    for (let i = 0; i < n; i++) {
      const ch = g[i];
      if (ch === "\n") { at[i] = { r, c: Math.min(c, W) }; next(); wordStart = true; continue; }
      const w = this.width(ch, lb);
      if (ch !== " " && c > 0) {
        if (c >= W) next();
        else if (wordStart && !atom(ch)) { const ww = wordWidth(i); if ((ww > W - c && ww <= W) || c + w > W) next(); }
        else if (c + w > W) next();
      }
      at[i] = { r, c: Math.min(c, W) };
      rows[r].push(lb.get(ch) ?? ch); c += w;
      wordStart = ch === " " || atom(ch);
    }
    if (c >= W) next();      // строка заполнена до края — курсор на новой
    at[n] = { r, c };
    return { rows, at, W };
  }
  render(cols, maxRows = 10) {
    const { rows, at, W } = this.layout(cols);
    const cur = at[this.pos];
    let start = 0;
    if (rows.length > maxRows) start = Math.min(Math.max(0, cur.r - maxRows + 1), rows.length - maxRows);
    // Пробелы, «висящие» за краем, не рисуем — ряд никогда не шире поля
    const shown = rows.slice(start, start + maxRows).map((r) => `${rail()} ${clipEnd(safeText(r.join("")), W)}`);
    return { rows: shown, cursor: { row: cur.r - start, col: 2 + cur.c } };
  }
  vertical(dir, cols) {
    const { rows, at } = this.layout(cols);
    const cur = at[this.pos];
    const tr = cur.r + dir;
    if (tr < 0 || tr >= rows.length) return false;
    let best = null;
    for (let i = 0; i < at.length; i++) if (at[i].r === tr && at[i].c <= cur.c) best = i;
    if (best === null) for (let i = 0; i < at.length; i++) if (at[i].r === tr) { best = i; break; }
    this.pos = best; return true;
  }
  historyMove(dir) {
    if (!this.history.length) return;
    if (this.hIndex === this.history.length) this.draft = this.g.slice();
    const n = Math.min(this.history.length, Math.max(0, this.hIndex + dir));
    if (n === this.hIndex) return;
    this.hIndex = n;
    if (n === this.history.length) { this.g = this.draft ?? []; this.pos = this.g.length; }
    else { this.g = []; this.pos = 0; this.insertRich(this.history[n]); }
  }
  // Картинка — один неделимый элемент (курсор перескакивает, Backspace стирает целиком)
  addImage(path, space = true) {
    path = this.keepImage(path) ?? path;
    this.imageN++;
    const token = `[картинка ${this.imageN}]`;
    this.images.set(token, path);
    this.g.splice(this.pos, 0, token); this.pos++;
    if (space) this.insert(" ");
  }
  // s — строка, key — разобранная клавиша (readline.emitKeypressEvents)
  key(s, key = {}, cols = 80) {
    if (this.queue) { this.queue.push([s, key, cols]); return; }
    const name = key.name;
    if (name === "paste-start") { this.pasting = true; this.pasteBuf = ""; return; }
    if (name === "paste-end") {
      this.pasting = false;
      const raw = this.pasteBuf; this.pasteBuf = "";
      const r = this.insertPaste(raw);
      if (r && typeof r.then === "function") return this.waitFor(r);
      return this.onChange();
    }
    if (this.pasting) { this.pasteBuf += name === "return" || name === "enter" ? "\n" : (s ?? ""); return; }
    // Терминал без «скобок вставки»: Enter, за которым сразу идут ещё символы, — это перенос строки во вставке
    if (this.submitTimer) {
      clearTimeout(this.submitTimer); this.submitTimer = null;
      this.insert("\n");
    }
    if ((name === "return" || name === "enter") && !key.meta && !key.shift) {
      this.submitTimer = setTimeout(() => { this.submitTimer = null; this.submit(); }, 12);
      return;
    }
    if ((name === "return" || name === "enter")) this.insert("\n");
    else if (key.ctrl && name === "c") return this.onInterrupt(this.text.length > 0);
    else if (key.ctrl && name === "d") { if (!this.g.length) return this.onExit(); this.g.splice(this.pos, 1); }
    else if (name === "escape") return this.onEscape();
    else if (key.ctrl && name === "v") return this.onImage();
    else if (name === "backspace") {
      if (key.meta || (key.ctrl && name === "w")) { const i = this.wordLeft(); this.g.splice(i, this.pos - i); this.pos = i; }
      else if (this.pos > 0) { this.g.splice(this.pos - 1, 1); this.pos--; }
    }
    else if (key.ctrl && name === "w") { const i = this.wordLeft(); this.g.splice(i, this.pos - i); this.pos = i; }
    else if (name === "delete") this.g.splice(this.pos, 1);
    else if (name === "left" || (key.ctrl && name === "b")) this.pos = key.meta ? this.wordLeft() : Math.max(0, this.pos - 1);
    else if (name === "right" || (key.ctrl && name === "f")) this.pos = key.meta ? this.wordRight() : Math.min(this.g.length, this.pos + 1);
    else if (key.meta && name === "b") this.pos = this.wordLeft();
    else if (key.meta && name === "f") this.pos = this.wordRight();
    else if (name === "home" || (key.ctrl && name === "a")) this.pos = 0;
    else if (name === "end" || (key.ctrl && name === "e")) this.pos = this.g.length;
    else if (key.ctrl && name === "u") { this.g.splice(0, this.pos); this.pos = 0; }
    else if (key.ctrl && name === "k") this.g.splice(this.pos);
    else if (key.ctrl && name === "x") return this.onToggle();
    else if (name === "up") { if (this.onArrow(-1)) return; if (!this.vertical(-1, cols)) this.historyMove(-1); }
    else if (name === "down") { if (this.onArrow(1)) return; if (!this.vertical(1, cols)) this.historyMove(1); }
    else if (name === "tab") this.insert("  ");
    else if (s && !key.ctrl && !/^\x1b/.test(s) && !/[\x00-\x08\x0b-\x1f\x7f]/.test(s)) { this.trackBurst(); this.insert(s); }
    else return;
    this.onChange();
  }
  // Пока вставка разбирается (ждём файл или буфер обмена), клавиши копятся и потом идут по порядку
  waitFor(p) {
    this.queue = [];
    const done = () => {
      const q = this.queue; this.queue = null;
      this.onChange();
      for (const a of q) this.key(...a);
    };
    return Promise.resolve(p).then(done, done);
  }
  // Терминал без «скобок вставки» (или перетаскивание файла) присылает путь как быстрый набор: все символы
  // приходят одной пачкой за один такт. Когда пачка закончилась, пути к картинкам в ней → пометки, как у вставки.
  trackBurst() {
    if (this.burst) { this.burst.n++; return; }
    this.burst = { start: this.pos, len: this.g.length, n: 1 };
    setImmediate(() => this.settleBurst());
  }
  settleBurst() {
    const b = this.burst; this.burst = null;
    if (!b || b.n < 8 || this.queue || this.pasting) return;
    const added = this.g.length - b.len;
    if (added <= 0 || this.pos - b.start !== added) return;          // курсор уходил — не трогаем
    const part = this.g.slice(b.start, this.pos);
    if (part.some((ch) => this.atom(ch))) return;
    const t = part.join(""), imgs = findImagePaths(t);
    if (!imgs.length) return;
    this.g.splice(b.start, added); this.pos = b.start;
    this.insertRich(t, imgs);
    this.onChange();
  }
}
