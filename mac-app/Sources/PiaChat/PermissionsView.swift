import AppKit
import SwiftUI

/// Мастер разрешений в окне pia: что нужно, зачем, есть ли сейчас (обновляется сам), кнопки «Разрешить» /
/// «Открыть настройки» / «Перезапустить pia». Открывается сам при первом запуске, если нет главного разрешения,
/// и потом — ⌘, , команда «/разрешения» в поле ввода или `open pia://permissions`.
struct PermissionsView: View {
    @Bindable var perms: Permissions
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            DragArea().frame(height: ChatView.dragStrip)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Разрешения")
                            .font(.system(size: 18, weight: .semibold))
                        Text("pia работает и без них — как обычный чат. Разрешения включают горячие клавиши и дают pia видеть, что у вас на экране. Включайте по одному: нажмите «Разрешить» — macOS спросит сама или откроет нужный раздел настроек; там включите переключатель напротив pia. Другие доступы (например, «Мониторинг ввода») pia не нужны.")
                            .font(.system(size: 12.5))
                            .lineSpacing(2)
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.bottom, 4)

                    PermissionCard(
                        icon: "keyboard", title: "Универсальный доступ", tag: "главное",
                        why: "Открывать pia двойным нажатием правого Option, прикладывать к сообщению то, что на экране, двойным нажатием правого Shift, и читать текст и выделенное в активном окне.",
                        status: perms.accessibility ? .on("Включено") : .off("Выключено"),
                        showButtons: !perms.accessibility,
                        primary: ("Разрешить", { perms.request(.accessibility) }),
                        settings: { perms.openSettings(.accessibility) },
                        hint: perms.asked.contains(.accessibility) && !perms.accessibility
                            ? "В списке включите переключатель напротив pia (macOS может спросить пароль). Уже включён, а здесь всё ещё «Выключено» — перезапустите pia." : nil,
                        restart: perms.asked.contains(.accessibility) && !perms.accessibility ? { perms.relaunch() } : nil,
                        showSettingsButton: false)

                    PermissionCard(
                        icon: "camera.viewfinder", title: "Запись экрана", tag: "необязательно",
                        why: "Прикладывать к сообщению снимок активного окна (по двойному правому Shift). Без него pia возьмёт только текст окна.",
                        status: perms.screen ? .on("Включено") : .off("Выключено"),
                        showButtons: !perms.screen,
                        primary: ("Разрешить", { perms.request(.screen) }),
                        settings: { perms.openSettings(.screen) },
                        hint: perms.asked.contains(.screen) && !perms.screen
                            ? "В списке включите переключатель напротив pia. macOS применяет это разрешение только после перезапуска программы — если включили, нажмите «Перезапустить pia»." : nil,
                        restart: perms.asked.contains(.screen) && !perms.screen ? { perms.relaunch() } : nil,
                        showSettingsButton: false)

                    PermissionCard(
                        icon: "safari", title: "Доступ к браузерам", tag: "необязательно",
                        why: "Брать адрес, заголовок и текст открытой страницы. macOS спрашивает отдельно про каждый браузер — сейчас, если браузер открыт, или при первом захвате.",
                        status: browserStatus,
                        showButtons: browserNeedsAction,
                        primary: perms.browsers.contains { $0.state == .notAsked }
                            ? (perms.askingBrowsers ? "Ждёт ответа…" : "Разрешить", { if !perms.askingBrowsers { perms.request(.browsers) } }) : nil,
                        settings: { perms.openSettings(.browsers) },
                        hint: browserHint,
                        restart: nil,
                        extra: perms.browsers.isEmpty ? nil : AnyView(BrowserChips(browsers: perms.browsers)),
                        footnote: "Чтобы pia видела весь текст страницы в Chrome и похожих браузерах, включите в самом браузере: Вид → Разработчик → «Разрешить JavaScript из Apple Events» (в Safari — меню «Разработка»).")
                }
                .padding(.horizontal, 26)
                .padding(.bottom, 14)
            }
            .scrollIndicators(.hidden)

            HStack(spacing: 10) {
                Text(perms.essentialsGranted
                     ? "Готово к работе. Открыть окно — двойной правый Option, приложить экран — двойной правый Shift."
                     : "Без «Универсального доступа» горячие клавиши не работают. Открыть pia: Spotlight (⌘ Пробел) → pia.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                PillButton(title: perms.essentialsGranted ? "Готово" : "Позже", primary: perms.essentialsGranted, action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 14)
            .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 0.5) }
        }
        .background(Theme.windowBg)
        .background(DragArea())
    }

    private var browserStatus: PermissionCard.Status {
        let b = perms.browsers
        if b.isEmpty { return .neutral("Браузер не открыт") }
        if b.contains(where: { $0.state == .denied }) { return .off("Запрещено") }
        if b.allSatisfy({ $0.state == .allowed }) { return .on("Разрешено") }
        if b.contains(where: { $0.state == .allowed }) { return .neutral("Частично") }
        return .off("Не спрашивали")
    }

    private var browserNeedsAction: Bool {
        perms.browsers.contains { $0.state != .allowed }
    }

    private var browserHint: String? {
        if perms.browsers.contains(where: { $0.state == .denied }) {
            return "Чтобы разрешить запрещённый браузер: «Открыть настройки» → pia → включите переключатель напротив браузера."
        }
        return nil
    }
}

struct PermissionCard: View {
    enum Status { case on(String), off(String), neutral(String) }

    let icon: String
    let title: String
    let tag: String
    let why: String
    let status: Status
    var showButtons: Bool
    var primary: (String, () -> Void)?
    var settings: () -> Void
    var hint: String?
    var restart: (() -> Void)?
    var showSettingsButton = true
    var extra: AnyView? = nil
    var footnote: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.primary.opacity(0.06)))
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 13.5, weight: .semibold))
                    Text(tag)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.faint)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.05)))
                    Spacer(minLength: 8)
                    StatusBadge(status: status)
                }
                Text(why)
                    .font(.system(size: 12.5))
                    .lineSpacing(2)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if let extra { extra }
                if showButtons {
                    HStack(spacing: 8) {
                        if let primary { PillButton(title: primary.0, primary: true, action: primary.1) }
                        if showSettingsButton { PillButton(title: "Открыть настройки", primary: false, action: settings) }
                        if let restart { PillButton(title: "Перезапустить pia", primary: false, action: restart) }
                    }
                    .padding(.top, 2)
                }
                if let hint {
                    Text(hint)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let footnote {
                    Text(footnote)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
        .animation(.snappy(duration: 0.2), value: showButtons)
    }
}

struct StatusBadge: View {
    let status: PermissionCard.Status
    var body: some View {
        HStack(spacing: 5) {
            switch status {
            case .on(let t):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(t).foregroundStyle(.primary)
            case .off(let t):
                Image(systemName: "circle").foregroundStyle(Theme.faint)
                Text(t).foregroundStyle(Theme.muted)
            case .neutral(let t):
                Image(systemName: "circle.dashed").foregroundStyle(Theme.faint)
                Text(t).foregroundStyle(Theme.muted)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .lineLimit(1)
        .fixedSize()
    }
}

struct BrowserChips: View {
    let browsers: [Permissions.Browser]
    var body: some View {
        HStack(spacing: 6) {
            ForEach(browsers, id: \.bundleId) { b in
                HStack(spacing: 5) {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b.bundleId) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 14, height: 14)
                    }
                    Text(b.name).foregroundStyle(.secondary)
                    Text(b.state == .allowed ? "разрешено" : b.state == .denied ? "запрещено" : "не спрашивали")
                        .foregroundStyle(b.state == .allowed ? AnyShapeStyle(.green) : AnyShapeStyle(Theme.faint))
                }
                .font(.system(size: 11.5, weight: .medium))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.07)))
            }
        }
    }
}

/// Кнопка-капсула: главная — графитовая (как пузырь своих сообщений), обычная — светло-серая.
struct PillButton: View {
    let title: String
    var primary: Bool
    var action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(primary ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .padding(.horizontal, 13)
                .padding(.vertical, 6)
                .background(Capsule().fill(primary ? Theme.bubble : Color.primary.opacity(hover ? 0.1 : 0.065)))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(primary ? 0 : 0.07)))
                .opacity(primary && hover ? 0.88 : 1)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Строка над полем ввода, когда нет главного разрешения и мастер закрыт: щелчок — открыть мастер.
struct PermissionsHintLine: View {
    var onOpen: () -> Void
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(Color.primary.opacity(0.3)).frame(width: 6, height: 6)
            Text("Горячие клавиши выключены: нет разрешения.").font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
            Text("Настроить").font(.system(size: 12, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }
}
