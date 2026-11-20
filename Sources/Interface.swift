import AppKit
import SwiftUI
import ServiceManagement

struct SwitcherLayout: Equatable {
    static let gap: CGFloat = 12
    static let inset: CGFloat = 20
    static let cardHeight: CGFloat = 210
    let columns: Int
    let cardWidth: CGFloat
    let size: CGSize

    static func fit(windowCount: Int, available: CGSize) -> SwitcherLayout {
        let count = max(1, windowCount)
        let cardWidth = min(240, max(1, available.width - inset * 2))
        let capacity = max(1, Int((available.width - inset * 2 + gap) / (cardWidth + gap)))
        let columns = min(4, count, capacity)
        let rows = min(3, (count + columns - 1) / columns)
        let width = CGFloat(columns) * cardWidth + CGFloat(columns - 1) * gap + inset * 2
        let height = min(available.height, CGFloat(rows) * cardHeight + CGFloat(rows - 1) * gap + inset * 2)
        return SwitcherLayout(columns: columns, cardWidth: cardWidth, size: CGSize(width: width, height: max(1, height)))
    }
}

final class SwitcherState: ObservableObject {

    @Published var windows: [WindowItem] = []
    @Published var selection = 0
    @Published var layout = SwitcherLayout.fit(windowCount: 1, available: CGSize(width: 1080, height: 800))
    var columns: Int { layout.columns }
    @Published var thumbnailRevision = 0
    var visibleIDs = Set<CGWindowID>()
    var visibilityChanged: () -> Void = {}
    var imageProvider: (CGWindowID) -> NSImage? = { _ in nil }
    var choose: (Int) -> Void = { _ in }
    var selectedID: CGWindowID? { windows.indices.contains(selection) ? windows[selection].id : nil }
}

private struct WindowFrames: PreferenceKey {
    static var defaultValue: [CGWindowID: CGRect] = [:]
    static func reduce(value: inout [CGWindowID: CGRect], nextValue: () -> [CGWindowID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

struct SwitcherView: View {

    @ObservedObject var state: SwitcherState
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(state.layout.cardWidth), spacing: SwitcherLayout.gap), count: state.columns), spacing: SwitcherLayout.gap) {
                    ForEach(Array(state.windows.enumerated()), id: \.element.id) { index, item in
                        let image = state.imageProvider(item.id)
                        Button { state.choose(index) } label: {
                            WindowCard(item: item, image: image, selected: index == state.selection, width: state.layout.cardWidth)
                        }
                        .buttonStyle(.plain)
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: WindowFrames.self, value: [item.id: geometry.frame(in: .named("windowhop-viewport"))])
                        })
                        .id(item.id)
                        .accessibilityLabel("\(item.appName): \(item.title)")
                        .accessibilityValue("\(index == state.selection ? "Выбрано" : "Не выбрано"), \(image != nil ? "Превью доступно" : "Без превью")\(item.minimized ? ", свёрнуто" : "")")
                        .accessibilityIdentifier("window-\(item.id)")
                    }
                }.padding(4)
            }
            .scrollIndicators(.hidden)
            .coordinateSpace(name: "windowhop-viewport")
            .onPreferenceChange(WindowFrames.self) { frames in
                let viewport = CGRect(x: 0, y: 0, width: max(1, state.layout.size.width - 32), height: max(1, state.layout.size.height - 32))
                let visible = Set(frames.filter { $0.value.intersects(viewport) }.map(\.key))
                if state.visibleIDs != visible {
                    state.visibleIDs = visible
                    state.visibilityChanged()
                }
            }
            .onChange(of: state.selection) {
                if let id = state.selectedID { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .padding(16)
        .frame(width: state.layout.size.width, height: state.layout.size.height)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.12)))
        .preferredColorScheme(.dark)
    }
}

private struct WindowPreview: View {
    let image: NSImage?
    let icon: NSImage?
    let minimized: Bool

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(4)
            } else {
                VStack(spacing: 9) {
                    if let icon { Image(nsImage: icon).resizable().frame(width: 48, height: 48) }
                    if minimized { Text("Окно свёрнуто").font(.system(size: 11)).foregroundStyle(.secondary) }
                }
            }
        }
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }
}

struct WindowCard: View {

    let item: WindowItem
    let image: NSImage?
    let selected: Bool
    let width: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.28))
                WindowPreview(image: image, icon: item.icon, minimized: item.minimized)
                if item.minimized && image != nil {
                    VStack { Spacer(); Text("Свёрнуто · последний кадр").font(.system(size: 10)).padding(5).background(.black.opacity(0.75)).clipShape(Capsule()) }.padding(6)
                }
            }.frame(width: max(1, width - 20), height: 140).clipped()
            HStack(spacing: 7) {
                if let icon = item.icon { Image(nsImage: icon).resizable().frame(width: 17, height: 17) }
                Text(item.appName).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
        }
        .padding(10)
        .frame(width: width, height: SwitcherLayout.cardHeight, alignment: .topLeading)
        .background(selected ? Color.mint.opacity(0.14) : Color.white.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? Color.mint : .white.opacity(0.09), lineWidth: selected ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .help(item.title)
    }
}

final class PreferencesState: ObservableObject {
    @Published var accessibility = false
    @Published var recording = false
    @Published var keyboard = false
    @Published var currentLayout = ""
    @Published var layoutCount = 0
    @Published var layoutSwitching = UserDefaults.standard.object(forKey: "layoutSwitching") as? Bool ?? true
    @Published var login = false
    @Published var error: String?
    @Published var menuIcon = UserDefaults.standard.object(forKey: "menuIcon") as? Bool ?? true
    var iconChanged: () -> Void = {}
    var refresh: () -> Void = {}

    func setLayoutSwitching(_ enabled: Bool) {
        layoutSwitching = enabled
        UserDefaults.standard.set(enabled, forKey: "layoutSwitching")
    }

    func setIcon(_ visible: Bool) {
        menuIcon = visible
        UserDefaults.standard.set(visible, forKey: "menuIcon")
        iconChanged()
    }

    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            login = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
                error = "Разрешите запуск WindowHop в настройках объектов входа."
            } else { error = nil }
        } catch { self.error = "Не удалось изменить автозапуск: \(error.localizedDescription)" }
    }
}

struct PreferencesView: View {
    @ObservedObject var state: PreferencesState
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(systemName: "rectangle.on.rectangle").font(.system(size: 35)).foregroundStyle(.mint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("WindowHop").font(.system(size: 27, weight: .bold))
                    Text("Каждое окно — под рукой.").foregroundStyle(.secondary)
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 9) {
                Text("Удерживайте ⌘ и нажимайте Tab").font(.headline)
                Text("Отпустите ⌘, чтобы открыть выбранное окно. ⇧Tab — назад, стрелки — выбор, Esc — отмена.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            VStack(alignment: .leading, spacing: 15) {
                permission("Универсальный доступ", detail: "Чтобы переключать окна и раскладку клавиатуры.", granted: state.accessibility) {
                    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                    AXIsProcessTrustedWithOptions(options)
                    openPrivacy("Privacy_Accessibility")
                }
                permission("Запись экрана", detail: "Чтобы показать миниатюры окон на этом Mac.", granted: state.recording) {
                    CGRequestScreenCaptureAccess()
                    openPrivacy("Privacy_ScreenCapture")
                }
            }
            HStack(spacing: 7) {
                Circle().fill(state.keyboard && state.recording ? Color.green : Color.orange).frame(width: 7, height: 7)
                Text(state.keyboard && state.recording ? "Готово к работе" : "Включите оба разрешения для работы переключателя")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 9) {
                Toggle("Переключать раскладку по ⌘ + ⇧", isOn: Binding(get: { state.layoutSwitching }, set: state.setLayoutSwitching))
                Text("Сразу при нажатии второй клавиши, в любом порядке. Сочетания ⌘⇧Tab и ⌘⇧T тоже меняют раскладку.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(!state.keyboard ? "Для смены раскладки нужен Универсальный доступ." : state.layoutCount < 2 ? "Добавьте вторую раскладку в macOS." : "Текущая раскладка: \(state.currentLayout)")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 13) {

                Toggle("Показывать иконку в строке меню", isOn: Binding(get: { state.menuIcon }, set: state.setIcon))
                Toggle("Запускать при входе в macOS", isOn: Binding(get: { state.login }, set: state.setLogin))
                Text("Иконки в Dock нет. Если скрыть иконку в меню, настройки можно открыть повторным запуском WindowHop через Spotlight или Finder.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error = state.error { Text(error).font(.system(size: 12)).foregroundStyle(.orange) }
            Spacer(minLength: 0)
            HStack {
                Text("Локально. Без рекламы и сетевых запросов.").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Выйти") { NSApp.terminate(nil) }
            }
        }
        .padding(28)
        .frame(width: 540, height: 740)
    }

    func permission(_ title: String, detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(granted ? .green : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted { Button("Разрешить", action: action) }
        }
    }

    func openPrivacy(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") { NSWorkspace.shared.open(url) }
    }
}

final class SwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
