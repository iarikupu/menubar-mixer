import CoreAudio
import Foundation

struct OutputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transport: UInt32

    /// SF Symbol that hints at the kind of device.
    var symbol: String {
        let lower = name.lowercased()
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            if lower.contains("buds") || lower.contains("pods") || lower.contains("cmf") { return "earbuds" }
            return "headphones"
        case kAudioDeviceTransportTypeBuiltIn:
            return lower.contains("headphone") ? "headphones" : "laptopcomputer"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return "display"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplayaudio"
        case kAudioDeviceTransportTypeUSB:
            return "hifispeaker"
        default:
            return "speaker.wave.2"
        }
    }

    var isBluetooth: Bool {
        transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }
}

enum Devices {
    static let virtualMainVolume: AudioObjectPropertySelector = 0x766D_7663 // 'vmvc'

    static func defaultOutput() -> AudioDeviceID {
        CA.get(CA.system, CA.address(kAudioHardwarePropertyDefaultOutputDevice)) ?? AudioDeviceID(kAudioObjectUnknown)
    }

    @discardableResult
    static func setDefaultOutput(_ id: AudioDeviceID) -> Bool {
        let a = CA.set(CA.system, CA.address(kAudioHardwarePropertyDefaultOutputDevice), id)
        // Alerts / system sounds follow the choice, like the Sound pane does.
        CA.set(CA.system, CA.address(kAudioHardwarePropertyDefaultSystemOutputDevice), id)
        if a != noErr { log("setDefaultOutput(\(id)) failed: \(fourCC(a))") }
        return a == noErr
    }

    static func uid(_ id: AudioObjectID) -> String { CA.string(id, kAudioDevicePropertyDeviceUID) }
    static func name(_ id: AudioObjectID) -> String { CA.string(id, kAudioObjectPropertyName) }

    static func hasOutput(_ id: AudioDeviceID) -> Bool {
        var a = CA.address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr && size > 0
    }

    static func outputs() -> [OutputDevice] {
        let ids: [AudioDeviceID] = CA.getArray(CA.system, CA.address(kAudioHardwarePropertyDevices))
        return ids.compactMap { id in
            guard hasOutput(id) else { return nil }
            if let hidden: UInt32 = CA.get(id, CA.address(kAudioDevicePropertyIsHidden)), hidden != 0 { return nil }
            let transport: UInt32 = CA.get(id, CA.address(kAudioDevicePropertyTransportType)) ?? 0
            let uid = uid(id)
            // Hide our own private aggregates and anything without a stable identity.
            if uid.isEmpty || uid.hasPrefix(AppTap.aggregateUIDPrefix) { return nil }
            return OutputDevice(id: id, uid: uid, name: name(id), transport: transport)
        }
    }

    // MARK: Volume

    private static func scalarAddr(_ selector: AudioObjectPropertySelector, _ element: UInt32) -> AudioObjectPropertyAddress {
        CA.address(selector, scope: kAudioObjectPropertyScopeOutput, element: element)
    }

    /// The addresses that together make up the device's output volume: the virtual main volume when
    /// available (what the system's own slider uses), else the main scalar, else per-channel scalars.
    private static func volumeAddresses(_ id: AudioObjectID) -> [AudioObjectPropertyAddress] {
        let candidates: [[AudioObjectPropertyAddress]] = [
            [scalarAddr(virtualMainVolume, 0)],
            [scalarAddr(kAudioDevicePropertyVolumeScalar, 0)],
            [scalarAddr(kAudioDevicePropertyVolumeScalar, 1), scalarAddr(kAudioDevicePropertyVolumeScalar, 2)],
        ]
        for group in candidates where group.allSatisfy({ CA.has(id, $0) && CA.isSettable(id, $0) }) { return group }
        return []
    }

    static func hasVolume(_ id: AudioObjectID) -> Bool { !volumeAddresses(id).isEmpty }

    static func volume(_ id: AudioObjectID) -> Float? {
        let addrs = volumeAddresses(id)
        guard !addrs.isEmpty else { return nil }
        let values = addrs.compactMap { CA.get(id, $0, as: Float32.self) }
        guard values.count == addrs.count else { return nil }
        return values.reduce(0, +) / Float(values.count)
    }

    static func setVolume(_ id: AudioObjectID, _ value: Float) {
        let v = Float32(max(0, min(1, value)))
        for a in volumeAddresses(id) { CA.set(id, a, v) }
    }

    /// Selectors whose changes mean "the volume (or mute) shown in the UI is stale".
    static func volumeListenerAddresses(_ id: AudioObjectID) -> [AudioObjectPropertyAddress] {
        var all = volumeAddresses(id)
        if let m = muteAddresses(id).first { all.append(m) }
        return all
    }

    // MARK: Mute

    private static func muteAddresses(_ id: AudioObjectID) -> [AudioObjectPropertyAddress] {
        let candidates = [[scalarAddr(kAudioDevicePropertyMute, 0)],
                          [scalarAddr(kAudioDevicePropertyMute, 1), scalarAddr(kAudioDevicePropertyMute, 2)]]
        for group in candidates where group.allSatisfy({ CA.has(id, $0) && CA.isSettable(id, $0) }) { return group }
        return []
    }

    static func hasMute(_ id: AudioObjectID) -> Bool { !muteAddresses(id).isEmpty }

    static func isMuted(_ id: AudioObjectID) -> Bool? {
        let addrs = muteAddresses(id)
        guard !addrs.isEmpty else { return nil }
        return addrs.contains { (CA.get(id, $0, as: UInt32.self) ?? 0) != 0 }
    }

    static func setMuted(_ id: AudioObjectID, _ muted: Bool) {
        for a in muteAddresses(id) { CA.set(id, a, UInt32(muted ? 1 : 0)) }
    }
}
