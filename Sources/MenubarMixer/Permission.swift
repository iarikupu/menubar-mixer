import Foundation

enum AudioPermission: Equatable {
    case unknown      // never asked
    case denied
    case authorized
}

/// "System Audio Recording" (kTCCServiceAudioCapture) — required for process taps to deliver audio.
/// There is no public API to query it, so this uses the same private TCC calls other tap-based apps use.
/// If the symbols aren't available the state is reported as `.unknown` and taps are attempted anyway.
enum AudioCapturePermission {
    private static let service = "kTCCServiceAudioCapture" as CFString

    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

    private static let handle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static var isQueryable: Bool { handle != nil && dlsym(handle, "TCCAccessPreflight") != nil }

    static func status() -> AudioPermission {
        guard let handle, let sym = dlsym(handle, "TCCAccessPreflight") else { return .unknown }
        let fn = unsafeBitCast(sym, to: PreflightFn.self)
        switch fn(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }

    static func request(_ completion: @escaping (Bool) -> Void) {
        guard let handle, let sym = dlsym(handle, "TCCAccessRequest") else { completion(false); return }
        let fn = unsafeBitCast(sym, to: RequestFn.self)
        fn(service, nil) { granted in DispatchQueue.main.async { completion(granted) } }
    }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
}
