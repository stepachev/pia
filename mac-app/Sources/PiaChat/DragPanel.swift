import AppKit

/// Плавающая подсказка рядом с окном Системных настроек: значок pia, который можно перетащить в список
/// («Универсальный доступ», «Запись экрана»), и текст. Не забирает фокус. Закрывается сама: когда разрешение
/// появилось, когда закрыли Системные настройки, по крестику или через ~2 мин.
@MainActor
final class DragPanel {
    static let shared = DragPanel()

    private var panel: NSPanel?
    private var timer: Timer?
    private var kind: Permissions.Kind = .accessibility
    private var started = Date()
    private var seenSettings = false
    private var waitForSettings = false   // системный диалог: ждём, пока пользователь сам откроет настройки
    private let size = NSSize(width: 400, height: 96)
    private var titleLabel: NSTextField?
    private var hintLabel: NSTextField?
    private var arrowView: NSImageView?
    private var arrowName: String?

    static let settingsIds = ["com.apple.systempreferences"]

    /// explicit — настройки открыли мы; иначе показался системный запрос macOS и панель ждёт, пока откроют настройки.
    func show(_ kind: Permissions.Kind, explicit: Bool) {
        guard kind == .accessibility || kind == .screen else { return }
        self.kind = kind
        started = Date()
        seenSettings = false
        waitForSettings = !explicit
        if panel == nil { panel = makePanel() }
        if kind == .screen {
            setTexts(title: "Разрешите запись экрана", hint: "Перетащите значок pia в список и включите переключатель")
        } else {
            setTexts(title: "Разрешите универсальный доступ", hint: "Перетащите значок pia в список и включите переключатель")
        }
        panel?.orderOut(nil)
        timer?.invalidate()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        if explicit { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.tick() } }
        Log.write("панель-подсказка: \(kind.rawValue), \(explicit ? "настройки открыты нами" : "ждёт открытия настроек")")
    }

    func close(_ why: String) {
        timer?.invalidate(); timer = nil
        if panel?.isVisible == true { Log.write("панель-подсказка закрыта: \(why)") }
        panel?.orderOut(nil)
    }

    private func granted() -> Bool {
        kind == .accessibility ? Permissions.shared.accessibility : Permissions.shared.screen
    }

    private func tick() {
        let age = Date().timeIntervalSince(started)
        if granted() { close("разрешение выдано"); return }
        if age > 120 { close("таймер 2 мин"); return }
        let frame = settingsWindowFrame()
        if let frame {
            seenSettings = true
            place(near: frame)
        } else if seenSettings {
            close("настройки закрыты"); return
        } else if !waitForSettings && age > 5 {
            placeInCorner()          // окно настроек не нашли — угол главного экрана
        } else if waitForSettings {
            panel?.orderOut(nil); return
        }
        showPanel()
    }

    // MARK: окно Системных настроек

    /// Рамка окна в координатах Cocoa (начало внизу слева), если окно на экране.
    private func settingsWindowFrame() -> NSRect? {
        let pids = Set(Self.settingsIds.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).map(\.processIdentifier) })
        guard !pids.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let primary = NSScreen.screens.first else { return nil }
        for w in list {
            guard let pid = w[kCGWindowOwnerPID as String] as? Int32, pids.contains(pid),
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let ww = b["Width"], let hh = b["Height"],
                  ww >= 300, hh >= 300 else { continue }
            return NSRect(x: x, y: primary.frame.height - y - hh, width: ww, height: hh)
        }
        return nil
    }

    private func place(near f: NSRect) {
        guard let panel else { return }
        let screen = NSScreen.screens.first { $0.frame.intersects(f) } ?? NSScreen.main ?? NSScreen.screens[0]
        let vis = screen.visibleFrame
        let gap: CGFloat = 12
        var arrow: String? = "arrow.up"
        var o = NSPoint(x: f.midX - size.width / 2, y: f.minY - size.height - gap)     // под окном по центру
        if o.y < vis.minY {
            arrow = "arrow.left"
            o = NSPoint(x: f.maxX + gap, y: f.midY - size.height / 2)                  // справа
            if o.x + size.width > vis.maxX {
                arrow = "arrow.right"
                o = NSPoint(x: f.minX - size.width - gap, y: f.midY - size.height / 2) // слева
                if o.x < vis.minX { arrow = nil; o = NSPoint(x: f.midX - size.width / 2, y: f.minY + 12) }
            }
        }
        o.x = min(max(o.x, vis.minX + 4), vis.maxX - size.width - 4)
        o.y = min(max(o.y, vis.minY + 4), vis.maxY - size.height - 4)
        setArrow(arrow)
        if panel.frame.origin != o { panel.setFrameOrigin(o) }
    }

    private func placeInCorner() {
        guard let panel, let s = NSScreen.screens.first else { return }
        let v = s.visibleFrame
        setArrow(nil)
        panel.setFrameOrigin(NSPoint(x: v.maxX - size.width - 20, y: v.minY + 20))
    }

    // MARK: вид

    func setTexts(title: String, hint: String) {
        titleLabel?.stringValue = title
        hintLabel?.stringValue = hint
    }

    /// Стрелка в сторону окна настроек: nil — окно не найдено или панель поверх него (стрелка скрыта).
    private func setArrow(_ name: String?) {
        guard let arrowView else { return }
        guard let name else { arrowView.isHidden = true; return }
        if arrowName != name {
            arrowName = name
            let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            arrowView.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        }
        arrowView.isHidden = false
    }

    /// Плавное появление: alpha 0→1 и масштаб 0.96→1 за 0,2 с.
    private func showPanel() {
        guard let panel, !panel.isVisible else { return }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        if let layer = panel.contentView?.layer {
            let cx = size.width / 2, cy = size.height / 2
            var t = CATransform3DMakeTranslation(cx, cy, 0)
            t = CATransform3DScale(t, 0.96, 0.96, 1)
            t = CATransform3DTranslate(t, -cx, -cy, 0)
            let a = CABasicAnimation(keyPath: "transform")
            a.fromValue = NSValue(caTransform3D: t)
            a.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            a.duration = 0.2
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(a, forKey: "appear")
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 1
        }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.hasShadow = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.isReleasedWhenClosed = false

        let fx = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 16
        fx.layer?.cornerCurve = .continuous
        fx.layer?.masksToBounds = true
        fx.layer?.borderWidth = 0.5
        fx.layer?.borderColor = NSColor.separatorColor.cgColor

        let pad: CGFloat = 16, iconSize: CGFloat = 64
        let icon = DragIconView(frame: NSRect(x: pad, y: (size.height - iconSize) / 2, width: iconSize, height: iconSize))
        fx.addSubview(icon)

        let tx = pad + iconSize + 14
        let tw = size.width - tx - pad - 14
        let title = NSTextField(labelWithString: "")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x: tx, y: size.height - pad - 17, width: tw, height: 17)
        fx.addSubview(title)
        titleLabel = title

        let hint = NSTextField(wrappingLabelWithString: "")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        hint.maximumNumberOfLines = 3
        hint.frame = NSRect(x: tx, y: pad, width: tw, height: size.height - pad * 2 - 17 - 3)
        fx.addSubview(hint)
        hintLabel = hint

        let arrow = NSImageView(frame: NSRect(x: size.width - pad - 14, y: pad - 1, width: 16, height: 16))
        arrow.contentTintColor = .tertiaryLabelColor
        arrow.imageScaling = .scaleProportionallyDown
        arrow.isHidden = true
        arrow.wantsLayer = true
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0; pulse.toValue = 0.3
        pulse.duration = 0.9; pulse.autoreverses = true; pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        arrow.layer?.add(pulse, forKey: "pulse")
        fx.addSubview(arrow)
        arrowView = arrow

        let close = NSButton(frame: NSRect(x: size.width - 14 - 12, y: size.height - 12 - 14, width: 14, height: 14))
        close.isBordered = false
        close.imageScaling = .scaleProportionallyDown
        close.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Закрыть")
        close.contentTintColor = .secondaryLabelColor
        close.target = self
        close.action = #selector(closeTapped)
        fx.addSubview(close)

        p.contentView = fx
        return p
    }

    @objc private func closeTapped() { close("закрыта кнопкой") }
}

/// Значок приложения: перетаскивается как файл-приложение (в список разрешений Системных настроек).
final class DragIconView: NSView, NSDraggingSource {
    private var downAt: NSPoint?
    private var hover = false
    private var dragging = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = "Перетащите в список"
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    private var icon: NSImage { NSWorkspace.shared.icon(forFile: Bundle.main.bundleURL.path) }

    override func draw(_ dirtyRect: NSRect) {
        let plate = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
        NSColor.labelColor.withAlphaComponent(dragging ? 0.14 : hover ? 0.10 : 0.06).setFill()
        plate.fill()
        NSColor.separatorColor.setStroke()
        plate.lineWidth = 1
        plate.stroke()
        icon.draw(in: bounds.insetBy(dx: 4, dy: 4))
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: dragging ? .closedHand : .openHand) }
    override func mouseEntered(with event: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hover = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        downAt = event.locationInWindow
        dragging = true; needsDisplay = true
        NSCursor.closedHand.set()
    }
    override func mouseUp(with event: NSEvent) { endDrag() }

    private func endDrag() {
        dragging = false; needsDisplay = true
        window?.invalidateCursorRects(for: self)
        NSCursor.openHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let d = downAt, hypot(event.locationInWindow.x - d.x, event.locationInWindow.y - d.y) > 3 else { return }
        downAt = nil
        let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
        item.setDraggingFrame(bounds.insetBy(dx: 4, dy: 4), contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { endDrag() }
}
