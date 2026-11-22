import AppKit

// Курсор «рука» над ссылками. Сообщения рисует SwiftUI Text (Markdown.swift) с textSelection — он ставит I-beam
// на весь текст и не отдаёт геометрию ссылок, поэтому ссылку определяем через доступность (AXLink) под курсором.
@MainActor enum LinkCursor {
    private static var monitor: Any?
    private static var overLink = false

    static func install(root: @escaping () -> NSView?) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { e in
            MainActor.assumeIsolated {
                guard e.type == .mouseMoved, let v = root(), e.window === v.window else { return }
                let p = NSEvent.mouseLocation
                var el: Any? = v.accessibilityHitTest(p)
                var link = false
                var depth = 0
                while let x = el as? NSAccessibilityProtocol, depth < 4 {
                    if x.accessibilityRole() == .link { link = true; break }
                    el = x.accessibilityParent()
                    depth += 1
                }
                if link { NSCursor.pointingHand.set(); overLink = true }
                else if overLink { overLink = false; NSCursor.iBeam.set() }
            }
            return e
        }
    }
}
