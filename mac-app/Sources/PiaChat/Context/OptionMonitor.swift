import AppKit
import ApplicationServices

/// Жест «двойное нажатие правого Option» (keyCode 61): показать окно pia или, если оно уже активно, спрятать.
/// Логика жеста — тот же автомат DoubleTapDetector (вход .rightShift здесь значит «правый Option»):
/// два коротких нажатия (≤ 300 мс), пауза ≤ 350 мс, между ними нет других клавиш и модификаторов;
/// левый Option (58) сбрасывает жест; удержание Option с набором символа (⌥+клавиша) не срабатывает.
/// Настройка: UserDefaults `pia.optionHotkey` (по умолчанию включено). Права — «Универсальный доступ»;
/// без них монитор просто молчит, приложение работает как раньше (системный запрос — один раз).
final class RightOptionDoubleTapMonitor: @unchecked Sendable {
    static let defaultsKey = "pia.optionHotkey"
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: defaultsKey) == nil ? true : UserDefaults.standard.bool(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    static let rightOptionKeyCode: UInt16 = 61
    static let deviceLeftOption: UInt = 0x0000_0020   // NX_DEVICELALTKEYMASK
    static let deviceRightOption: UInt = 0x0000_0040  // NX_DEVICERALTKEYMASK

    private let onTrigger: () -> Void
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var timer: Timer?
    private var installedTrusted = false
    private var detector = DoubleTapDetector()

    init(onTrigger: @escaping () -> Void) { self.onTrigger = onTrigger }

    deinit { removeMonitors(); timer?.invalidate() }

    var isRunning: Bool { globalMonitor != nil || localMonitor != nil }

    func start() {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.start() }; return }
        guard !isRunning else { return }
        let trusted = RightShiftDoubleTapMonitor.requestPermissionsIfNeeded()
        install(trusted: trusted)
        if !trusted {
            let t = Timer(timeInterval: 2, repeats: true) { [weak self] t in
                guard let self else { t.invalidate(); return }
                if AXIsProcessTrusted() {
                    t.invalidate(); self.timer = nil
                    if self.isRunning && !self.installedTrusted { self.removeMonitors(); self.install(trusted: true) }
                }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    func stop() {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.stop() }; return }
        timer?.invalidate(); timer = nil
        removeMonitors()
        detector.reset()
    }

    private func install(trusted: Bool) {
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] e in self?.handle(e) }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] e in self?.handle(e); return e }
        installedTrusted = trusted
    }

    private func removeMonitors() {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        globalMonitor = nil; localMonitor = nil
    }

    private func handle(_ event: NSEvent) {
        let input: DoubleTapDetector.Input
        switch event.type {
        case .keyDown: input = .other
        case .flagsChanged: input = Self.classify(keyCode: event.keyCode, flags: event.modifierFlags)
        default: return
        }
        if detector.feed(input, at: event.timestamp) { onTrigger() }
    }

    static func classify(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> DoubleTapDetector.Input {
        guard keyCode == rightOptionKeyCode else { return .other }
        let others: NSEvent.ModifierFlags = [.command, .control, .shift, .function]
        guard flags.intersection(others).isEmpty else { return .other }
        let raw = flags.rawValue
        if raw & (deviceLeftOption | deviceRightOption) != 0 {
            if raw & deviceLeftOption != 0 { return .other }
            return .rightShift(down: raw & deviceRightOption != 0)
        }
        return .rightShift(down: flags.contains(.option))
    }
}
