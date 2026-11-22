import Foundation
import ServiceManagement

/// Автозапуск через SMAppService: службы лежат внутри pia.app (Contents/Library/LaunchAgents), и macOS показывает их
/// в «Объектах входа» одной строкой «pia» со значком приложения.
enum Autostart {
    static let plists = ["com.pi-agent.server.plist", "com.pi-agent.chat.plist"]

    static func name(_ s: SMAppService.Status) -> String {
        switch s {
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notRegistered: return "notRegistered"
        case .notFound: return "notFound"
        @unknown default: return "unknown"
        }
    }

    /// Идемпотентно: регистрирует только то, что ещё не включено. Возвращает строки состояния.
    @discardableResult
    static func ensureRegistered() -> [String] {
        var out: [String] = []
        for p in plists {
            let svc = SMAppService.agent(plistName: p)
            // status == .enabled значит лишь «разрешено», а не «загружено в launchd»: register() вызываем всегда (повторный вызов безвреден)
            if svc.status != .requiresApproval {
                do { try svc.register() } catch { out.append("\(p): register: \(error.localizedDescription)") }
            }
            out.append("\(p): \(name(svc.status))")
        }
        return out
    }

    static func unregisterAll() -> [String] {
        var out: [String] = []
        for p in plists {
            let svc = SMAppService.agent(plistName: p)
            do { try svc.unregister() } catch { out.append("\(p): \(error.localizedDescription)") }
            out.append("\(p): \(name(svc.status))")
        }
        return out
    }

    static func status() -> [String] { plists.map { "\($0): \(name(SMAppService.agent(plistName: $0).status))" } }
}
