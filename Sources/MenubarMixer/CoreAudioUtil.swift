import CoreAudio
import Foundation

/// Thin typed wrappers around the CoreAudio property API.
enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func has(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> Bool {
        var a = addr
        return AudioObjectHasProperty(obj, &a)
    }

    static func isSettable(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> Bool {
        var a = addr
        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(obj, &a, &settable) == noErr && settable.boolValue
    }

    static func get<T>(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress, as type: T.Type = T.self) -> T? {
        var a = addr
        var size = UInt32(MemoryLayout<T>.size)
        let p = UnsafeMutableRawPointer.allocate(byteCount: max(Int(size), 8), alignment: max(MemoryLayout<T>.alignment, 8))
        defer { p.deallocate() }
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, p) == noErr else { return nil }
        return p.load(as: T.self)
    }

    static func getArray<T>(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress, as type: T.Type = T.self) -> [T] {
        var a = addr
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let p = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { p.deallocate() }
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, p) == noErr else { return [] }
        return Array(UnsafeBufferPointer(start: p, count: Int(size) / MemoryLayout<T>.stride))
    }

    @discardableResult
    static func set<T>(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ value: T) -> OSStatus {
        var a = addr
        var v = value
        return withUnsafePointer(to: &v) { AudioObjectSetPropertyData(obj, &a, 0, nil, UInt32(MemoryLayout<T>.size), $0) }
    }

    static func string(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String {
        guard let cf: Unmanaged<CFString>? = get(obj, address(selector, scope: scope)), let s = cf else { return "" }
        return s.takeRetainedValue() as String
    }
}

/// Registers CoreAudio property listeners on the main queue and removes them on deinit.
final class CAListener {
    private var entries: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    func add(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress, handler: @escaping () -> Void) {
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        var a = addr
        if AudioObjectAddPropertyListenerBlock(obj, &a, .main, block) == noErr {
            entries.append((obj, addr, block))
        }
    }

    func removeAll() {
        for (obj, addr, block) in entries {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(obj, &a, .main, block)
        }
        entries = []
    }

    deinit { removeAll() }
}
