import AppKit

@objc private protocol ClassicOSDService {
    @objc(showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:)
    func showImage(_ image: Int64, onDisplayID: UInt32, priority: UInt32, msecUntilFade: UInt32,
                   filledChiclets: UInt32, totalChiclets: UInt32, locked: Bool)
    @objc(fadeClassicImageOnDisplay:)
    func fadeClassicImage(onDisplay display: UInt32)
}

final class ClassicSystemIndicator {
    private var connection: NSXPCConnection?
    private var display: CGDirectDisplayID?
    private var visibleUntil: TimeInterval = 0
    private var latestRequest: UUID?

    func show(_ control: MediaControl, level: MediaLevel, display: CGDirectDisplayID, onFailure: @escaping () -> Void) {
        if self.display != display { dismiss() }
        let channel: NSXPCConnection
        if let connection {
            channel = connection
        } else {
            channel = NSXPCConnection(machServiceName: "com.apple.OSDUIHelper", options: [])
            channel.remoteObjectInterface = NSXPCInterface(with: ClassicOSDService.self)
            channel.resume()
            connection = channel
        }
        let request = UUID()
        latestRequest = request
        self.display = display
        visibleUntil = ProcessInfo.processInfo.systemUptime + 1.4
        let failed = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.latestRequest == request else { return }
                self.latestRequest = nil
                self.display = nil
                self.connection?.invalidate()
                self.connection = nil
                if ProcessInfo.processInfo.systemUptime < self.visibleUntil { onFailure() }
            }
        }
        guard let proxy = channel.remoteObjectProxyWithErrorHandler({ _ in failed() }) as? ClassicOSDService else {
            failed()
            return
        }
        let silent = control == .volume && (level.muted || level.value == 0)
        let graphic: Int64 = control == .brightness ? 1 : (silent ? 4 : 3)
        let quarters = silent ? 0 : UInt32((min(1, max(0, level.value)) * 64).rounded())
        proxy.showImage(graphic, onDisplayID: display, priority: 500, msecUntilFade: 1000,
                        filledChiclets: quarters, totalChiclets: 64, locked: false)
    }

    func dismiss() {
        latestRequest = nil
        if let display, ProcessInfo.processInfo.systemUptime < visibleUntil,
           let proxy = connection?.remoteObjectProxyWithErrorHandler({ _ in }) as? ClassicOSDService {
            proxy.fadeClassicImage(onDisplay: display)
        }
        display = nil
    }

    deinit { connection?.invalidate() }
}
