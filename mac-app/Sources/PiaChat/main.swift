import AppKit

// Служебные режимы без окна: регистрация/снятие/состояние автозапуска (SMAppService). Печатают состояние и выходят.
let args = CommandLine.arguments
// необязательный аргумент после флага — одна служба: `--register-only chat` / `--unregister chat` (сервер не трогается)
func onlyService(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count, !args[i + 1].hasPrefix("-") else { return nil }
    return args[i + 1]
}
if args.contains("--register-only") { Autostart.ensureRegistered(only: onlyService("--register-only")).forEach { print($0) }; exit(0) }
if args.contains("--unregister") { Autostart.unregisterAll(only: onlyService("--unregister")).forEach { print($0) }; exit(0) }
if args.contains("--autostart-status") { Autostart.status().forEach { print($0) }; exit(0) }

// Одно окно: если pia уже запущена (вручную или службой), второй экземпляр тихо выходит (код 0 — служба его не перезапускает).
// Проверочный запуск (PIA_TEST_OFFSCREEN с мок-сервером) работает рядом с настоящей pia.
if ProcessInfo.processInfo.environment["PIA_TEST_OFFSCREEN"] != "1", let bid = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: bid).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
    exit(0)
}

// Точка входа: обычное AppKit-приложение без значка в Dock (LSUIElement + .accessory).
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) {
        app.run()
    }
}
