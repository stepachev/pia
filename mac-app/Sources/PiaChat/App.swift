import AppKit
import SwiftUI

// Окно pia: borderless — без заголовка и светофора, непрозрачный фон (белый / тёмный, как Raycast AI Chat), перетаскивается за фон, меняет размер.
// Тень своя (мягкая, как у плавающих окон macOS/Raycast): системная тень активного окна тяжёлая и с тёмным ободком. Поэтому окно
// шире карточки на `margin` со всех сторон; поля под тенью пропускают мышь (ignoresMouseEvents по опросу, см. updatePassThrough),
// размер меняется за край карточки, перетаскивание — за верхнюю полосу и пустой фон карточки.
final class PiaPanel: NSPanel {
    static let margin: CGFloat = 40   // поле под тень: мягкая тень (σ 14 ≈ blur 28) + смещение 11 вниз гаснет до края окна
    var onCancel: () -> Void = {}
    var onResized: () -> Void = {}
    /// мышь (щелчок/наведение) в окне, когда pia не активна — сделать активной (иначе курсор и наведение «видит» приложение позади)
    var onMouseWhileInactive: (String) -> Void = { _ in }

    init() {
        let m = PiaPanel.margin
        let card = PiaPanel.savedSize()
        super.init(contentRect: NSRect(origin: .zero, size: NSSize(width: card.width + 2 * m, height: card.height + 2 * m)),
                   // nonactivatingPanel: окно становится key и принимает ввод сразу, даже если macOS отложила/не дала
                   // активацию приложения (вызов из фона двойным правым Shift) — как у Spotlight/Raycast
                   // borderless (без .titled): у окна нет заголовка и кнопок-«светофора» вовсе — macOS не может их
                   // снова показать (при .titled они вылезали в поле под тень после показа/смены фокуса/размера).
                   // key-окном остаётся благодаря canBecomeKey; размер — ResizeEdgesView, перемещение — DragArea.
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { standardWindowButton(b)?.isHidden = true }
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false          // тень рисует PiaShadowView
        acceptsMouseMovedEvents = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        minSize = NSSize(width: 300 + 2 * m, height: 300 + 2 * m)
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    var mouseGuard: StuckMouseGuard?

    override func sendEvent(_ e: NSEvent) {
        if e.type == .leftMouseDown { mouseGuard?.downInPanel = true }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier, [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(e.type) { onMouseWhileInactive("щелчок") }
        super.sendEvent(e)
    }
    override func cancelOperation(_ sender: Any?) { onCancel() }

    /// Видимая карточка в координатах экрана
    var cardFrame: NSRect { frame.insetBy(dx: Self.margin, dy: Self.margin) }

    func saveSize() {
        UserDefaults.standard.set(cardFrame.width, forKey: "pia.window.w")
        UserDefaults.standard.set(cardFrame.height, forKey: "pia.window.h")
    }

    static func savedSize() -> NSSize {
        let d = UserDefaults.standard
        let w = d.double(forKey: "pia.window.w"), h = d.double(forKey: "pia.window.h")
        return (w >= 300 && h >= 300) ? NSSize(width: w, height: h) : NSSize(width: 750, height: 500)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = ChatModel()
    let perms = Permissions.shared
    var panel: PiaPanel!
    var shiftMonitor: RightShiftDoubleTapMonitor?
    var optionMonitor: RightOptionDoubleTapMonitor?
    private var optionItem: NSMenuItem?
    private var capturing = false
    private var activity: NSObjectProtocol?   // пока окно видно — без App Nap (опрос и анимации не замедляются)
    private var launched = false
    private let launchedAt = Date()
    private var pendingURLs: [String] = []    // pia://… пришёл до applicationDidFinishLaunching (холодный запуск по ссылке)
    private var shownAt = Date.distantPast
    private var hideGen = 0                   // поколение показа: отложенное скрытие не трогает окно, показанное заново
    /// Сразу после показа фокус может на миг вернуться прежнему приложению (Raycast закрывает своё окно,
    /// отложенная активация) — это не уход пользователя, окно не прячем.
    private let showGrace: TimeInterval = 1.0
    private let ownPid = ProcessInfo.processInfo.processIdentifier

    func applicationWillFinishLaunching(_ n: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        NSScrollView.piaHideScrollers()
        Log.write("запуск pia.app, сервер: \(model.client.configPath)")
        NSApp.setActivationPolicy(.accessory)
        // проверочная копия (PIA_TEST_OFFSCREEN) службы на себя не регистрирует
        if !TestHooks.offscreen { Autostart.ensureRegistered().forEach { Log.write("автозапуск: \($0)") } }   // идемпотентно: служба и окно в «Объектах входа» под pia
        buildMenu()
        buildPanel()
        launched = true

        // разрешения при запуске НЕ запрашиваются: без них мониторы ждут и подключатся сами; выдача — в мастере «Разрешения»
        shiftMonitor = RightShiftDoubleTapMonitor { [weak self] in
            DispatchQueue.main.async { self?.captureAndShow() }
        }
        if !TestHooks.offscreen { shiftMonitor?.start() }
        Log.write("двойной правый Shift: монитор запущен (Универсальный доступ: \(RightShiftDoubleTapMonitor.hasAccessibility ? "есть" : "нет"), Мониторинг ввода: \(RightShiftDoubleTapMonitor.hasInputMonitoring ? "есть" : "нет") — не требуется)")
        perms.refresh()
        Log.write("разрешения: \(perms.summary())")
        perms.onGranted = { [weak self] kind in self?.permissionGranted(kind) }
        model.onOpenPermissions = { [weak self] in self?.openPermissions(source: "команда в поле ввода") }
        model.onClosePermissions = { [weak self] in self?.closePermissions() }

        optionMonitor = RightOptionDoubleTapMonitor { [weak self] in
            DispatchQueue.main.async { self?.toggleByOption() }
        }
        if RightOptionDoubleTapMonitor.isEnabled && !TestHooks.offscreen { optionMonitor?.start() }
        Log.write("двойной правый Option: \(RightOptionDoubleTapMonitor.isEnabled ? "включён" : "выключен")")

        // Прятать окно — только когда пользователь реально перешёл в другое приложение
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] n in
            let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = a?.processIdentifier ?? 0, bid = a?.bundleIdentifier ?? "?"
            MainActor.assumeIsolated { self?.otherAppActivated(pid: pid, bundleId: bid) }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panelResignedKey() }
        }

        let urls = pendingURLs; pendingURLs = []
        if UserDefaults.standard.bool(forKey: Permissions.reopenKey) {
            // перезапуск кнопкой «Перезапустить pia» в мастере — сразу вернуть мастер
            UserDefaults.standard.removeObject(forKey: Permissions.reopenKey)
            openPermissions(source: "перезапуск из мастера")
        } else if !CommandLine.arguments.contains("--hidden") && urls.isEmpty { show(source: "запуск") }
        for u in urls { perform(url: u) }
        TestHooks.run(self)
        // при скрытом окне держим ленту свежей, но редко
        Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.panel.isVisible else { return }
                await self.model.pollOnce()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // при запуске службой (--hidden) macOS сразу шлёт reopen — окно при входе в систему не показываем
        if CommandLine.arguments.contains("--hidden"), Date().timeIntervalSince(launchedAt) < 2 {
            Log.write("reopen сразу после запуска --hidden — пропущен")
            if NSApp.isActive && !(panel?.isVisible ?? false) { NSApp.hide(nil) }   // фокус — обратно прежнему приложению
            return false
        }
        if launched { show(source: "reopen") }
        return false
    }

    // Потеря активности сама по себе окно не прячет (это бывает и из-за внутренних событий) — см. otherAppActivated.
    func applicationDidResignActive(_ n: Notification) {
        guard let panel, panel.isVisible, !TestHooks.offscreen else { return }
        Log.write("pia неактивна при видимом окне (впереди: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-"), key=\(panel.isKeyWindow))")
    }

    private var lastMouseActivate = Date.distantPast
    /// Окно видно, а активно другое приложение (окно — nonactivatingPanel): щелчок или наведение мыши на карточку делает pia
    /// активной и окно key — иначе форму курсора и наведение обрабатывает приложение позади (браузер подсвечивает строки под pia).
    private func activateFromMouse(_ how: String) {
        guard let panel, panel.isVisible, panel.alphaValue > 0.5, !TestHooks.offscreen, !perms.wizardVisible, !isFrontmost else { return }
        guard Date().timeIntervalSince(lastMouseActivate) > 0.5 else { return }
        lastMouseActivate = Date()
        Log.write("мышь (\(how)) в окне, а pia не активна (впереди: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-")) — активирую")
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func applicationDidBecomeActive(_ n: Notification) {
        if TestHooks.offscreen { return }
        panel?.level = .floating
    }

    private func otherAppActivated(pid: pid_t, bundleId: String) {
        guard let panel, panel.isVisible, !TestHooks.offscreen, pid != ownPid, bundleId != Bundle.main.bundleIdentifier else { return }
        if perms.wizardVisible {
            // мастер разрешений: пользователь ушёл в Системные настройки / системный запрос — окно не прячем,
            // только опускаем под них (иначе плавающее окно закроет настройки); вернётся — снова поверх
            panel.level = .normal
            Log.write("мастер разрешений: фокус в \(bundleId) — окно остаётся (под ним)")
            return
        }
        if PiaDrop.recentlyDragging || bundleId.hasPrefix("pl.maketheweb") {
            Log.write("фокус ушёл в \(bundleId) во время перетаскивания/CleanShot — не прячу")
            return
        }
        let dt = Date().timeIntervalSince(shownAt)
        if dt < showGrace {
            Log.write("фокус ушёл в \(bundleId) через \(String(format: "%.2f", dt)) с после показа — не прячу, возвращаю фокус")
            focusPanel()
            return
        }
        hide(reason: "переход в \(bundleId)")
    }

    /// Окно не активирующее (nonactivatingPanel): если pia так и не стала активной, а пользователь щёлкнул в окно
    /// уже активного приложения, didActivateApplication не приходит — ловим по потере key.
    private func panelResignedKey() {
        guard !TestHooks.offscreen, !perms.wizardVisible else { return }
        if PiaDrop.recentlyDragging { Log.write("потеря key во время перетаскивания — не прячу"); return }
        let gen = hideGen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, gen == self.hideGen, self.panel.isVisible, !self.panel.isKeyWindow else { return }
            guard Date().timeIntervalSince(self.shownAt) >= self.showGrace else { self.focusPanel(); return }
            if PiaDrop.recentlyDragging || NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.hasPrefix("pl.maketheweb") == true { return }
            // своё окно (поповер, диалог) стало key или pia активна — это не уход
            if NSApp.keyWindow != nil || NSApp.isActive { return }
            let front = NSWorkspace.shared.frontmostApplication
            guard let front, front.processIdentifier != self.ownPid else { return }
            self.hide(reason: "щелчок в \(front.bundleIdentifier ?? "?")")
        }
    }

    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        let s = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue ?? ""
        Log.write("url: \(s)")
        // при холодном запуске по ссылке событие приходит раньше applicationDidFinishLaunching — окна ещё нет
        guard launched else { pendingURLs.append(s); return }
        perform(url: s)
    }

    private func perform(url s: String) {
        let u = URL(string: s)
        let cmd = (u?.host ?? u?.path ?? "show").lowercased()
        switch cmd {
        case "capture", "context": captureAndShow()
        case "hide": hide(reason: "pia://hide")
        case "option-on": setOptionHotkey(true)
        case "option-off": setOptionHotkey(false)
        case "permissions", "permission", "access": openPermissions(source: "pia://\(cmd)")
        case "toggle": isFocused ? hide(reason: "pia://toggle") : show(source: "pia://toggle")
        case "test-width": TestHooks.setCardWidth(self, u)
        case "test-stuck-selection": TestHooks.stuckSelection(self)
        default: show(source: "pia://\(cmd)")
        }
    }

    /// Двойной правый Option: окно активно — спрятать, иначе показать и вывести вперёд (без снимка контекста).
    private func toggleByOption() {
        if isFocused { hide(reason: "двойной правый Option") } else { show(source: "двойной правый Option") }
    }

    func setOptionHotkey(_ on: Bool) {
        RightOptionDoubleTapMonitor.isEnabled = on
        if on { optionMonitor?.start() } else { optionMonitor?.stop() }
        optionItem?.state = on ? .on : .off
        Log.write("двойной правый Option: \(on ? "включён" : "выключен")")
    }

    @objc func toggleOptionHotkey() { setOptionHotkey(!RightOptionDoubleTapMonitor.isEnabled) }

    // MARK: разрешения

    /// Показать мастер разрешений (⌘, , «/разрешения», pia://permissions, перезапуск из мастера).
    func openPermissions(source: String) {
        Log.write("мастер разрешений: открыт (\(source)); \(perms.summary())")
        perms.wizardVisible = true
        show(source: source)
        panel.makeFirstResponder(nil)   // набор не уходит в спрятанное под мастером поле ввода
    }

    /// «Готово» / «Позже» / Esc: закрыть мастер, сам он больше не откроется.
    func closePermissions() {
        guard perms.wizardVisible else { return }
        perms.wizardVisible = false
        UserDefaults.standard.set(true, forKey: Permissions.dismissedKey)
        panel.level = .floating
        Log.write("мастер разрешений: закрыт; \(perms.summary())")
        if let tv = model.inputView { panel.makeFirstResponder(tv) }
    }

    @objc func permissionsAction() { openPermissions(source: "⌘,") }

    /// Разрешение только что появилось: если мастер открыт — вывести окно вперёд (видна галочка).
    /// «Запись экрана» — не выводим: Системные настройки сами предлагают «Завершить и открыть снова», окно бы его закрыло.
    private func permissionGranted(_ kind: Permissions.Kind) {
        guard perms.wizardVisible, panel.isVisible, kind != .screen else { return }
        show(source: "разрешение выдано: \(kind.rawValue)")
    }

    private var isFocused: Bool { panel.isVisible && (panel.isKeyWindow || NSApp.isActive) }

    // MARK: окно

    private func buildPanel() {
        panel = PiaPanel()
        panel.delegate = self
        panel.mouseGuard = StuckMouseGuard(panel: panel)
        panel.mouseGuard?.start()
        panel.onMouseWhileInactive = { [weak self] how in self?.activateFromMouse(how) }
        panel.onCancel = { [weak self] in
            guard let self else { return }
            if self.perms.wizardVisible { self.closePermissions() } else { self.hide(reason: "Esc") }
        }
        let root = ChatView(model: model, onEscape: { [weak self] in self?.hide(reason: "Esc") })
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []

        let m = PiaPanel.margin
        let container = PiaContainerView()
        container.onHover = { [weak self] in self?.panel.onMouseWhileInactive("наведение") }
        let shadow = PiaShadowView()
        let bg = PiaBackgroundView()
        PiaDrop.model = model
        panel.registerForDraggedTypes(PiaDrop.types)
        let edges = ResizeEdgesView()
        edges.onEnd = { [weak self] in self?.panel.saveSize() }
        for v in [shadow, bg] { v.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(v) }
        for v in [host, edges] { v.translatesAutoresizingMaskIntoConstraints = false; bg.addSubview(v) }
        var cs: [NSLayoutConstraint] = []
        for v in [shadow, bg] {
            cs += [v.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: m),
                   v.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -m),
                   v.topAnchor.constraint(equalTo: container.topAnchor, constant: m),
                   v.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -m)]
        }
        for v in [host, edges] {
            cs += [v.leadingAnchor.constraint(equalTo: bg.leadingAnchor), v.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
                   v.topAnchor.constraint(equalTo: bg.topAnchor), v.bottomAnchor.constraint(equalTo: bg.bottomAnchor)]
        }
        NSLayoutConstraint.activate(cs)
        panel.contentView = container
        panel.center()

        panel.ignoresMouseEvents = false
    }

    // MARK: поле под тенью пропускает мышь

    /// Окно шире карточки на margin (тень). Пока окно видно, раз в 1/30 с сверяем курсор с карточкой: снаружи — мышь
    /// проходит в окна позади (не таскается и не щёлкается поле под тенью), внутри — окно ловит всё.
    /// Опрос, а не мониторы событий: прошлая версия на мониторах залипала в «прозрачном» состоянии.
    private var passTimer: Timer?

    private func startPassThrough() {
        passTimer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePassThrough() }
        }
        RunLoop.main.add(t, forMode: .common)   // и во время перетаскивания/изменения размера
        passTimer = t
        updatePassThrough()
    }

    private func stopPassThrough() {
        passTimer?.invalidate()
        passTimer = nil
        panel?.ignoresMouseEvents = false
    }

    private func updatePassThrough() {
        guard let panel, panel.isVisible, !TestHooks.offscreen else { return }
        let inside = panel.cardFrame.insetBy(dx: -1, dy: -1).contains(NSEvent.mouseLocation)
        let ignore = !inside
        guard ignore != panel.ignoresMouseEvents else { return }
        // кнопка зажата (перетаскивание окна, размер, файл в окно) — карточку не отпускаем, но поймать можно всегда
        if ignore && NSEvent.pressedMouseButtons != 0 { return }
        panel.ignoresMouseEvents = ignore
    }

    // MARK: место окна

    /// Окно двинули (перетаскивание, размер за верх/лево) — запомнить, где стоит карточка
    func windowDidMove(_ n: Notification) {
        guard let panel, panel.isVisible, !TestHooks.offscreen else { return }
        let o = panel.cardFrame.origin
        UserDefaults.standard.set(o.x, forKey: "pia.window.x")
        UserDefaults.standard.set(o.y, forKey: "pia.window.y")
    }

    /// Поставить окно туда, где оно было; если того места больше нет на экранах — по центру экрана с курсором
    private func placePanel() {
        let d = UserDefaults.standard
        guard d.object(forKey: "pia.window.x") != nil else { centerOnActiveScreen(); return }
        let m = PiaPanel.margin
        let card = NSRect(x: d.double(forKey: "pia.window.x"), y: d.double(forKey: "pia.window.y"),
                          width: panel.frame.width - 2 * m, height: panel.frame.height - 2 * m)
        // хотя бы верхняя полоса (за неё таскают) должна быть видна на каком-то экране
        let grip = NSRect(x: card.minX, y: card.maxY - ChatView.dragStrip, width: card.width, height: ChatView.dragStrip)
        let ok = NSScreen.screens.contains { s in
            let i = s.visibleFrame.intersection(grip)
            return !i.isNull && i.width >= min(120, card.width) && i.height >= ChatView.dragStrip - 1
        }
        guard ok else { centerOnActiveScreen(); return }
        panel.setFrameOrigin(NSPoint(x: card.minX - m, y: card.minY - m))
    }

    func show(source: String = "") {
        guard let panel else { return }
        hideGen += 1                         // отменяет незавершённое скрытие
        let wasVisible = panel.isVisible && panel.alphaValue > 0.99
        if !panel.isVisible {
            placePanel()
            panel.alphaValue = 0
        }
        panel.ignoresMouseEvents = false
        startPassThrough()
        shownAt = Date()
        perms.startWatching()
        if perms.shouldAutoShow && !perms.wizardVisible {
            perms.wizardVisible = true   // первый запуск без главного разрешения — сначала мастер
            Log.write("мастер разрешений: открыт сам (первый запуск); \(perms.summary())")
        }
        Log.write("показ (\(source)), было видно: \(wasVisible), впереди: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-")")
        panel.level = .floating
        if TestHooks.offscreen {
            // проверочный режим: не отнимать фокус у пользователя, окно под всеми окнами (screencapture -l снимает и так)
            panel.level = ProcessInfo.processInfo.environment["PIA_TEST_FLOAT"] == "1" ? .floating
                : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
            panel.orderFrontRegardless()
            panel.makeKey()
            if ProcessInfo.processInfo.environment["PIA_TEST_DARK"] == "1" { NSApp.appearance = NSAppearance(named: .darkAqua) }
        } else {
            focusPanel()
            // активация из фона (двойной правый Shift) бывает отложенной — проверяем и повторяем
            let gen = hideGen
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, gen == self.hideGen, self.panel.isVisible else { return }
                if !self.isFrontmost || !self.panel.isKeyWindow { self.focusPanel() }
                Log.write("окно: key=\(self.panel.isKeyWindow), pia впереди=\(self.isFrontmost)")
            }
        }
        if !wasVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                panel.animator().alphaValue = 1
            }
            model.scrollToBottomToken += 1
        }
        model.startPolling()
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "окно pia открыто")
        }
    }

    /// pia по-настоящему впереди (frontmostApplication). NSApp.isActive тут не годится: при nonactivatingPanel он бывает true,
    /// хотя впереди осталось другое приложение — тогда курсор и наведение мыши обслуживает оно (браузер подсвечивает строки под pia).
    private var isFrontmost: Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == ownPid }

    /// Окно впереди, key, курсор в поле ввода; приложение — активное.
    private func focusPanel() {
        // Из фона (двойной Shift/Option — глобальный монитор) кооперативный NSApp.activate() macOS не выполняет:
        // окно становится key, но впереди остаётся прежнее приложение. activate(ignoringOtherApps:) делает pia frontmost.
        if !isFrontmost { NSApp.activate(ignoringOtherApps: true) }
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        if perms.wizardVisible { panel.makeFirstResponder(nil); return }
        if let tv = model.inputView, panel.firstResponder !== tv { panel.makeFirstResponder(tv) }
    }

    func hide(reason: String = "") {
        guard let panel, panel.isVisible else { return }
        Log.write("скрыто: \(reason)")
        hideGen += 1
        let gen = hideGen
        model.stopPolling()
        perms.stopWatching()
        stopPassThrough()
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                // окно успели показать снова — не прятать
                guard let self, gen == self.hideGen else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
                if NSApp.isActive { NSApp.hide(nil) }   // фокус возвращается в прежнее приложение
            }
        })
    }

    private func centerOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { panel.center(); return }
        let s = panel.frame.size
        // как Raycast: по центру, чуть выше середины
        let x = vf.midX - s.width / 2
        let y = vf.midY - s.height / 2 + vf.height * 0.06
        panel.setFrameOrigin(NSPoint(x: round(x), y: round(min(y, vf.maxY - s.height + PiaPanel.margin))))
    }

    /// Двойное нажатие правого Shift: сначала снимаем контекст (пока впереди чужое приложение), потом показываем окно
    func captureAndShow() {
        guard !capturing else { return }
        capturing = true
        let pia = isFocused
        Task { @MainActor in
            defer { capturing = false }
            if pia {
                // pia в фокусе — берём первое окно другого приложения под ней (фокус не переключаем)
                if let ctx = await ContextCapture.captureBelowSelf() {
                    model.attachContext(ctx)
                } else {
                    model.showHint("Под окном pia нет окон для захвата")
                }
            } else if let ctx = await ContextCapture.captureFrontmost() {
                model.attachContext(ctx)
            }
            show(source: "двойной правый Shift")
        }
    }

    func windowDidEndLiveResize(_ n: Notification) { panel.saveSize() }

    // Меню не видно (LSUIElement), но без него не работают ⌘C/⌘V/⌘A/⌘Z
    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Скрыть pia", action: #selector(hideAction), keyEquivalent: "w").target = self
        let oi = appMenu.addItem(withTitle: "Открывать по двойному правому Option", action: #selector(toggleOptionHotkey), keyEquivalent: "")
        oi.target = self
        oi.state = RightOptionDoubleTapMonitor.isEnabled ? .on : .off
        optionItem = oi
        appMenu.addItem(withTitle: "Разрешения…", action: #selector(permissionsAction), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: "Выйти из pia", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Правка")
        edit.addItem(withTitle: "Отменить", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Повторить", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Копировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Выделить всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    @objc func hideAction() { hide(reason: "⌘W") }
}

// Непрозрачный фон карточки: светлая тема — белый, тёмная — тёмно-серый; волосяная рамка, скруглённые углы.
/// Контейнер окна: наведение на карточку, когда pia не активна (tracking area .activeAlways — события идут и в неактивное окно)
final class PiaContainerView: NSView {
    var onHover: () -> Void = {}
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseMoved(with e: NSEvent) { check(); super.mouseMoved(with: e) }
    override func mouseEntered(with e: NSEvent) { check() }
    private func check() {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              NSEvent.pressedMouseButtons == 0, let w = window as? PiaPanel, w.cardFrame.contains(NSEvent.mouseLocation) else { return }
        onHover()
    }
}

final class PiaBackgroundView: NSView {
    static let radius: CGFloat = 24
    static func fill(dark: Bool) -> NSColor { dark ? NSColor(srgbRed: 0.106, green: 0.106, blue: 0.11, alpha: 1) : .white }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Self.radius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        registerForDraggedTypes(PiaDrop.types)
        layer?.borderWidth = 0.5   // край как у Raycast AI Chat: 0.5 pt, почти незаметный
        // фон как у Raycast Notes: размытие того, что под окном, + молочная подкраска (bg=blur)
        let fx = NSVisualEffectView(frame: bounds)
        fx.material = .hudWindow; fx.blendingMode = .behindWindow; fx.state = .active
        fx.autoresizingMask = [.width, .height]
        addSubview(fx, positioned: .below, relativeTo: nil)
        tint.frame = bounds; tint.autoresizingMask = [.width, .height]; tint.wantsLayer = true
        addSubview(tint, positioned: .above, relativeTo: fx)
    }
    private let tint = NSView()
    static func tint(dark: Bool) -> NSColor { dark ? NSColor(white: 0.11, alpha: 0.7) : NSColor(white: 0.97, alpha: 0.72) }
    required init?(coder: NSCoder) { fatalError() }
    // приём перетаскивания всей карточкой (дети без своей регистрации отдают drag сюда)
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { PiaDrop.entered(s, where: "карточка") }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation { PiaDrop.canAccept(s.draggingPasteboard) ? .copy : [] }
    override func draggingExited(_ s: NSDraggingInfo?) { PiaDrop.exited(where: "карточка") }
    override func prepareForDragOperation(_ s: NSDraggingInfo) -> Bool { PiaDrop.canAccept(s.draggingPasteboard) }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool { PiaDrop.drop(s, where: "карточка") }
    override func draggingEnded(_ s: NSDraggingInfo) { PiaDrop.active = false; PiaDrop.lastEnd = Date() }
    override var wantsUpdateLayer: Bool { true }
    override var isOpaque: Bool { false }
    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.clear.cgColor
        tint.layer?.backgroundColor = Self.tint(dark: isDark).cgColor
        layer?.borderColor = (isDark ? NSColor(white: 1, alpha: 0.09) : NSColor(white: 0, alpha: 0.07)).cgColor
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// Тень под карточкой (вместо системной): широкая мягкая + узкая контактная.
final class PiaShadowView: NSView {
    private let soft = CALayer(), contact = CALayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for l in [soft, contact] { layer?.addSublayer(l); l.shadowColor = NSColor.black.cgColor; l.masksToBounds = false }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override var isOpaque: Bool { false }
    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
    override func layout() {
        super.layout()
        let path = CGPath(roundedRect: bounds, cornerWidth: PiaBackgroundView.radius, cornerHeight: PiaBackgroundView.radius, transform: nil)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for l in [soft, contact] { l.frame = bounds; l.shadowPath = path }
        CATransaction.commit()
    }
    override func updateLayer() {
        let dark = isDark
        // широкая мягкая (вниз) + близкая контактная; в тёмной теме сильнее, иначе на тёмном фоне не видно
        // shadowRadius у CALayer ≈ половина «blur» из Figma/CSS: 14 ≈ blur 28, 2 ≈ blur 4
        soft.shadowRadius = 14; soft.shadowOffset = CGSize(width: 0, height: -11); soft.shadowOpacity = dark ? 0.34 : 0.20
        contact.shadowRadius = 2; contact.shadowOffset = CGSize(width: 0, height: -1); contact.shadowOpacity = dark ? 0.20 : 0.09
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// Изменение размера за край карточки (полосы ~5 pt по краям и углы); остальное пропускает к содержимому.
final class ResizeEdgesView: NSView {
    var onEnd: () -> Void = {}
    private let band: CGFloat = 5, corner: CGFloat = 14
    private var start: (mouse: NSPoint, frame: NSRect, edges: Set<Edge>)?
    enum Edge { case left, right, top, bottom }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func edges(at p: NSPoint) -> Set<Edge> {
        let w = bounds.width, h = bounds.height
        var e = Set<Edge>()
        if p.y <= band || p.y >= h - band {
            e.insert(p.y <= band ? .bottom : .top)
            if p.x < corner { e.insert(.left) } else if p.x > w - corner { e.insert(.right) }
        }
        if p.x <= band || p.x >= w - band {
            e.insert(p.x <= band ? .left : .right)
            if p.y < corner { e.insert(.bottom) } else if p.y > h - corner { e.insert(.top) }
        }
        return e
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let sv = superview else { return nil }
        let p = convert(point, from: sv)
        return bounds.contains(p) && !edges(at: p).isEmpty ? self : nil
    }

    override func resetCursorRects() {
        let b = bounds, w = b.width, h = b.height
        func add(_ r: NSRect, _ pos: NSCursor.FrameResizePosition) {
            addCursorRect(r, cursor: NSCursor.frameResize(position: pos, directions: .all))
        }
        add(NSRect(x: corner, y: 0, width: w - 2 * corner, height: band), .bottom)
        add(NSRect(x: corner, y: h - band, width: w - 2 * corner, height: band), .top)
        add(NSRect(x: 0, y: corner, width: band, height: h - 2 * corner), .left)
        add(NSRect(x: w - band, y: corner, width: band, height: h - 2 * corner), .right)
        add(NSRect(x: 0, y: 0, width: corner, height: band), .bottomLeft); add(NSRect(x: 0, y: 0, width: band, height: corner), .bottomLeft)
        add(NSRect(x: w - corner, y: 0, width: corner, height: band), .bottomRight); add(NSRect(x: w - band, y: 0, width: band, height: corner), .bottomRight)
        add(NSRect(x: 0, y: h - band, width: corner, height: band), .topLeft); add(NSRect(x: 0, y: h - corner, width: band, height: corner), .topLeft)
        add(NSRect(x: w - corner, y: h - band, width: corner, height: band), .topRight); add(NSRect(x: w - band, y: h - corner, width: band, height: corner), .topRight)
    }

    override func mouseDown(with e: NSEvent) {
        guard let win = window else { return }
        start = (NSEvent.mouseLocation, win.frame, edges(at: convert(e.locationInWindow, from: nil)))
    }

    override func mouseDragged(with e: NSEvent) {
        guard let win = window, let s = start else { return }
        let m = NSEvent.mouseLocation
        let dx = m.x - s.mouse.x, dy = m.y - s.mouse.y
        var f = s.frame
        let minW = win.minSize.width, minH = win.minSize.height
        if s.edges.contains(.right) { f.size.width = max(minW, s.frame.width + dx) }
        if s.edges.contains(.left) { let w = max(minW, s.frame.width - dx); f.origin.x = s.frame.maxX - w; f.size.width = w }
        if s.edges.contains(.top) { f.size.height = max(minH, s.frame.height + dy) }
        if s.edges.contains(.bottom) { let h = max(minH, s.frame.height - dy); f.origin.y = s.frame.maxY - h; f.size.height = h }
        win.setFrame(f, display: true)
    }

    override func mouseUp(with e: NSEvent) {
        if start != nil { onEnd() }
        start = nil
    }
}
