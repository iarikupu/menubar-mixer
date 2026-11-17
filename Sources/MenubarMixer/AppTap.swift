import CoreAudio
import Foundation

/// A process tap on one application's audio, played back through a private aggregate device
/// (tap in → gain → output device out). While the tap is running the app's own output is muted
/// (`mutedWhenTapped`), so what you hear is exactly what this IOProc writes.
final class AppTap {
    static let aggregateUIDPrefix = "local.menubarmixer.agg."

    enum TapError: Error, CustomStringConvertible {
        case failed(String, OSStatus)
        var description: String {
            switch self { case let .failed(what, status): return "\(what) failed: \(fourCC(status))" }
        }
        var status: OSStatus { switch self { case let .failed(_, s): return s } }
    }

    let processObjects: Set<AudioObjectID>
    let outputUID: String
    /// Listen-only: the app's own audio is left untouched and nothing is replayed (used for meters).
    let monitorOnly: Bool

    /// Realtime-shared floats: [0] target gain, [1] current gain, [2] output peak since last read,
    /// [3] frames seen, [4] input (pre-gain) peak since last read.
    private let shared: UnsafeMutablePointer<Float>
    private struct ChannelRef { var base: UnsafeMutablePointer<Float>?; var stride: Int; var frames: Int }
    private let scratch: UnsafeMutablePointer<ChannelRef>
    private static let maxChannels = 32

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private(set) var running = false
    let tapUUID = UUID()
    /// Human-readable description of the formats involved, for the log.
    private(set) var formatSummary = ""

    init(processObjects: [AudioObjectID], outputUID: String, name: String, gain: Float, startIO: Bool = true, monitorOnly: Bool = false) throws {
        self.processObjects = Set(processObjects)
        self.outputUID = outputUID
        self.monitorOnly = monitorOnly
        shared = .allocate(capacity: 8)
        shared.initialize(repeating: 0, count: 8)
        shared[0] = monitorOnly ? 0 : gain
        shared[1] = monitorOnly ? 0 : gain
        scratch = .allocate(capacity: Self.maxChannels)
        scratch.initialize(repeating: ChannelRef(base: nil, stride: 1, frames: 0), count: Self.maxChannels)
        do { try start(name: name, startIO: startIO, monitorOnly: monitorOnly) } catch { teardown(); freeMemory(); throw error }
    }

    deinit {
        teardown()
        freeMemory()
    }

    private func freeMemory() {
        shared.deallocate()
        scratch.deallocate()
    }

    // MARK: Control (main thread)

    func setGain(_ g: Float) { if !monitorOnly { shared[0] = max(0, g) } }

    /// Highest absolute output sample since the previous call (0…1+).
    func takePeak() -> Float {
        if monitorOnly { return takeInputPeak() }
        let p = shared[2]
        shared[2] = 0
        return p
    }

    var framesProcessed: Float { shared[3] }

    /// Highest pre-gain input sample since the previous call (diagnostics).
    func takeInputPeak() -> Float {
        let p = shared[4]
        shared[4] = 0
        return p
    }
    static func debugAggregateID(_ t: AppTap) -> AudioObjectID { t.aggID }

    func stop() { teardown() }

    // MARK: Setup

    private func start(name: String, startIO: Bool, monitorOnly: Bool) throws {
        let desc = CATapDescription(stereoMixdownOfProcesses: Array(processObjects))
        desc.uuid = tapUUID
        desc.name = "Mixer tap: \(name)"
        desc.isPrivate = true
        // monitorOnly (diagnostics): listen without muting; the IOProc runs at gain 0 so nothing is replayed.
        desc.muteBehavior = monitorOnly ? .unmuted : .mutedWhenTapped

        var status = AudioHardwareCreateProcessTap(desc, &tapID)
        guard status == noErr else { throw TapError.failed("AudioHardwareCreateProcessTap", status) }

        let aggUID = Self.aggregateUIDPrefix + UUID().uuidString
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Mixer – \(name)",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapUUID.uuidString,
            ]],
        ]
        status = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggID)
        guard status == noErr else { throw TapError.failed("AudioHardwareCreateAggregateDevice", status) }

        if let fmt: AudioStreamBasicDescription = CA.get(tapID, CA.address(kAudioTapPropertyFormat)) {
            formatSummary = "tap \(Int(fmt.mSampleRate))Hz \(fmt.mChannelsPerFrame)ch flags=\(fmt.mFormatFlags)"
        }

        let shared = self.shared
        let scratch = self.scratch
        let maxCh = Self.maxChannels
        let block: AudioDeviceIOBlock = { _, inInput, _, outOutput, _ in
            AppTap.render(inInput: inInput, outOutput: outOutput, shared: shared, scratch: scratch, maxChannels: maxCh)
        }
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil, block)
        guard status == noErr, procID != nil else { throw TapError.failed("AudioDeviceCreateIOProcIDWithBlock", status) }

        disableUnusedInputs()

        guard startIO else { return }
        status = AudioDeviceStart(aggID, procID)
        guard status == noErr else { throw TapError.failed("AudioDeviceStart", status) }
        running = true
    }

    /// The output device (often a Bluetooth headset) can expose its microphone as an input stream.
    /// Streaming from it would flip the headset into low-quality call mode, so switch every aggregate
    /// input stream off except the ones belonging to the tap.
    private func disableUnusedInputs() {
        guard let procID else { return }
        let streams: [AudioStreamID] = CA.getArray(aggID, CA.address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput))
        guard !streams.isEmpty else { return }
        let subDeviceID = Self.deviceID(forUID: outputUID)
        let subInputStreams: Set<AudioStreamID> = Set(
            subDeviceID.map { CA.getArray($0, CA.address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput), as: AudioStreamID.self) } ?? [])
        guard !subInputStreams.isEmpty else { return }

        // Aggregate streams are proxies, so identify the tap's stream by position (sub-device inputs come
        // first, the tap last) and only act when the formats confirm that reading: the last stream must look
        // like the tap (its channel count and rate) and there must be exactly one more stream than the
        // sub-device has. If anything is off, leave the inputs alone rather than risk muting the tap.
        let n = streams.count
        let skip = subInputStreams.count
        func format(_ s: AudioStreamID) -> AudioStreamBasicDescription? { CA.get(s, CA.address(kAudioStreamPropertyVirtualFormat)) }
        guard n == skip + 1,
              let tapFmt: AudioStreamBasicDescription = CA.get(tapID, CA.address(kAudioTapPropertyFormat)),
              let last = format(streams[n - 1]),
              last.mChannelsPerFrame == tapFmt.mChannelsPerFrame, last.mSampleRate == tapFmt.mSampleRate else {
            log("input stream layout not recognised (\(n) streams, \(skip) on sub-device); leaving inputs enabled")
            return
        }
        var usage = [UInt32](repeating: 1, count: n)
        for i in 0..<skip { usage[i] = 0 }

        let headerSize = MemoryLayout<UnsafeRawPointer?>.size + MemoryLayout<UInt32>.size
        let byteCount = headerSize + n * MemoryLayout<UInt32>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 8)
        defer { raw.deallocate() }
        raw.storeBytes(of: unsafeBitCast(procID, to: UnsafeRawPointer?.self), as: UnsafeRawPointer?.self)
        raw.storeBytes(of: UInt32(n), toByteOffset: MemoryLayout<UnsafeRawPointer?>.size, as: UInt32.self)
        for i in 0..<n { raw.storeBytes(of: usage[i], toByteOffset: headerSize + i * 4, as: UInt32.self) }
        var addr = CA.address(kAudioDevicePropertyIOProcStreamUsage, scope: kAudioObjectPropertyScopeInput)
        let st = AudioObjectSetPropertyData(aggID, &addr, 0, nil, UInt32(byteCount), raw)
        log("disabled \(skip) sub-device input stream(s) of \(n) on aggregate: \(st == noErr ? "ok" : fourCC(st))")
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var cf = uid as CFString
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = CA.address(kAudioHardwarePropertyTranslateUIDToDevice)
        let st = withUnsafeMutablePointer(to: &cf) {
            AudioObjectGetPropertyData(CA.system, &addr, UInt32(MemoryLayout<CFString>.size), $0, &size, &id)
        }
        return st == noErr && id != kAudioObjectUnknown ? id : nil
    }

    private func teardown() {
        if running, let procID { AudioDeviceStop(aggID, procID) }
        running = false
        if let procID, aggID != kAudioObjectUnknown { AudioDeviceDestroyIOProcID(aggID, procID) }
        procID = nil
        if aggID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggID); aggID = AudioObjectID(kAudioObjectUnknown) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = AudioObjectID(kAudioObjectUnknown) }
    }

    // MARK: Realtime render

    /// Runs on the HAL's IO thread: no allocation, no locks, no logging.
    private static func render(inInput: UnsafePointer<AudioBufferList>,
                               outOutput: UnsafeMutablePointer<AudioBufferList>,
                               shared: UnsafeMutablePointer<Float>,
                               scratch: UnsafeMutablePointer<ChannelRef>,
                               maxChannels: Int) {
        // Flatten the input buffers into per-channel (base, stride) references.
        var nIn = 0
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInput))
        for buf in ins {
            guard let data = buf.mData, buf.mNumberChannels > 0 else { continue }
            let ch = Int(buf.mNumberChannels)
            let frames = Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * ch)
            let base = data.assumingMemoryBound(to: Float.self)
            for c in 0..<ch where nIn < maxChannels {
                scratch[nIn] = ChannelRef(base: base + c, stride: ch, frames: frames)
                nIn += 1
            }
        }

        let outs = UnsafeMutableAudioBufferListPointer(outOutput)
        var frameCount = 0
        for buf in outs where buf.mData != nil && buf.mNumberChannels > 0 {
            frameCount = Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * Int(buf.mNumberChannels))
            break
        }
        guard frameCount > 0 else { return }

        let g0 = shared[1]
        let g1 = shared[0]
        let step = (g1 - g0) / Float(frameCount)
        var peak: Float = 0
        var inPeak: Float = 0
        var oc = 0
        for buf in outs {
            guard let data = buf.mData, buf.mNumberChannels > 0 else { continue }
            let ch = Int(buf.mNumberChannels)
            let frames = Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * ch)
            let out = data.assumingMemoryBound(to: Float.self)
            for c in 0..<ch {
                // Stereo in → stereo out; mono in → every channel; extra output channels stay silent.
                let srcIndex = nIn == 1 ? 0 : oc
                if srcIndex < nIn, let src = scratch[srcIndex].base {
                    let sStride = scratch[srcIndex].stride
                    let n = min(frames, scratch[srcIndex].frames)
                    var g = g0
                    for i in 0..<n {
                        let raw = src[i * sStride]
                        let ra = abs(raw)
                        if ra > inPeak { inPeak = ra }
                        let v = raw * g
                        out[i * ch + c] = v
                        let a = abs(v)
                        if a > peak { peak = a }
                        g += step
                    }
                    if n < frames { for i in n..<frames { out[i * ch + c] = 0 } }
                } else {
                    for i in 0..<frames { out[i * ch + c] = 0 }
                }
                oc += 1
            }
        }
        shared[1] = g1
        if peak > shared[2] { shared[2] = peak }
        if inPeak > shared[4] { shared[4] = inPeak }
        shared[3] += Float(frameCount)
    }
}
