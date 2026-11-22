import SwiftUI

/// Индикатор «думаю»: порт Dotm3x3_16 (Dot Matrix, «Smiley Spin») — сетка 3×3, смайлик из точек
/// поворачивается на 90° каждые 180 мс (цикл 720 мс, speed 1), переход со smoothstep.
/// Прозрачность точки: 0.09 + вес·(0.88 − 0.09), как в оригинале. Оригинал: size 24, dotSize 6.
struct Dots3x3Loader: View {
    var size: CGFloat = 12
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let glyph: [Double] = [1, 0, 1, 0, 0, 0, 0, 1, 0]
    private static let baseOpacity = 0.09
    private static let peakOpacity = 0.88
    private static let stepSeconds = 0.18
    private static let steps = 4

    private static func rotate(_ p: [Double], _ turns: Int) -> [Double] {
        var out = p
        for _ in 0..<(((turns % steps) + steps) % steps) {
            var next = [Double](repeating: 0, count: 9)
            for i in 0..<9 { next[(i % 3) * 3 + (2 - i / 3)] = out[i] }
            out = next
        }
        return out
    }

    private static let rotations: [[Double]] = (0...steps).map { rotate(glyph, $0) }

    private static func smooth(_ v: Double) -> Double {
        let t = min(1, max(0, v))
        return t * t * (3 - 2 * t)
    }

    var body: some View {
        Group {
            if reduceMotion {
                canvas(turns: 0, t: 0)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
                    let cycle = Self.stepSeconds * Double(Self.steps)
                    let phase = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle) / cycle
                    let scaled = phase * Double(Self.steps)
                    canvas(turns: Int(floor(scaled)) % Self.steps, t: Self.smooth(scaled - floor(scaled)))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Думаю")
    }

    private func canvas(turns: Int, t: Double) -> some View {
        let cur = Self.rotations[turns], nxt = Self.rotations[turns + 1]
        return Canvas { gc, sz in
            let pitch = sz.width / 3
            let d = sz.width * 6 / 24
            for i in 0..<9 {
                let w = cur[i] * (1 - t) + nxt[i] * t
                let o = Self.baseOpacity + w * (Self.peakOpacity - Self.baseOpacity)
                let cx = (Double(i % 3) + 0.5) * pitch, cy = (Double(i / 3) + 0.5) * pitch
                let rect = CGRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d)
                gc.fill(Path(ellipseIn: rect), with: .color(Color.primary.opacity(o * 0.75)))
            }
        }
    }
}
