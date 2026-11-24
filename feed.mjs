// Лента главного разговора — то, что видит пользователь в окнах (терминал, окно pia):
// его сообщения, ответы ассистента, отчёты помощников. Служебные вызовы инструментов сюда не попадают.
// Хранится в ~/.pi-agent/feed.jsonl (одна строка — одна запись); при первом запуске заполняется из memory.sqlite.
// Без зависимостей от pi — проверяется в tests/server.test.mjs.
import fs from "node:fs";
import path from "node:path";

export const REPORT_RE = /^\[Отчёт помощника #(\d+)(?: «([^»]*)»)?\]/;
// Текст сообщения для модели: строка или текстовые части
export const textOf = (content) => typeof content === "string" ? content
  : (content ?? []).filter((c) => c.type === "text").map((c) => c.text).join("");
// «[картинка 1] (CleanShot ….png)» → «[картинка 1]», как в карточке терминала
export const cardOf = (t) => t.replace(/(\[картинка \d+\]) \([^)\n]*\)/g, "$1");
// Несколько отчётов, отданных главному одним сообщением, — по отдельности
export const splitReports = (t) => t.split(/\n\n(?=\[Отчёт помощника #\d+)/);

export class Feed {
  // file — feed.jsonl; imageDir — куда класть картинки из старой истории (при заполнении из базы)
  constructor(file, { imageDir = null, now = () => Date.now() } = {}) {
    Object.assign(this, { file, imageDir, now });
    this.items = [];          // готовые записи по возрастанию seq
    this.seq = 0;             // последний выданный номер
    this.lastEntry = 0;       // последняя учтённая запись разговора (id в memory.sqlite)
    this.expected = [];       // свои отправки (текст для модели), которые ещё не появились записью в разговоре
    this.live = null;         // дописываемый ответ: { key, text }
    this.candidates = [];     // ответы, показанные в потоке, но ещё не записанные (ключ потока → запись)
    this.listeners = new Set();
    this.n = 0;
  }
  get exists() { return fs.existsSync(this.file); }
  load() {
    if (!this.exists) return this;
    for (const line of fs.readFileSync(this.file, "utf8").split("\n")) {
      if (!line.trim()) continue;
      let o; try { o = JSON.parse(line); } catch { continue; }
      if (o.lastEntry != null) { this.lastEntry = Math.max(this.lastEntry, o.lastEntry); continue; }
      if (typeof o.seq !== "number") continue;
      this.items.push(o); this.seq = Math.max(this.seq, o.seq);
      if (o.entry) this.lastEntry = Math.max(this.lastEntry, o.entry);
    }
    this.items.sort((a, b) => a.seq - b.seq);
    // Отправки после последнего записанного ответа могли не дойти до записи в разговоре — ждём их
    let i = this.items.length;
    while (i > 0 && !this.items[i - 1].entry) i--;
    this.expected = this.items.slice(i).filter((x) => x.role !== "assistant").map((x) => x.key ?? x.text);
    return this;
  }
  write(o) { fs.mkdirSync(path.dirname(this.file), { recursive: true }); fs.appendFileSync(this.file, JSON.stringify(o) + "\n"); }
  emit(ev) { for (const f of this.listeners) { try { f(ev); } catch {} } }
  subscribe(f) { this.listeners.add(f); return () => this.listeners.delete(f); }

  append(fields, { persist = true } = {}) {
    const item = { seq: ++this.seq, role: fields.role, text: fields.text ?? "", images: fields.images ?? [], ts: fields.ts ?? new Date(this.now()).toISOString() };
    for (const k of ["card", "notes", "n", "title", "source", "entry", "stream", "key", "service"]) if (fields[k] != null && !(Array.isArray(fields[k]) && !fields[k].length)) item[k] = fields[k];
    this.items.push(item);
    if (persist) this.write(item);
    this.emit({ type: "item", item });
    return item;
  }
  // Сообщение пользователя (из любого окна). key — текст, который получит модель (чтобы узнать его запись в разговоре)
  addUser({ text, card, notes, images, key, source }) {
    if (key != null) this.expected.push(key);
    return this.append({ role: "user", text, card: card !== text ? card : undefined, notes, images, key: key !== text ? key : undefined, source });
  }
  // Отчёты помощников, которые отдаются главному одним сообщением
  addReports(reports) {
    const joined = reports.map((r) => r.text).join("\n\n");
    this.expected.push(joined);
    return reports.map((r) => this.append({ role: "report", text: r.text, n: r.n, title: r.title }));
  }
  // Служебная строка от pia («Остановил.», «Не получилось ответить…») — видна в обоих окнах
  addService(text) { return this.append({ role: "assistant", text, service: true }); }

  // Поток: частичный текст текущего ответа модели (null — идёт инструмент, текст не показываем)
  setLive(text) {
    if (!text) return false;
    for (const c of this.candidates) if (c.done && (c.text === text || c.text.startsWith(text))) return false;   // устаревший кусок уже записанного ответа
    if (this.live && text.startsWith(this.live.text)) { if (this.live.text === text) return false; this.live.text = text; return true; }
    this.live = { key: `s${this.now().toString(36)}-${++this.n}`, text };
    this.candidates.push(this.live);
    if (this.candidates.length > 20) this.candidates.shift();
    return true;
  }
  endTurn() { this.live = null; this.candidates = this.candidates.filter((c) => c.done).slice(-5); }

  // Новая запись в разговоре (из watch или при догонке) → запись ленты
  entry(e, { backfill = false } = {}) {
    if (!e || e.id <= this.lastEntry) return null;
    this.lastEntry = e.id;
    const m = e.model?.[0];
    if (e.kind === "pi.assistant" && m?.role === "assistant") {
      const text = textOf(m.content).trim();
      if (!text) return null;
      // Этот ответ уже показывался в потоке — тот же ключ, чтобы окна не нарисовали его второй раз
      const c = this.candidates.find((x) => !x.done && (text.startsWith(x.text.trimEnd()) || x.text.startsWith(text)));
      if (c) { c.done = true; c.text = text; if (this.live === c) this.live = null; }
      return this.append({ role: "assistant", text, entry: e.id, stream: c?.key, ts: m.timestamp ? new Date(m.timestamp).toISOString() : undefined });
    }
    if (e.kind === "pi.user" && m?.role === "user") {
      const key = textOf(m.content);
      const i = this.expected.indexOf(key);
      if (i >= 0) { this.expected.splice(i, 1); this.write({ lastEntry: e.id }); return null; }
      if (!key.trim()) return null;
      const ts = m.timestamp ? new Date(m.timestamp).toISOString() : undefined;
      if (REPORT_RE.test(key)) {
        const out = splitReports(key).map((t) => { const r = REPORT_RE.exec(t); return this.append({ role: "report", text: t, n: r ? Number(r[1]) : undefined, title: r?.[2], ts, entry: e.id }); });
        return out[0];
      }
      const images = backfill ? [] : this.saveImages(e.id, m.content);
      return this.append({ role: "user", text: cardOf(key), images, key: cardOf(key) !== key ? key : undefined, ts, entry: e.id });
    }
    return null;
  }
  // Картинки из старой записи разговора → файлы (чтобы окно могло их показать)
  saveImages(id, content) {
    if (!this.imageDir || !Array.isArray(content)) return [];
    const out = [];
    content.filter((c) => c.type === "image" && c.data).forEach((c, k) => {
      const ext = { "image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp" }[c.mimeType] ?? "png";
      const f = path.join(this.imageDir, `${id}-${k + 1}.${ext}`);
      try { if (!fs.existsSync(f)) { fs.mkdirSync(this.imageDir, { recursive: true }); fs.writeFileSync(f, Buffer.from(c.data, "base64")); } out.push(f); } catch {}
    });
    return out;
  }
  // Первое заполнение из всей истории разговора (entries по возрастанию id); картинки — только у последних keepImages
  backfill(entries, keepImages = 200) {
    const withImages = [];
    for (const e of entries) {
      const it = this.entry(e, { backfill: true });
      if (it?.role === "user" && Array.isArray(e.model?.[0]?.content) && e.model[0].content.some((c) => c.type === "image")) withImages.push([it, e]);
    }
    const from = this.items.length > keepImages ? this.items[this.items.length - keepImages].seq : 0;
    let changed = false;
    for (const [it, e] of withImages) if (it.seq >= from) { it.images = this.saveImages(e.id, e.model[0].content); changed = changed || it.images.length > 0; }
    if (changed) this.rewrite();
  }
  rewrite() {
    const tmp = this.file + ".tmp";
    fs.writeFileSync(tmp, this.items.map((x) => JSON.stringify(x)).join("\n") + (this.items.length ? "\n" : "") + JSON.stringify({ lastEntry: this.lastEntry }) + "\n");
    fs.renameSync(tmp, this.file);
  }

  // История для окон: записи с seq > after (последние limit) + дописываемый ответ (partial: true) в конце.
  // Его seq — номер, который ответ получит, если до его записи ничего не придёт; last — последний готовый seq:
  // клиенту достаточно в следующий раз спросить after=last.
  history(after = 0, limit = 200, { busy = false, toolRunning = false } = {}) {
    const lim = Math.max(1, Math.min(1000, Number(limit) || 200));
    const a = Number(after) || 0;
    const list = this.items.filter((x) => x.seq > a).slice(-lim).map(publicItem);
    if (busy && this.live && !toolRunning) list.push({ seq: this.seq + 1, role: "assistant", text: this.live.text, images: [], ts: new Date(this.now()).toISOString(), partial: true, stream: this.live.key });
    return { items: list, busy: !!busy, last: this.seq };
  }
  tail(n) { return n > 0 ? this.items.slice(-n).map(publicItem) : []; }
}
// Наружу — без служебного key (текст для модели)
export const publicItem = ({ key, entry, ...x }) => x;
