import AppKit

/// Наведение курсора на правый край экрана по центру (средняя треть высоты) — показать окно pia.
/// Курсор должен постоять у края ~0,25 с: случайный пролёт мимо не считается.
/// Край считается только если справа нет другого монитора. Разрешений не требует (только движение мыши).
final class EdgeHoverMonitor {
    static let key = "edgeHoverEnabled"
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    private var global: Any?
    private var local: Any?
    private var timer: Timer?
    private var fired = false
    private let onTrigger: () -> Void

    init(onTrigger: @escaping () -> Void) { self.onTrigger = onTrigger }

    func start() {
        guard global == nil else { return }
        global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in self?.check() }
        local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] e in self?.check(); return e }
    }

    func stop() {
        if let g = global { NSEvent.removeMonitor(g) }
        if let l = local { NSEvent.removeMonitor(l) }
        global = nil; local = nil
        timer?.invalidate(); timer = nil
    }

    static func inZone(_ p: NSPoint) -> Bool {
        guard let s = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) || (p.x >= $0.frame.maxX - 1 && p.x <= $0.frame.maxX && p.y >= $0.frame.minY && p.y <= $0.frame.maxY) }) else { return false }
        let f = s.frame
        guard p.x >= f.maxX - 2 else { return false }
        // справа другой монитор — это не край, а проход между экранами
        if NSScreen.screens.contains(where: { $0 != s && $0.frame.minX >= f.maxX - 1 && $0.frame.minY < p.y && $0.frame.maxY > p.y }) { return false }
        let rel = (p.y - f.minY) / f.height
        return rel > 1.0 / 3 && rel < 2.0 / 3
    }

    private func check() {
        let p = NSEvent.mouseLocation
        if EdgeHoverMonitor.inZone(p) {
            guard !fired, timer == nil else { return }
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.timer = nil
                if EdgeHoverMonitor.inZone(NSEvent.mouseLocation) { self.fired = true; self.onTrigger() }
            }
        } else {
            timer?.invalidate(); timer = nil
            fired = false   // ушёл от края — следующий заход сработает снова
        }
    }
}
