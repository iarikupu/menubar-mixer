import AppKit
import CoreAudio
import Darwin
import Foundation

/// One CoreAudio "process object" (a process that has opened an audio client).
struct AudioProc {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let runningOutput: Bool
}

/// The user-facing application an audio process belongs to (browser helpers roll up into the browser).
struct HostApp: Hashable {
    let path: String
    let bundleID: String
    let name: String

    /// Stable key used for remembered volumes.
    var persistKey: String { bundleID.isEmpty ? path : bundleID }
}

enum AudioProcs {
    static func list() -> [AudioProc] {
        let ids: [AudioObjectID] = CA.getArray(CA.system, CA.address(kAudioHardwarePropertyProcessObjectList))
        return ids.compactMap { id in
            guard let pid: pid_t = CA.get(id, CA.address(kAudioProcessPropertyPID)) else { return nil }
            let running: UInt32 = CA.get(id, CA.address(kAudioProcessPropertyIsRunningOutput)) ?? 0
            return AudioProc(objectID: id, pid: pid, bundleID: CA.string(id, kAudioProcessPropertyBundleID), runningOutput: running != 0)
        }
    }

    static func isRunningOutput(_ id: AudioObjectID) -> Bool {
        (CA.get(id, CA.address(kAudioProcessPropertyIsRunningOutput), as: UInt32.self) ?? 0) != 0
    }

    // MARK: pid → app

    private static var hostCache: [String: HostApp] = [:]
    private static var pidCache: [pid_t: String?] = [:]

    static func forgetPids(except live: Set<pid_t>) {
        pidCache = pidCache.filter { live.contains($0.key) }
    }

    static func hostApp(forPid pid: pid_t) -> HostApp? {
        if let cached = pidCache[pid] { return cached.flatMap { hostCache[$0] } }
        let path = appBundlePath(forPid: pid) ?? responsiblePid(pid).flatMap { $0 != pid ? appBundlePath(forPid: $0) : nil }
        pidCache[pid] = .some(path)
        guard let path else { return nil }
        if hostCache[path] == nil {
            let bundle = Bundle(path: path)
            hostCache[path] = HostApp(path: path,
                                      bundleID: bundle?.bundleIdentifier ?? "",
                                      name: FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: ""))
        }
        return hostCache[path]
    }

    /// Outermost `.app` bundle containing the process's executable, e.g. "Google Chrome Helper" → "Google Chrome.app".
    private static func appBundlePath(forPid pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        let path = String(cString: buf)
        var prefix = ""
        for comp in path.split(separator: "/", omittingEmptySubsequences: true) {
            prefix += "/" + comp
            if comp.hasSuffix(".app") { return prefix }
        }
        return nil
    }

    /// The process macOS considers responsible for `pid` (Safari for its WebKit XPC services, etc.).
    private static func responsiblePid(_ pid: pid_t) -> pid_t? {
        typealias Fn = @convention(c) (pid_t) -> pid_t
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        let r = unsafeBitCast(sym, to: Fn.self)(pid)
        return r > 0 ? r : nil
    }

    // MARK: Icons

    private static var iconCache: [String: NSImage] = [:]

    static func icon(forPath path: String) -> NSImage {
        if let i = iconCache[path] { return i }
        let img = NSWorkspace.shared.icon(forFile: path)
        img.size = NSSize(width: 32, height: 32)
        iconCache[path] = img
        return img
    }
}
