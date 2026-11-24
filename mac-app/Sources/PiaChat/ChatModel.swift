import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum Attachment: Identifiable {
    case image(id: UUID, path: String)
    case context(id: UUID, CapturedContext)
    var id: UUID {
        switch self { case .image(let id, _), .context(let id, _): return id }
    }
}

@MainActor
@Observable
final class ChatModel {
    var items: [FeedItem] = []
    var busy = false
    var activity: Activity = .thinking  // чем занята — какой спиннер показывать
    var stopping = false
    @ObservationIgnored private var activityAt = Date.distantPast
    @ObservationIgnored private var activityTask: Task<Void, Never>?
    var connected: Bool? = nil          // nil — ещё не знаем (первая секунда)
    var helpers: [HelperInfo] = []
    var attachments: [Attachment] = []
    var draft = ""
    var sendError: String?
    var hint: String?                    // короткая подсказка в окне (например, нет окон под pia)
    @ObservationIgnored private var hintTask: Task<Void, Never>?
    var zoomImage: String?
    var helpersExpanded = false
    var loadingOlder = false
    var noOlder = false
    var scrollToBottomToken = 0          // изменилось — лента прокручивается вниз
    var newAnswerSeq = 0                 // пришёл новый ответ (не из истории) — лента держит его начало у верха
    var anchorAfterPrepend: Int?         // после подгрузки старых — держать этот seq наверху

    @ObservationIgnored let client = PiaClient()
    @ObservationIgnored private var lastSeq = 0
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var loadedOnce = false
    @ObservationIgnored private var lastHelpersPoll = Date.distantPast
    @ObservationIgnored private var pollGen = 0          // номер запуска опроса
    @ObservationIgnored private var appliedGen = 0       // самый новый опрос, чей busy уже применён (старые ответы его не затирают)
    @ObservationIgnored weak var inputView: NSTextView?
    /// Открыть / закрыть мастер разрешений (задаёт AppDelegate)
    @ObservationIgnored var onOpenPermissions: () -> Void = {}
    @ObservationIgnored var onClosePermissions: () -> Void = {}
    /// Команды в поле ввода, открывающие мастер разрешений (не уходят в службу)
    static let permissionCommands: Set<String> = ["/разрешения", "/доступы", "/permissions"]

    static let imagesDir = NSHomeDirectory() + "/.pi-agent/pia/mac-images"

    // MARK: опрос службы

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let ok = await self.pollOnce()
                let delay: Double = ok ? (self.busy ? 0.6 : 1.0) : 2.0
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    @discardableResult
    func pollOnce() async -> Bool {
        pollGen += 1
        let gen = pollGen
        do {
            let first = !loadedOnce
            let h = try await client.history(after: lastSeq, limit: first ? 80 : 300)
            let seqBefore = lastSeq
            merge(h, animated: !first)
            let newAnswer = h.items.contains { $0.role == "assistant" && !$0.isPartial && $0.seq > seqBefore }
            var busyNow = h.busy ?? false
            if first {
                loadedOnce = true
                Log.write("история загружена: \(h.items.count) записей, last=\(h.last ?? -1), busy=\(h.busy ?? false), сервер \(client.configPath)")
                scrollToBottomToken += 1
            }
            if connected != true {
                Log.write("подключено к службе")
                connected = true
            }
            // помощники — из /api/state (там же, где их видит терминал)
            // пока думаем (или появился готовый ответ) — state спрашиваем на каждом опросе: он главнее и свежее history
            if busyNow || Date().timeIntervalSince(lastHelpersPoll) > 1.5 || newAnswer {
                lastHelpersPoll = Date()
                if let s = try? await client.state() {
                    // «занят» — только сам главный разговор (helpers в busy не входят)
                    if let sb = s.busy { busyNow = sb }
                    let hs = (s.helpers ?? []).filter(\.isWorking).sorted { ($0.n ?? .max) < ($1.n ?? .max) }
                    // спиннер — только про главного; помощников показывает строка «N работяг»
                    let l = s.live
                    setActivity(Activity.from(tool: l?.tool, label: l?.label, toolRunning: l?.toolRunning ?? false, text: l?.text), busyNow: busyNow)
                    if (l?.stopping ?? false) != stopping { stopping = l?.stopping ?? false }
                    if hs != helpers { withAnimation(.easeOut(duration: 0.2)) { helpers = hs } }
                    if hs.isEmpty && helpersExpanded { helpersExpanded = false }
                }
            }
            if gen > appliedGen {
                appliedGen = gen
                if busyNow != busy {
                    Log.write("точки: \(busyNow ? "вкл" : "выкл")")
                    if busyNow { activityTask?.cancel(); activityAt = Date() } else { stopping = false }
                    withAnimation(.easeOut(duration: 0.2)) { busy = busyNow }
                }
            }
            return true
        } catch {
            if busy { busy = false }
            if connected != false {
                Log.write("служба недоступна: \(error.localizedDescription)")
                connected = false
            }
            client.reloadConfig()
            return false
        }
    }

    /// Сменить спиннер не чаще раза в 0.7 с: короткие инструменты не дёргают картинку (последнее состояние применится позже)
    private func setActivity(_ a: Activity, busyNow: Bool) {
        activityTask?.cancel()
        guard a != activity else { return }
        let wait = 0.7 - Date().timeIntervalSince(activityAt)
        let apply = { [weak self] in
            guard let self else { return }
            Log.write("спиннер: \(a.rawValue)")
            withAnimation(.easeInOut(duration: 0.25)) { self.activity = a }
            self.activityAt = Date()
        }
        if wait <= 0 || !busyNow || !busy { apply(); return }
        activityTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, self?.busy == true else { return }
            apply()
        }
    }

    private func merge(_ h: HistoryResponse, animated: Bool) {
        var list = items
        var changed = false
        var appended = false
        var newAssistant = 0
        let incomingPartial = Set(h.items.filter(\.isPartial).map(\.seq))
        // недописанный ответ, который пропал из ответа службы (остановлен) — убрать
        let before = list.count
        list.removeAll { $0.isPartial && !incomingPartial.contains($0.seq) && $0.seq > (h.last ?? lastSeq) }
        if list.count != before { changed = true }
        // отчёты фоновых помощников в окне не показываем
        for it in h.items where it.role != "report" {
            if let i = list.firstIndex(where: { $0.seq == it.seq }) {
                if list[i] != it {
                    if list[i].isPartial && !it.isPartial { Log.write("ответ готов: seq=\(it.seq), символов \(it.text.count)") }
                    list[i] = it; changed = true
                }
            } else {
                let pos = list.firstIndex(where: { $0.seq > it.seq }) ?? list.count
                list.insert(it, at: pos)
                changed = true
                appended = true
                if it.role == "assistant" { newAssistant = max(newAssistant, it.seq) }
            }
        }
        if animated && newAssistant > 0 { newAnswerSeq = newAssistant }
        if let last = h.last { lastSeq = max(lastSeq, last) }
        else if let m = h.items.filter({ !$0.isPartial }).map(\.seq).max() { lastSeq = max(lastSeq, m) }
        if changed {
            if animated && appended {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { items = list }
            } else {
                items = list
            }
        }
        if animated && appended, let a = list.last, a.role != "user", !a.isPartial {
            Log.write("пришло: \(a.role) seq=\(a.seq), символов \(a.text.count)")
        }
    }

    /// ⌘↑: подгрузить более ранние сообщения (у службы нет before=, поэтому берём окно after=first-N и фильтруем)
    func loadOlder() {
        guard !loadingOlder, !noOlder, let first = items.first?.seq, first > 1 else { return }
        loadingOlder = true
        Task {
            defer { loadingOlder = false }
            let after = max(0, first - 61)
            do {
                let h = try await client.history(after: after, limit: 1000)
                let older = h.items.filter { $0.seq < first && !$0.isPartial && $0.role != "report" }
                if older.isEmpty { noOlder = true; return }
                anchorAfterPrepend = first
                items = older + items
                if after == 0 { noOlder = true }
                Log.write("подгружено раньше: \(older.count)")
            } catch {
                Log.write("подгрузка раньше не вышла: \(error.localizedDescription)")
            }
        }
    }

    // MARK: отправка

    var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty }

    func send() {
        guard canSend else { return }
        let userText = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if attachments.isEmpty, Self.permissionCommands.contains(userText.lowercased()) {
            draft = ""
            onOpenPermissions()
            return
        }
        let atts = attachments
        var images: [String] = []
        var parts: [String] = []
        for a in atts {
            switch a {
            case .context(_, let c):
                // Путь скриншота уже стоит в блоке <context> («Скриншот окна: /…/context-….png») — служба сама
                // превращает его в [картинка N]. В images его не дублируем, иначе та же картинка уйдёт второй раз.
                let block = ContextFormat.wrap(c)
                parts.append(block)
                if let s = c.screenshotPath, FileManager.default.fileExists(atPath: s), !block.contains(s) { images.append(s) }
            case .image(_, let p):
                images.append(p)
            }
        }
        if !userText.isEmpty { parts.append(userText) }
        let text = parts.joined(separator: "\n\n")
        // одна и та же картинка — один раз (и не повторять пути, которые уже есть в тексте)
        var seen = Set<String>()
        images = images.filter { !text.contains($0) && seen.insert($0).inserted }
        draft = ""
        attachments = []
        sendError = nil
        Task {
            do {
                let seq = try await client.send(text: text, images: images)
                Log.write("отправлено: seq=\(seq ?? -1), картинок \(images.count), символов \(text.count)")
                if let seq, !items.contains(where: { $0.seq == seq }) {
                    let local = FeedItem(seq: seq, role: "user", text: text, images: images)
                    var list = items
                    // недописанный ответ мог занять этот номер — он вернётся при следующем опросе
                    list.removeAll { $0.isPartial && $0.seq >= seq }
                    list.append(local)
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { items = list }
                }
                scrollToBottomToken += 1
                await pollOnce()
            } catch {
                Log.write("отправка не вышла: \(error.localizedDescription)")
                if draft.isEmpty { draft = userText }
                if attachments.isEmpty { attachments = atts }
                sendError = "не отправилось: \(error.localizedDescription)"
            }
        }
    }

    // MARK: вложения

    func removeLastAttachment() {
        guard !attachments.isEmpty else { return }
        _ = withAnimation(.easeOut(duration: 0.15)) { attachments.removeLast() }
    }

    func showHint(_ text: String) {
        hint = text
        hintTask?.cancel()
        hintTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled { self?.hint = nil }
        }
    }

    func attachContext(_ c: CapturedContext) {
        // одно вложение-контекст за раз: новое заменяет старое
        withAnimation(.easeOut(duration: 0.18)) {
            attachments.removeAll { if case .context = $0 { return true } else { return false } }
            attachments.insert(.context(id: UUID(), c), at: 0)
        }
        Log.write("контекст: \(c.appName) · \(c.pageTitle ?? c.windowTitle ?? "-")")
    }

    /// Вставка из буфера: файлы-картинки или сырое изображение → вложение. Возвращает true, если что-то прикрепили.
    func attachFromPasteboard(_ pb: NSPasteboard) -> Bool {
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let imageURLs = urls.filter(Self.isImageFile)
        if !imageURLs.isEmpty {
            for u in imageURLs { if let p = Self.storeFile(u) { addImage(p) } }
            return true
        }
        if !urls.isEmpty { return false }
        // текст важнее картинки (например, копирование из Word кладёт и то и другое)
        if pb.string(forType: .string) != nil { return false }
        for t in [NSPasteboard.PasteboardType.png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic")] {
            if let data = pb.data(forType: t), let p = Self.storeImageData(data) {
                addImage(p)
                return true
            }
        }
        if let img = NSImage(pasteboard: pb), let tiff = img.tiffRepresentation, let p = Self.storeImageData(tiff) {
            addImage(p)
            return true
        }
        return false
    }

    func attachFiles(_ urls: [URL]) -> Bool {
        let imgs = urls.filter(Self.isImageFile)
        for u in imgs { if let p = Self.storeFile(u) { addImage(p) } }
        return !imgs.isEmpty
    }

    /// Файл получен по file promise (уже лежит в mac-images) — прикрепить как есть
    func attachReceived(_ u: URL) -> Bool {
        guard Self.isImageFile(u) else { return false }
        addImage(u.path)
        return true
    }

    private func addImage(_ path: String) {
        withAnimation(.easeOut(duration: 0.18)) { attachments.append(.image(id: UUID(), path: path)) }
        Log.write("картинка прикреплена: \(path)")
    }

    static func isImageFile(_ u: URL) -> Bool {
        guard u.isFileURL else { return false }
        if let t = UTType(filenameExtension: u.pathExtension.lowercased()) { return t.conforms(to: .image) }
        return false
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        return f.string(from: Date())
    }

    private static func ensureDir() {
        try? FileManager.default.createDirectory(atPath: imagesDir, withIntermediateDirectories: true)
    }

    static func storeImageData(_ data: Data) -> String? {
        ensureDir()
        let png: Data?
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { png = data }
        else { png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) }
        guard let png else { return nil }
        let path = "\(imagesDir)/\(stamp()).png"
        return FileManager.default.createFile(atPath: path, contents: png) ? path : nil
    }

    /// Файл копируется в mac-images (временные файлы CleanShot и т. п. могут исчезнуть). Не png/jpeg/gif/webp — в png.
    static func storeFile(_ u: URL) -> String? {
        ensureDir()
        let ext = u.pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "webp"].contains(ext) {
            let path = "\(imagesDir)/\(stamp()).\(ext)"
            do { try FileManager.default.copyItem(atPath: u.path, toPath: path); return path } catch { return u.path }
        }
        guard let data = try? Data(contentsOf: u) else { return nil }
        return storeImageData(data)
    }
}

// Как контекст уходит в текст и как его узнать в ленте
enum ContextFormat {
    static func label(_ c: CapturedContext) -> String {
        let t = (c.pageTitle?.nonEmpty ?? c.windowTitle?.nonEmpty ?? c.url.flatMap { URL(string: $0)?.host } ?? "")
        return t.isEmpty ? c.appName : "\(c.appName) · \(t)"
    }

    static func wrap(_ c: CapturedContext) -> String {
        let label = label(c).replacingOccurrences(of: "\"", with: "'")
        return "<context source=\"\(label)\">\n\(c.asMarkdown().trimmingCharacters(in: .whitespacesAndNewlines))\n</context>"
    }

    /// Разобрать текст пользователя: плашки контекста + собственно текст; пометки [картинка N] убираются.
    static func split(_ text: String) -> (contexts: [String], body: String) {
        var rest = text
        var labels: [String] = []
        let re = /^\s*<context source="([^"]*)">[\s\S]*?<\/context>\s*/
        while let m = rest.firstMatch(of: re) {
            labels.append(String(m.1))
            rest = String(rest[m.range.upperBound...])
        }
        rest = rest.replacing(/\s*\[картинка \d+\]/, with: "")
        return (labels, rest.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

extension String {
    var nonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
