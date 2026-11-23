import SwiftUI

// Индикаторы «чем занята pia»: свой спиннер на каждое состояние (как у Gemini).
// Порты лоадеров ldrs (uiball.com/ldrs, MIT): Trio, Dot Pulse, Leapfrog, Dot Stream, Metronome, Newton's Cradle, Momentum, Dot Wave.
// Геометрия и тайминги — из их CSS (размер S, скорость, keyframes, задержки); рисуем Canvas'ом по времени t (сек).
// Цвет — primary × 0.66.

enum Activity: String, CaseIterable {
    case thinking    // думаю                         — Trio
    case writing     // печатает ответ                — Dot Pulse
    case computer    // bash / файлы                  — Leapfrog
    case web         // интернет, страница, браузер   — Dot Stream
    case memory      // вспоминаю / запоминаю         — Metronome
    case helpers     // помощники                     — Newton's Cradle
    case compacting  // сжимаю разговор               — Momentum
    case other       // прочие инструменты            — Dot Wave

    var title: String {
        switch self {
        case .thinking: "думаю"
        case .writing: "пишу ответ"
        case .computer: "работаю на компьютере"
        case .web: "в интернете"
        case .memory: "память"
        case .helpers: "помощники"
        case .compacting: "сжимаю разговор"
        case .other: "работаю"
        }
    }

    /// Из live-состояния службы: имя инструмента (если служба его шлёт), иначе подпись label.
    static func from(tool: String?, label: String?, toolRunning: Bool, text: String?) -> Activity {
        if let t = tool, !t.isEmpty {
            switch t {
            case "web_search", "fetch_page", "browser": return .web
            case "bash", "read", "write", "edit": return .computer
            case "memory_search", "memory_read", "remember", "tool_search": return .memory
            case _ where t.hasPrefix("helper"): return .helpers
            default: return .other
            }
        }
        switch label ?? "" {
        case "сжимаю разговор": return .compacting
        case "ищу в интернете", "читаю страницу", "работаю в браузере": return .web
        case "работаю на компьютере", "читаю файл", "пишу файл": return .computer
        case "вспоминаю", "запоминаю", "ищу нужное умение": return .memory
        case "запускаю помощника", "смотрю, кто работает", "передаю помощнику", "останавливаю помощника": return .helpers
        case "думаю", "": return toolRunning ? .other : ((text ?? "").isEmpty ? .thinking : .writing)
        default: return toolRunning ? .other : .thinking
        }
    }
}

struct ActivityLoader: View {
    var activity: Activity
    var dimmed = false                // «останавливаю» — тот же спиннер, но бледнее
    var dot: CGFloat = 3.2            // диаметр точки (у старого 3×3 было 3)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// «думаю» ↔ «пишу ответ»: три точки Trio перетекают в строку Dot Pulse (и обратно), а не сменяются
    @State private var morph: (from: Activity, at: Date, order: [Int])?
    static let morphSeconds = 0.5

    private static func isTalk(_ a: Activity) -> Bool { a == .thinking || a == .writing }

    var body: some View {
        Group {
            if reduceMotion {
                LoaderShape(activity: activity, dot: dot, t: 0)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 60)) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    if let m = morph, Self.isTalk(activity), ctx.date.timeIntervalSince(m.at) < Self.morphSeconds {
                        let k = ctx.date.timeIntervalSince(m.at) / Self.morphSeconds
                        TalkMorph(dot: dot, t: t, toWriting: activity == .writing, k: k, order: m.order)
                    } else {
                        LoaderShape(activity: activity, dot: dot, t: t)
                    }
                }
            }
        }
        .id(Self.isTalk(activity) ? "talk" : activity.rawValue)   // пара думаю/пишу — один вид, без растворения
        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.6)), removal: .opacity))
        .onChange(of: activity) { old, new in
            guard Self.isTalk(old), Self.isTalk(new) else { morph = nil; return }
            morph = (old, Date(), TalkMorph.order(dot: dot, t: Date().timeIntervalSinceReferenceDate))
        }
        .opacity(dimmed ? 0.4 : 1)
        .frame(width: 30, height: 14, alignment: .leading)
        .contentShape(Rectangle())
        .help(dimmed ? "останавливаю" : activity.title)
        .accessibilityLabel(dimmed ? "останавливаю" : activity.title)
    }
}

/// Кадр перехода Trio ↔ Dot Pulse в рамке 30×14 (выравнивание как у обычных: слева, по центру по высоте).
/// k — доля перехода 0…1; order — какой точке Trio какая точка строки (фиксируется в начале, чтобы пары не менялись на ходу).
struct TalkMorph: View {
    var dot: CGFloat
    var t: Double
    var toWriting: Bool
    var k: Double
    var order: [Int]

    static let box = CGSize(width: 30, height: 14)

    static func trio(dot: CGFloat, t: Double) -> [(CGPoint, CGFloat, Double)] {
        let S = dot / 0.25, dy = (box.height - S) / 2
        var a: [(CGPoint, CGFloat, Double)] = []
        L.draw(.thinking, s: S, t: t) { a.append((CGPoint(x: $0.x, y: $0.y + dy), $1, $2)) }
        return a
    }
    static func pulse(dot: CGFloat, t: Double) -> [(CGPoint, CGFloat, Double)] {
        let S = dot / 0.24, dy = (box.height - S * 0.24) / 2
        var a: [(CGPoint, CGFloat, Double)] = []
        L.draw(.writing, s: S, t: t) { a.append((CGPoint(x: $0.x, y: $0.y + dy), $1, $2)) }
        return a
    }
    /// order[i] — номер точки Trio, которая станет i-й слева точкой строки
    static func order(dot: CGFloat, t: Double) -> [Int] {
        trio(dot: dot, t: t).enumerated().sorted { $0.element.0.x < $1.element.0.x }.map(\.offset)
    }

    var body: some View {
        Canvas { gc, _ in
            let e = { (x: Double) in x * x * (3 - 2 * x) }(min(1, max(0, toWriting ? k : 1 - k)))   // 0 — Trio, 1 — строка
            let tr = Self.trio(dot: dot, t: t), pu = Self.pulse(dot: dot, t: t)
            for i in 0..<3 {
                let a = tr[order.indices.contains(i) ? order[i] : i], b = pu[i]
                let c = CGPoint(x: a.0.x + (b.0.x - a.0.x) * e, y: a.0.y + (b.0.y - a.0.y) * e)
                let d = a.1 + (b.1 - a.1) * e
                gc.fill(Path(ellipseIn: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)), with: .color(.primary))
            }
        }
        .frame(width: Self.box.width, height: Self.box.height)
        .opacity(0.66)
    }
}

/// Один кадр лоадера в момент t. Размер — из диаметра точки (у каждого лоадера своя доля S).
struct LoaderShape: View {
    var activity: Activity
    var dot: CGFloat
    var t: Double

    static let color = Color.primary

    /// Сторона S лоадера в CSS и пропорции рамки (ширина × высота в долях S)
    private var spec: (s: CGFloat, w: CGFloat, h: CGFloat) {
        switch activity {
        case .thinking: (dot / 0.25, 1, 1)
        case .writing: (dot / 0.24, 1, 0.24)
        case .computer: (dot / 0.22, 1, 0.62)
        case .web: (dot / 0.18, 1, 0.18)
        case .memory: (dot / 0.25, 1, 0.63)
        case .helpers: (dot / 0.1275, 1, 0.3)
        case .compacting: (dot / 0.25, 1, 1)
        case .other: (dot / 0.17, 1, 0.5)
        }
    }

    var body: some View {
        let sp = spec
        Canvas { gc, _ in
            var dots: [(CGPoint, CGFloat, Double)] = []   // центр, диаметр, прозрачность
            L.draw(activity, s: sp.s, t: t) { dots.append(($0, $1, $2)) }
            for (c, d, o) in dots where d > 0.05 {
                gc.fill(Path(ellipseIn: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)),
                        with: .color(Self.color.opacity(o)))
            }
        }
        .frame(width: sp.s * sp.w, height: sp.s * sp.h)
        .opacity(0.66)   // общий слой: перекрытые точки не темнеют
    }
}

// MARK: - математика лоадеров (координаты — в рамке хоста ldrs, S = сторона)

enum L {
    typealias Put = (CGPoint, CGFloat, Double) -> Void

    static func draw(_ a: Activity, s S: CGFloat, t: Double, put: Put) {
        switch a {
        case .thinking: trio(S, t, put)
        case .writing: dotPulse(S, t, put)
        case .computer: leapfrog(S, t, put)
        case .web: dotStream(S, t, put)
        case .memory: metronome(S, t, put)
        case .helpers: newtonsCradle(S, t, put)
        case .compacting: momentum(S, t, put)
        case .other: dotWave(S, t, put)
        }
    }

    /// фаза 0..1 с CSS-задержкой (отрицательная задержка = сдвиг вперёд)
    static func phase(_ t: Double, _ speed: Double, delay: Double = 0) -> Double {
        let p = (t - delay) / speed
        return p - floor(p)
    }

    /// Значение по keyframes [(доля, значение, easing к следующему)]
    static func keys(_ p: Double, _ k: [(Double, Double, Bezier)]) -> Double {
        for i in 0..<(k.count - 1) where p <= k[i + 1].0 {
            let (a, va, e) = k[i], (b, vb, _) = k[i + 1]
            let u = b > a ? (p - a) / (b - a) : 1
            return va + (vb - va) * e.y(u)
        }
        return k.last!.1
    }

    static func rot(_ p: CGPoint, around c: CGPoint, deg: Double) -> CGPoint {
        // поворот по часовой (экранные координаты, y вниз) — как CSS rotate
        let r = deg * .pi / 180, dx = p.x - c.x, dy = p.y - c.y
        return CGPoint(x: c.x + dx * cos(r) - dy * sin(r), y: c.y + dx * sin(r) + dy * cos(r))
    }

    // Trio: size 40, speed 1.3. Три точки (25%) на 120°, всё крутится; точки «дышат» к центру на 65% диаметра.
    static func trio(_ S: CGFloat, _ t: Double, _ put: Put) {
        let speed = 1.3, d = S * 0.25, c = CGPoint(x: S / 2, y: S / 2)
        let spin = phase(t, speed) * 360
        let w = keys(phase(t, speed), [(0, 0, .easeInOut), (0.5, 0.65, .easeInOut), (1, 0, .linear)])
        for a in [120.0, -120, 0] {
            let p = CGPoint(x: S / 2, y: d / 2 + d * w)
            put(rot(p, around: c, deg: a + spin), d, 1)
        }
    }

    // Dot Pulse: size 43, speed 1.3. Три точки 24% растут 0→1→0, задержки −0.375/−0.25/−0.125.
    static func dotPulse(_ S: CGFloat, _ t: Double, _ put: Put) {
        let speed = 1.3, d = S * 0.24
        for (i, dl) in [0.375, 0.25, 0.125].enumerated() {
            let k = keys(phase(t, speed, delay: -dl * speed), [(0, 0, .easeInOut), (0.5, 1, .easeInOut), (1, 0, .linear)])
            let x = d / 2 + CGFloat(i) * (S - d) / 2
            put(CGPoint(x: x, y: d / 2), d * k, 1)
        }
    }

    // Leapfrog: size 40, speed 2.5. Точка 22% прыгает дугой (поворот 180° вокруг центра) и съезжает назад; три со сдвигом в 1/3.
    static func leapfrog(_ S: CGFloat, _ t: Double, _ put: Put) {
        let speed = 2.5, d = S * 0.22, cy = S * 0.46
        let c = CGPoint(x: S / 2, y: cy)
        for dl in [0.0, speed / 1.5, speed / 3] {
            let p = phase(t, speed, delay: -dl)
            let r = keys(p, [(0, 0, .ease), (1.0 / 3, 180, .ease), (1, 180, .linear)])
            let x = keys(p, [(0, 0, .ease), (1.0 / 3, 0, .ease), (2.0 / 3, -0.38 * S, .ease), (1, -0.78 * S, .linear)])
            var q = rot(CGPoint(x: d / 2, y: cy), around: c, deg: r)
            q.x += x
            put(q, d, 1)
        }
    }

    // Dot Stream: size 60, speed 2.5. Пять точек 18% плывут слева направо, растут к середине и тают.
    static func dotStream(_ S: CGFloat, _ t: Double, _ put: Put) {
        let speed = 2.5, d = S * 0.18
        for i in 0..<5 {
            let p = phase(t, speed, delay: -Double(i) * 0.2 * speed)
            let x = keys(p, [(0, 0, .linear), (0.5, 0.5 * S, .linear), (1, S, .linear)])
            let k = keys(p, [(0, 0, .linear), (0.5, 1, .linear), (1, 0, .linear)])
            put(CGPoint(x: x, y: d / 2), d * k, 1)
        }
    }

    // Metronome: size 40, speed 1.6. Четыре точки 25% качаются по дуге слева направо и обратно, хвост бледнее и меньше.
    static func metronome(_ S: CGFloat, _ t: Double, _ put: Put) {
        let speed = 1.6, d = S * 0.25, cy = S * 0.53
        let c = CGPoint(x: S / 2, y: cy)
        let tail: [(Double, Double, CGFloat)] = [(0.36, 1, 1), (0.27, 0.8, 0.9), (0.18, 0.6, 0.8), (0.09, 0.4, 0.7)]
        for (dl, op, sc) in tail.reversed() {
            let r = keys(phase(t, speed, delay: -dl * speed), [(0, 0, .linear), (0.15, 0, .linear), (0.5, 180, .linear), (0.65, 180, .linear), (1, 0, .linear)])
            put(rot(CGPoint(x: d / 2, y: cy), around: c, deg: r), d * sc, op)
        }
    }

    // Newton's Cradle: size 78, speed 1.4. Четыре шарика 12.75% на подвесах; крайние по очереди отлетают на 70°.
    static func newtonsCradle(_ S: CGFloat, _ t: Double, _ put: Put) {
        let speed = 1.4, d = S * 0.1275, len = S * 0.255
        let pivotY = S * -0.021, left = S * 0.245
        let p = phase(t, speed)
        for i in 0..<4 {
            var a = 0.0
            if i == 0 { a = keys(p, [(0, 0, .easeOut), (0.25, 70, .easeIn), (0.5, 0, .linear), (1, 0, .linear)]) }
            if i == 3 { a = keys(p, [(0, 0, .linear), (0.5, 0, .easeOut), (0.75, -70, .easeIn), (1, 0, .linear)]) }
            let pivot = CGPoint(x: left + (CGFloat(i) + 0.5) * d, y: pivotY)
            put(rot(CGPoint(x: pivot.x, y: pivot.y + len), around: pivot, deg: a), d, 1)
        }
    }

    // Momentum: size 40, speed 1.1. Две точки 25% расходятся и сходятся (период ×1.25), всё вращается.
    static func momentum(_ S: CGFloat, _ t: Double, _ put: Put) {
        let speed = 1.1, d = S * 0.25, c = CGPoint(x: S / 2, y: S / 2)
        let spin = phase(t, speed) * 360
        let p = phase(t, speed * 1.25)
        let dx = keys(p, [(0, 0, .easeInOut), (0.5, 0.2 * S, .easeInOut), (1, 0, .linear)])
        let sc = keys(p, [(0, 1, .easeInOut), (0.5, 1.1, .easeInOut), (1, 1, .linear)])
        put(rot(CGPoint(x: 0.325 * S - dx, y: S / 2), around: c, deg: spin), d * sc, 1)
        put(rot(CGPoint(x: 0.675 * S + dx, y: S / 2), around: c, deg: spin), d * sc, 1)
    }

    // Dot Wave: size 47, speed 1. Четыре точки 17% по очереди подпрыгивают на два диаметра.
    static func dotWave(_ S: CGFloat, _ t: Double, _ put: Put) {
        let speed = 1.0, d = S * 0.17, h = S * 0.5
        for (i, dl) in [0.45, 0.3, 0.15, 0].enumerated() {
            let y = keys(phase(t, speed, delay: -dl * speed), [(0, 0, .easeInOut), (0.5, -2 * d, .easeInOut), (1, 0, .linear)])
            let x = d / 2 + CGFloat(i) * (S - d) / 3
            put(CGPoint(x: x, y: h - d / 2 + y), d, 1)
        }
    }
}

/// CSS cubic-bezier (x1, y1, x2, y2)
struct Bezier {
    let x1, y1, x2, y2: Double
    static let linear = Bezier(x1: 0, y1: 0, x2: 1, y2: 1)
    static let ease = Bezier(x1: 0.25, y1: 0.1, x2: 0.25, y2: 1)
    static let easeIn = Bezier(x1: 0.42, y1: 0, x2: 1, y2: 1)
    static let easeOut = Bezier(x1: 0, y1: 0, x2: 0.58, y2: 1)
    static let easeInOut = Bezier(x1: 0.42, y1: 0, x2: 0.58, y2: 1)

    private func c(_ s: Double, _ a: Double, _ b: Double) -> Double {
        let i = 1 - s
        return 3 * i * i * s * a + 3 * i * s * s * b + s * s * s
    }

    func y(_ x: Double) -> Double {
        let x = min(1, max(0, x))
        if x1 == 0 && y1 == 0 && x2 == 1 && y2 == 1 { return x }
        var lo = 0.0, hi = 1.0, s = x
        for _ in 0..<24 {   // бисекция по параметру кривой
            s = (lo + hi) / 2
            if c(s, x1, x2) < x { lo = s } else { hi = s }
        }
        return c(s, y1, y2)
    }
}

/// Лист проверки: строка на каждый спиннер, 8 кадров по циклу, крупно (pia-app --loaders-sheet путь.png)
@MainActor
enum LoaderSheet {
    static func write(to path: String) {
        let frames = 8
        let view = VStack(alignment: .leading, spacing: 10) {
            ForEach(Activity.allCases, id: \.self) { a in
                HStack(spacing: 14) {
                    Text(a.title).font(.system(size: 11)).frame(width: 150, alignment: .leading)
                    ForEach(0..<frames, id: \.self) { f in
                        LoaderShape(activity: a, dot: 3.2, t: Double(f) * 0.3125 / 2)
                            .frame(width: 30, height: 14, alignment: .leading)
                            .padding(4).background(Color.gray.opacity(0.08))
                    }
                }
            }
            HStack(spacing: 14) {
                Text("думаю → пишу").font(.system(size: 11)).frame(width: 150, alignment: .leading)
                ForEach(0..<frames, id: \.self) { f in
                    TalkMorph(dot: 3.2, t: 0.2, toWriting: true, k: Double(f) / Double(frames - 1), order: TalkMorph.order(dot: 3.2, t: 0.2))
                        .padding(4).background(Color.gray.opacity(0.08))
                }
            }
        }
        .padding(16).background(Color.white).environment(\.colorScheme, .light)
        let r = ImageRenderer(content: view)
        r.scale = 4
        guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { print("не отрисовалось"); return }
        try? png.write(to: URL(fileURLWithPath: path))
        print("ok \(path)")
    }
}
