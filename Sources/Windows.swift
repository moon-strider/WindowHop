import AppKit
import ScreenCaptureKit
import ApplicationServices

struct WindowItem: Identifiable {
    let id: CGWindowID
    let pid: pid_t
    let title: String
    let appName: String
    let icon: NSImage?
    let element: AXUIElement
    let minimized: Bool
}

func axValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value
}

func windowID(_ element: AXUIElement) -> CGWindowID? {
    typealias Getter = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
    var id: CGWindowID = 0
    guard unsafeBitCast(symbol, to: Getter.self)(element, &id) == .success, id != 0 else { return nil }
    return id
}

private final class ObservedApplication {
    let pid: pid_t
    let name: String
    let icon: NSImage?
    let element: AXUIElement
    let observer: AXObserver?
    var registeredWindows = Set<CGWindowID>()
    var subscribed = false
    var refreshing = false
    var needsRefresh = false
    var pending: DispatchWorkItem?
    var windows: [WindowItem] = []

    init(_ app: NSRunningApplication, context: UnsafeMutableRawPointer) {
        pid = app.processIdentifier
        name = app.localizedName ?? "Приложение"
        icon = app.icon
        element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.08)
        var result: AXObserver?
        AXObserverCreate(pid, { _, element, notification, context in
            guard let context else { return }
            let catalog = Unmanaged<WindowCatalog>.fromOpaque(context).takeUnretainedValue()
            catalog.received(element, notification as String)
        }, &result)
        observer = result
    }
}

final class WindowCatalog {
    var onChange: ([WindowItem]) -> Void = { _ in }
    var onThumbnail: (CGWindowID) -> Void = { _ in }
    private(set) var snapshot: [WindowItem] = []
    private let discovery = OperationQueue()
    private let focusQueue = DispatchQueue(label: "local.windowhop.focus", qos: .userInitiated)
    private let cache = NSCache<NSNumber, NSImage>()
    private var applications: [pid_t: ObservedApplication] = [:]
    private var recent: [CGWindowID: TimeInterval] = [:]
    private var stackingOrder: [CGWindowID: Int] = [:]
    private var lastFocus: CGWindowID?
    private var focusInFlight = false
    private var running = false
    private var generation = UUID()
    private var maintenance: Timer?
    private var focusTimer: Timer?
    private var workspaceTokens: [NSObjectProtocol] = []
    private var captureWindows: [CGWindowID: SCWindow] = [:]
    private var previewSession: UUID?
    private var visiblePreviewIDs: [CGWindowID] = []
    private var attemptedPreviewIDs = Set<CGWindowID>()
    private var captureCatalogReady = false
    private var captureDiscoveryInFlight = false
    private var captureQueue: [CGWindowID] = []
    private var queuedCaptures = Set<CGWindowID>()
    private var capturing = Set<CGWindowID>()
    private var lastCapture: [CGWindowID: TimeInterval] = [:]
    private var lastCaptureAttempt: [CGWindowID: TimeInterval] = [:]
    private let previewLifetime: TimeInterval = 60
    private var paused = false

    init() {
        cache.totalCostLimit = 48 * 1024 * 1024
        cache.countLimit = 150
        discovery.name = "local.windowhop.discovery"
        discovery.maxConcurrentOperationCount = 3
        discovery.qualityOfService = .utility
    }

    func cached(_ id: CGWindowID) -> NSImage? { cache.object(forKey: NSNumber(value: id)) }

    func start() {
        guard !running else { return }
        running = true
        generation = UUID()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            workspaceTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let self else { return }
                self.syncApplications()
                if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                    self.refresh(app.processIdentifier)
                } else {
                    for pid in self.applications.keys { self.refresh(pid) }
                }
                self.trackFocus()
                self.refreshCaptureWindows()
            })
        }
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspaceTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.paused = true
                self?.captureQueue.removeAll()
                self?.queuedCaptures.removeAll()
            })
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspaceTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.paused = false
                self?.syncApplications()
                self?.refreshCaptureWindows()
            })
        }
        syncApplications()
        refreshStackingOrder()
        trackFocus()
        refreshCaptureWindows()
        maintenance = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in
            guard let self, !self.paused else { return }
            self.syncApplications()
            for pid in self.applications.keys { self.refresh(pid) }
        }
        focusTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, !self.paused else { return }
            self.trackFocus()
        }
    }

    func stop() {
        guard running else { return }
        running = false
        generation = UUID()
        maintenance?.invalidate()
        focusTimer?.invalidate()
        endPreviews()
        for token in workspaceTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        workspaceTokens.removeAll()
        for app in applications.values { detach(app) }
        applications.removeAll()
        snapshot.removeAll()
        captureQueue.removeAll()
        queuedCaptures.removeAll()
        captureWindows.removeAll()
        cache.removeAllObjects()
        lastCapture.removeAll()
        lastCaptureAttempt.removeAll()
        onChange([])
    }

    private func detach(_ app: ObservedApplication) {
        app.pending?.cancel()
        if let observer = app.observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
    }

    private func syncApplications() {
        guard running else { return }
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != getpid() && !$0.isTerminated
        }
        let alive = Set(apps.map(\.processIdentifier))
        for pid in Array(applications.keys) where !alive.contains(pid) {
            if let app = applications.removeValue(forKey: pid) { detach(app) }
        }
        for app in apps where applications[app.processIdentifier] == nil {
            let observed = ObservedApplication(app, context: Unmanaged.passUnretained(self).toOpaque())
            applications[observed.pid] = observed
            if let observer = observed.observer { CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
            refresh(observed.pid)
        }
        publish()
    }

    fileprivate func received(_ element: AXUIElement, _ notification: String) {
        guard running else { return }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        if notification == kAXFocusedWindowChangedNotification { trackFocus() }
        if notification == kAXUIElementDestroyedNotification, let app = applications[pid] {
            app.windows.removeAll { CFEqual($0.element, element) }
            publish()
        }
        refresh(pid)
    }

    private func refresh(_ pid: pid_t) {
        guard running, let app = applications[pid] else { return }
        if app.refreshing { app.needsRefresh = true; return }
        guard app.pending == nil else { return }
        let work = DispatchWorkItem { [weak self, weak app] in
            guard let self, let app, self.applications[pid] === app else { return }
            app.pending = nil
            self.enumerate(app)
        }
        app.pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: work)
    }

    private func enumerate(_ app: ObservedApplication) {
        guard running else { return }
        app.refreshing = true
        let token = generation
        let context = Unmanaged.passUnretained(self).toOpaque()
        let previouslyRegistered = app.registeredWindows
        let subscribed = app.subscribed
        discovery.addOperation {
            if !subscribed, let observer = app.observer {
                for name in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification] {
                    AXObserverAddNotification(observer, app.element, name as CFString, context)
                }
            }
            let elements = axValue(app.element, kAXWindowsAttribute) as? [AXUIElement]
            var windows: [WindowItem] = []
            var ids = Set<CGWindowID>()
            for element in elements ?? [] {
                guard let id = windowID(element), ids.insert(id).inserted else { continue }
                let role = axValue(element, kAXSubroleAttribute) as? String
                guard role == kAXStandardWindowSubrole || role == kAXDialogSubrole else { continue }
                let title = axValue(element, kAXTitleAttribute) as? String ?? ""
                let minimized = axValue(element, kAXMinimizedAttribute) as? Bool ?? false
                windows.append(WindowItem(id: id, pid: app.pid, title: title.isEmpty ? app.name : title,
                    appName: app.name, icon: app.icon, element: element, minimized: minimized))
                if !previouslyRegistered.contains(id), let observer = app.observer {
                    for name in [kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification,
                                 kAXWindowDeminiaturizedNotification, kAXTitleChangedNotification] {
                        AXObserverAddNotification(observer, element, name as CFString, context)
                    }
                }
            }
            DispatchQueue.main.async {
                guard self.running, self.generation == token, self.applications[app.pid] === app else { return }
                app.refreshing = false
                app.subscribed = true
                if elements != nil {
                    let oldIDs = Set(app.windows.map(\.id))
                    app.windows = windows
                    app.registeredWindows = ids
                    self.publish()
                    self.enqueueVisiblePreviews()
                    if oldIDs != Set(windows.map(\.id)) { self.refreshCaptureWindows() }
                }
                if app.needsRefresh { app.needsRefresh = false; self.refresh(app.pid) }
            }
        }
    }

    private func publish() {
        let items = applications.values.flatMap(\.windows)
        let alive = Set(items.map(\.id))
        recent = recent.filter { alive.contains($0.key) || $0.key == lastFocus }
        for id in Array(lastCapture.keys) where !alive.contains(id) {
            cache.removeObject(forKey: NSNumber(value: id))
            lastCapture.removeValue(forKey: id)
        }
        lastCaptureAttempt = lastCaptureAttempt.filter { alive.contains($0.key) }
        snapshot = items.sorted {
            let a = recent[$0.id] ?? 0
            let b = recent[$1.id] ?? 0
            if a != b { return a > b }
            let rankA = stackingOrder[$0.id] ?? Int.max
            let rankB = stackingOrder[$1.id] ?? Int.max
            if rankA != rankB { return rankA < rankB }
            return $0.id < $1.id
        }
        onChange(snapshot)
    }

    private func refreshStackingOrder() {
        let token = generation
        discovery.addOperation {
            let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            let ids = list.compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
            let order = Dictionary(ids.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { a, _ in a })
            DispatchQueue.main.async {
                guard self.running, self.generation == token else { return }
                self.stackingOrder = order
                self.publish()
            }
        }
    }

    private func trackFocus() {
        guard running, !focusInFlight, let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier, pid != getpid() else { return }
        focusInFlight = true
        let token = generation
        focusQueue.async {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.08)
            var id: CGWindowID?
            if let value = axValue(app, kAXFocusedWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() {
                id = windowID(value as! AXUIElement)
            }
            DispatchQueue.main.async {
                self.focusInFlight = false
                guard self.running, self.generation == token, let id,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                if self.lastFocus != id {
                    self.lastFocus = id
                    self.recent[id] = Date.timeIntervalSinceReferenceDate
                    self.publish()
                }
            }
        }
    }

    private func needsPreviewRefresh(_ id: CGWindowID) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if let attempted = lastCaptureAttempt[id], now - attempted < previewLifetime { return false }
        guard cached(id) != nil, let captured = lastCapture[id] else { return true }
        return now - captured >= previewLifetime
    }

    private func matchesCachedImage(_ image: CGImage, id: CGWindowID) -> Bool {
        guard let previous = cached(id)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              previous.width == image.width, previous.height == image.height,
              previous.bitsPerComponent == image.bitsPerComponent, previous.bitsPerPixel == image.bitsPerPixel,
              previous.bytesPerRow == image.bytesPerRow, previous.bitmapInfo == image.bitmapInfo,
              let previousSpace = previous.colorSpace, let currentSpace = image.colorSpace,
              CFEqual(previousSpace, currentSpace),
              let previousData = previous.dataProvider?.data, let currentData = image.dataProvider?.data else { return false }
        return CFEqual(previousData, currentData)
    }

    private func refreshCaptureWindows() {

        guard running, !paused, previewSession != nil, !captureDiscoveryInFlight else { return }
        let eligible = Set(snapshot.filter { !$0.minimized }.map(\.id))
        guard visiblePreviewIDs.contains(where: { eligible.contains($0) && needsPreviewRefresh($0) && !capturing.contains($0) && !attemptedPreviewIDs.contains($0) }) else { return }
        captureDiscoveryInFlight = true
        let token = generation
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { content, _ in
            DispatchQueue.main.async {
                self.captureDiscoveryInFlight = false
                guard self.running, self.generation == token else { return }
                if let content {
                    self.captureWindows = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
                    self.captureCatalogReady = self.previewSession != nil
                    self.enqueueVisiblePreviews()
                }
            }
        }
    }

    func beginPreviews(prioritizing ids: [CGWindowID]) {
        guard running, !paused else { return }
        endPreviews()
        previewSession = UUID()
        visiblePreviewIDs = ids
        refreshCaptureWindows()
    }

    func updateVisiblePreviews(prioritizing ids: [CGWindowID]) {
        guard previewSession != nil else { return }
        visiblePreviewIDs = ids
        let visible = Set(ids)
        captureQueue.removeAll { !visible.contains($0) }
        queuedCaptures.formIntersection(visible)
        if captureCatalogReady { enqueueVisiblePreviews() } else { refreshCaptureWindows() }
    }

    func endPreviews() {
        previewSession = nil
        visiblePreviewIDs.removeAll()
        attemptedPreviewIDs.removeAll()
        captureQueue.removeAll()
        queuedCaptures.removeAll()
        captureCatalogReady = false
    }

    private func enqueueVisiblePreviews() {
        guard running, !paused, previewSession != nil, captureCatalogReady else { return }
        let available = Set(snapshot.filter { !$0.minimized }.map(\.id))
        for id in visiblePreviewIDs where available.contains(id) && captureWindows[id] != nil {
            guard needsPreviewRefresh(id), !attemptedPreviewIDs.contains(id), !capturing.contains(id), !queuedCaptures.contains(id) else { continue }
            captureQueue.append(id)
            queuedCaptures.insert(id)
        }
        let priority = Dictionary(visiblePreviewIDs.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { a, _ in a })
        captureQueue.sort { (priority[$0] ?? Int.max) < (priority[$1] ?? Int.max) }
        pumpCaptures()
    }

    private func pumpCaptures() {
        guard running, !paused, previewSession != nil, captureCatalogReady else { return }
        while capturing.count < 2 && !captureQueue.isEmpty {
            let id = captureQueue.removeFirst()
            queuedCaptures.remove(id)
            guard needsPreviewRefresh(id), visiblePreviewIDs.contains(id), let item = snapshot.first(where: { $0.id == id }), !item.minimized,
                  let window = captureWindows[id], window.frame.width > 0, window.frame.height > 0 else { continue }
            capturing.insert(id)
            attemptedPreviewIDs.insert(id)
            lastCaptureAttempt[id] = ProcessInfo.processInfo.systemUptime
            let token = generation
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            let scale = min(1, 560 / window.frame.width, 360 / window.frame.height)
            config.width = max(1, Int(window.frame.width * scale))
            config.height = max(1, Int(window.frame.height * scale))
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, _ in
                DispatchQueue.main.async {
                    self.capturing.remove(id)
                    guard self.running, self.generation == token else { self.enqueueVisiblePreviews(); return }
                    if let image, self.snapshot.contains(where: { $0.id == id }) {
                        self.lastCapture[id] = ProcessInfo.processInfo.systemUptime
                        if self.matchesCachedImage(image, id: id) { self.enqueueVisiblePreviews(); return }
                        self.cache.setObject(NSImage(cgImage: image, size: .zero), forKey: NSNumber(value: id), cost: image.bytesPerRow * image.height)
                        self.onThumbnail(id)
                    }
                    self.enqueueVisiblePreviews()
                }
            }
        }
    }

    func focus(_ item: WindowItem, completion: @escaping (Bool) -> Void) {
        focusQueue.async {
            guard let app = NSRunningApplication(processIdentifier: item.pid), !app.isTerminated else {
                DispatchQueue.main.async { self.refresh(item.pid); completion(false) }
                return
            }
            AXUIElementSetMessagingTimeout(item.element, 0.2)
            let restore = AXUIElementSetAttributeValue(item.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            DispatchQueue.main.async {
                app.unhide()
                app.activate(options: [])
                self.focusQueue.asyncAfter(deadline: .now() + (item.minimized ? 0.35 : 0.02)) {
                    AXUIElementSetAttributeValue(item.element, kAXMainAttribute as CFString, kCFBooleanTrue)
                    let raised = AXUIElementPerformAction(item.element, kAXRaiseAction as CFString)
                    DispatchQueue.main.async {
                        if raised == .success {
                            self.recent[item.id] = Date.timeIntervalSinceReferenceDate
                            self.lastFocus = item.id
                            self.publish()
                        }
                        self.refresh(item.pid)
                        completion(raised == .success && (!item.minimized || restore == .success))
                    }
                }
            }
        }
    }
}
