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
    private let size = NSSize(width: 340, height: 84)

    static let settingsIds = ["com.apple.systempreferences"]

    /// explicit — настройки открыли мы; иначе показался системный запрос macOS и панель ждёт, пока откроют настройки.
    func show(_ kind: Permissions.Kind, explicit: Bool) {
        guard kind == .accessibility || kind == .screen else { return }
        self.kind = kind
        started = Date()
        seenSettings = false
        waitForSettings = !explicit
        if panel == nil { panel = makePanel() }
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
        if panel?.isVisible != true { panel?.orderFrontRegardless() }
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
        let gap: CGFloat = 8
        var o = NSPoint(x: f.midX - size.width / 2, y: f.minY - size.height - gap)     // под окном
        if o.y < vis.minY {
            o = NSPoint(x: f.maxX + gap, y: f.minY)                                    // справа
            if o.x + size.width > vis.maxX {
                o = NSPoint(x: f.midX - size.width / 2, y: f.minY + 12)                // поверх нижнего края окна
            }
        }
        o.x = min(max(o.x, vis.minX + 4), vis.maxX - size.width - 4)
        o.y = min(max(o.y, vis.minY + 4), vis.maxY - size.height - 4)
        if panel.frame.origin != o { panel.setFrameOrigin(o) }
    }

    private func placeInCorner() {
        guard let panel, let s = NSScreen.screens.first else { return }
        let v = s.visibleFrame
        panel.setFrameOrigin(NSPoint(x: v.maxX - size.width - 20, y: v.minY + 20))
    }

    // MARK: вид

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
        fx.material = .popover
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 16
        fx.layer?.masksToBounds = true
        fx.layer?.borderWidth = 0.5
        fx.layer?.borderColor = NSColor.separatorColor.cgColor

        let icon = DragIconView(frame: NSRect(x: 14, y: 14, width: 56, height: 56))
        fx.addSubview(icon)

        let label = NSTextField(wrappingLabelWithString: "Перетащите pia в список и включите переключатель")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.frame = NSRect(x: 82, y: 14, width: size.width - 82 - 34, height: 56)
        label.maximumNumberOfLines = 3
        fx.addSubview(label)

        let close = NSButton(frame: NSRect(x: size.width - 28, y: size.height - 28, width: 18, height: 18))
        close.isBordered = false
        close.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Закрыть")
        close.contentTintColor = .tertiaryLabelColor
        close.target = self
        close.action = #selector(closeTapped)
        fx.addSubview(close)

        p.contentView = fx
        return p
    }

    @objc private func closeTapped() { close("закрыта кнопкой") }
}

/// Значок pia.app: перетаскивается как файл-приложение (в список разрешений Системных настроек).
final class DragIconView: NSView, NSDraggingSource {
    private var downAt: NSPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = "Перетащите в список"
    }
    required init?(coder: NSCoder) { fatalError() }

    private var icon: NSImage { NSWorkspace.shared.icon(forFile: Bundle.main.bundleURL.path) }

    override func draw(_ dirtyRect: NSRect) { icon.draw(in: bounds) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) { downAt = event.locationInWindow }

    override func mouseDragged(with event: NSEvent) {
        guard let d = downAt, hypot(event.locationInWindow.x - d.x, event.locationInWindow.y - d.y) > 3 else { return }
        downAt = nil
        let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
        item.setDraggingFrame(bounds, contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}
