import AppKit
import SwiftUI

// Текст сообщений — NSTextView (TextKit 1), а не SwiftUI Text: только так над ссылкой курсор «рука»
// (SwiftUI Text с textSelection ставит I-beam на весь текст и геометрию ссылок не отдаёт).
// Строчная разметка та же (AttributedString(markdown:)), шрифты/цвета/интервалы — как были у Text.

enum MDAttr {
    private static let measureLM = NSLayoutManager()
    /// Базовая линия первой строки от верха (TextKit 1, системный шрифт) — для выравнивания с маркером списка
    static func baseline(size: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
        measureLM.defaultBaselineOffset(for: .systemFont(ofSize: size, weight: weight))
    }

    /// Строчная Markdown-разметка → NSAttributedString: жирный, курсив, `код`, ~~зачёркнутый~~, ссылки (.link)
    static func make(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor,
                     lineSpacing: CGFloat = 0) -> NSAttributedString {
        let a = (try? AttributedString(markdown: s, options: .init(allowsExtendedAttributes: true, interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                                    failurePolicy: .returnPartiallyParsedIfPossible))) ?? AttributedString(s)
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = lineSpacing
        let out = NSMutableAttributedString()
        for run in a.runs {
            let intent = run.inlinePresentationIntent ?? []
            var font: NSFont
            if intent.contains(.code) {
                font = .monospacedSystemFont(ofSize: size - 1, weight: intent.contains(.stronglyEmphasized) ? .bold : .regular)
            } else {
                font = .systemFont(ofSize: size, weight: intent.contains(.stronglyEmphasized) ? .bold : weight)
            }
            if intent.contains(.emphasized) {
                font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.italic), size: font.pointSize) ?? font
            }
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: ps]
            if intent.contains(.code) { attrs[.backgroundColor] = NSColor.labelColor.withAlphaComponent(0.08) }
            if intent.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let url = run.link {
                attrs[.link] = url
                attrs[.foregroundColor] = NSColor.labelColor
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            out.append(NSAttributedString(string: String(a[run.range].characters), attributes: attrs))
        }
        return out
    }
}

/// Не редактируемый, выделяемый текст без фона и прокрутки; высота — под ширину (sizeThatFits).
final class PiaTextView: NSTextView {
    var selectableText = true { didSet { isSelectable = selectableText } }
    private var lastMeasure: (width: CGFloat, size: NSSize)?

    static func make() -> PiaTextView {
        let storage = NSTextStorage()
        let lm = NSLayoutManager()
        storage.addLayoutManager(lm)
        let tc = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        tc.lineFragmentPadding = 0
        tc.widthTracksTextView = false
        tc.heightTracksTextView = false
        lm.addTextContainer(tc)
        let v = PiaTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20), textContainer: tc)
        v.isEditable = false
        v.isSelectable = true
        v.isRichText = true
        v.drawsBackground = false
        v.backgroundColor = .clear
        v.textContainerInset = .zero
        v.isVerticallyResizable = false
        v.isHorizontallyResizable = false
        v.autoresizingMask = []
        v.usesFindBar = false
        v.isAutomaticLinkDetectionEnabled = false
        v.displaysLinkToolTips = false
        v.linkTextAttributes = [.foregroundColor: NSColor.labelColor,
                                .underlineStyle: NSUnderlineStyle.single.rawValue,
                                .cursor: NSCursor.pointingHand]
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return v
    }

    func setText(_ s: NSAttributedString) {
        guard let ts = textStorage, !ts.isEqual(to: s) else { return }
        ts.setAttributedString(s)
        lastMeasure = nil
        invalidateIntrinsicContentSize()
        window?.invalidateCursorRects(for: self)
    }

    /// Размер текста при ширине width. Меряем на отдельной копии TextKit: контейнер, которым текст рисуется,
    /// не трогаем (иначе SwiftUI, меряя при разных ширинах, оставлял его не той ширины — строки налезали друг на друга).
    func measure(width: CGFloat) -> NSSize {
        if let m = lastMeasure, m.width == width { return m.size }
        guard let ts = textStorage, ts.length > 0 else { return .zero }
        let storage = NSTextStorage(attributedString: ts)
        let lm = NSLayoutManager()
        lm.usesFontLeading = layoutManager?.usesFontLeading ?? true
        lm.typesetterBehavior = layoutManager?.typesetterBehavior ?? .latestBehavior
        let tc = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        tc.lineFragmentPadding = 0
        lm.addTextContainer(tc)
        storage.addLayoutManager(lm)
        lm.ensureLayout(for: tc)
        let r = lm.usedRect(for: tc)
        let s = NSSize(width: ceil(r.width), height: ceil(r.height))
        lastMeasure = (width, s)
        return s
    }

    override func setFrameSize(_ s: NSSize) {
        super.setFrameSize(s)
        syncContainer()
    }

    override func layout() {
        super.layout()
        syncContainer()
    }

    /// Ширина контейнера, которым текст рисуется, всегда равна ширине вида
    private func syncContainer() {
        guard let tc = textContainer, bounds.width > 0, tc.size.width != bounds.width else { return }
        tc.size = NSSize(width: bounds.width, height: .greatestFiniteMagnitude)
        needsDisplay = true
    }

    // MARK: мышь

    /// Ссылка под точкой окна (nil — нет)
    func link(atWindowPoint wp: NSPoint) -> Any? {
        guard let lm = layoutManager, let tc = textContainer, let ts = textStorage, ts.length > 0 else { return nil }
        let p = convert(wp, from: nil)
        let tp = NSPoint(x: p.x - textContainerOrigin.x, y: p.y - textContainerOrigin.y)
        var frac: CGFloat = 0
        let g = lm.glyphIndex(for: tp, in: tc, fractionOfDistanceThroughGlyph: &frac)
        guard lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc).contains(tp) else { return nil }
        let ci = lm.characterIndexForGlyph(at: g)
        guard ci < ts.length else { return nil }
        return ts.attribute(.link, at: ci, effectiveRange: nil)
    }

    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        // .activeAlways: курсор ставим сами и в неактивном/не key окне (cursor rects работают только в key окне)
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    /// Курсор над этим текстом и ничего его не накрывает: лента прокручивается под полосой-хватом и полем ввода,
    /// там курсор ставит то, что сверху (рука для перетаскивания), а не этот текст.
    private func isTopmost(_ e: NSEvent) -> Bool {
        guard let cv = window?.contentView, let fv = cv.superview else { return false }
        guard let hit = cv.hitTest(fv.convert(e.locationInWindow, from: nil)) else { return false }
        return hit === self || hit.isDescendant(of: self)
    }

    private func updateCursor(_ e: NSEvent) {
        guard selectableText, isTopmost(e) else { return }
        (link(atWindowPoint: e.locationInWindow) != nil ? NSCursor.pointingHand : NSCursor.iBeam).set()
    }

    override func mouseMoved(with e: NSEvent) { if isTopmost(e) { super.mouseMoved(with: e) }; updateCursor(e) }
    override func mouseEntered(with e: NSEvent) { updateCursor(e) }
    override func cursorUpdate(with e: NSEvent) { updateCursor(e) }
    override func mouseExited(with e: NSEvent) {
        // ушли с текста на пустое место — обычная стрелка (но не поверх руки хвата)
        guard selectableText, let cv = window?.contentView, let fv = cv.superview else { return }
        if !(cv.hitTest(fv.convert(e.locationInWindow, from: nil)) is GrabStripView) { NSCursor.arrow.set() }
    }

    // Системные cursor rects NSTextView не знают про накрывающие виды и перебивали руку хвата — курсор ставим сами (updateCursor)
    override func resetCursorRects() {}

    override func hitTest(_ p: NSPoint) -> NSView? { selectableText ? super.hitTest(p) : nil }
    override var acceptsFirstResponder: Bool { selectableText }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }   // ссылка открывается и выделение начинается с первого щелчка
    override var mouseDownCanMoveWindow: Bool { false }

    /// как у SwiftUI: выделение снимается, когда фокус уходит (в поле ввода или другой текст)
    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok, selectedRange().length > 0 { setSelectedRange(NSRange(location: selectedRange().location, length: 0)) }
        return ok
    }

    // колесо/трекпад — ленте (своей прокрутки нет)
    override func scrollWheel(with e: NSEvent) { nextResponder?.scrollWheel(with: e) }
}

struct MessageText: NSViewRepresentable {
    let text: NSAttributedString
    var selectable = true

    func makeNSView(context: Context) -> PiaTextView {
        let v = PiaTextView.make()
        v.setText(text)
        v.selectableText = selectable
        return v
    }

    func updateNSView(_ v: PiaTextView, context: Context) {
        v.setText(text)
        if v.selectableText != selectable { v.selectableText = selectable }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView v: PiaTextView, context: Context) -> CGSize? {
        if let w = proposal.width, w.isFinite, w > 0 {
            return CGSize(width: w, height: v.measure(width: w).height)
        }
        let s = v.measure(width: 100_000)   // идеальный размер — одна строка на абзац
        return CGSize(width: s.width, height: s.height)
    }
}
