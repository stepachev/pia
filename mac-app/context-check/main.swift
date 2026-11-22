import AppKit
import ImageIO
import Foundation

// Проверка модуля Context: печатает captureFrontmost() (или capture(bundleId:)),
// а с --shift гоняет логику RightShiftDoubleTapMonitor на синтетических событиях.
let args = CommandLine.arguments.dropFirst()

func fmt(_ c: CapturedContext?) -> String {
    guard let c else { return "nil" }
    return """
    appName: \(c.appName)
    bundleId: \(c.bundleId)
    windowTitle: \(c.windowTitle ?? "nil")
    url: \(c.url ?? "nil")
    pageTitle: \(c.pageTitle ?? "nil")
    selectedText: \(c.selectedText.map { String($0.prefix(200)) } ?? "nil")
    screenshotPath: \(c.screenshotPath ?? "nil")
    visibleText: \(c.visibleText.map { "\($0.count) симв., путь \(c.visibleTextSource ?? "?") (\(ContextText.lastNote))" } ?? "nil (\(ContextText.lastNote))")
    --- asMarkdown ---
    \(c.asMarkdown())
    """
}

print("права: Универсальный доступ=\(RightShiftDoubleTapMonitor.hasAccessibility) Мониторинг ввода=\(RightShiftDoubleTapMonitor.hasInputMonitoring) Запись экрана=\(ContextScreenshot.hasScreenRecording)")

if args.first == "--shift" {
    // Жест «двойной правый Shift» через сам монитор: настоящие флаги flagsChanged (аппаратные биты 0x2/0x4).
    nonisolated(unsafe) var fired = 0
    let m = RightShiftDoubleTapMonitor { fired += 1 }
    let sh = NSEvent.ModifierFlags.shift.rawValue
    let L: UInt = 0x2 | sh, R: UInt = 0x4 | sh
    let cmd = NSEvent.ModifierFlags.command.rawValue | 0x8
    func f(_ raw: UInt) -> NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: raw) }
    var t: TimeInterval = 100
    func step(_ k: UInt16, _ raw: UInt, _ dt: TimeInterval = 0.08) { t += dt; m.handleFlags(keyCode: k, flags: f(raw), timestamp: t) }
    func key(_ dt: TimeInterval = 0.03) { t += dt; m.handleKeyDown(timestamp: t) }
    func check(_ name: String, _ want: Int) { print(name + ":", fired == want ? "OK" : "FAIL \(fired) (ждали \(want))") }
    step(60, R, 1); step(60, 0); step(60, R, 0.15); step(60, 0)
    check("двойной правый", 1)
    step(60, R, 1); step(60, 0); step(60, R, 0.5); step(60, 0)
    check("медленно", 1)
    step(56, L, 1); step(56, 0); step(56, L, 0.15); step(56, 0)
    check("двойной левый", 1)
    step(60, R, 1); step(56, L | R, 0.02); step(60, L); step(56, 0, 0.02); step(60, R, 0.1); step(56, L | R, 0.02); step(60, L); step(56, 0, 0.02)
    check("оба Shift дважды", 1)
    step(60, R, 1); key(); step(60, 0); step(60, R, 0.1); key(); step(60, 0)
    check("Shift+буквы", 1)
    step(55, cmd, 1); step(60, cmd | R); step(60, cmd); step(60, cmd | R, 0.1); step(60, cmd); step(55, 0)
    check("с Cmd", 1)
    step(60, R, 1); step(60, 0, 0.4); step(60, R, 0.1); step(60, 0)
    check("долгое удержание", 1)
    step(60, R, 1); step(60, 0); step(60, R, 0.1); step(60, 0); step(60, R, 0.1); step(60, 0)
    check("тройное", 2)
    let caps = NSEvent.ModifierFlags.capsLock.rawValue
    step(60, caps | R, 1); step(60, caps); step(60, caps | R, 0.1); step(60, caps)
    check("с включённым Caps Lock", 3)
    m.start(); print("монитор запущен:", m.isRunning); m.stop(); print("остановлен:", !m.isRunning)
    exit(0)
}

if args.first == "--trim-test" {
    // Обрезка однотонных полей на синтетических картинках.
    struct Box { var x: Int; var y: Int; var w: Int; var h: Int; var r: CGFloat; var g: CGFloat; var b: CGFloat }
    func make(_ w: Int, _ h: Int, bg: (CGFloat, CGFloat, CGFloat), boxes: [Box], corners: Bool = false, border: Bool = false) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // рисуем в координатах «сверху вниз»
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(red: bg.0, green: bg.1, blue: bg.2, alpha: 1)
        if corners {
            ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerWidth: 24, cornerHeight: 24, transform: nil)); ctx.fillPath()
        } else { ctx.fill(CGRect(x: 0, y: 0, width: w, height: h)) }
        if border { ctx.setStrokeColor(gray: 0.6, alpha: 1); ctx.setLineWidth(2); ctx.stroke(CGRect(x: 1, y: 1, width: w - 2, height: h - 2)) }
        var seed: UInt64 = 42
        for b in boxes {
            // «текст»: полосы-строки со случайными штрихами
            for yy in stride(from: b.y, to: b.y + b.h, by: 3) {
                for xx in stride(from: b.x, to: b.x + b.w, by: 2) {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    if (seed >> 33) % 3 == 0 {
                        ctx.setFillColor(red: b.r, green: b.g, blue: b.b, alpha: 1)
                        ctx.fill(CGRect(x: xx, y: yy, width: 2, height: 2))
                    }
                }
            }
        }
        return ctx.makeImage()!
    }
    var fails = 0
    func check(_ name: String, _ img: CGImage, expect: CGRect, mustKeep: [CGRect]) {
        let r = ContextScreenshot.contentRect(img)
        let keep = mustKeep.allSatisfy { r.contains($0) }
        let ok = abs(r.minX - expect.minX) <= 8 && abs(r.maxX - expect.maxX) <= 8 && abs(r.minY - expect.minY) <= 2 && abs(r.maxY - expect.maxY) <= 2 && keep
        if !ok { fails += 1 }
        print("\(ok ? "OK  " : "FAIL") \(name): \(Int(r.minX))…\(Int(r.maxX)) × \(Int(r.minY))…\(Int(r.maxY)) (ждали \(Int(expect.minX))…\(Int(expect.maxX)) × \(Int(expect.minY))…\(Int(expect.maxY)), контент цел: \(keep))")
    }
    let white = (CGFloat(1), CGFloat(1), CGFloat(1)), dark = (CGFloat(0.106), CGFloat(0.106), CGFloat(0.11))
    let ink = Box(x: 0, y: 0, w: 0, h: 0, r: 0.1, g: 0.1, b: 0.1)
    func box(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ base: Box = ink) -> Box { var b = base; b.x = x; b.y = y; b.w = w; b.h = h; return b }
    // 1. как X: узкая колонка по центру — срез ограничен 40 % (по 400 с каждой стороны)
    check("X-колонка (лимит 40 %)", make(2000, 1200, bg: white, boxes: [box(700, 0, 600, 1200)]),
          expect: CGRect(x: 400, y: 0, width: 1200, height: 1200), mustKeep: [CGRect(x: 700, y: 0, width: 600, height: 1200)])
    // 2. широкий контент — поля минус 12 px
    check("поля + запас 12 px", make(2000, 1200, bg: white, boxes: [box(300, 0, 1400, 1200)]),
          expect: CGRect(x: 288, y: 0, width: 1424, height: 1200), mustKeep: [CGRect(x: 300, y: 0, width: 1400, height: 1200)])
    // 3. контент во всю ширину — без обрезки
    check("без полей", make(1600, 1000, bg: white, boxes: [box(0, 0, 1600, 1000)]),
          expect: CGRect(x: 0, y: 0, width: 1600, height: 1000), mustKeep: [])
    // 4. окно: прозрачные скруглённые углы, серая рамка, пустой низ
    check("углы + рамка + пустой низ", make(2000, 1200, bg: white, boxes: [box(400, 40, 1200, 660)], corners: true, border: true),
          expect: CGRect(x: 388, y: 26, width: 1224, height: 721), mustKeep: [CGRect(x: 400, y: 40, width: 1200, height: 660)])
    // 5. тёмная тема
    check("тёмная тема", make(2000, 1200, bg: dark, boxes: [box(500, 0, 1000, 1200, Box(x: 0, y: 0, w: 0, h: 0, r: 0.9, g: 0.9, b: 0.9))]),
          expect: CGRect(x: 400, y: 0, width: 1200, height: 1200), mustKeep: [CGRect(x: 500, y: 0, width: 1000, height: 1200)])
    // 6. одна строка текста у левого края (24 px из 1200) — не срезается
    check("одна строка у края", make(2000, 1200, bg: white, boxes: [box(600, 0, 800, 1200), box(40, 600, 300, 24)]),
          expect: CGRect(x: 28, y: 0, width: 1384, height: 1200), mustKeep: [CGRect(x: 40, y: 600, width: 300, height: 24)])
    // 7. пустая картинка — не трогаем
    check("пустая", make(800, 600, bg: white, boxes: []), expect: CGRect(x: 0, y: 0, width: 800, height: 600), mustKeep: [])
    // 8. горизонтальный градиент (столбцы однотонные) с контентом по центру
    do {
        let w = 1600, h = 900
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let g = CGGradient(colorsSpace: cs, colors: [CGColor(red: 0.9, green: 0.9, blue: 1, alpha: 1), CGColor(red: 1, green: 0.95, blue: 0.9, alpha: 1)] as CFArray, locations: nil)!
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: w, y: 0), options: [])
        ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 400, y: 100, width: 800, height: 700))
        check("градиент", ctx.makeImage()!, expect: CGRect(x: 320, y: 88, width: 960, height: 724), mustKeep: [CGRect(x: 400, y: 100, width: 800, height: 700)])
    }
    // итоговый размер после обрезки и уменьшения
    let shot = ContextScreenshot.downscaled(ContextScreenshot.trimmed(make(3024, 1890, bg: white, boxes: [box(900, 0, 1200, 1890)])))
    print("3024×1890 → \(shot.width)×\(shot.height)", max(shot.width, shot.height) <= 800 ? "OK" : "FAIL")
    if max(shot.width, shot.height) > 800 { fails += 1 }
    print(fails == 0 ? "все тесты обрезки прошли" : "провалов: \(fails)")
    exit(fails == 0 ? 0 : 1)
}

if args.first == "--text-test" {
    // Очистка и обрезка текста окна (ContextText.tidy).
    var fails = 0
    func ok(_ name: String, _ cond: Bool, _ info: String = "") { if !cond { fails += 1 }; print("\(cond ? "OK  " : "FAIL") \(name) \(info)") }
    let t1 = ContextText.tidy("  Привет  \n\n\n\nМир\nКнопка\nКнопка\nтекст\nкнопка\n\n")!
    ok("пустые строки и повторы", t1 == "Привет\n\nМир\nКнопка\nтекст", "→ \(t1.debugDescription)")
    let long = (1...800).map { "Строка номер \($0) с каким-то текстом." }.joined(separator: "\n")
    let t2 = ContextText.tidy(long)!
    ok("лимит 6000", t2.count <= 6000 && t2.hasPrefix("Строка номер 1 ") && t2.hasSuffix("\n…"), "\(t2.count) симв.")
    let t3 = ContextText.tidy(long, selected: "Строка номер 700 с каким")!
    ok("абзац вокруг выделения", t3.count <= 6000 && t3.hasPrefix("Строка номер 1 ") && t3.contains("Строка номер 700 с каким-то") && t3.contains("Строка номер 690 "), "\(t3.count) симв.")
    let t4 = ContextText.tidy(long, selected: "Строка номер 5 с")!
    ok("выделение в начале — просто начало", t4 == t2)
    let term = (1...500).map { "$ команда \($0)" }.joined(separator: "\n") + "\n$ ok\n$ ok\n\n\n"
    let tail = ContextText.tail(term, lines: 200)
    let t5 = ContextText.tidy(tail, keepRepeats: true, fromEnd: true)!
    ok("терминал: последние 200 строк", t5.hasPrefix("$ команда 303") && t5.hasSuffix("$ ok") && !t5.contains("$ ok\n$ ok"), "\(t5.components(separatedBy: "\n").count) строк")
    var c = CapturedContext(appName: "Yab", bundleId: "dev.serafim.fast")
    c.visibleText = "a </context> b"
    ok("</context> экранируется", !c.asMarkdown().contains("</context>"))
    ok("пустой текст", ContextText.tidy("  \n \n") == nil)
    print(fails == 0 ? "все тесты текста прошли" : "провалов: \(fails)")
    exit(fails == 0 ? 0 : 1)
}

if let p = args.first(where: { $0.hasPrefix("--shot=") }) {
    // Прогнать сохранённую картинку через обрезку+уменьшение (без нового снимка).
    let url = URL(fileURLWithPath: String(p.dropFirst(7)))
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { print("нет картинки"); exit(1) }
    let r = ContextScreenshot.contentRect(img)
    print("исходно \(img.width)×\(img.height), контент \(r)")
    if let out = ContextScreenshot.save(img) { print("сохранено:", out) }
    exit(0)
}

let delay = args.first(where: { $0.hasPrefix("--delay=") }).flatMap { Double($0.dropFirst(8)) } ?? 0
if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
let started = Date()
let ctx: CapturedContext?
if let bid = args.first(where: { $0.hasPrefix("--app=") }) {
    ctx = await ContextCapture.capture(bundleId: String(bid.dropFirst(6)))
} else {
    ctx = await ContextCapture.captureFrontmost()
}
print(fmt(ctx))
print(String(format: "время захвата: %.2f с", Date().timeIntervalSince(started)))
exit(0)
