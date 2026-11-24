import Foundation

/// URL и заголовок активной вкладки браузера через AppleScript.
/// Скрипт выполняется через /usr/bin/osascript (отдельный процесс — его можно
/// прервать по таймауту, а главный поток не блокируется). Право «Автоматизация»
/// система спрашивает от имени pia при первом обращении к каждому браузеру.
enum ContextBrowsers {
    enum Kind: Sendable { case safari, chromium, other }

    struct Tab: Sendable {
        var url: String?
        var title: String?
    }

    /// Yab: bundle id dev.serafim.fast, AppleScript как у Chrome
    /// (`active tab of front window`, свойства URL и title).
    static let yabBundleId = "dev.serafim.fast"

    static let safariIds: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
    ]
    /// Chromium-подобные со словарём Chrome (window → active tab → URL/title).
    static let chromiumIds: Set<String> = [
        yabBundleId,
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "company.thebrowser.Browser",          // Arc
        "company.thebrowser.dia",              // Dia
        "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev", "com.microsoft.edgemac.Canary",
        "org.chromium.Chromium",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera", "com.operasoftware.OperaGX",
        "ru.yandex.desktop.yandex-browser",
        "net.imput.helium",
        "ai.perplexity.comet",
    ]
    /// Браузеры без нужного AppleScript — URL пробуем достать через AX.
    static let otherIds: Set<String> = [
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
        "app.zen-browser.zen", "net.waterfox.waterfox", "io.github.nicehash.librewolf", "org.torproject.torbrowser",
        "com.kagi.kagimacOS",
    ]

    static func kind(of bundleId: String) -> Kind? {
        if safariIds.contains(bundleId) { return .safari }
        if chromiumIds.contains(bundleId) { return .chromium }
        if otherIds.contains(bundleId) { return .other }
        return nil
    }

    /// Chromium/CEF/Electron — для них включаем AXManualAccessibility.
    static func isChromium(_ bundleId: String) -> Bool {
        chromiumIds.contains(bundleId)
    }

    static func script(for bundleId: String) -> String? {
        let tabExpr: String
        let titleProp: String
        switch kind(of: bundleId) {
        case .safari?: tabExpr = "current tab of front window"; titleProp = "name"
        case .chromium?: tabExpr = "active tab of front window"; titleProp = "title"
        default: return nil
        }
        return """
        tell application id "\(bundleId)"
            if (count of windows) is 0 then return ""
            set t to \(tabExpr)
            set u to ""
            set n to ""
            try
                set u to URL of t
            end try
            try
                set n to \(titleProp) of t
            end try
            return u & linefeed & n
        end tell
        """
    }

    /// Активная вкладка браузера; nil — не браузер, нет окон, нет права или таймаут.
    static func activeTab(bundleId: String, timeout: TimeInterval) async -> Tab? {
        guard let source = script(for: bundleId) else { return nil }
        guard let out = await runOsascript(source, timeout: timeout) else { return nil }
        let parts = out.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let url = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let tab = Tab(url: (url?.isEmpty ?? true) ? nil : url, title: (title?.isEmpty ?? true) ? nil : title)
        return (tab.url == nil && tab.title == nil) ? nil : tab
    }

    /// Запустить AppleScript через osascript с жёстким таймаутом (процесс убивается).
    static func runOsascript(_ source: String, timeout: TimeInterval) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", source]
            let outPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            let once = CtxOnce<String>(cont)
            do {
                try p.run()
            } catch {
                once.resume(nil)
                return
            }
            // Вывод читаем сразу (а не после выхода): иначе большой вывод (> 64 КБ) забьёт канал и osascript повиснет.
            DispatchQueue.global(qos: .userInitiated).async {
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                guard p.terminationReason == .exit, p.terminationStatus == 0 else { once.resume(nil); return }
                once.resume(String(data: data, encoding: .utf8))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if p.isRunning { p.terminate() }
                once.resume(nil)
            }
        }
    }
}
