import Foundation

/// Appends timestamped lines to ~/Library/Logs/MenubarMixer.log (and stderr when run from a terminal).
enum Log {
    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("MenubarMixer.log")
    }()

    private static let queue = DispatchQueue(label: "mixer.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func rotateIfNeeded() {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size > 1_000_000 {
            let old = url.deletingPathExtension().appendingPathExtension("old.log")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
        }
    }

    static func write(_ message: String) {
        queue.async {
            let line = "\(formatter.string(from: Date())) \(message)\n"
            if isatty(STDERR_FILENO) != 0 { FileHandle.standardError.write(Data(line.utf8)) }
            guard let data = line.data(using: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(data)
                try? h.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}

func log(_ message: @autoclosure () -> String) { Log.write(message()) }

/// Four-character-code helper for readable OSStatus values in the log.
func fourCC(_ status: OSStatus) -> String {
    let n = UInt32(bitPattern: status)
    let bytes = [UInt8((n >> 24) & 0xff), UInt8((n >> 16) & 0xff), UInt8((n >> 8) & 0xff), UInt8(n & 0xff)]
    if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) { return "'\(String(bytes: bytes, encoding: .ascii) ?? "")'" }
    return "\(status)"
}
