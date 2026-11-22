import AppKit
import ApplicationServices
import CoreGraphics

/// Жест «двойное нажатие правого Shift» (keyCode 60), как двойной ⌘ / двойной Shift в других программах:
/// два коротких нажатия (каждое ≤ ~300 мс), второе — не позже ~350 мс после первого отпускания,
/// без других клавиш и модификаторов между ними. Левый Shift (56) не участвует и сбрасывает жест;
/// оба Shift сразу — не срабатывает. Логика — в чистом автомате DoubleTapDetector (без NSEvent),
/// здесь — только мониторы и перевод NSEvent → DoubleTapDetector.Input.
///
/// Мониторы: flagsChanged (Shift и прочие модификаторы) и keyDown (набор между/во время нажатий
/// сбрасывает жест, например заглавная буква правым Shift). Глобальный монитор клавиатурных событий
/// (и keyDown, и flagsChanged) работает с правом «Универсальный доступ» — «Мониторинг ввода» не нужен.
/// start() ничего не запрашивает (разрешения выдаются по одному в мастере — Permissions/PermissionsView);
/// если прав ещё нет, монитор сам подключится, как только они появятся (проверка раз в 2 с).
///
/// Все вызовы — с главного потока (как обычно в AppKit/SwiftUI); с другого потока
/// start()/stop() сами перейдут на главный.
final class RightShiftDoubleTapMonitor: @unchecked Sendable {
    // MARK: Настройки
    /// Максимум между первым отпусканием и вторым нажатием правого Shift.
    var tapWindow: TimeInterval {
        get { detector.tapWindow }
        set { detector.tapWindow = newValue }
    }
    /// Максимальная длительность каждого нажатия.
    var maxHold: TimeInterval {
        get { detector.maxHold }
        set { detector.maxHold = newValue }
    }

    // MARK: Права
    /// Есть ли право «Универсальный доступ» (без запроса).
    static var hasAccessibility: Bool { AXIsProcessTrusted() }
    /// Есть ли право «Мониторинг ввода» (без запроса; только для журнала — pia его не требует).
    static var hasInputMonitoring: Bool { CGPreflightListenEventAccess() }
    /// Хватает ли прав, чтобы жест ловился во всех приложениях.
    static var hasPermissions: Bool { hasAccessibility }

    // Запросы разрешений и переход в Системные настройки — только в мастере «Разрешения» (Permissions.swift),
    // по нажатию пользователя. «Мониторинг ввода» не нужен: глобальным мониторам клавиш хватает «Универсального доступа».

    // MARK: Жизненный цикл
    private let onTrigger: () -> Void
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var permissionTimer: Timer?
    private var installedWhileTrusted = false

    // Состояние жеста (меняется только на главном потоке).
    private(set) var detector = DoubleTapDetector()

    init(onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
    }

    deinit {
        // Мониторы держат слабую ссылку; снимаем их, если про stop() забыли.
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        permissionTimer?.invalidate()
    }

    func start() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.start() }
            return
        }
        guard globalMonitor == nil, localMonitor == nil else { return }
        // без запроса: разрешение выдаётся в мастере «Разрешения»; без него монитор ждёт и подключится сам
        let trusted = Self.hasAccessibility
        installMonitors(trusted: trusted)
        if !trusted { waitForPermission() }
    }

    func stop() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.stop() }
            return
        }
        permissionTimer?.invalidate()
        permissionTimer = nil
        removeMonitors()
        detector.reset()
    }

    var isRunning: Bool { globalMonitor != nil || localMonitor != nil }

    // MARK: Мониторы
    private func installMonitors(trusted: Bool) {
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }
        installedWhileTrusted = trusted
    }

    private func removeMonitors() {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        globalMonitor = nil
        localMonitor = nil
    }

    /// Глобальный монитор, поставленный без прав, событий не получает и после выдачи
    /// прав — поэтому ждём права и переустанавливаем мониторы.
    private func waitForPermission() {
        permissionTimer?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            if AXIsProcessTrusted() {
                t.invalidate()
                self.permissionTimer = nil
                if self.isRunning && !self.installedWhileTrusted {
                    self.removeMonitors()
                    self.installMonitors(trusted: true)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    // MARK: Логика жеста
    static let leftShiftKeyCode: UInt16 = 56
    static let rightShiftKeyCode: UInt16 = 60
    // Аппаратные биты левого/правого Shift (NX_DEVICELSHIFTKEYMASK / NX_DEVICERSHIFTKEYMASK).
    static let deviceLeftShift: UInt = 0x0000_0002
    static let deviceRightShift: UInt = 0x0000_0004

    /// Обработка события (internal — чтобы проверять логику без реальной клавиатуры).
    func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            feed(.other, at: event.timestamp)
        case .flagsChanged:
            handleFlags(keyCode: event.keyCode, flags: event.modifierFlags, timestamp: event.timestamp)
        default:
            break
        }
    }

    func handleFlags(keyCode: UInt16, flags: NSEvent.ModifierFlags, timestamp: TimeInterval) {
        feed(Self.classify(keyCode: keyCode, flags: flags), at: timestamp)
    }

    /// Любая клавиша (keyDown) — для проверок без NSEvent.
    func handleKeyDown(timestamp: TimeInterval) { feed(.other, at: timestamp) }

    private func feed(_ input: DoubleTapDetector.Input, at time: TimeInterval) {
        if detector.feed(input, at: time) { onTrigger() }
    }

    /// flagsChanged → вход автомата: «правый Shift вниз/вверх» только если изменился именно правый Shift
    /// (keyCode 60), левый Shift не зажат и нет ⌘/⌃/⌥/fn; всё остальное (левый Shift, Caps Lock, прочие
    /// модификаторы) — `.other`. Включённый Caps Lock жест не блокирует.
    static func classify(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> DoubleTapDetector.Input {
        guard keyCode == rightShiftKeyCode else { return .other }
        let others: NSEvent.ModifierFlags = [.command, .control, .option, .function]
        guard flags.intersection(others).isEmpty else { return .other }
        let raw = flags.rawValue
        let hasDeviceBits = raw & (deviceLeftShift | deviceRightShift) != 0
        if hasDeviceBits {
            if raw & deviceLeftShift != 0 { return .other }   // зажат левый Shift (оба сразу)
            return .rightShift(down: raw & deviceRightShift != 0)
        }
        // Нет аппаратных битов (синтетическое событие или отпускание) — по общему флагу Shift.
        return .rightShift(down: flags.contains(.shift))
    }
}
