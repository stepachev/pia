import AppKit

// Точка входа: обычное AppKit-приложение без значка в Dock (LSUIElement + .accessory).
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) {
        app.run()
    }
}
