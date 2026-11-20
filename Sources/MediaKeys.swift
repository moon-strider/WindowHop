import AppKit
import AudioToolbox

enum IndicatorStyle: String, CaseIterable, Identifiable {
    case system, classic, notch

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "Системный"
        case .classic: "Классический"
        case .notch: "Из чёлки"
        }
    }

    var detail: String {
        switch self {
        case .system: "Индикатор текущей версии macOS."
        case .classic: "Индикатор с 16 делениями, как в macOS Sequoia."
        case .notch: "Плавное раскрытие от верхнего края экрана."
        }
    }
}

enum MediaControl: CaseIterable, Identifiable {
    case volume, brightness

    var id: Self { self }
    var title: String { self == .volume ? "Громкость" : "Яркость" }
    var preferenceKey: String { self == .volume ? "volumeIndicatorStyle" : "brightnessIndicatorStyle" }

    func icon(level: Float, muted: Bool = false) -> String {
        switch self {
        case .brightness: "sun.max"
        case .volume where muted: "speaker.slash.fill"
        case .volume where level == 0: "speaker.fill"
        case .volume where level < 0.34: "speaker.wave.1.fill"
        case .volume where level < 0.67: "speaker.wave.2.fill"
        case .volume: "speaker.wave.3.fill"
        }
    }
}

enum MediaKey: Int {
    case volumeUp = 0
    case volumeDown = 1
    case brightnessUp = 2
    case brightnessDown = 3
    case mute = 7

    var control: MediaControl {
        switch self {
        case .brightnessUp, .brightnessDown: .brightness
        case .volumeUp, .volumeDown, .mute: .volume
        }
    }

    func nextLevel(from level: Float, fine: Bool) -> Float {
        let steps: Float = fine ? 64 : 16
        let scaled = level * steps
        let up = self == .volumeUp || self == .brightnessUp
        let next = up ? floor(scaled + 0.001) + 1 : ceil(scaled - 0.001) - 1
        return min(1, max(0, next / steps))
    }
}

final class MediaKeyHook {
    var adjust: (MediaKey, Bool) -> Bool = { _, _ in false }
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var swallowed = Set<MediaKey>()
    private static let systemDefined = CGEventType(rawValue: 14)!
    var running: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    func start() {
        guard tap == nil, AXIsProcessTrusted() else { return }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let hook = Unmanaged<MediaKeyHook>.fromOpaque(context).takeUnretainedValue()
            return hook.handle(type, event) ? nil : Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: 1 << Self.systemDefined.rawValue, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return
        }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap { CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        tap = nil
        swallowed.removeAll()
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            swallowed.removeAll()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard type == Self.systemDefined, let mediaEvent = NSEvent(cgEvent: event),
              mediaEvent.subtype.rawValue == 8 else { return false }
        return handle(data: mediaEvent.data1, flags: event.flags)
    }

    func handle(data: Int, flags: CGEventFlags) -> Bool {
        guard let key = MediaKey(rawValue: (data >> 16) & 0xFFFF) else { return false }
        let state = (data >> 8) & 0xFF
        if state == 0xB { return swallowed.remove(key) != nil }
        guard state == 0xA else { return false }
        let repeating = data & 1 != 0
        if repeating && key == .mute && swallowed.contains(key) { return true }
        guard flags.intersection([.maskCommand, .maskControl]).isEmpty else { return false }
        let fine = flags.contains([.maskAlternate, .maskShift])
        guard !flags.contains(.maskAlternate) || (fine && key != .mute), adjust(key, fine) else { return false }
        swallowed.insert(key)
        return true
    }
}

struct MediaLevel {
    let value: Float
    var muted = false
}

struct OutputVolume {
    private let device: AudioDeviceID
    private let volume = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
    private let mute = kAudioDevicePropertyMute

    init?() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var output = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout.size(ofValue: output))
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &output) == noErr,
              output != kAudioObjectUnknown else { return nil }
        device = output
    }

    var level: MediaLevel? {
        guard let value = read(volume, as: Float32(0)), value.isFinite, (0...1).contains(value) else { return nil }
        return MediaLevel(value: value, muted: read(mute, as: UInt32(0)) == 1)
    }

    func adjust(_ key: MediaKey, fine: Bool) -> MediaLevel? {
        guard let current = level, canWrite(volume) else { return nil }
        if key == .mute {
            guard write(mute, value: UInt32(current.muted ? 0 : 1)) else { return nil }
            return level ?? MediaLevel(value: current.value, muted: !current.muted)
        }
        let next = key.nextLevel(from: current.value, fine: fine)
        if current.muted && next > 0 && !canWrite(mute) { return nil }
        guard next == current.value || write(volume, value: next) else { return nil }
        if current.muted && next > 0 && !write(mute, value: UInt32(0)) {
            return next == current.value ? nil : (level ?? MediaLevel(value: next, muted: true))
        }
        return level ?? MediaLevel(value: next)
    }

    private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
    }

    private func canWrite(_ selector: AudioObjectPropertySelector) -> Bool {
        var property = address(selector)
        var writable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &property, &writable) == noErr && writable.boolValue
    }

    private func read<T>(_ selector: AudioObjectPropertySelector, as initialValue: T) -> T? {
        var property = address(selector)
        var value = initialValue
        return withUnsafeMutablePointer(to: &value) { pointer in
            var size = UInt32(MemoryLayout<T>.size)
            guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, pointer) == noErr else { return nil }
            return pointer.pointee
        }
    }

    private func write<T>(_ selector: AudioObjectPropertySelector, value: T) -> Bool {
        var property = address(selector)
        var value = value
        return withUnsafePointer(to: &value) {
            AudioObjectSetPropertyData(device, &property, 0, nil, UInt32(MemoryLayout<T>.size), $0) == noErr
        }
    }
}

struct DisplayBrightness {
    private typealias Read = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Write = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private static let framework = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY | RTLD_LOCAL)
    private static let read = framework.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: Read.self) }
    private static let write = framework.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: Write.self) }
    let display: CGDirectDisplayID

    init?(screen: NSScreen) {
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              CGDisplayIsBuiltin(id.uint32Value) != 0 else { return nil }
        display = id.uint32Value
    }

    var level: Float? {
        var value: Float = 0
        guard Self.read?(display, &value) == 0, value.isFinite, (0...1).contains(value) else { return nil }
        return value
    }

    func adjust(_ key: MediaKey, fine: Bool) -> MediaLevel? {
        guard let current = level, let write = Self.write else { return nil }
        let next = key.nextLevel(from: current, fine: fine)
        guard next == current || write(display, next) == 0 else { return nil }
        return MediaLevel(value: next)
    }
}
