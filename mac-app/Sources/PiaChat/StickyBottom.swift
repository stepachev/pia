import AppKit

/// Режим «прилипания к низу» (чистая логика, без AppKit — проверяется tests/sticky.sh).
/// Выключается только реальной прокруткой пользователя вверх; рост контента его не трогает.
struct StickyBottom {
    static let threshold: CGFloat = 30
    var on = true

    /// колесо/тачпад: scrollingDeltaY > 0 — контент едет вниз, т.е. пользователь листает вверх
    mutating func userScrolled(deltaY: CGFloat, distanceToBottom: CGFloat) {
        if deltaY > 0 { on = false }
        else if distanceToBottom <= StickyBottom.threshold { on = true }
    }
    /// пользователь сам оказался у низа (ползунок, клавиши)
    mutating func reachedBottom(distanceToBottom: CGFloat) {
        if distanceToBottom <= StickyBottom.threshold { on = true }
    }
    /// отправил сообщение / открыл окно
    mutating func reset() { on = true }
    /// изменение контента/контейнера: ничего не выключает
    mutating func contentChanged() {}
}

// MARK: полосы прокрутки — нигде (даже при «Показывать полосы прокрутки: всегда»)
import AppKit
import ObjectiveC

extension NSScrollView {
    @objc func pia_tile() {
        pia_tile()   // после обмена — оригинальный tile
        if hasVerticalScroller || hasHorizontalScroller {
            hasVerticalScroller = false
            hasHorizontalScroller = false
            pia_tile()
        }
    }
    static func piaHideScrollers() {
        guard let a = class_getInstanceMethod(NSScrollView.self, NSSelectorFromString("tile")),
              let b = class_getInstanceMethod(NSScrollView.self, #selector(pia_tile)) else { return }
        method_exchangeImplementations(a, b)
    }
}
