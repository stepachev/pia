import AppKit

// Курсор «рука» над ссылками. Сообщения рисует SwiftUI Text (Markdown.swift) с textSelection — он ставит I-beam
// на весь текст и не отдаёт геометрию ссылок, поэтому ссылку определяем через доступность (AXLink) под курсором.
// События — через NSTrackingArea (.activeAlways): работает и когда pia не в фокусе (локальный монитор не работал).
final class LinkTrackingView: NSView {
    private var overLink = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) { update() }
    override func cursorUpdate(with event: NSEvent) { update() }
    override func mouseExited(with event: NSEvent) { overLink = false }

    private func update() {
        var el: Any? = accessibilityHitTest(NSEvent.mouseLocation)
        var link = false
        var depth = 0
        while let x = el as? NSAccessibilityProtocol, depth < 5 {
            if x.accessibilityRole() == .link { link = true; break }
            el = x.accessibilityParent()
            depth += 1
        }
        if link { NSCursor.pointingHand.set(); overLink = true }
        else if overLink { overLink = false; NSCursor.iBeam.set() }
    }
}
