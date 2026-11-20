import AppKit

final class KeyboardHook {
    var switchLayout: () -> Void = {}
    private var previousFlags: CGEventFlags = []
    var pressed: (Bool) -> Void = { _ in }
    var released: () -> Void = {}
    var cancelled: () -> Void = {}
    var move: (Int) -> Void = { _ in }
    var confirm: () -> Void = {}
    var settings: () -> Void = {}
    var isSwitching: () -> Bool = { false }
    var canStart: () -> Bool = { true }
    var columnCount: () -> Int = { 4 }
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var swallowed = Set<Int64>()
    var running: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    func start() {
        guard tap == nil, AXIsProcessTrusted() else { return }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return Unmanaged<KeyboardHook>.fromOpaque(context).takeUnretainedValue().handle(type, event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask), callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        previousFlags = CGEventSource.flagsState(.combinedSessionState)
        tap = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    func stop() {
        if let tap { CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        tap = nil
        swallowed.removeAll()
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            previousFlags = CGEventSource.flagsState(.combinedSessionState)
            swallowed.removeAll()
            cancelled()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp, swallowed.remove(key) != nil { return nil }
        if type == .flagsChanged {
            let flags = event.flags
            let combination: CGEventFlags = [.maskCommand, .maskShift]
            let blocked: CGEventFlags = [.maskControl, .maskAlternate, .maskSecondaryFn]
            let newlyPressed = flags.subtracting(previousFlags).intersection(combination)
            let wasHeld = previousFlags.contains(combination)
            previousFlags = flags
            if !wasHeld && !newlyPressed.isEmpty && flags.contains(combination) && flags.intersection(blocked).isEmpty {
                switchLayout()
            }
            if isSwitching() && !event.flags.contains(.maskCommand) { released() }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        if key == 48 && (isSwitching() || canStart()) && event.flags.contains(.maskCommand) && !event.flags.contains(.maskAlternate) && !event.flags.contains(.maskControl) {
            swallowed.insert(key)
            pressed(event.flags.contains(.maskShift))
            return nil
        }
        if isSwitching() {
            var handled = true
            switch key {
            case 53: cancelled()
            case 36, 76: confirm()
            case 123: move(-1)
            case 124: move(1)
            case 125: move(columnCount())
            case 126: move(-columnCount())
            case 43 where event.flags.contains(.maskCommand): settings()
            default: handled = false
            }
            if handled { swallowed.insert(key); return nil }
        }
        return Unmanaged.passUnretained(event)
    }
}
