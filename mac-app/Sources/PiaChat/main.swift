import AppKit

// Служебные режимы без окна: регистрация/снятие/состояние автозапуска (SMAppService). Печатают состояние и выходят.
let args = CommandLine.arguments
if args.contains("--register-only") { Autostart.ensureRegistered().forEach { print($0) }; exit(0) }
if args.contains("--unregister") { Autostart.unregisterAll().forEach { print($0) }; exit(0) }
if args.contains("--autostart-status") { Autostart.status().forEach { print($0) }; exit(0) }

// Точка входа: обычное AppKit-приложение без значка в Dock (LSUIElement + .accessory).
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) {
        app.run()
    }
}
