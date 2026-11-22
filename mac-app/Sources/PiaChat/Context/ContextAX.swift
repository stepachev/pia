import AppKit
import ApplicationServices
import Foundation

/// Чтение заголовка окна, выделенного текста и URL через Accessibility API.
/// Синхронно (вызывать через ctxRunBlocking); у каждого обращения к приложению
/// таймаут сообщений 0.5 с, так что зависшее приложение не держит захват.
enum ContextAX {
    struct Info: Sendable {
        var windowTitle: String?
        var selectedText: String?
        var url: String?
    }

    static func read(pid: pid_t, chromium: Bool, browser: Bool, target: WindowTarget? = nil) -> Info {
        var info = Info()
        guard AXIsProcessTrusted() else { return info }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        if chromium {
            // Chromium/Electron/CEF строят дерево доступности для веб-страницы только по просьбе.
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }

        let window = pickWindow(app, target) ?? element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute)
        if let window {
            info.windowTitle = string(window, kAXTitleAttribute)
            // AXDocument: у Safari — URL страницы, у документных приложений — путь к файлу.
            if let doc = string(window, kAXDocumentAttribute) { info.url = doc }
        }

        if let focused = element(app, kAXFocusedUIElementAttribute) {
            if let sel = string(focused, kAXSelectedTextAttribute), !sel.isEmpty {
                info.selectedText = sel
            }
        }
        if info.selectedText == nil {
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0.5)
            if let focused = element(system, kAXFocusedUIElementAttribute),
               let sel = string(focused, kAXSelectedTextAttribute), !sel.isEmpty {
                var fpid: pid_t = 0
                if AXUIElementGetPid(focused, &fpid) == .success, fpid == pid { info.selectedText = sel }
            }
        }

        if browser, info.url == nil || info.url?.hasPrefix("file:") == true, let window {
            if let u = webAreaURL(in: window) { info.url = u }
        }
        return info
    }

    /// Поиск AXWebArea с AXURL в окне (ограниченный обход дерева).
    /// Окно приложения, соответствующее найденному в CGWindowList (по рамке, затем по заголовку); nil — не нашли.
    static func pickWindow(_ app: AXUIElement, _ target: WindowTarget?) -> AXUIElement? {
        guard let target, let wins = elements(app, kAXWindowsAttribute) else { return nil }
        func frame(_ w: AXUIElement) -> CGRect? {
            var pos = CGPoint.zero, size = CGSize.zero
            guard let p = value(w, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
                  AXValueGetValue(p as! AXValue, .cgPoint, &pos),
                  let s = value(w, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID(),
                  AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
            return CGRect(origin: pos, size: size)
        }
        func close(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.minX - b.minX) < 4 && abs(a.minY - b.minY) < 4 && abs(a.width - b.width) < 4 && abs(a.height - b.height) < 4
        }
        if let w = wins.first(where: { frame($0).map { close($0, target.bounds) } ?? false }) { return w }
        if let t = target.title, !t.isEmpty, let w = wins.first(where: { string($0, kAXTitleAttribute) == t }) { return w }
        return nil
    }

    static func webAreaURL(in root: AXUIElement, maxNodes: Int = 600, maxDepth: Int = 30) -> String? {
        let deadline = Date().addingTimeInterval(1.0)
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var seen = 0
        while !queue.isEmpty, seen < maxNodes, Date() < deadline {
            let (el, depth) = queue.removeFirst()
            seen += 1
            if string(el, kAXRoleAttribute) == "AXWebArea" {
                if let u = urlValue(el, kAXURLAttribute) { return u }
            }
            if depth < maxDepth, let kids = elements(el, kAXChildrenAttribute) {
                queue.append(contentsOf: kids.map { ($0, depth + 1) })
            }
        }
        return nil
    }

    // MARK: Низкоуровневые чтения

    static func value(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v
    }

    static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = value(el, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func elements(_ el: AXUIElement, _ attr: String) -> [AXUIElement]? {
        value(el, attr) as? [AXUIElement]
    }

    static func string(_ el: AXUIElement, _ attr: String) -> String? {
        guard let v = value(el, attr) else { return nil }
        if let s = v as? String { return s.isEmpty ? nil : s }
        if let u = v as? URL { return u.absoluteString }
        return nil
    }

    static func urlValue(_ el: AXUIElement, _ attr: String) -> String? {
        guard let v = value(el, attr) else { return nil }
        if let u = v as? URL { return u.absoluteString }
        if let s = v as? String, !s.isEmpty { return s }
        return nil
    }
}
