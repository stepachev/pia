import AppKit

// Проверочные крючки (только для мок-сервера; в обычном запуске ничего не делают):
//   PIA_TEST_OFFSCREEN=1          — окно не забирает фокус и стоит под всеми окнами (PIA_TEST_FLOAT=1 — поверх, тоже без фокуса)
//   PIA_TEST_ATTACH=путь.png      — прикрепить картинку как вставку из буфера
//   PIA_TEST_CONTEXT=1            — прикрепить пример контекста (как по двойному правому Shift); PIA_TEST_CONTEXT_SHOT=путь.png — со скриншотом окна, PIA_TEST_CONTEXT_TEXT=… — с текстом окна
//   PIA_TEST_DRAFT=текст          — набрать текст в поле ввода
//   PIA_TEST_SEND=1               — через 2 с отправить (только если сервер не ~/.pi-agent/server.json)
//   PIA_TEST_CYCLE=1              — скрыть/показать, сменить размер, key туда-обратно; в лог — есть ли кнопки-«светофор»
//   PIA_TEST_EXPAND_REPORTS / PIA_TEST_HELPERS=1 — показать список помощников раскрытым
@MainActor
enum TestHooks {
    static let env = ProcessInfo.processInfo.environment
    static var offscreen: Bool { env["PIA_TEST_OFFSCREEN"] == "1" }

    static func run(_ app: AppDelegate) {
        let m = app.model
        if let p = env["PIA_TEST_ATTACH"], !p.isEmpty {
            let pb = NSPasteboard(name: NSPasteboard.Name("pia-test"))
            pb.clearContents()
            if let img = NSImage(contentsOfFile: p), let tiff = img.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
            _ = m.attachFromPasteboard(pb)
        }
        if env["PIA_TEST_CONTEXT"] == "1" {
            var c = CapturedContext(appName: "Yab", bundleId: "dev.serafim.fast")
            c.pageTitle = "Raycast AI Chat — обзор"
            c.url = "https://www.raycast.com/core-features/ai"
            c.selectedText = "Raycast AI Chat"
            if let shot = env["PIA_TEST_CONTEXT_SHOT"], !shot.isEmpty { c.screenshotPath = shot }   // скриншот окна, как у двойного правого Shift
            if let text = env["PIA_TEST_CONTEXT_TEXT"], !text.isEmpty { c.visibleText = text; c.visibleTextSource = "AX" }   // текст окна
            m.attachContext(c)
        }
        if env["PIA_TEST_DROP"] == "1" { dropTest(m, env["PIA_TEST_ATTACH"] ?? "") }
        if env["PIA_TEST_CYCLE"] == "1" { cycle(app) }
        if let d = env["PIA_TEST_DRAFT"] { m.draft = d }
        if env["PIA_TEST_HELPERS"] == "1" { m.helpersExpanded = true }
        if env["PIA_TEST_SEND"] == "1" {
            guard m.client.configPath != NSHomeDirectory() + "/.pi-agent/server.json" else {
                Log.write("PIA_TEST_SEND пропущен: это настоящая служба")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { m.send() }
        }
    }

    /// Проверка обработчика drop на частных NSPasteboard (без мыши): file-url, tiff-данные, file promise.
    final class Promise: NSObject, NSFilePromiseProviderDelegate {
        let src: URL
        init(_ s: URL) { src = s }
        func filePromiseProvider(_ p: NSFilePromiseProvider, fileNameForType t: String) -> String { "promise-test.png" }
        let q = OperationQueue()
        func operationQueue(for p: NSFilePromiseProvider) -> OperationQueue { q }
        func filePromiseProvider(_ p: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
            Log.write("DROP-ТЕСТ provider: пишу \(url.path)")
            do { try? FileManager.default.removeItem(at: url); try FileManager.default.copyItem(at: src, to: url); completionHandler(nil) } catch { completionHandler(error) }
        }
    }
    static var keep: [Any] = []
    static func dropTest(_ m: ChatModel, _ img: String) {
        let src = URL(fileURLWithPath: img.isEmpty ? "/tmp/pia-drop-src.png" : img)
        Log.write("DROP-ТЕСТ: старт, вложений=\(m.attachments.count)")
        let a = NSPasteboard(name: NSPasteboard.Name("pia-test-drop-url")); a.clearContents(); a.writeObjects([src as NSURL])
        Log.write("DROP-ТЕСТ file-url: типы=[\(PiaDrop.typeList(a))] принимаю=\(PiaDrop.canAccept(a)) → \(PiaDrop.handle(a)), вложений=\(m.attachments.count)")
        let b = NSPasteboard(name: NSPasteboard.Name("pia-test-drop-data")); b.clearContents()
        if let t = NSImage(contentsOf: src)?.tiffRepresentation { b.setData(t, forType: .tiff) }
        Log.write("DROP-ТЕСТ tiff: типы=[\(PiaDrop.typeList(b))] принимаю=\(PiaDrop.canAccept(b)) → \(PiaDrop.handle(b)), вложений=\(m.attachments.count)")
        let d = Promise(src); keep.append(d)
        let prov = NSFilePromiseProvider(fileType: "public.png", delegate: d); keep.append(prov)
        let c = NSPasteboard(name: NSPasteboard.Name("pia-test-drop-promise")); c.clearContents(); c.writeObjects([prov])
        Log.write("DROP-ТЕСТ promise: типы=[\(PiaDrop.typeList(c))] принимаю=\(PiaDrop.canAccept(c))")
        PiaDrop.handle(c) { n in Log.write("DROP-ТЕСТ promise готово, вложений=\(n)") }
    }

    /// Светофор: есть ли видимые стандартные кнопки окна (у borderless их нет вовсе).
    static func traffic(_ w: NSWindow) -> String {
        let bs = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].map { w.standardWindowButton($0) }
        let visible = bs.compactMap { $0 }.filter { !$0.isHidden }.count
        return "кнопок=\(bs.compactMap { $0 }.count) видимых=\(visible) titled=\(w.styleMask.contains(.titled)) key=\(w.isKeyWindow) canKey=\(w.canBecomeKey)"
    }

    static func cycle(_ app: AppDelegate) {
        let p = app.panel!
        Log.write("тест-цикл: старт \(traffic(p))")
        let steps: [(Double, String, () -> Void)] = [
            (1.0, "скрыто", { app.hide(reason: "тест-цикл") }),
            (1.6, "показано", { app.show(source: "тест-цикл") }),
            (2.4, "размер +120×80", { var f = p.frame; f.size.width += 120; f.size.height += 80; p.setFrame(f, display: true) }),
            (3.0, "resignKey", { p.resignKey() }),
            (3.4, "makeKey", { p.makeKey() }),
            (4.0, "размер обратно", { var f = p.frame; f.size.width -= 120; f.size.height -= 80; p.setFrame(f, display: true) }),
        ]
        for (t, name, f) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { f(); Log.write("тест-цикл: \(name) — \(traffic(p))") }
        }
    }
}
