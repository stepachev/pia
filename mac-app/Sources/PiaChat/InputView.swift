import AppKit
import SwiftUI

// Поле ввода: NSTextView (многострочное, растёт вверх до ~половины окна, полосы прокрутки нет) со своими клавишами.
final class InputTextView: NSTextView {
    var onSubmit: () -> Void = {}
    var onEscape: () -> Void = {}
    var onBackspaceEmpty: () -> Void = {}
    var onLoadOlder: () -> Void = {}
    var onDownEmpty: () -> Void = {}
    var onPaste: (NSPasteboard) -> Bool = { _ in false }
    var onDropFiles: ([URL]) -> Bool = { _ in false }

    override func keyDown(with e: NSEvent) {
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch e.keyCode {
        case 36, 76: // Return / Enter
            if hasMarkedText() { super.keyDown(with: e); return }
            if f.contains(.shift) || f.contains(.option) { insertNewlineIgnoringFieldEditor(nil); return }
            onSubmit(); return
        case 53: // Esc
            if hasMarkedText() { super.keyDown(with: e); return }
            onEscape(); return
        case 51: // Backspace
            if string.isEmpty { onBackspaceEmpty(); return }
        case 126: // ↑
            if f.contains(.command) && string.isEmpty { onLoadOlder(); return }
        case 125: // ↓
            if string.isEmpty && f.intersection([.command, .shift, .option, .control]).isEmpty { onDownEmpty(); return }
        default: break
        }
        super.keyDown(with: e)
    }

    override func paste(_ sender: Any?) {
        if onPaste(NSPasteboard.general) { return }
        pasteAsPlainText(sender)
    }

    // перетаскивание картинок прямо в поле
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        let isText = pb.types?.contains(.string) == true && !PiaDrop.canAccept(pb)
        if !isText, PiaDrop.drop(sender, where: "поле ввода") { return true }
        return super.performDragOperation(sender)
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if PiaDrop.canAccept(sender.draggingPasteboard) { return PiaDrop.entered(sender, where: "поле ввода") }
        return super.draggingEntered(sender)
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { PiaDrop.exited(where: "поле ввода"); super.draggingExited(sender) }
}

// Прокрутка поля без видимого скроллера: после смены высоты (поле растёт вверх) — если текст помещается,
// показываем его с первой строки; если нет — держим курсор в видимой области.
final class InputScrollView: NSScrollView {
    override func setFrameSize(_ newSize: NSSize) {
        let changed = abs(newSize.height - frame.height) > 0.1
        super.setFrameSize(newSize)
        if changed { settle() }
    }

    func settle() {
        guard let tv = documentView as? NSTextView else { return }
        let docH = tv.frame.height, clipH = contentView.bounds.height
        if docH <= clipH + 0.5 {
            if contentView.bounds.origin.y != 0 {
                contentView.scroll(to: .zero)
                reflectScrolledClipView(contentView)
            }
        } else {
            tv.scrollRangeToVisible(tv.selectedRange())
        }
    }
}

struct InputView: NSViewRepresentable {
    @Bindable var model: ChatModel
    @Binding var height: CGFloat
    /// предел высоты поля (≈ половина окна); выше — прокрутка внутри без полосы
    var maxHeight: CGFloat
    var onEscape: () -> Void

    static let font = NSFont.systemFont(ofSize: 14)
    static var lineHeight: CGFloat { ceil(font.ascender - font.descender + font.leading) + 2 }
    static let inset = NSSize(width: 0, height: 5)
    static var minHeight: CGFloat { lineHeight + inset.height * 2 }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = InputScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false     // полосы прокрутки нет совсем (колесо/трекпад и курсор прокручивают)
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .none

        let tv = InputTextView()
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.font = Self.font
        tv.textColor = .labelColor
        tv.insertionPointColor = .labelColor
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.textContainerInset = Self.inset
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.selectedTextAttributes = [.backgroundColor: NSColor.labelColor.withAlphaComponent(0.18)]
        let ps = NSMutableParagraphStyle(); ps.lineSpacing = 2
        tv.defaultParagraphStyle = ps
        tv.typingAttributes = [.font: Self.font, .foregroundColor: NSColor.labelColor, .paragraphStyle: ps]
        tv.delegate = context.coordinator
        tv.registerForDraggedTypes(PiaDrop.types)

        let m = model
        tv.onSubmit = { [weak m] in m?.send() }
        tv.onEscape = onEscape
        tv.onBackspaceEmpty = { [weak m] in m?.removeLastAttachment() }
        tv.onLoadOlder = { [weak m] in m?.loadOlder() }
        tv.onDownEmpty = { [weak m] in
            guard let m, !m.helpers.isEmpty else { return }
            withAnimation(.snappy(duration: 0.22)) { m.helpersExpanded.toggle() }
        }
        tv.onPaste = { [weak m] pb in m?.attachFromPasteboard(pb) ?? false }
        tv.onDropFiles = { [weak m] urls in m?.attachFiles(urls) ?? false }

        scroll.documentView = tv
        model.inputView = tv
        context.coordinator.textView = tv
        DispatchQueue.main.async { context.coordinator.recalcHeight() }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let oldMax = context.coordinator.parent.maxHeight
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? InputTextView else { return }
        if tv.string != model.draft {
            tv.string = model.draft
            context.coordinator.recalcHeight()
        } else if abs(oldMax - maxHeight) > 0.5 {
            context.coordinator.recalcHeight()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: InputView
        weak var textView: NSTextView?
        init(_ p: InputView) { parent = p }

        func textDidChange(_ n: Notification) {
            guard let tv = textView else { return }
            if parent.model.draft != tv.string { parent.model.draft = tv.string }
            if parent.model.sendError != nil { parent.model.sendError = nil }
            recalcHeight()
        }

        /// Высота поля по реальной высоте текста (layoutManager.usedRect, включая пустую строку после \n) + отступы сверху/снизу.
        func recalcHeight() {
            guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let used = lm.usedRect(for: tc).height
            let content = ceil(max(InputView.lineHeight, used) + InputView.inset.height * 2)
            let maxH = max(InputView.minHeight, floor(parent.maxHeight))
            let h = min(maxH, content)
            let scroll = tv.enclosingScrollView as? InputScrollView
            scroll?.verticalScrollElasticity = content > maxH + 0.5 ? .allowed : .none
            if abs(parent.height - h) > 0.5 {
                DispatchQueue.main.async {
                    self.parent.height = h
                    // после того как SwiftUI поменяет рамку — поправить прокрутку (первая строка / курсор)
                    DispatchQueue.main.async { scroll?.settle() }
                }
            } else {
                scroll?.settle()
            }
        }
    }
}
