import AppKit
import CoreGraphics
import ImageIO
import Foundation
import ScreenCaptureKit

/// Скриншот активного окна через ScreenCaptureKit (macOS 14+).
/// Без права «Запись экрана» ничего не снимает и не спрашивает — возвращает nil.
enum ContextScreenshot {
    /// Есть ли право «Запись экрана» (без запроса).
    static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

    /// Окна приложения на экране (обычный слой 0): сначала самое большое по площади (у Yab поверх главного окна лежит
    /// узкая полоса 1440×68 — она не должна выигрывать только за счёт порядка), при равенстве — то, что выше.
    static func frontWindows(pid: pid_t) -> [(id: CGWindowID, title: String?)] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        var out: [(id: CGWindowID, title: String?, area: Double)] = []
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let id = w[kCGWindowNumber as String] as? Int,
                  let b = w[kCGWindowBounds as String] as? [String: Any],
                  let wd = b["Width"] as? Double, let ht = b["Height"] as? Double, wd >= 40, ht >= 40 else { continue }
            out.append((CGWindowID(id), w[kCGWindowName as String] as? String, wd * ht))
        }
        let ordered = out.enumerated().sorted { l, r in
            l.element.area != r.element.area ? l.element.area > r.element.area : l.offset < r.offset
        }
        return ordered.map { ($0.element.id, $0.element.title) }
    }

    /// Заголовок переднего окна из CGWindowList (запасной путь; нужен «Запись экрана»).
    static func frontWindowTitle(pid: pid_t) -> String? {
        frontWindows(pid: pid).first.flatMap { $0.title }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Самое верхнее видимое обычное окно чужого приложения (сверху вниз; слой 0, не своё, не Dock/меню/оверлеи).
    static func topWindowBelow(excludingPid own: pid_t) -> (app: ContextCapture.AppInfo, target: WindowTarget)? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let skipOwners: Set<String> = ["Dock", "Window Server", "SystemUIServer", "Control Center", "Notification Center",
                                       "Центр управления", "Центр уведомлений", "Spotlight", "loginwindow"]
        for w in list {
            guard let pid = (w[kCGWindowOwnerPID as String] as? Int).map(pid_t.init), pid != own,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let id = w[kCGWindowNumber as String] as? Int,
                  let b = w[kCGWindowBounds as String] as? [String: Any],
                  let x = b["X"] as? Double, let y = b["Y"] as? Double,
                  let wd = b["Width"] as? Double, let ht = b["Height"] as? Double, wd >= 120, ht >= 120 else { continue }
            if let o = w[kCGWindowOwnerName as String] as? String, skipOwners.contains(o) { continue }
            guard let ra = NSRunningApplication(processIdentifier: pid), ra.activationPolicy == .regular else { continue }
            let info = ContextCapture.AppInfo(pid: pid, name: ra.localizedName ?? ra.bundleIdentifier ?? "?",
                                              bundleId: ra.bundleIdentifier ?? "")
            // у приложения может быть несколько окон (панели, полосы): берём самое большое из подходящих
            var best = (id: id, x: x, y: y, wd: wd, ht: ht, title: w[kCGWindowName as String] as? String)
            for o in list {
                guard (o[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid, (o[kCGWindowLayer as String] as? Int) == 0,
                      (o[kCGWindowAlpha as String] as? Double ?? 1) > 0.05, let oid = o[kCGWindowNumber as String] as? Int,
                      let ob = o[kCGWindowBounds as String] as? [String: Any],
                      let ox = ob["X"] as? Double, let oy = ob["Y"] as? Double,
                      let ow = ob["Width"] as? Double, let oh = ob["Height"] as? Double, ow >= 120, oh >= 120,
                      ow * oh > best.wd * best.ht else { continue }
                best = (oid, ox, oy, ow, oh, o[kCGWindowName as String] as? String)
            }
            return (info, WindowTarget(windowID: CGWindowID(best.id), bounds: CGRect(x: best.x, y: best.y, width: best.wd, height: best.ht), title: best.title))
        }
        return nil
    }

    /// Снять переднее окно приложения и сохранить (поля обрезаны, ≤ 800 px, PNG или JPEG); вернуть путь или nil.
    static func capture(pid: pid_t, windowID: CGWindowID? = nil) async -> String? {
        guard hasScreenRecording else { return nil }
        guard #available(macOS 14.0, *) else { return nil }
        let ids = windowID.map { [$0] } ?? frontWindows(pid: pid).map(\.id)
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let window = ids.lazy.compactMap { id in content.windows.first { $0.windowID == id } }.first
                ?? content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.isOnScreen && $0.frame.width >= 40 && $0.frame.height >= 40 }
                    .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
            guard let window else { return nil }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            let rect = filter.contentRect
            // Снимаем в родном разрешении (Retina) — так уменьшение даёт чёткий текст; потом save() ужмёт до maxSide.
            let cap: CGFloat = 4096
            var w = rect.width * scale, h = rect.height * scale
            let k = min(1, cap / max(w, h, 1))
            w *= k; h *= k
            config.width = max(1, Int(w))
            config.height = max(1, Int(h))
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return save(image)
        } catch {
            return nil
        }
    }

    /// Длинная сторона сохраняемого снимка (px). 800 px — ~550 токенов у модели, текст ещё читается
    /// (поля вокруг контента сперва обрезаются, так что масштаб у текста лучше, чем у всего окна).
    static let maxSide = 800
    /// PNG больше этого — сохраняем JPEG 0.85 (.jpg); служба и чат принимают оба.
    static let pngLimit = 300_000

    // MARK: Обрезка однотонных полей

    /// Отступ, оставляемый вокруг контента после обрезки (px исходного снимка).
    static let trimPadding = 12
    /// Сколько максимум можно срезать по каждой оси (доля исходной ширины/высоты, суммарно с двух сторон).
    static let trimMaxFraction = 0.4
    /// Порог отличия канала от «цвета линии» (0…255) и доля пикселей-выбросов, при которых линия ещё однотонная.
    static let trimTolerance = 14
    static let trimOutliers = 0.004

    /// Прямоугольник без однотонных полей по краям (в координатах CGImage: начало сверху слева).
    /// Линия (столбец/строка) однотонная, если ≥ 99.6 % её непрозрачных пикселей отличаются от её медианного цвета
    /// не больше чем на trimTolerance (прозрачные скруглённые углы пропускаются, рамка окна — сама однотонная линия; одна строка текста у края — уже не однотонная).
    static func contentRect(_ image: CGImage) -> CGRect {
        let w = image.width, h = image.height
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        guard w >= 64, h >= 64 else { return full }
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bpr = w * 4
        var buf = [UInt8](repeating: 0, count: bpr * h)
        let ok: Bool = buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                                      space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return full }
        // строки буфера идут сверху вниз (CGContext с данными: первая строка памяти — верх картинки)
        /// Цвет линии, если она однотонная (пиксели px(i) для i в range; прозрачные — углы окна — пропускаем), иначе nil.
        /// Полностью прозрачная линия — (-1, -1, -1).
        func uniform(_ range: Range<Int>, _ px: (Int) -> Int) -> (Int, Int, Int)? {
            // концы линии (скруглённые углы окна и страницы внутри рамки) не смотрим
            let skip = min(40, max(8, range.count / 40))
            let range = range.count > 4 * skip ? (range.lowerBound + skip)..<(range.upperBound - skip) : range
            let count = range.count
            let step = max(1, count / 700)
            var rs: [UInt8] = [], gs: [UInt8] = [], bs: [UInt8] = []
            rs.reserveCapacity(count / step + 1); gs.reserveCapacity(count / step + 1); bs.reserveCapacity(count / step + 1)
            var i = range.lowerBound
            while i < range.upperBound {
                let o = px(i)
                if buf[o + 3] >= 200 { rs.append(buf[o]); gs.append(buf[o + 1]); bs.append(buf[o + 2]) }
                i += step
            }
            if rs.count < 8 { return (-1, -1, -1) }   // почти вся линия прозрачная — край окна
            let mr = Int(rs.sorted()[rs.count / 2]), mg = Int(gs.sorted()[gs.count / 2]), mb = Int(bs.sorted()[bs.count / 2])
            var bad = 0
            let allowed = Int(Double(rs.count) * trimOutliers)
            for k in 0..<rs.count {
                if abs(Int(rs[k]) - mr) > trimTolerance || abs(Int(gs[k]) - mg) > trimTolerance || abs(Int(bs[k]) - mb) > trimTolerance {
                    bad += 1
                    if bad > allowed { return nil }
                }
            }
            return (mr, mg, mb)
        }
        // Рамка окна (первые frameZone px от края) может быть другого цвета, чем поле; дальше поле должно
        // оставаться того же цвета (плавно меняться можно), иначе это уже контент (сплошной баннер, видео).
        let frameZone = max(32, min(w, h) / 60)
        func near(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Bool {
            a.0 < 0 || b.0 < 0 || (abs(a.0 - b.0) <= trimTolerance && abs(a.1 - b.1) <= trimTolerance && abs(a.2 - b.2) <= trimTolerance)
        }
        /// Сдвигать край, пока линии однотонные и (за пределами рамки) того же цвета.
        func advance(_ start: Int, _ dir: Int, _ edge: Int, _ last: inout (Int, Int, Int)?,
                     _ ok: (Int) -> Bool, _ line: (Int) -> (Int, Int, Int)?) -> Int {
            var pos = start
            while ok(pos), let c = line(pos) {
                if let l = last, abs(pos - edge) >= frameZone, !near(c, l) { break }
                last = c
                pos += dir
            }
            return pos
        }

        // Срезаем однотонные строки/столбцы по кругу, каждый раз только внутри уже найденной рамки:
        // так рамка окна (серая полоса по периметру) не мешает найти поля внутри неё.
        var left = 0, right = w, top = 0, bottom = h
        // цвет поля у каждой стороны (запоминается между кругами)
        var cTop: (Int, Int, Int)?, cBottom: (Int, Int, Int)?, cLeft: (Int, Int, Int)?, cRight: (Int, Int, Int)?
        for _ in 0..<4 {
            let before = (left, right, top, bottom)
            let (l0, r0) = (left, right)
            top = advance(top, 1, 0, &cTop, { y in bottom - y > 16 && y < h / 2 }, { y in uniform(l0..<r0) { x in y * bpr + x * 4 } })
            let t0 = top
            bottom = advance(bottom - 1, -1, h - 1, &cBottom, { y in y - t0 > 16 && y > h / 2 }, { y in uniform(l0..<r0) { x in y * bpr + x * 4 } }) + 1
            let b0 = bottom
            left = advance(left, 1, 0, &cLeft, { x in r0 - x > 16 && x < w / 2 }, { x in uniform(t0..<b0) { y in y * bpr + x * 4 } })
            let l1 = left
            right = advance(right - 1, -1, w - 1, &cRight, { x in x - l1 > 16 && x > w / 2 }, { x in uniform(t0..<b0) { y in y * bpr + x * 4 } }) + 1
            if before == (left, right, top, bottom) { break }
        }
        if ProcessInfo.processInfo.environment["PIA_TRIM_DEBUG"] != nil {
            print("trim: края \(left)…\(right) × \(top)…\(bottom) из \(w)×\(h)")
        }
        // дошли до середины — картинка пустая/однотонная: не трогаем
        if right - left <= 16 || bottom - top <= 16 || top >= h / 2 || left >= w / 2 || bottom <= h / 2 + 1 || right <= w / 2 + 1 {
            return full
        }

        // запас и ограничение: суммарно не больше 40 % по оси (лишнее урезаем пропорционально сторонам)
        func limit(_ lo: Int, _ hi: Int, _ size: Int) -> (Int, Int) {
            var a = max(0, lo - trimPadding), b = max(0, size - hi - trimPadding)
            let cap = Int(Double(size) * trimMaxFraction)
            if a + b > cap {
                let k = Double(cap) / Double(a + b)
                a = Int(Double(a) * k); b = Int(Double(b) * k)
            }
            // срезать меньше 2 % — не стоит
            if a + b < size / 50 { return (0, size) }
            return (a, size - b)
        }
        let (x0, x1) = limit(left, right, w)
        let (y0, y1) = limit(top, bottom, h)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Обрезать однотонные поля (см. contentRect).
    static func trimmed(_ image: CGImage) -> CGImage {
        let r = contentRect(image)
        if r.width >= CGFloat(image.width), r.height >= CGFloat(image.height) { return image }
        return image.cropping(to: r) ?? image
    }

    /// Уменьшить так, чтобы длинная сторона была ≤ maxSide (меньшие не увеличиваем); качественная интерполяция.
    static func downscaled(_ image: CGImage, maxSide: Int = maxSide) -> CGImage {
        let w = image.width, h = image.height
        let long = max(w, h)
        guard long > maxSide, long > 0 else { return image }
        let k = Double(maxSide) / Double(long)
        let nw = max(1, Int((Double(w) * k).rounded())), nh = max(1, Int((Double(h) * k).rounded()))
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        return ctx.makeImage() ?? image
    }

    /// PNG или JPEG (с белым фоном вместо прозрачных углов окна) через ImageIO.
    static func encode(_ image: CGImage, jpeg: Bool) -> Data? {
        let data = NSMutableData()
        let type = (jpeg ? "public.jpeg" : "public.png") as CFString
        guard let dest = CGImageDestinationCreateWithData(data, type, 1, nil) else { return nil }
        var props: [CFString: Any] = [:]
        if jpeg {
            props[kCGImageDestinationLossyCompressionQuality] = 0.85
            props[kCGImageDestinationBackgroundColor] = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    static func save(_ original: CGImage) -> String? {
        let dir = ContextCapture.imagesDirectory
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let image = downscaled(trimmed(original))
        var ext = "png"
        guard var data = encode(image, jpeg: false) else { return nil }
        if data.count > pngLimit, let jpg = encode(image, jpeg: true), jpg.count < data.count {
            data = jpg; ext = "jpg"
        }
        let url = dir.appendingPathComponent("context-\(f.string(from: Date())).\(ext)")
        do {
            try data.write(to: url, options: .atomic)
            return url.path
        } catch { return nil }
    }
}
