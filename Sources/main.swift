import AppKit
import SwiftUI
import ServiceManagement
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let state = SwitcherState()
    let preferences = PreferencesState()
    let catalog = WindowCatalog()
    let keyboard = KeyboardHook()
    var statusItem: NSStatusItem?
    var settingsWindow: NSWindow?
    var panel: SwitcherPanel?
    var timer: Timer?
    var session: UUID?
    var suspended = false
    let layoutItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: "local.windowhop.app").filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty { NSApp.terminate(nil); return }
        NSApp.setActivationPolicy(.accessory)
        preferences.iconChanged = { [weak self] in self?.updateMenu() }
        state.choose = { [weak self] index in self?.state.selection = index; self?.commit() }
        state.imageProvider = { [weak self] id in self?.catalog.cached(id) }
        state.visibilityChanged = { [weak self] in self?.updatePreviewTargets() }
        catalog.onChange = { [weak self] windows in self?.updateWindows(windows) }
        catalog.onThumbnail = { [weak self] id in
            guard let self, self.state.windows.contains(where: { $0.id == id }) else { return }
            self.state.thumbnailRevision &+= 1
        }
        keyboard.switchLayout = { [weak self] in
            guard let self, self.preferences.layoutSwitching else { return }
            let result = Layouts.next()
            self.preferences.error = result == noErr ? nil : "Ошибка переключения раскладки: \(result)"
            self.refreshLayout()
        }
        keyboard.pressed = { [weak self] reverse in self?.cycle(reverse: reverse) }
        keyboard.released = { [weak self] in self?.commit() }
        keyboard.confirm = { [weak self] in self?.commit() }
        keyboard.cancelled = { [weak self] in self?.dismiss() }
        keyboard.move = { [weak self] delta in self?.move(delta) }
        keyboard.settings = { [weak self] in self?.dismiss(); self?.showSettings() }
        keyboard.isSwitching = { [weak self] in self?.session != nil }
        keyboard.canStart = { [weak self] in self?.preferences.recording == true && !(self?.state.windows.isEmpty ?? true) }
        keyboard.columnCount = { [weak self] in self?.state.columns ?? 4 }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(resume), name: NSWorkspace.didWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(resume), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(suspend), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(suspend), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(refreshLayout), name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil)
        createPanel()
        updateMenu()
        refreshPermissions()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if !self.suspended && (self.settingsWindow?.isVisible == true || !self.keyboard.running) { self.refreshPermissions() }
        }
        if !preferences.accessibility || !preferences.recording || CommandLine.arguments.contains("--settings") { showSettings() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func refreshPermissions() {
        preferences.accessibility = AXIsProcessTrusted()
        preferences.recording = CGPreflightScreenCaptureAccess()
        preferences.login = SMAppService.mainApp.status == .enabled
        guard !suspended else { return }
        if preferences.accessibility { keyboard.start() } else { keyboard.stop() }
        if preferences.accessibility && preferences.recording {
            catalog.start()
        } else {
            catalog.stop()
            dismiss()
        }
        preferences.keyboard = keyboard.running
        refreshLayout()
    }

    @objc func suspend() {
        suspended = true
        keyboard.stop()
        dismiss()
    }

    @objc func resume() {
        suspended = false
        refreshPermissions()
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        suspend()
        catalog.stop()
    }

    @objc func refreshLayout() {
        let current = Layouts.name(TISCopyCurrentKeyboardInputSource().takeRetainedValue())
        preferences.currentLayout = current
        preferences.layoutCount = Layouts.enabled().count
        layoutItem.title = "Раскладка: \(current)"
    }

    func menuWillOpen(_ menu: NSMenu) { refreshPermissions() }

    func updateMenu() {

        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem); self.statusItem = nil }
        guard preferences.menuIcon else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "WindowHop")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "WindowHop · ⌘Tab · ⌘⇧"
        let menu = NSMenu()
        menu.delegate = self
        layoutItem.menu?.removeItem(layoutItem)
        menu.addItem(layoutItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Настройки…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Выйти из WindowHop", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        statusItem = item
    }

    @objc func quit() { NSApp.terminate(nil) }

    @objc func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 740), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "WindowHop — настройки"
            window.contentView = NSHostingView(rootView: PreferencesView(state: preferences))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        refreshPermissions()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func updateWindows(_ windows: [WindowItem]) {
        if session != nil {
            let selected = state.selectedID
            let byID = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            state.windows = state.windows.compactMap { byID[$0.id] }
            if state.windows.isEmpty { dismiss(); return }
            if let selected, let index = state.windows.firstIndex(where: { $0.id == selected }) {
                state.selection = index
            } else {
                state.selection = min(state.selection, state.windows.count - 1)
            }
        } else {
            state.windows = windows
            state.selection = windows.count > 1 ? 1 : 0
        }
        resizePanel()
        panel?.contentView?.layoutSubtreeIfNeeded()
        updatePreviewTargets()
    }

    func cycle(reverse: Bool) {
        if session != nil { move(reverse ? -1 : 1); return }
        guard !state.windows.isEmpty else { return }
        let token = UUID()
        session = token
        state.selection = reverse ? state.windows.count - 1 : min(1, state.windows.count - 1)
        resizePanel()
        panel?.orderFrontRegardless()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.session == token else { return }
            self.catalog.beginPreviews(prioritizing: self.previewTargets())
        }
    }

    func move(_ delta: Int) {
        guard !state.windows.isEmpty else { return }
        let count = state.windows.count
        state.selection = ((state.selection + delta) % count + count) % count
        updatePreviewTargets()
    }

    func previewTargets() -> [CGWindowID] {
        guard let selected = state.selectedID else { return [] }
        var visible = state.windows.filter { state.visibleIDs.contains($0.id) }.map(\.id)
        if visible.isEmpty {
            let first = max(0, state.selection / state.columns - 1) * state.columns
            visible = Array(state.windows.dropFirst(first).prefix(state.columns * 3)).map(\.id)
        }
        return [selected] + visible.filter { $0 != selected }
    }

    func updatePreviewTargets() {
        guard session != nil else { return }
        catalog.updateVisiblePreviews(prioritizing: previewTargets())
    }

    func createPanel() {

        let window = SwitcherPanel(contentRect: NSRect(origin: .zero, size: state.layout.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.level = .popUpMenu
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        let container = NSView(frame: NSRect(origin: .zero, size: state.layout.size))
        let hosting = NSHostingView(rootView: SwitcherView(state: state))
        hosting.sizingOptions = []
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        window.contentView = container
        panel = window
    }

    func resizePanel() {
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let available = CGSize(width: max(1, min(1080, frame.width - 80)), height: max(1, frame.height - 80))
        let layout = SwitcherLayout.fit(windowCount: state.windows.count, available: available)
        if state.layout != layout { state.layout = layout }
        let target = NSRect(x: frame.midX - layout.size.width / 2, y: frame.midY - layout.size.height / 2,
                            width: layout.size.width, height: layout.size.height)
        if panel?.frame != target { panel?.setFrame(target, display: true) }
    }

    func commit() {
        guard session != nil, state.windows.indices.contains(state.selection) else { dismiss(); return }
        let item = state.windows[state.selection]
        dismiss()
        catalog.focus(item) { [weak self] success in
            if !success { self?.preferences.error = "Окно закрылось или приложение не разрешило его активировать." }
        }
    }

    func dismiss() {
        let wasSwitching = session != nil
        session = nil
        catalog.endPreviews()
        panel?.orderOut(nil)
        if wasSwitching { updateWindows(catalog.snapshot) }
    }
}

if CommandLine.arguments.contains("--status") {
    print("Accessibility: \(AXIsProcessTrusted() ? "granted" : "not granted")")
    print("Screen Capture: \(CGPreflightScreenCaptureAccess() ? "granted" : "not granted")")
    print("Enabled input sources: \(Layouts.enabled().count)")
    print("Layout switching: \(UserDefaults.standard.object(forKey: "layoutSwitching") as? Bool ?? true)")
    let keyboard = KeyboardHook()
    keyboard.start()
    print("Keyboard hook: \(keyboard.running ? "available" : "unavailable")")
    keyboard.stop()
} else if CommandLine.arguments.contains("--layouts") {
    let current = Layouts.id(TISCopyCurrentKeyboardInputSource().takeRetainedValue())
    for source in Layouts.enabled() { print("\(Layouts.id(source) == current ? "*" : " ") \(Layouts.id(source))\t\(Layouts.name(source))") }
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}

