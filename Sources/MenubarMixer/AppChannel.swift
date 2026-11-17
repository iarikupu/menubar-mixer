import AppKit
import CoreAudio
import Foundation

/// Drives only the level-meter view, so 30 Hz updates don't re-render the whole row.
final class MeterModel: ObservableObject {
    @Published var level: Float = 0
}

/// One row in the mixer: an application that is (or just was) playing audio.
final class AppChannel: ObservableObject, Identifiable {
    enum Status: Equatable {
        case idle                // not intercepted (meters off and volume at 100%)
        case active              // tapped; the slider controls what you hear
        case needsPermission     // can't tap without System Audio Recording permission
        case failed(String)
    }

    let id: String
    let host: HostApp
    let icon: NSImage
    let meter = MeterModel()

    @Published var volume: Float
    @Published var muted: Bool
    @Published var status: Status = .idle
    /// Device UID this app is routed to; nil follows the system output.
    @Published var outputUID: String?
    /// True while a chosen output is unavailable (e.g. earbuds switched off) and the app falls back to the system output.
    @Published var routeMissing = false

    // Engine bookkeeping (main actor only).
    var tap: AppTap?
    var allProcessObjects: Set<AudioObjectID> = []
    var runningProcessObjects: Set<AudioObjectID> = []
    var isRunning = false
    var lastPlaying = Date()
    var retryAfter = Date.distantPast
    var displayLevel: Float = 0

    init(host: HostApp, volume: Float = 1, muted: Bool = false, outputUID: String? = nil) {
        id = host.path
        self.host = host
        icon = AudioProcs.icon(forPath: host.path)
        self.volume = volume
        self.muted = muted
        self.outputUID = outputUID
    }

    /// Slider position → linear gain. A squared taper puts more of the slider's travel where the ear
    /// is sensitive (50% ≈ −12 dB), and 100% is exactly unity so an untouched app is bit-transparent.
    var gain: Float { muted ? 0 : volume * volume }

    var needsTap: Bool { muted || volume < 0.999 || outputUID != nil }
}
