import Foundation

// Связь со службой pia (daemon.mjs → server.mjs): 127.0.0.1:<port>, Authorization: Bearer <token>.
// Адрес и ключ — ~/.pi-agent/server.json; для проверок — PIA_SERVER_JSON=путь или аргумент --server-json путь.

struct ServerConfig: Decodable, Equatable {
    let port: Int
    let token: String
}

struct FeedItem: Decodable, Identifiable, Equatable {
    let seq: Int
    let role: String          // user | assistant | report
    var text: String
    var images: [String]
    var ts: String?
    var partial: Bool?
    var n: Int?
    var title: String?
    var id: Int { seq }
    var isPartial: Bool { partial == true }

    enum CodingKeys: String, CodingKey { case seq, role, text, images, ts, partial, n, title }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        seq = try c.decode(Int.self, forKey: .seq)
        role = (try? c.decode(String.self, forKey: .role)) ?? "assistant"
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        images = (try? c.decode([String].self, forKey: .images)) ?? []
        ts = try? c.decode(String.self, forKey: .ts)
        partial = try? c.decode(Bool.self, forKey: .partial)
        n = try? c.decode(Int.self, forKey: .n)
        title = try? c.decode(String.self, forKey: .title)
    }
    init(seq: Int, role: String, text: String, images: [String]) {
        self.seq = seq; self.role = role; self.text = text; self.images = images
    }
}

struct HistoryResponse: Decodable {
    var items: [FeedItem]
    var busy: Bool?
    var last: Int?
}

struct HelperInfo: Decodable, Equatable, Identifiable {
    struct Doing: Decodable, Equatable { var label: String?; var since: Double?; var stuck: Bool? }
    var n: Int?          // у ещё не запущенных служба присылает null
    var title: String?
    var state: String?
    var status: String?
    var since: Double?
    var startedAt: Double?
    var doing: Doing?
    var id: String { n.map { "#\($0)" } ?? "t:" + (title ?? "") }
    /// «готов» — отчёт ждёт отправки, помощник уже не работает
    var isWorking: Bool { state != "готов" }
    var statusText: String { status ?? state ?? "работает" }
    var startMs: Double? { startedAt ?? since }
}

struct LiveState: Decodable, Equatable {
    var busy: Bool?
    var stopping: Bool?
    var label: String?
    var tool: String?        // имя инструмента (новые версии службы), иначе — по label
    var toolRunning: Bool?
    var text: String?
}

struct StateResponse: Decodable {
    var busy: Bool?
    var live: LiveState?
    var helpers: [HelperInfo]?
}

struct SendResponse: Decodable { var ok: Bool?; var seq: Int?; var error: String? }

enum PiaError: LocalizedError {
    case noConfig(String), http(Int, String)
    var errorDescription: String? {
        switch self {
        case .noConfig(let p): return "нет \(p)"
        case .http(let c, let m): return "HTTP \(c): \(m)"
        }
    }
}

final class PiaClient: @unchecked Sendable {
    let configPath: String
    private var config: ServerConfig?
    private let session: URLSession

    init() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--server-json"), i + 1 < args.count {
            configPath = (args[i + 1] as NSString).expandingTildeInPath
        } else if let env = ProcessInfo.processInfo.environment["PIA_SERVER_JSON"], !env.isEmpty {
            configPath = (env as NSString).expandingTildeInPath
        } else {
            configPath = NSHomeDirectory() + "/.pi-agent/server.json"
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.connectionProxyDictionary = [:]   // только локальная служба, без прокси
        session = URLSession(configuration: cfg)
    }

    func reloadConfig() { config = nil }

    private func currentConfig() throws -> ServerConfig {
        if let c = config { return c }
        guard let data = FileManager.default.contents(atPath: configPath),
              let c = try? JSONDecoder().decode(ServerConfig.self, from: data) else {
            throw PiaError.noConfig(configPath)
        }
        config = c
        return c
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil, timeout: TimeInterval = 8) async throws -> Data {
        let c = try currentConfig()
        guard let url = URL(string: "http://127.0.0.1:\(c.port)\(path)") else { throw PiaError.http(0, "адрес") }
        var r = URLRequest(url: url, timeoutInterval: timeout)
        r.httpMethod = method
        r.setValue("Bearer \(c.token)", forHTTPHeaderField: "Authorization")
        if let body { r.httpBody = body; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        do {
            let (data, resp) = try await session.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                if code == 401 { config = nil }
                let msg = (try? JSONDecoder().decode(SendResponse.self, from: data))?.error ?? String(decoding: data.prefix(200), as: UTF8.self)
                throw PiaError.http(code, msg)
            }
            return data
        } catch let e as PiaError {
            throw e
        } catch {
            config = nil   // служба могла переехать на другой порт — перечитаем server.json
            throw error
        }
    }

    func history(after: Int, limit: Int) async throws -> HistoryResponse {
        let d = try await request("/api/history?after=\(after)&limit=\(limit)", timeout: 15)
        return try JSONDecoder().decode(HistoryResponse.self, from: d)
    }

    func state() async throws -> StateResponse {
        let d = try await request("/api/state")
        return try JSONDecoder().decode(StateResponse.self, from: d)
    }

    func send(text: String, images: [String]) async throws -> Int? {
        let body = try JSONSerialization.data(withJSONObject: ["text": text, "images": images, "source": "mac"])
        let d = try await request("/api/send", method: "POST", body: body, timeout: 30)
        return (try? JSONDecoder().decode(SendResponse.self, from: d))?.seq
    }
}

// Простой журнал: ~/.pi-agent/mac-app/app.log (PIA_APP_LOG — другой путь)
enum Log {
    static let path: String = ProcessInfo.processInfo.environment["PIA_APP_LOG"] ?? (NSHomeDirectory() + "/.pi-agent/mac-app/app.log")
    private static let q = DispatchQueue(label: "pia.log")
    static func write(_ s: String) {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line = "\(f.string(from: Date())) [\(ProcessInfo.processInfo.processIdentifier)] \(s)\n"
        q.async {
            let url = URL(fileURLWithPath: path)
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
