import AppKit
import ApplicationServices
import Foundation

/// Текст окна (как «Work with apps» у ChatGPT/Raycast):
/// - браузеры: сначала JS `document.body.innerText` через AppleScript (Chrome-подобные — нужна настройка
///   «Разрешить JavaScript из Apple Events», Safari — «Разрешить JavaScript из Apple Events» в меню «Разработка»;
///   сами мы её не включаем), запасной путь — Accessibility (AXWebArea фокусного окна);
/// - остальные приложения: Accessibility (AXStaticText, AXTextArea, AXTextField…) фокусного окна;
/// - терминалы: последние ~200 строк.
/// Ошибки, отсутствие прав и таймауты дают nil — не падаем.
enum ContextText {
    enum Source: String, Sendable { case javascript = "JS", accessibility = "AX" }

    struct Result: Sendable {
        var text: String
        var source: Source
        /// Исходный текст до очистки/обрезки (для переобрезки вокруг выделения).
        var raw: String
        /// Терминал: текст обрезается с конца.
        var fromEnd = false
    }

    /// Предел текста окна в контексте (символов).
    static let limit = 6000
    static let axTimeLimit: TimeInterval = 1.0
    static let axMaxDepth = 25
    static let axMaxNodes = 6000
    static let terminalLines = 200

    /// Терминалы: берём хвост (последние строки), а не начало.
    static let terminalIds: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "org.alacritty", "io.alacritty", "co.zeit.hyper", "com.github.wez.wezterm",
    ]
    /// Chromium-подобные без команды `execute javascript` в AppleScript (Yab — только title/URL).
    static let noJavaScriptIds: Set<String> = [ContextBrowsers.yabBundleId]

    /// Последний путь и причина (для проверки: context-check печатает).
    nonisolated(unsafe) static var lastNote = ""

    /// Собрать текст окна приложения (уже очищенный и обрезанный до `limit`).
    static func collect(pid: pid_t, bundleId: String, selected: String?, target: WindowTarget? = nil) async -> Result? {
        let kind = ContextBrowsers.kind(of: bundleId)
        var note: [String] = []
        if kind == .safari || (kind == .chromium && !noJavaScriptIds.contains(bundleId)) {
            if let raw = await javascriptText(bundleId: bundleId, timeout: 0.9),
               let t = tidy(raw, selected: selected) {
                lastNote = "JS"
                return Result(text: t, source: .javascript, raw: raw)
            }
            note.append("JS не дал текста (выключено «JavaScript из Apple Events» или нет права)")
        } else if kind == .chromium {
            note.append("JS: у браузера нет execute javascript")
        }
        let terminal = terminalIds.contains(bundleId)
        let chromium = ContextBrowsers.isChromium(bundleId)
        let raw = await ctxRunBlocking {
            axText(pid: pid, web: kind != nil, chromium: chromium, terminal: terminal, target: target)
        } ?? nil
        guard let raw else {
            lastNote = (note + ["AX: текста нет"]).joined(separator: "; ")
            return nil
        }
        let text = terminal ? tail(raw, lines: terminalLines) : raw
        guard let t = tidy(text, selected: selected, keepRepeats: terminal, fromEnd: terminal) else {
            lastNote = (note + ["AX: пусто"]).joined(separator: "; ")
            return nil
        }
        lastNote = (note + ["AX"]).joined(separator: "; ")
        return Result(text: t, source: .accessibility, raw: text, fromEnd: terminal)
    }

    // MARK: - JavaScript через AppleScript

    static func javascriptScript(for bundleId: String) -> String? {
        let js = "(document.body ? document.body.innerText : '').slice(0, 200000)"
        switch ContextBrowsers.kind(of: bundleId) {
        case .safari?:
            return """
            tell application id "\(bundleId)"
                if (count of windows) is 0 then return ""
                return do JavaScript "\(js)" in current tab of front window
            end tell
            """
        case .chromium?:
            return """
            tell application id "\(bundleId)"
                if (count of windows) is 0 then return ""
                return execute active tab of front window javascript "\(js)"
            end tell
            """
        default: return nil
        }
    }

    static func javascriptText(bundleId: String, timeout: TimeInterval) async -> String? {
        guard let src = javascriptScript(for: bundleId) else { return nil }
        guard let out = await ContextBrowsers.runOsascript(src, timeout: timeout) else { return nil }
        let t = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t == "missing value" ? nil : t
    }

    // MARK: - Accessibility

    nonisolated(unsafe) private static let attrs = ["AXRole", "AXSubrole", "AXValue", "AXTitle", "AXDescription", "AXChildren",
                                "AXPosition", "AXSize"] as CFArray

    private struct Node {
        var role: String?
        var subrole: String?
        var value: String?
        var title: String?
        var desc: String?
        var children: [AXUIElement]
        var frame: CGRect?
    }

    private static func node(_ el: AXUIElement) -> Node? {
        var out: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(el, attrs, AXCopyMultipleAttributeOptions(rawValue: 0), &out) == .success,
              let arr = out as? [AnyObject], arr.count == 8 else { return nil }
        func str(_ i: Int) -> String? {
            if let s = arr[i] as? String { return s }
            if let a = arr[i] as? NSAttributedString { return a.string }
            return nil
        }
        var n = Node(role: str(0), subrole: str(1), value: str(2), title: str(3), desc: str(4),
                     children: (arr[5] as? [AXUIElement]) ?? [], frame: nil)
        let pv = arr[6], sv = arr[7]
        if CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() {
            var p = CGPoint.zero, s = CGSize.zero
            if AXValueGetValue(pv as! AXValue, .cgPoint, &p), AXValueGetValue(sv as! AXValue, .cgSize, &s) {
                n.frame = CGRect(origin: p, size: s)
            }
        }
        return n
    }

    /// Текст фокусного окна через AX. web — искать AXWebArea и брать текст из неё.
    static func axText(pid: pid_t, web: Bool, chromium: Bool, terminal: Bool, target: WindowTarget? = nil) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let deadline = Date().addingTimeInterval(axTimeLimit)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        if chromium {
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        guard let window = ContextAX.pickWindow(app, target) ?? ContextAX.element(app, kAXFocusedWindowAttribute) ?? ContextAX.element(app, kAXMainWindowAttribute)
        else { return nil }
        AXUIElementSetMessagingTimeout(window, 0.4)
        var root = window
        if web {
            // У Chromium дерево страницы строится по запросу — если пусто, даём ему мгновение и пробуем снова.
            var area = webArea(in: window, deadline: deadline)
            if area == nil, chromium, Date() < deadline.addingTimeInterval(-0.4) {
                Thread.sleep(forTimeInterval: 0.25)
                area = webArea(in: window, deadline: deadline)
            }
            if let area { root = area }
        }
        let s = walk(root, deadline: deadline, web: web, terminal: terminal)
        return s.isEmpty ? nil : s
    }

    /// Самая крупная AXWebArea окна (страница, а не панели браузера).
    static func webArea(in root: AXUIElement, deadline: Date) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var head = 0
        var best: (AXUIElement, CGFloat)?
        while head < queue.count, head < 3000, Date() < deadline {
            let (el, depth) = queue[head]; head += 1
            guard let n = node(el) else { continue }
            if n.role == "AXWebArea" {
                let area = n.frame.map { $0.width * $0.height } ?? 0
                if !n.children.isEmpty, best == nil || area > best!.1 { best = (el, area) }
                continue   // вложенные веб-области (iframe) не ищем
            }
            if depth < 30 { queue.append(contentsOf: n.children.map { ($0, depth + 1) }) }
        }
        return best?.0
    }

    /// Обход в глубину (порядок документа). Фрагменты на одной строке (по координатам) склеиваются.
    private static func walk(_ root: AXUIElement, deadline: Date, web: Bool, terminal: Bool) -> String {
        var out = ""
        var lastFrame: CGRect?
        var nodes = 0
        let textRoles: Set<String> = ["AXStaticText", "AXTextArea", "AXTextField", "AXComboBox", "AXHeading"]
        let perValue = terminal ? 400_000 : 20_000

        func emit(_ raw: String, _ frame: CGRect?) {
            var s = raw.replacingOccurrences(of: "\u{00A0}", with: " ")
            if s.count > perValue { s = terminal ? String(s.suffix(perValue)) : String(s.prefix(perValue)) }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            var sameLine = false
            if let f = frame, let p = lastFrame, f.height > 0, p.height > 0 {
                sameLine = f.minY < p.maxY - 2 && f.maxY > p.minY + 2 && !s.contains("\n")
            }
            if out.isEmpty {
                out = trimmed
            } else if sameLine {
                if web {
                    let first = trimmed.first!, last = out.last!
                    let noSpace = last.isWhitespace || ",.;:!?)]»”’%".contains(first) || "([«“‘".contains(last)
                    out += (noSpace ? "" : " ") + trimmed
                } else {
                    out += " · " + trimmed
                }
            } else {
                out += "\n" + (terminal ? s.trimmingCharacters(in: .newlines) : trimmed)
            }
            if let frame { lastFrame = frame }
        }

        func visit(_ el: AXUIElement, _ depth: Int) {
            guard nodes < axMaxNodes, Date() < deadline else { return }
            nodes += 1
            guard let n = node(el) else { return }
            let role = n.role ?? ""
            if n.subrole == "AXSecureTextField" { return }
            if textRoles.contains(role) {
                if role == "AXHeading" {
                    // у веб-заголовка текст обычно в детях (AXStaticText); иначе — title/description
                    if n.children.isEmpty, let t = n.title ?? n.desc { emit(t, n.frame); return }
                } else {
                    if let v = n.value, !v.isEmpty { emit(v, n.frame) }
                    else if role == "AXStaticText", let t = n.title ?? n.desc { emit(t, n.frame) }
                    if role != "AXHeading" { return }   // в текстовые поля не спускаемся
                }
            }
            if depth < axMaxDepth {
                for c in n.children {
                    guard nodes < axMaxNodes, Date() < deadline else { return }
                    visit(c, depth + 1)
                }
            }
        }
        visit(root, 0)
        return out
    }

    // MARK: - Очистка и обрезка

    static func tail(_ s: String, lines: Int) -> String {
        var arr = s.components(separatedBy: "\n")
        while let l = arr.last, l.trimmingCharacters(in: .whitespaces).isEmpty { arr.removeLast() }
        return arr.suffix(lines).joined(separator: "\n")
    }

    /// Убрать лишние пустые строки и повторы, ограничить `limit` символов.
    /// Длинный текст: начало + (если выделение найдено дальше) абзац вокруг выделения; терминал — хвост.
    static func tidy(_ raw: String, selected: String? = nil, limit: Int = limit,
                     keepRepeats: Bool = false, fromEnd: Bool = false) -> String? {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        var lines: [String] = []
        var seen = Set<String>()
        var blank = false
        for line0 in normalized.components(separatedBy: "\n") {
            var line = line0
            while let c = line.last, c == " " || c == "\t" { line.removeLast() }
            if !keepRepeats {
                line = line.trimmingCharacters(in: .whitespaces)
                line = line.replacing(/[ \t]{2,}/, with: " ")
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                blank = !lines.isEmpty
                continue
            }
            if keepRepeats {
                if lines.last == line { continue }          // подряд одинаковые
            } else {
                let key = line.lowercased()
                if seen.contains(key) { continue }           // повтор где угодно (кнопки, меню, «Ответить»…)
                seen.insert(key)
            }
            if blank { lines.append(""); blank = false }
            lines.append(line)
        }
        let text = lines.joined(separator: "\n")
        guard !text.isEmpty else { return nil }
        if text.count <= limit { return text }
        if fromEnd { return "…\n" + cutStartToLine(String(text.suffix(limit - 2))) }

        // Выделенный текст далеко от начала — показать абзац вокруг него.
        if let sel = selected?.trimmingCharacters(in: .whitespacesAndNewlines), !sel.isEmpty {
            let probe = String(sel.prefix(200)).components(separatedBy: "\n").first ?? ""
            if probe.count >= 3, let r = text.range(of: probe, options: [.caseInsensitive]) {
                let offset = text.distance(from: text.startIndex, to: r.lowerBound)
                if offset + probe.count > limit - 200 {
                    let window = paragraph(around: r, in: text, budget: limit * 6 / 10)
                    let headBudget = max(0, limit - window.count - 4)
                    let head = cutEndToLine(String(text.prefix(headBudget)))
                    return (head.isEmpty ? "" : head + "\n…\n") + window + "\n…"
                }
            }
        }
        return cutEndToLine(String(text.prefix(limit - 2))) + "\n…"
    }

    /// Абзац(ы) вокруг диапазона в пределах budget символов: расширяем до границ строк/абзацев.
    static func paragraph(around r: Range<String.Index>, in text: String, budget: Int) -> String {
        var lo = r.lowerBound, hi = r.upperBound
        // начало абзаца (пустая строка) или строки
        if let p = text.range(of: "\n\n", options: .backwards, range: text.startIndex..<lo) { lo = p.upperBound }
        else if let p = text.range(of: "\n", options: .backwards, range: text.startIndex..<lo) { lo = p.upperBound }
        if let p = text.range(of: "\n\n", range: hi..<text.endIndex) { hi = p.lowerBound }
        else if let p = text.range(of: "\n", range: hi..<text.endIndex) { hi = p.lowerBound }
        // слишком длинный — ограничиваем вокруг выделения
        if text.distance(from: lo, to: hi) > budget {
            let back = text.index(r.lowerBound, offsetBy: -(budget / 3), limitedBy: text.startIndex) ?? text.startIndex
            if back > lo { lo = back }
            hi = text.index(lo, offsetBy: budget, limitedBy: text.endIndex) ?? text.endIndex
        } else {
            // есть место — добавляем соседние строки вокруг
            while text.distance(from: lo, to: hi) < budget {
                var grew = false
                if lo > text.startIndex {
                    let prev = text.index(before: lo)
                    let start = text.range(of: "\n", options: .backwards, range: text.startIndex..<prev)?.upperBound ?? text.startIndex
                    if text.distance(from: start, to: hi) <= budget { lo = start; grew = true }
                }
                if hi < text.endIndex {
                    let next = text.index(after: hi)
                    let end = text.range(of: "\n", range: next..<text.endIndex)?.lowerBound ?? text.endIndex
                    if text.distance(from: lo, to: end) <= budget { hi = end; grew = true }
                }
                if !grew { break }
            }
        }
        return String(text[lo..<hi]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cutEndToLine(_ s: String) -> String {
        guard let r = s.range(of: "\n", options: .backwards),
              s.distance(from: r.lowerBound, to: s.endIndex) < 400 else { return s }
        return String(s[..<r.lowerBound])
    }

    private static func cutStartToLine(_ s: String) -> String {
        guard let r = s.range(of: "\n"), s.distance(from: s.startIndex, to: r.lowerBound) < 400 else { return s }
        return String(s[r.upperBound...])
    }
}
