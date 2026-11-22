import AppKit
import UniformTypeIdentifiers

// Приём перетаскивания (CleanShot X и др.): file-url, данные картинки (png/tiff/jpeg/heic), file promise.
// Принимает вся карточка: PiaBackgroundView (корень видимой карточки) и поле ввода; всё пишется в app.log.
@MainActor
enum PiaDrop {
    static let promiseTypes: [NSPasteboard.PasteboardType] = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    static let types: [NSPasteboard.PasteboardType] = {
        var t: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff, NSPasteboard.PasteboardType("public.jpeg"),
                                               NSPasteboard.PasteboardType("public.heic"), NSPasteboard.PasteboardType("NSFilenamesPboardType")]
        t += promiseTypes
        return t
    }()
    static weak var model: ChatModel?
    /// идёт перетаскивание над окном — окно не прячем
    static var active = false
    static var lastEnd = Date.distantPast
    static var recentlyDragging: Bool { active || Date().timeIntervalSince(lastEnd) < 2 }

    static func typeList(_ pb: NSPasteboard) -> String { (pb.types ?? []).map(\.rawValue).joined(separator: ", ") }

    static func canAccept(_ pb: NSPasteboard) -> Bool {
        guard let ts = pb.types else { return false }
        return ts.contains { types.contains($0) }
    }

    static func entered(_ info: NSDraggingInfo, where w: String) -> NSDragOperation {
        active = true
        let pb = info.draggingPasteboard
        Log.write("drag enter (\(w)): типы=[\(typeList(pb))] принимаю=\(canAccept(pb))")
        return canAccept(pb) ? .copy : []
    }

    static func exited(where w: String) {
        active = false; lastEnd = Date()
        Log.write("drag exit (\(w))")
    }

    static func drop(_ info: NSDraggingInfo, where w: String) -> Bool {
        active = false; lastEnd = Date()
        Log.write("drop (\(w)): типы=[\(typeList(info.draggingPasteboard))]")
        return handle(info.draggingPasteboard)
    }

    /// Общий обработчик: используется и настоящим drop, и проверкой на тестовом NSPasteboard.
    @discardableResult
    static func handle(_ pb: NSPasteboard, done: ((Int) -> Void)? = nil) -> Bool {
        guard let model else { Log.write("drop: нет модели"); return false }
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if urls.contains(where: ChatModel.isImageFile) {
            let ok = model.attachFiles(urls)
            Log.write("drop: file-url → \(ok ? "прикреплено" : "не картинка")")
            done?(model.attachments.count)
            return ok
        }
        if let rs = pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver],
           rs.contains(where: { $0.fileTypes.contains { UTType($0)?.conforms(to: .image) == true } }) {
            let dir = URL(fileURLWithPath: ChatModel.imagesDir, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            Log.write("drop: file promise ×\(rs.count), типы файлов=\(rs.flatMap(\.fileTypes))")
            for r in rs {
                r.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: .main) { url, err in
                    MainActor.assumeIsolated {
                        if let err { Log.write("drop: promise ошибка: \(err.localizedDescription)"); done?(model.attachments.count); return }
                        let ok = model.attachReceived(url)
                        Log.write("drop: promise → \(url.lastPathComponent) \(ok ? "прикреплено" : "не картинка")")
                        done?(model.attachments.count)
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { Log.write("drop: promise — через 8 с вложений=\(model.attachments.count)") }
            return true
        }
        let ok = model.attachFromPasteboard(pb)
        Log.write("drop: данные картинки → \(ok ? "прикреплено" : "ничего подходящего")")
        done?(model.attachments.count)
        return ok
    }
}
