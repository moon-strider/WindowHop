import AppKit
import Carbon

struct Layouts {
    static func id(_ source: TISInputSource) -> String {
        guard let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "" }
        return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
    }

    static func name(_ source: TISInputSource) -> String {
        guard let value = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else { return id(source) }
        return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
    }

    static func enabled() -> [TISInputSource] {
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as Any,
                      kTISPropertyInputSourceIsEnabled as String: true,
                      kTISPropertyInputSourceIsSelectCapable as String: true] as CFDictionary
        return TISCreateInputSourceList(filter, false).takeRetainedValue() as! [TISInputSource]
    }

    static func next() -> OSStatus {
        let sources = enabled()
        guard sources.count > 1 else { return noErr }
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let index = sources.firstIndex { id($0) == id(current) }
        return TISSelectInputSource(sources[index.map { ($0 + 1) % sources.count } ?? 0])
    }
}

