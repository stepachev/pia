import AppKit
import SwiftUI

struct ChatView: View {
    @Bindable var model: ChatModel
    var onEscape: () -> Void
    @State private var inputHeight: CGFloat = InputView.minHeight
    @State private var windowHeight: CGFloat = 500
    // состояние прокрутки — в обычном классе, не в @State: запись на каждом кадре прокрутки иначе перерисовывает всю ленту (лаги)
    @State private var scroll = ScrollState()
    private var atBottom: Bool { get { scroll.atBottom } nonmutating set { scroll.atBottom = newValue } }
    private var metrics: ScrollMetrics { get { scroll.metrics } nonmutating set { scroll.metrics = newValue } }
    @State private var wheelMonitor: Any?
    /// до этого момента лента держится низа, пока меняется высота поля ввода
    @State private var holdBottomUntil = Date.distantPast
    /// высота полосы, за которую окно перетаскивается (pt)
    static let dragStrip: CGFloat = 30
    /// высота градиента над полем ввода: лента получает такой же отступ снизу
    static let feedBottomInset: CGFloat = 26

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // полоса перетаскивания сверху карточки (заголовка не видно); лента под неё не заезжает,
                // поэтому выделению текста в сообщениях полоса не мешает
                // прозрачная область-хват: лента идёт под ней на всю высоту, отдельной плашки и разделителя нет
                feed
                    .overlay(alignment: .top) {
                        GrabStrip().frame(height: ChatView.dragStrip)
                    }
                    // как у Raycast: лента плавно исчезает под полем ввода (маской — фон окна размытый, заливка цветом дала бы полосу)
                    .mask {
                        VStack(spacing: 0) {
                            Rectangle()
                            LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom).frame(height: 26)
                        }
                    }
                bottom
            }
            if let z = model.zoomImage {
                ZoomedImage(path: z) { withAnimation(.easeOut(duration: 0.15)) { model.zoomImage = nil } }
                    .transition(.opacity)
            }
            // мастер разрешений — поверх чата (чат и черновик живут под ним)
            if Permissions.shared.wizardVisible {
                PermissionsView(perms: Permissions.shared) { model.onClosePermissions() }
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: Permissions.shared.wizardVisible)
        .background(DragArea())
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { windowHeight = $0 }
    }

    /// поле ввода растёт примерно до половины окна (капсула = поле + вертикальные отступы)
    private var inputMaxHeight: CGFloat {
        max(InputView.minHeight, windowHeight * 0.5 - (36 - InputView.minHeight))
    }

    // MARK: лента

    private var signature: String {
        "\(model.items.count)|\(model.items.last?.seq ?? 0)|\(model.items.last?.text.count ?? 0)|\(model.busy)|\(model.helpers.count)|\(model.helpersExpanded)"
    }

    private var feed: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // не Lazy: у LazyVStack высоты ещё не показанных строк оценочные, и прокрутка «до низа» не доходила до конца (markdown-списки)
                VStack(alignment: .leading, spacing: 18) {
                    if model.loadingOlder {
                        HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                    }
                    ForEach(model.items.filter { $0.role != "report" && !($0.isPartial && $0.text.isEmpty) }) { it in
                        MessageRow(item: it) { p in withAnimation(.easeOut(duration: 0.15)) { model.zoomImage = p } }
                            .equatable()
                            .id(it.seq)
                            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 10)), removal: .opacity))
                    }
                    // один спиннер на всё: занят я — мой лоадер (с помощниками — желейный, с путником);
                    // свободен, но работают помощники — Jelly Triangle. Щелчок / ↓ — список помощников.
                    if model.busy || !model.helpers.isEmpty {
                        TypingDots(model: model).id("typing").transition(.opacity)
                    }
                    if model.items.isEmpty && model.connected == false {
                        Text("pia не запущена").font(.system(size: 13)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.top, 140)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 22)
                // верхний отступ = высота хвата: первая строка не прячется под ним
                .padding(.top, ChatView.dragStrip)
                .padding(.bottom, 8 + ChatView.feedBottomInset)   // запас под градиент над полем: последняя строка целиком выше него
                .background(DragArea())
            }
            .scrollIndicators(.hidden)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onScrollGeometryChange(for: ScrollMetrics.self) { g in
                ScrollMetrics(offset: g.contentOffset.y, content: g.contentSize.height, container: g.containerSize.height)
            } action: { old, new in
                metrics = new
                let grew = abs(new.content - old.content) >= 0.5 || abs(new.container - old.container) >= 0.5
                if grew {
                    // рост ленты (дописывается ответ), смена окна — это НЕ прокрутка пользователя: прилипание не трогаем
                    if atBottom { proxy.scrollTo("bottom", anchor: .bottom) }
                } else if !atBottom, Date() >= holdBottomUntil {
                    // пользователь сам докрутил до низа
                    var st = StickyBottom(on: false)
                    st.reachedBottom(distanceToBottom: new.content - new.offset - new.container)
                    if st.on { atBottom = true }
                }
            }
            .onAppear {
                guard wheelMonitor == nil else { return }
                wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { ev in
                    guard let w = ev.window, let cv = w.contentView else { return ev }
                    var v: NSView? = cv.hitTest(cv.convert(ev.locationInWindow, from: nil))
                    while let x = v { if x is NSTextView { return ev }; v = x.superview }
                    let dy = ev.scrollingDeltaY
                    if dy > 0 { atBottom = false }
                    else if dy < 0 || ev.momentumPhase != [] {
                        // дистанцию читаем после применения прокрутки
                        DispatchQueue.main.async {
                            var st = StickyBottom(on: atBottom)
                            st.userScrolled(deltaY: dy, distanceToBottom: metrics.content - metrics.offset - metrics.container)
                            atBottom = st.on
                        }
                    }
                    return ev
                }
            }
            .onDisappear { if let m = wheelMonitor { NSEvent.removeMonitor(m); wheelMonitor = nil } }
            .onChange(of: model.scrollToBottomToken) {
                atBottom = true
                // ленивый список досчитывает высоты не сразу — прокручиваем несколько раз
                for d in [0.0, 0.08, 0.25, 0.6] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + d) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            .onChange(of: inputHeight) {
                // поле растёт вверх — лента сжимается, последнее сообщение остаётся видимым
                guard atBottom else { return }
                holdBottomUntil = Date().addingTimeInterval(0.6)
                for d in [0.0, 0.05, 0.15, 0.3, 0.5] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + d) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            .onChange(of: signature) {
                guard atBottom else { return }
                proxy.scrollTo("bottom", anchor: .bottom)
                // markdown дорисовывается после первого прохода вёрстки — повторяем, пока высота не устоится
                for d in [0.05, 0.15, 0.4] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + d) { if atBottom { proxy.scrollTo("bottom", anchor: .bottom) } }
                }
            }
            .onChange(of: model.anchorAfterPrepend) {
                if let s = model.anchorAfterPrepend {
                    proxy.scrollTo(s, anchor: .top)
                    model.anchorAfterPrepend = nil
                }
            }
        }
    }

    // MARK: низ: строка помощников / состояние, вложения, поле ввода

    private var bottom: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.connected == false && !model.items.isEmpty {
                StatusLine(text: "pia не запущена")
            } else if let e = model.sendError {
                StatusLine(text: e)
            } else if let h = model.hint {
                StatusLine(text: h)
            } else if !Permissions.shared.accessibility && !Permissions.shared.wizardVisible {
                PermissionsHintLine { model.onOpenPermissions() }
            }
            if !model.attachments.isEmpty {
                AttachmentsRow(model: model)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            // ввод как в терминале: без капсулы, только мигающий курсор; пока есть текст — слева полоса «моё сообщение»
            // (место под полосу занято всегда, чтобы текст не прыгал). Откат — backups/pia.app.before-cursor-input-*
            HStack(alignment: .top, spacing: 6) {
                Capsule()
                    .fill(Color.primary.opacity(0.22))
                    .frame(width: 1.5)
                    .padding(.vertical, 3)
                    .opacity(model.draft.isEmpty ? 0 : 1)
                    .animation(.easeOut(duration: 0.15), value: model.draft.isEmpty)
                InputView(model: model, height: $inputHeight, maxHeight: inputMaxHeight, onEscape: escape)
            }
            .frame(height: inputHeight)
            .contentShape(Rectangle())
            .onTapGesture { if let tv = model.inputView { tv.window?.makeFirstResponder(tv) } }
            .padding(.leading, 22 - 1.5 - 6)   // курсор и текст — по краю текста сообщений (22), полоса — левее, на полях
            .padding(.trailing, 22)
            .padding(.top, 8)
            .padding(.bottom, 14)
        }
        .animation(.snappy(duration: 0.2), value: model.attachments.count)
        .animation(.snappy(duration: 0.2), value: inputHeight)
    }

    private func escape() {
        if model.zoomImage != nil {
            withAnimation(.easeOut(duration: 0.15)) { model.zoomImage = nil }
        } else if model.helpersExpanded {
            withAnimation(.snappy(duration: 0.2)) { model.helpersExpanded = false }
        } else {
            onEscape()
        }
    }
}

final class ScrollState {
    var atBottom = true
    var metrics = ScrollMetrics(offset: 0, content: 0, container: 0)
}

struct ScrollMetrics: Equatable {
    var offset: CGFloat
    var content: CGFloat
    var container: CGFloat
}

// Верхняя область-хват: рука openHand, при перетаскивании closedHand
struct GrabStrip: NSViewRepresentable {
    func makeNSView(context: Context) -> GrabStripView { GrabStripView() }
    func updateNSView(_ v: GrabStripView, context: Context) {}
}

final class GrabStripView: NSView {
    private var dragging = false
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: dragging ? .closedHand : .openHand) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func cursorUpdate(with event: NSEvent) { (dragging ? NSCursor.closedHand : NSCursor.openHand).set() }
    override func mouseEntered(with event: NSEvent) { if !dragging { NSCursor.openHand.set() } }
    override func mouseMoved(with event: NSEvent) { if !dragging { NSCursor.openHand.set() } }
    override func mouseExited(with event: NSEvent) { if !dragging { NSCursor.arrow.set() } }
    override func mouseDown(with event: NSEvent) {
        guard let win = window else { return }
        dragging = true
        NSCursor.closedHand.set()
        win.performDrag(with: event)
        dragging = false
        let p = convert(win.mouseLocationOutsideOfEventStream, from: nil)
        if bounds.contains(p) { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
        win.invalidateCursorRects(for: self)
    }
}

// Фон, за который окно перетаскивается
struct DragArea: View {
    var body: some View {
        Color.clear.contentShape(Rectangle()).gesture(WindowDragGesture())
    }
}

// MARK: - сообщения

// Цвета: светлая тема — белый фон, тёмная — тёмно-серый; всё непрозрачно и читаемо
enum Theme {
    static func dyn(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light })
    }
    /// пузырь моих сообщений — графитовый, текст белый
    static let bubble = dyn(NSColor(srgbRed: 0.20, green: 0.20, blue: 0.22, alpha: 1), NSColor(srgbRed: 0.27, green: 0.27, blue: 0.29, alpha: 1))
    static let windowBg = dyn(.white, NSColor(srgbRed: 0.106, green: 0.106, blue: 0.11, alpha: 1))
    /// поле ввода: #F7F7F8 и обводка #E5E5E7 (тёмная тема — чуть светлее фона)
    static let inputFill = dyn(NSColor(srgbRed: 0.969, green: 0.969, blue: 0.973, alpha: 1), NSColor(srgbRed: 0.15, green: 0.15, blue: 0.155, alpha: 1))
    static let inputStroke = dyn(NSColor(srgbRed: 0.898, green: 0.898, blue: 0.906, alpha: 1), NSColor(white: 1, alpha: 0.11))
    static let placeholder = dyn(NSColor(white: 0, alpha: 0.42), NSColor(white: 1, alpha: 0.42))
    /// второстепенный текст (время, помощники) — серый, но читаемый
    static let muted = dyn(NSColor(white: 0, alpha: 0.55), NSColor(white: 1, alpha: 0.58))
    /// ещё светлее (время работы помощников)
    static let faint = dyn(NSColor(white: 0, alpha: 0.38), NSColor(white: 1, alpha: 0.40))
}

struct MessageRow: View, Equatable {
    let item: FeedItem
    var onZoom: (String) -> Void
    static func == (a: MessageRow, b: MessageRow) -> Bool { a.item == b.item }

    var body: some View {
        switch item.role {
        case "user": user
        case "report": ReportBlock(item: item, onZoom: onZoom)
        default: assistant
        }
    }

    private var user: some View {
        let parts = ContextFormat.split(item.text)
        return HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(Array(parts.contexts.enumerated()), id: \.offset) { _, l in
                    ContextPill(label: l, bundleId: nil, compact: true)
                }
                if !item.images.isEmpty {
                    ImagesStrip(paths: item.images, height: 110, onZoom: onZoom)
                }
                if !parts.body.isEmpty {
                    Text(verbatim: parts.body)
                        .font(.system(size: 13.5))
                        .lineSpacing(2.5)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(.white)
                        .tint(.white)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 17, style: .continuous).fill(Theme.bubble))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var assistant: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !item.images.isEmpty { ImagesStrip(paths: item.images, height: 140, onZoom: onZoom) }
            MarkdownView(text: item.text, onZoom: onZoom)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 40)
    }
}

struct ImagesStrip: View {
    let paths: [String]
    var height: CGFloat
    var onZoom: (String) -> Void
    var body: some View {
        // превью фиксированной ширины: не влезают в узкое окно — листаются вбок, а не раздвигают ленту шире окна
        ViewThatFits(in: .horizontal) {
            row
            ScrollView(.horizontal, showsIndicators: false) { row }
        }
    }
    private var row: some View {
        HStack(spacing: 6) {
            ForEach(paths, id: \.self) { p in
                Thumb(path: p, height: height, maxWidth: height * 2)
                    .onTapGesture { onZoom(p) }
                    .help(URL(fileURLWithPath: p).lastPathComponent)
            }
        }
    }
}

struct ReportBlock: View {
    let item: FeedItem
    var onZoom: (String) -> Void
    @State private var expanded = false

    private var body_: String {
        // первая строка «[Отчёт помощника #N «…»]» — уже в заголовке
        item.text.replacing(/^\s*\[Отчёт[^\n]*\]\s*\n?/, with: "")
    }
    private var header: String {
        var s = "Отчёт помощника"
        if let n = item.n { s += " #\(n)" }
        if let t = item.title?.nonEmpty { s += " · \(t)" }
        else if let m = item.text.firstMatch(of: /«([^»\n]+)»/) , item.text.hasPrefix("[") { s += " · \(m.1)" }
        return s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
                Text(header)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.snappy(duration: 0.25)) { expanded.toggle() } }
            Group {
                if expanded {
                    MarkdownView(text: body_, size: 13, secondary: true, onZoom: onZoom)
                } else {
                    MarkdownView(text: body_, size: 13, secondary: true, selectable: false)
                        .frame(maxHeight: 62, alignment: .top)
                        .clipped()
                        .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.55), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                }
            }
            if expanded && !item.images.isEmpty { ImagesStrip(paths: item.images, height: 100, onZoom: onZoom) }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        // свёрнутый раскрывается кликом в любом месте; развёрнутый сворачивается кликом по заголовку (текст можно выделять)
        .onTapGesture { if !expanded { withAnimation(.snappy(duration: 0.25)) { expanded = true } } }
    }
}

struct TypingDots: View {
    @Bindable var model: ChatModel
    var body: some View {
        let n = model.helpers.count
        VStack(alignment: .leading, spacing: 6) {
            // минимум сущностей: я занят (чем угодно) — Momentum; свободен, но работают помощники — Jelly
            ActivityLoader(activity: model.busy ? .compacting : .pair, dimmed: model.busy && model.stopping)
                .help(n > 0 ? "\(model.busy ? model.activity.title + ", " : "")\(n) \(plural(n, "помощник", "помощника", "помощников")) — щелчок или ↓" : model.activity.title)
                .onTapGesture { if n > 0 { withAnimation(.snappy(duration: 0.22)) { model.helpersExpanded.toggle() } } }
            if model.helpersExpanded && n > 0 {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.helpers) { h in HelperRow(h: h, now: ctx.date) }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - строка помощников

struct HelpersBar: View {
    @Bindable var model: ChatModel
    @State private var hovering = false

    private var expanded: Bool { model.helpersExpanded || hovering }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                // без надписи: число работяг = число «желейных» точек (до 3); список — ↓, щелчок или наведение
                JellyDots(count: model.helpers.count)
                    .help("\(model.helpers.count) \(plural(model.helpers.count, "работяга", "работяги", "работяг")) — ↓ показать")
                Spacer()
            }
            if expanded {
                // время работы тикает раз в секунду (только пока список раскрыт)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.helpers) { h in
                            HelperRow(h: h, now: ctx.date)
                        }
                    }
                }
                .padding(.leading, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.snappy(duration: 0.22)) { hovering = h } }
        .onTapGesture { withAnimation(.snappy(duration: 0.22)) { model.helpersExpanded.toggle() } }
    }
}

/// строка списка: коротко, что делает (слева), и сколько уже работает (справа)
struct HelperRow: View {
    let h: HelperInfo
    let now: Date
    var body: some View {
        HStack(spacing: 10) {
            Text(shortTitle(h.title)).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
            Spacer(minLength: 8)
            Text(workTime(h.startMs, now)).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.faint).lineLimit(1)
        }
    }
}

/// Работяги: желейные точки (как Jelly из ldrs) — 1 точка дышит и чуть сплющивается, 2–3 отпочковываются от общей капли,
/// кружат и снова сливаются (метаболы: размытие + порог прозрачности). Больше трёх не рисуем.
struct JellyDots: View {
    var count: Int
    var body: some View {
        let n = max(1, min(3, count))
        TimelineView(.animation(minimumInterval: 1 / 60)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Canvas { gc, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                gc.addFilter(.alphaThreshold(min: 0.5, color: Color.primary.opacity(0.5)))
                gc.addFilter(.blur(radius: 1.6))
                gc.drawLayer { l in
                    let d: CGFloat = 6
                    if n == 1 {
                        let w = sin(t * 2 * .pi / 1.4)
                        let sx = d * (1 + 0.14 * w), sy = d * (1 - 0.14 * w)
                        l.fill(Path(ellipseIn: CGRect(x: c.x - sx / 2, y: c.y - sy / 2, width: sx, height: sy)), with: .color(.black))
                    } else {
                        // расхождение 0→1→0 с паузой «вместе», всё медленно вращается
                        let ph = (t / 2.4).truncatingRemainder(dividingBy: 1)
                        let spread = CGFloat(max(0, sin(ph * 2 * .pi))) * 0.35 + 0.65
                        let r: CGFloat = 5.2 * spread
                        let spin = t * 2 * .pi / 3.2
                        for i in 0..<n {
                            let a = spin + Double(i) * 2 * .pi / Double(n)
                            let p = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
                            l.fill(Path(ellipseIn: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)), with: .color(.black))
                        }
                        l.fill(Path(ellipseIn: CGRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4)), with: .color(.black))
                    }
                }
            }
        }
        .frame(width: 22, height: 18)
        .animation(.snappy(duration: 0.3), value: n)
    }
}

/// тонкая серая точка, мягко «дышит»
struct PulseDot: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let p = (sin(t * 2 * .pi / 1.8) + 1) / 2
            Circle().fill(Color.primary.opacity(0.22 + 0.22 * p)).frame(width: 5, height: 5)
        }
        .frame(width: 6, height: 6)
    }
}

struct StatusLine: View {
    let text: String
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(Color.primary.opacity(0.3)).frame(width: 6, height: 6)
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.top, 10)
    }
}

// MARK: - вложения над полем ввода

struct AttachmentsRow: View {
    @Bindable var model: ChatModel
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.attachments) { a in
                    switch a {
                    case .image(_, let p):
                        Thumb(path: p, maxPixel: 200, height: ContextPill.height, maxWidth: 64, corner: ContextPill.height / 2)
                            .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { model.zoomImage = p } }
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                    case .context(_, let c):
                        HStack(spacing: 6) {
                            ContextPill(label: ContextFormat.label(c), bundleId: c.bundleId, compact: false)
                            if let s = c.screenshotPath, FileManager.default.fileExists(atPath: s) {
                                Thumb(path: s, maxPixel: 200, height: ContextPill.height, maxWidth: 64, corner: ContextPill.height / 2)
                                    .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { model.zoomImage = s } }
                            }
                        }
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                }
            }
        }
        .scrollClipDisabled()
    }
}

struct ContextPill: View {
    static let height: CGFloat = 28
    let label: String
    let bundleId: String?
    var compact: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let bundleId, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable().frame(width: 15, height: 15)
            } else {
                Image(systemName: "macwindow").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Text(label)
                .font(.system(size: compact ? 11.5 : 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                // не fixedSize: пилюля с длинным заголовком (до 360) не держит ширину ленты — в узком окне сокращается «…»
                .modifier(CappedWidth(max: 360))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, compact ? 4 : 0)
        .frame(height: compact ? nil : Self.height)   // над курсором — высота как у миниатюр (один ряд вровень)
        .background(Capsule().fill(Color.primary.opacity(compact ? 0.06 : 0.08)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.07)))
        .help(label)
    }
}

// MARK: - вспомогательное

/// Ширина не больше max и не больше предложенной; сам вид — по своему размеру (короткий текст не растягивается до max).
/// Замена `.frame(maxWidth:).fixedSize(horizontal: true)`: тот держал ширину max даже в узком окне.
struct CappedWidth: ViewModifier {
    let max: CGFloat
    func body(content: Content) -> some View { CappedWidthLayout(max: max) { content } }
}

struct CappedWidthLayout: Layout {
    let max: CGFloat
    private func cap(_ p: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: Swift.min(p.width ?? max, max), height: p.height)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(cap(proposal)) ?? .zero
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    let m10 = n % 10, m100 = n % 100
    if m10 == 1 && m100 != 11 { return one }
    if (2...4).contains(m10) && !(12...14).contains(m100) { return few }
    return many
}

/// сколько помощник уже работает: «12 с», «3 мин», «1 ч 05 мин» (нет времени начала — пусто)
func workTime(_ ms: Double?, _ now: Date) -> String {
    guard let ms, ms > 0 else { return "" }
    let s = Int(max(0, now.timeIntervalSince1970 - ms / 1000))
    if s < 60 { return "\(s) с" }
    let m = s / 60
    if m < 60 { return "\(m) мин" }
    return "\(m / 60) ч " + String(format: "%02d", m % 60) + " мин"
}

/// Короткое название задачи помощника: 2 слова (3 — если второе предлог/союз), после двоеточия, если оно есть;
/// без висящих предлогов, союзов и знаков в конце; слова не режем.
func shortTitle(_ title: String?) -> String {
    var t = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if let c = t.firstIndex(of: ":") {
        let after = t[t.index(after: c)...].trimmingCharacters(in: .whitespaces)
        if after.contains(where: { $0.isLetter || $0.isNumber }) { t = after }
    }
    let stop: Set<String> = ["в", "во", "на", "по", "для", "и", "или", "с", "со", "к", "ко", "о", "об", "обо", "от", "до", "из", "за",
                             "без", "при", "через", "а", "но", "что", "как", "под", "над", "у", "про", "чтобы", "же", "ли", "не",
                             "the", "a", "an", "of", "to", "in", "on", "for", "and", "or", "with"]
    let edge = CharacterSet.punctuationCharacters.union(.symbols).subtracting(CharacterSet(charactersIn: "#@"))
    let words = t.split(whereSeparator: { $0.isWhitespace }).map { String($0) }
    func isStop(_ w: String) -> Bool {
        let core = w.trimmingCharacters(in: edge).lowercased()
        return core.isEmpty || stop.contains(core)
    }
    var out: [String] = []
    for w in words {
        if out.count >= 3 { break }
        if out.count == 2 && !isStop(out[1]) && !isStop(out[0]) { break }
        if out.isEmpty && w.trimmingCharacters(in: edge).isEmpty { continue }   // «+», «—» в начале
        out.append(w)
        if w.hasSuffix(",") || w.hasSuffix(";") || w.hasSuffix(".") || w.hasSuffix("—") { break }   // конец фразы
    }
    while out.count > 1, isStop(out[out.count - 1]) { out.removeLast() }
    var r = out.joined(separator: " ").trimmingCharacters(in: edge.union(.whitespaces).subtracting(CharacterSet(charactersIn: "»)\"")))
    if r.hasSuffix("»") && !r.contains("«") { r.removeLast() }
    if r.hasPrefix("«") && !r.contains("»") { r.removeFirst() }
    return r.isEmpty ? "задача" : r
}
