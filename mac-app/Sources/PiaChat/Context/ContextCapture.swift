import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Контекст активного окна на момент жеста.
struct CapturedContext: Sendable, Codable, Equatable {
    var appName: String
    var bundleId: String
    var windowTitle: String?
    var url: String?
    var pageTitle: String?
    var selectedText: String?
    var screenshotPath: String?
    /// Текст окна (страница браузера или текст элементов окна через Accessibility), уже очищенный, ≤ ~6000 симв.
    var visibleText: String?
    /// Откуда текст окна: "JS" (document.body.innerText) или "AX" (Accessibility). В asMarkdown не идёт.
    var visibleTextSource: String?

    /// Предел длины выделенного текста в asMarkdown().
    static let selectionLimit = 4000

    /// Компактный блок для ИИ, например:
    /// Контекст: Yab — «Заголовок» — https://…
    /// Выделено: «…»
    /// Скриншот окна: /Users/…/context-….png или .jpg (≤ 800 px по длинной стороне, без пустых полей)
    /// Текст окна:
    /// «…»
    func asMarkdown() -> String {
        var head = "Контекст: \(appName.isEmpty ? bundleId : appName)"
        let title = Self.clean(pageTitle) ?? Self.clean(windowTitle)
        if let title { head += " — «\(title)»" }
        if let win = Self.clean(windowTitle), let page = Self.clean(pageTitle),
           win != page, !win.contains(page) {
            head += " (окно «\(win)»)"
        }
        if let url = Self.clean(url) { head += " — \(url)" }
        var lines = [head]
        if let sel = selectedText?.trimmingCharacters(in: .whitespacesAndNewlines), !sel.isEmpty {
            var text = sel
            if text.count > Self.selectionLimit {
                text = String(text.prefix(Self.selectionLimit)) + "… (обрезано, всего \(sel.count) симв.)"
            }
            lines.append(text.contains("\n") ? "Выделено:\n«\(text)»" : "Выделено: «\(text)»")
        }
        if let shot = Self.clean(screenshotPath) { lines.append("Скриншот окна: \(shot)") }
        if var text = Self.clean(visibleText) {
            // не дать тексту страницы закрыть обёртку <context>…</context> раньше времени
            text = text.replacingOccurrences(of: "</context", with: "</ context", options: .caseInsensitive)
                .replacingOccurrences(of: "<context", with: "< context", options: .caseInsensitive)
            lines.append("Текст окна:\n«\(text)»")
        }
        return lines.joined(separator: "\n")
    }

    private static func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}

/// Захват контекста активного приложения: имя, окно, URL/заголовок вкладки браузера,
/// выделенный текст и скриншот окна. Каждый шаг ≤ ~1.5 с, шаги идут параллельно,
/// весь захват ≤ 3 с. Ошибки и отсутствие прав не роняют приложение — поле просто nil.
enum ContextCapture {
    static let stepTimeout: TimeInterval = 1.5
    static let totalTimeout: TimeInterval = 3.0
    /// Папка для скриншотов.
    static var imagesDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi-agent/pia/mac-images", isDirectory: true)
    }
    /// Делать ли скриншот окна (нужно право «Запись экрана»).
    nonisolated(unsafe) static var screenshotsEnabled = true

    /// Контекст frontmost-приложения. nil — если активно само pia или приложения нет.
    static func captureFrontmost() async -> CapturedContext? {
        guard let app = await frontmostAppInfo() else { return nil }
        if app.pid == ProcessInfo.processInfo.processIdentifier { return nil }
        return await capture(app)
    }

    /// Контекст конкретного запущенного приложения (по bundle id) — для проверок.
    static func capture(bundleId: String) async -> CapturedContext? {
        let info: AppInfo? = await MainActor.run {
            guard let a = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else { return nil }
            return AppInfo(pid: a.processIdentifier, name: a.localizedName ?? bundleId, bundleId: bundleId)
        }
        guard let info else { return nil }
        return await capture(info)
    }

    // MARK: - Внутреннее

    struct AppInfo: Sendable {
        var pid: pid_t
        var name: String
        var bundleId: String
    }

    private static func frontmostAppInfo() async -> AppInfo? {
        await MainActor.run {
            guard let a = NSWorkspace.shared.frontmostApplication else { return nil }
            return AppInfo(pid: a.processIdentifier,
                           name: a.localizedName ?? a.bundleIdentifier ?? "?",
                           bundleId: a.bundleIdentifier ?? "")
        }
    }

    private static func capture(_ app: AppInfo) async -> CapturedContext {
        let base = CapturedContext(appName: app.name, bundleId: app.bundleId)
        let isBrowser = ContextBrowsers.kind(of: app.bundleId) != nil
        let chromium = ContextBrowsers.isChromium(app.bundleId)
        let wantShot = screenshotsEnabled
        let step = stepTimeout

        let result = await ctxWithDeadline(totalTimeout) { () -> CapturedContext? in
            // Шаги идут параллельно, у каждого свой таймаут.
            async let axInfo: ContextAX.Info? = ctxWithDeadline(step) {
                await ctxRunBlocking { ContextAX.read(pid: app.pid, chromium: chromium, browser: isBrowser) }
            }
            async let tab: ContextBrowsers.Tab? = isBrowser
                ? ctxWithDeadline(step) { await ContextBrowsers.activeTab(bundleId: app.bundleId, timeout: step) }
                : nil
            async let text: ContextText.Result? = ctxWithDeadline(2.2) {
                await ContextText.collect(pid: app.pid, bundleId: app.bundleId, selected: nil)
            }
            async let shot: String? = wantShot
                ? ctxWithDeadline(step) { await ContextScreenshot.capture(pid: app.pid) }
                : nil

            var c = base
            let ax = await axInfo
            c.windowTitle = ax?.windowTitle
            c.selectedText = ax?.selectedText
            if let t = await tab {
                c.url = t.url
                c.pageTitle = t.title
            }
            if c.url == nil { c.url = ax?.url }
            if isBrowser, c.pageTitle == nil { c.pageTitle = ax?.windowTitle }
            if c.windowTitle == nil {
                c.windowTitle = await ctxWithDeadline(0.5) {
                    await ctxRunBlocking { ContextScreenshot.frontWindowTitle(pid: app.pid) } ?? nil
                }
            }
            c.screenshotPath = await shot
            if let t = await text {
                c.visibleText = t.text
                c.visibleTextSource = t.source.rawValue
                // есть выделение (оно приходит параллельно) — переобрезать: абзац вокруг выделения приоритетно
                if let sel = c.selectedText, !t.fromEnd, t.raw.count > ContextText.limit,
                   let again = ContextText.tidy(t.raw, selected: sel) { c.visibleText = again }
            }
            return c
        }
        return result ?? base
    }
}

// MARK: - Таймауты

/// Возобновить continuation только один раз (кто первый — результат или таймаут).
final class CtxOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T?, Never>?
    init(_ c: CheckedContinuation<T?, Never>) { cont = c }
    func resume(_ v: T?) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(returning: v)
    }
}

/// Выполнить асинхронную работу не дольше `seconds`; по таймауту — nil (работа отменяется
/// и дорабатывает в фоне, её результат отбрасывается).
func ctxWithDeadline<T: Sendable>(_ seconds: TimeInterval, _ op: @escaping @Sendable () async -> T?) async -> T? {
    await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
        let once = CtxOnce<T>(cont)
        let task = Task.detached {
            let v = await op()
            once.resume(v)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            task.cancel()
            once.resume(nil)
        }
    }
}

/// Блокирующая работа (AX, CGWindowList) — на отдельной очереди, не на пуле Swift Concurrency.
func ctxRunBlocking<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T? {
    await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
        DispatchQueue.global(qos: .userInitiated).async {
            cont.resume(returning: work())
        }
    }
}
