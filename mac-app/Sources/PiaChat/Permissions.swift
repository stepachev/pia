import AppKit
import ApplicationServices
import CoreGraphics
import Observation

/// Разрешения macOS для pia — что реально нужно и зачем (сверено с кодом):
/// - Универсальный доступ (Accessibility): глобальные мониторы клавиш — двойной правый Option (показать окно)
///   и двойной правый Shift (захват контекста); чтение заголовка окна, выделения и текста окна (ContextAX, ContextText).
///   С ним же работают и глобальные мониторы клавиатуры, поэтому «Мониторинг ввода» отдельно НЕ нужен и не запрашивается.
/// - Запись экрана (необязательно): снимок активного окна (ContextScreenshot, ScreenCaptureKit) и запасной заголовок окна.
/// - Автоматизация браузеров (необязательно): адрес, заголовок и текст вкладки через AppleScript (ContextBrowsers,
///   ContextText); macOS спрашивает отдельно для каждого браузера.
/// Ничего не запрашивается при запуске: только по кнопке в мастере (PermissionsView) — по одному.
@MainActor
@Observable
final class Permissions {
    static let shared = Permissions()

    enum Kind: String, CaseIterable, Identifiable {
        case accessibility, screen, browsers
        var id: String { rawValue }
        var pane: String {
            switch self {
            case .accessibility: return "Privacy_Accessibility"
            case .screen: return "Privacy_ScreenCapture"
            case .browsers: return "Privacy_Automation"
            }
        }
    }

    /// Браузер, запущенный сейчас, и его ответ на «Автоматизацию».
    struct Browser: Equatable {
        enum State { case allowed, denied, notAsked }
        var name: String
        var bundleId: String
        var state: State
    }

    var accessibility = AXIsProcessTrusted()
    var screen = CGPreflightScreenCaptureAccess()
    var browsers: [Browser] = []
    var askingBrowsers = false
    /// Что уже запрашивали в этом запуске (для подсказки «перезапустите pia»).
    var asked: Set<Kind> = []

    /// Показывать ли мастер в окне.
    var wizardVisible = false
    /// Вызывается, когда разрешение только что появилось (окно выводится вперёд, чтобы была видна галочка).
    @ObservationIgnored var onGranted: (Kind) -> Void = { _ in }
    @ObservationIgnored private var timer: Timer?

    static let dismissedKey = "pia.permissions.dismissed"
    static let reopenKey = "pia.permissions.reopen"
    private static let promptedKey = "pia.permissions.prompted."   // + kind: системный запрос уже показывали

    /// Главное (горячие клавиши и текст окна) есть?
    var essentialsGranted: Bool { accessibility }
    var allGranted: Bool { accessibility && screen && !browsers.contains { $0.state != .allowed } }

    /// Мастер сам открывается только при первом запуске и только если нет главного разрешения.
    var shouldAutoShow: Bool { !accessibility && !UserDefaults.standard.bool(forKey: Self.dismissedKey) }

    func summary() -> String {
        let b = browsers.isEmpty ? "нет открытых" : browsers.map { "\($0.name)=\($0.state)" }.joined(separator: ", ")
        return "Универсальный доступ: \(accessibility ? "есть" : "нет"), Запись экрана: \(screen ? "есть" : "нет"), браузеры: \(b)"
    }

    // MARK: опрос

    /// Опрос раз в 1,5 с, пока окно видно (дёшево: две проверки TCC; браузеры — только при открытом мастере).
    func startWatching() {
        refresh()
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopWatching() { timer?.invalidate(); timer = nil }

    func refresh() {
        let ax = AXIsProcessTrusted(), sc = CGPreflightScreenCaptureAccess()
        if ax != accessibility {
            accessibility = ax
            Log.write("разрешение «Универсальный доступ»: \(ax ? "выдано" : "снято")")
            if ax { onGranted(.accessibility) }
        }
        if sc != screen {
            screen = sc
            Log.write("разрешение «Запись экрана»: \(sc ? "выдано" : "снято")")
            if sc { onGranted(.screen) }
        }
        if wizardVisible && !askingBrowsers { refreshBrowsers() }
    }

    private func refreshBrowsers() {
        let running = Self.runningBrowsers()
        Task.detached(priority: .utility) {
            let list = running.map { Browser(name: $0.name, bundleId: $0.id, state: Self.automationState($0.id, ask: false)) }
            await MainActor.run {
                let s = Permissions.shared
                if list != s.browsers {
                    let wasAllowed = Set(s.browsers.filter { $0.state == .allowed }.map(\.bundleId))
                    s.browsers = list
                    if list.contains(where: { $0.state == .allowed && !wasAllowed.contains($0.bundleId) }) { s.onGranted(.browsers) }
                }
            }
        }
    }

    // MARK: запрос — по одному, по нажатию

    /// Кнопка «Разрешить»: в первый раз — штатный запрос macOS, потом — нужный раздел Системных настроек.
    func request(_ kind: Kind) {
        asked.insert(kind)
        switch kind {
        case .accessibility, .screen:
            // одна кнопка: сразу нужный раздел Системных настроек + панель со значком pia для перетаскивания
            openSettings(kind)
        case .browsers:
            let pending = browsers.filter { $0.state == .notAsked }
            if pending.isEmpty { openSettings(kind); return }
            askingBrowsers = true
            Log.write("разрешения: запрос «Автоматизация» для \(pending.map(\.name).joined(separator: ", "))")
            Task.detached(priority: .userInitiated) {
                // запросы блокируют поток до ответа — по одному, вне главного потока
                for b in pending { _ = Self.automationState(b.bundleId, ask: true) }
                await MainActor.run {
                    Permissions.shared.askingBrowsers = false
                    Permissions.shared.refresh()
                }
            }
        }
        refresh()
    }

    func openSettings(_ kind: Kind) {
        asked.insert(kind)
        Log.write("разрешения: открываю Системные настройки → \(kind.pane)")
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(kind.pane)") {
            NSWorkspace.shared.open(url)
        }
        DragPanel.shared.show(kind, explicit: true)   // подсказка с перетаскиваемым значком pia (только для разрешений-списков)
    }

    // MARK: перезапуск окна (не службы)

    /// Перезапустить только окно pia (службу 127.0.0.1 не трогает); после запуска мастер откроется снова.
    func relaunch() {
        UserDefaults.standard.set(true, forKey: Self.reopenKey)
        UserDefaults.standard.synchronize()
        Log.write("разрешения: перезапуск окна pia")
        let underLaunchd = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == "com.pi-agent.chat"
            || CommandLine.arguments.contains("--hidden")
        if underLaunchd {
            // запущены агентом com.pi-agent.chat — пусть он и перезапустит (без задержки ThrottleInterval)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = ["kickstart", "-k", "gui/\(getuid())/com.pi-agent.chat"]
            if (try? p.run()) != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { exit(1) }   // запасной путь: KeepAlive поднимет снова
                return
            }
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { _, err in
            DispatchQueue.main.async {
                if let err { Log.write("перезапуск не вышел: \(err.localizedDescription)"); return }
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: браузеры

    nonisolated static func runningBrowsers() -> [(id: String, name: String)] {
        let known = ContextBrowsers.safariIds.union(ContextBrowsers.chromiumIds)
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications.compactMap { a in
            guard let id = a.bundleIdentifier, known.contains(id), seen.insert(id).inserted else { return nil }
            return (id, a.localizedName ?? id)
        }.sorted { $0.name < $1.name }
    }

    /// Ответ «Автоматизации» для браузера (то же событие, что шлёт AppleScript «get URL»: core/getd).
    nonisolated static func automationState(_ bundleId: String, ask: Bool) -> Browser.State {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleId)
        guard let desc = target.aeDesc else { return .notAsked }
        let r = AEDeterminePermissionToAutomateTarget(desc, AEEventClass(kAECoreSuite), AEEventID(kAEGetData), ask)
        switch r {
        case noErr: return .allowed
        case OSStatus(errAEEventNotPermitted): return .denied
        default: return .notAsked     // -1744 — ещё не спрашивали; -600 — браузер закрылся
        }
    }
}
