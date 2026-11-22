import SwiftUI

/// Индикатор «думаю»: порт DotmHex10 (Dot Matrix, «Liquid Vortex») — шестиугольная сетка 3-4-5-4-3, по ней бежит волна яркости.
/// Цикл 1850 мс / speed 1.55; прозрачность от 0.09 до 0.98 (как в оригинале).
struct HexDotsLoader: View {
    var pitch: CGFloat = 4.2
    var dotSize: CGFloat = 3
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let rows = [3, 4, 5, 4, 3]
    private static let rowPitch = 3.0.squareRoot() / 2
    private static let cycle = 1.85 / 1.55

    private struct Cell { let x, y, radius: Double }
    private static let cells: [Cell] = {
        var out: [Cell] = []
        for (r, n) in rows.enumerated() {
            for c in 0..<n {
                let x = Double(c) - Double(n - 1) / 2
                let y = Double(r - 2) * rowPitch
                out.append(Cell(x: x, y: y, radius: (x * x + y * y).squareRoot()))
            }
        }
        return out
    }()

    private static func ripple(_ v: Double, _ width: Double) -> Double {
        let w = v - floor(v)
        return max(0, 1 - min(w, 1 - w) / width)
    }

    private static func opacity(_ c: Cell, _ phase: Double) -> Double {
        let tau = phase * 2 * .pi
        let lensCenter = sin(tau) * 1.15
        let lens = max(0, 1 - abs(lensCenter - c.x * 0.88 - c.y * 0.16) / 0.78)
        let front = ripple(phase + c.x * 0.12 - c.y * 0.045 + c.radius * 0.07, 0.16)
        let back = ripple(phase + 0.34 + c.x * 0.09 + c.y * 0.035 + c.radius * 0.05, 0.2) * 0.34
        let comp = max(0, 1 - abs(cos(tau) * 1.18 - c.y * 1.25) / 1.1) * 0.18
        let sheen = (0.5 + 0.5 * sin(tau - c.radius * 1.9)) * (c.radius > 1.35 ? 0.16 : 0.06)
        let core = c.radius < 0.1 ? 0.34 + sin(tau) * 0.1 : 0
        return min(0.98, 0.09 + lens * 0.72 + front * 0.38 + back + comp + sheen + core)
    }

    private var size: CGSize {
        CGSize(width: pitch * 4 + dotSize, height: pitch * Self.rowPitch * 4 + dotSize)
    }

    var body: some View {
        Group {
            if reduceMotion {
                canvas(phase: 0.14)
            } else {
                // ~30 кадров/с хватает для плавности и экономит процессор
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    canvas(phase: (t / Self.cycle).truncatingRemainder(dividingBy: 1))
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityLabel("Думаю")
    }

    private func canvas(phase: Double) -> some View {
        Canvas { gc, sz in
            let d = dotSize, p = pitch
            for cell in Self.cells {
                let cx = sz.width / 2 + cell.x * p
                let cy = sz.height / 2 + cell.y * p
                let rect = CGRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d)
                gc.fill(Path(ellipseIn: rect), with: .color(Color.primary.opacity(Self.opacity(cell, phase) * 0.75)))
            }
        }
    }
}
