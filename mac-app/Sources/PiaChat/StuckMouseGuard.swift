import AppKit

/// Страховка от зависания в цикле отслеживания мыши (выделение текста в NSTextView).
/// NSTextView.mouseDown крутит свой nextEvent(.eventTracking) до отпускания левой кнопки. Если окно спрятали
/// (уход в другое приложение, Esc, хоткей), пока кнопка зажата, отпускание уходит другому окну — цикл ждёт вечно,
/// главный поток не принимает ни pia://show, ни хоткеи, ни обновления ленты (2026-11-23, сэмпл в backups/pia-app-hang-sample-*).
/// Решение: таймер в .common (он срабатывает и внутри цикла отслеживания) видит «нажатие было в окне pia,
/// главный поток во вложенном цикле, а кнопка мыши физически отпущена» два тика подряд — и кладёт в очередь
/// pia собственное событие leftMouseUp. Цикл выходит как при обычном отпускании; выделение остаётся.
/// Системный ввод не эмулируется: событие только во внутренней очереди приложения.
@MainActor
final class StuckMouseGuard {
    private weak var panel: PiaPanel?
    private var timer: Timer?
    private var strikes = 0
    /// Выставляется в PiaPanel.sendEvent на leftMouseDown (до входа в цикл отслеживания).
    var downInPanel = false

    init(panel: PiaPanel) { self.panel = panel }

    func start() {
        let t = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let mode = RunLoop.current.currentMode ?? .default
        // верхний цикл приложения — значит, никакого отслеживания нет; прошлое нажатие закончилось нормально
        if mode == .default { downInPanel = false; strikes = 0; return }
        guard downInPanel, NSEvent.pressedMouseButtons & 1 == 0, let panel else { strikes = 0; return }
        strikes += 1
        guard strikes >= 2 else { return }   // ~0.4–0.8 с: настоящее отпускание к этому времени уже обработано
        strikes = 0
        downInPanel = false
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: panel.mouseLocationOutsideOfEventStream, modifierFlags: [],
                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 0)
        if let up { NSApp.postEvent(up, atStart: true) }
        Log.write("мышь: прерван зависший цикл отслеживания (режим \(mode.rawValue), окно видно: \(panel.isVisible)) — отпускание кнопки ушло мимо pia")
    }
}
