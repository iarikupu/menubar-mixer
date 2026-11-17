import AppKit
import CoreAudio
import ServiceManagement
import SwiftUI

/// Everything the panel shows: master volume / output device, the list of playing apps and their taps.
/// Main thread only.
final class MixerModel: ObservableObject {
    // MARK: Published state

    @Published private(set) var outputs: [OutputDevice] = []
    @Published private(set) var currentOutputID = AudioDeviceID(kAudioObjectUnknown)
    @Published private(set) var masterVolume: Float = 0.5
    @Published private(set) var masterMuted = false
    /// Output devices whose own system mute is on; an app routed to one of these is silent however loud its slider is.
    @Published private(set) var mutedOutputs: Set<AudioDeviceID> = []
    @Published private(set) var masterAdjustable = true
    @Published private(set) var channels: [AppChannel] = []
    @Published private(set) var permission: AudioPermission = .unknown
    @Published private(set) var loginItemState: SMAppService.Status = .notRegistered
    @Published var loginItemError: String?
    @Published var liveMeters: Bool {
        didSet { UserDefaults.standard.set(liveMeters, forKey: Keys.liveMeters); reconcile() }
    }
    @Published var panelVisible = false {
        didSet { if panelVisible != oldValue { panelVisibilityChanged() } }
    }

    var showPermissionBanner: Bool {
        permission == .denied || (permission == .unknown && (AudioCapturePermission.isQueryable || !isLive))
    }

    var currentOutput: OutputDevice? { outputs.first { $0.id == currentOutputID } }

    // MARK: Internals

    private enum Keys {
        static let channels = "channelSettings"
        static let liveMeters = "liveMeters"
        static let askedPermission = "askedAudioPermission"
    }
    private struct Saved: Codable { var volume: Float; var muted: Bool; var output: String? }

    static weak var current: MixerModel?
    let isLive: Bool
    private var saved: [String: Saved] = [:]
    private var persistWork: DispatchWorkItem?

    private let systemListener = CAListener()
    private var deviceListener: CAListener?
    private var processListeners: [AudioObjectID: CAListener] = [:]
    private var reconcileTimer: Timer?
    private var meterTimer: Timer?
    private var ignoreDeviceEchoUntil = Date.distantPast
    private var preMuteVolume: Float?
    private var permissionOverride: AudioPermission?
    private let removalGrace: TimeInterval = 4

    // MARK: Init

    init(live: Bool = true) {
        isLive = live
        liveMeters = UserDefaults.standard.object(forKey: Keys.liveMeters) as? Bool ?? true
        guard live else { return }
        Self.current = self
        loadSaved()
        refreshDevices()
        refreshLoginItem()
        permission = AudioCapturePermission.status()
        log("started; permission=\(permission) output=\(currentOutput?.name ?? "?")")

        let defaultOut = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
        let devices = CA.address(kAudioHardwarePropertyDevices)
        let processList = CA.address(kAudioHardwarePropertyProcessObjectList)
        systemListener.add(CA.system, defaultOut) { [weak self] in self?.refreshDevices(); self?.reconcile() }
        systemListener.add(CA.system, devices) { [weak self] in self?.refreshDevices(); self?.reconcile() }
        systemListener.add(CA.system, processList) { [weak self] in self?.reconcile() }

        reconcileTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        reconcileTimer?.tolerance = 0.3

        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.shutdown()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            log("wake from sleep: rebuilding taps")
            self?.stopAllTaps()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.refreshDevices(); self?.reconcile() }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let bars = NSApp.windows.filter { String(describing: type(of: $0)).contains("StatusBar") }
            log("menu bar item windows: \(bars.map { "\(type(of: $0)) frame=\(NSStringFromRect($0.frame)) visible=\($0.isVisible)" })")
        }
        reconcile()
        // First launch: ask for System Audio Recording once, up front, so the sliders just work afterwards.
        if permission == .unknown, AudioCapturePermission.isQueryable, !UserDefaults.standard.bool(forKey: Keys.askedPermission) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.requestPermission() }
        }
    }

    /// Canned data for layout snapshots; never touches CoreAudio.
    static func mock(permission: AudioPermission = .authorized) -> MixerModel {
        let m = MixerModel(live: false)
        m.outputs = [
            OutputDevice(id: 1, uid: "a", name: "CMF Buds Pro 2", transport: kAudioDeviceTransportTypeBluetooth),
            OutputDevice(id: 2, uid: "b", name: "MacBook Pro Speakers", transport: kAudioDeviceTransportTypeBuiltIn),
            OutputDevice(id: 3, uid: "c", name: "LG UltraFine", transport: kAudioDeviceTransportTypeDisplayPort),
        ]
        m.currentOutputID = 1
        m.masterVolume = 0.62
        m.permission = permission
        func ch(_ name: String, _ path: String, _ v: Float, _ muted: Bool, _ level: Float, out: String? = nil) -> AppChannel {
            let c = AppChannel(host: HostApp(path: path, bundleID: name, name: name), volume: v, muted: muted, outputUID: out)
            c.status = permission == .authorized ? .active : .needsPermission
            c.meter.level = level
            return c
        }
        m.channels = [
            ch("Spotify", "/Applications/Spotify.app", 0.8, false, 0.72),
            ch("Google Chrome", "/Applications/Google Chrome.app", 0.35, false, 0.4, out: "b"),
            ch("Safari", "/Applications/Safari.app", 1, true, 0),
        ]
        return m
    }

    func setChannelsForSnapshot(_ list: [AppChannel]) { channels = list }
    func setMutedOutputsForSnapshot(_ ids: Set<AudioDeviceID>) { mutedOutputs = ids }

    // MARK: Master volume & output devices

    func refreshDevices() {
        guard isLive else { return }
        let list = Devices.outputs()
        let cur = Devices.defaultOutput()
        if list != outputs { outputs = list }
        if cur != currentOutputID {
            currentOutputID = cur
            preMuteVolume = nil
            attachDeviceListener(cur)
            log("default output → \(currentOutput?.name ?? "?") (\(cur))")
        }
        refreshMutedOutputs()
        refreshMaster()
    }

    private func refreshMutedOutputs() {
        let muted = Set(outputs.filter { Devices.isMuted($0.id) == true }.map(\.id))
        if muted != mutedOutputs { mutedOutputs = muted }
    }

    private func attachDeviceListener(_ id: AudioDeviceID) {
        let l = CAListener()
        for a in Devices.volumeListenerAddresses(id) { l.add(id, a) { [weak self] in self?.refreshMaster() } }
        deviceListener = l
    }

    private func refreshMaster() {
        guard isLive, Date() >= ignoreDeviceEchoUntil else { return }
        let id = currentOutputID
        let vol = Devices.volume(id)
        masterAdjustable = vol != nil
        if let vol, vol != masterVolume { masterVolume = vol }
        let muted = Devices.isMuted(id) ?? (preMuteVolume != nil)
        if muted != masterMuted { masterMuted = muted }
    }

    func setMasterVolume(_ v: Float) {
        let v = max(0, min(1, v))
        masterVolume = v
        ignoreDeviceEchoUntil = Date().addingTimeInterval(0.25)
        guard isLive else { return }
        if v > 0, masterMuted { setMasterMuted(false) }
        Devices.setVolume(currentOutputID, v)
    }

    func toggleMasterMute() { setMasterMuted(!masterMuted) }

    private func setMasterMuted(_ muted: Bool) {
        masterMuted = muted
        ignoreDeviceEchoUntil = Date().addingTimeInterval(0.25)
        guard isLive else { return }
        if Devices.hasMute(currentOutputID) {
            Devices.setMuted(currentOutputID, muted)
        } else if muted {
            // Devices with no mute switch: park the volume at zero and remember it.
            preMuteVolume = masterVolume
            Devices.setVolume(currentOutputID, 0)
        } else if let restore = preMuteVolume {
            preMuteVolume = nil
            Devices.setVolume(currentOutputID, restore)
        }
    }

    func selectOutput(_ device: OutputDevice) {
        guard device.id != currentOutputID else { return }
        if isLive { Devices.setDefaultOutput(device.id) } else { currentOutputID = device.id }
    }

    // MARK: Per-app volume

    func setVolume(_ channel: AppChannel, _ v: Float) {
        channel.volume = max(0, min(1, v))
        if channel.muted && v > 0 { channel.muted = false }
        applyChange(channel)
    }

    func toggleMute(_ channel: AppChannel) {
        channel.muted.toggle()
        applyChange(channel)
    }

    func resetVolume(_ channel: AppChannel) {
        channel.volume = 1
        channel.muted = false
        applyChange(channel)
    }

    /// Route one app to a specific output device (nil = follow the system output).
    func setOutput(_ channel: AppChannel, uid: String?) {
        guard channel.outputUID != uid else { return }
        channel.outputUID = uid
        log("route \(channel.host.name) → \(uid.flatMap { u in outputs.first { $0.uid == u }?.name } ?? "system default")")
        guard isLive else { return }
        stopTap(channel)
        ensureTap(channel)
        schedulePersist(channel)
    }

    /// The device this app should actually play through right now.
    func resolvedOutput(for channel: AppChannel) -> OutputDevice? {
        if let uid = channel.outputUID, let d = outputs.first(where: { $0.uid == uid }) { return d }
        return currentOutput
    }

    private func applyChange(_ channel: AppChannel) {
        guard isLive else { return }
        ensureTap(channel)
        schedulePersist(channel)
    }

    // MARK: Persistence

    private func loadSaved() {
        if let data = UserDefaults.standard.data(forKey: Keys.channels),
           let decoded = try? JSONDecoder().decode([String: Saved].self, from: data) { saved = decoded }
    }

    private func schedulePersist(_ channel: AppChannel) {
        let key = channel.host.persistKey
        if channel.volume >= 0.999 && !channel.muted && channel.outputUID == nil { saved[key] = nil } else { saved[key] = Saved(volume: channel.volume, muted: channel.muted, output: channel.outputUID) }
        persistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushSaved() }
        persistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func flushSaved() {
        if let data = try? JSONEncoder().encode(saved) { UserDefaults.standard.set(data, forKey: Keys.channels) }
    }

    // MARK: Discovering apps

    private func tick() {
        if permission != .authorized {
            let latest = permissionOverride ?? AudioCapturePermission.status()
            if latest != permission {
                log("permission changed: \(permission) → \(latest)")
                permission = latest
            }
        }
        if isLive { refreshMutedOutputs() }
        reconcile()
    }

    func reconcile() {
        guard isLive else { return }
        let procs = AudioProcs.list()
        AudioProcs.forgetPids(except: Set(procs.map(\.pid)))

        struct Group { var host: HostApp; var all = Set<AudioObjectID>(); var running = Set<AudioObjectID>() }
        var groups: [String: Group] = [:]
        let myBundle = Bundle.main.bundleIdentifier
        for p in procs where p.pid != getpid() {
            guard let host = AudioProcs.hostApp(forPid: p.pid), host.bundleID != myBundle else { continue }
            var g = groups[host.path] ?? Group(host: host)
            g.all.insert(p.objectID)
            if p.runningOutput { g.running.insert(p.objectID) }
            groups[host.path] = g
        }
        syncProcessListeners(Set(procs.map(\.objectID)))

        let now = Date()
        for ch in channels {
            if let g = groups[ch.id] {
                ch.allProcessObjects = g.all
                ch.runningProcessObjects = g.running
                ch.isRunning = !g.running.isEmpty
                if ch.isRunning { ch.lastPlaying = now }
            } else {
                ch.allProcessObjects = []
                ch.runningProcessObjects = []
                ch.isRunning = false
            }
        }

        // Rows appear when an app starts playing and fade out a few seconds after it stops.
        var next = channels
        var changed = false
        for (key, g) in groups where !g.running.isEmpty && !next.contains(where: { $0.id == key }) {
            let s = saved[g.host.persistKey]
            let ch = AppChannel(host: g.host, volume: s?.volume ?? 1, muted: s?.muted ?? false, outputUID: s?.output)
            ch.allProcessObjects = g.all
            ch.runningProcessObjects = g.running
            ch.isRunning = true
            ch.lastPlaying = now
            next.append(ch)
            changed = true
            log("+ \(g.host.name) [\(g.host.persistKey)] vol=\(ch.volume) muted=\(ch.muted) processes=\(g.all.count)")
        }
        let leaving = next.filter { !$0.isRunning && now.timeIntervalSince($0.lastPlaying) > removalGrace }
        if !leaving.isEmpty {
            for ch in leaving { stopTap(ch); log("- \(ch.host.name)") }
            next.removeAll { ch in leaving.contains { $0 === ch } }
            changed = true
        }
        if changed { withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { channels = next } }

        for ch in channels { ensureTap(ch) }
    }

    private func syncProcessListeners(_ live: Set<AudioObjectID>) {
        for id in processListeners.keys where !live.contains(id) { processListeners[id] = nil }
        for id in live where processListeners[id] == nil {
            let l = CAListener()
            l.add(id, CA.address(kAudioProcessPropertyIsRunningOutput)) { [weak self] in self?.reconcile() }
            processListeners[id] = l
        }
    }

    // MARK: Taps

    private var canTap: Bool {
        switch permission {
        case .authorized: return true
        case .denied: return false
        case .unknown: return !AudioCapturePermission.isQueryable // can't ask → just try
        }
    }

    private func ensureTap(_ ch: AppChannel) {
        guard isLive else { return }
        guard canTap else {
            stopTap(ch)
            ch.status = ch.isRunning || ch.needsTap ? .needsPermission : .idle
            return
        }
        let wanted = liveMeters || ch.needsTap
        guard wanted, let output = resolvedOutput(for: ch) else {
            stopTap(ch)
            if ch.status != .idle { ch.status = .idle }
            return
        }
        let missing = ch.outputUID != nil && !outputs.contains { $0.uid == ch.outputUID }
        if ch.routeMissing != missing { ch.routeMissing = missing }
        if let tap = ch.tap {
            let covered = ch.runningProcessObjects.isSubset(of: tap.processObjects)
            // Untouched apps get a listen-only tap (meters, original audio left alone); adjusted ones a full tap.
            let wrongMode = tap.monitorOnly != !ch.needsTap
            if tap.outputUID != output.uid || !covered || !tap.running || wrongMode {
                log("rebuilding tap for \(ch.host.name) (output: \(tap.outputUID) → \(output.uid), uncovered process: \(!covered), mode change: \(wrongMode))")
                stopTap(ch)
            } else {
                tap.setGain(ch.gain)
                if ch.status != .active { ch.status = .active }
                return
            }
        }
        guard ch.isRunning, Date() >= ch.retryAfter else { return }
        do {
            let tap = try AppTap(processObjects: Array(ch.allProcessObjects), outputUID: output.uid, name: ch.host.name, gain: ch.gain, monitorOnly: !ch.needsTap)
            ch.tap = tap
            ch.status = .active
            log("tap on \(ch.host.name): \(tap.monitorOnly ? "listen-only" : "active"), \(ch.allProcessObjects.count) process(es), out=\(output.name), \(tap.formatSummary), gain=\(ch.gain)")
        } catch {
            ch.retryAfter = Date().addingTimeInterval(5)
            ch.status = .failed("\(error)")
            log("tap on \(ch.host.name) failed: \(error)")
        }
    }

    private func stopTap(_ ch: AppChannel) {
        guard let tap = ch.tap else { return }
        tap.stop()
        ch.tap = nil
        ch.displayLevel = 0
        if ch.meter.level != 0 { ch.meter.level = 0 }
    }

    private func stopAllTaps() { channels.forEach(stopTap) }

    private func shutdown() {
        flushSaved()
        stopAllTaps()
        log("shutdown")
    }

    // MARK: Level meters

    private func panelVisibilityChanged() {
        meterTimer?.invalidate()
        meterTimer = nil
        guard isLive else { return }
        log("panel \(panelVisible ? "opened" : "closed")")
        if panelVisible {
            refreshDevices()
            refreshLoginItem()
            reconcile()
            let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.updateMeters() }
            RunLoop.main.add(t, forMode: .common)
            meterTimer = t
        }
    }

    private func updateMeters() {
        for ch in channels {
            guard let tap = ch.tap else { continue }
            let peak = tap.takePeak()
            let db = 20 * log10(max(peak, 1e-5))
            let target = max(0, min(1, (db + 54) / 54))
            ch.displayLevel = target > ch.displayLevel ? target * 0.65 + ch.displayLevel * 0.35 : ch.displayLevel * 0.86
            let shown = ch.displayLevel < 0.015 ? 0 : ch.displayLevel
            if abs(shown - ch.meter.level) > 0.004 { ch.meter.level = shown }
        }
    }

    // MARK: Permission

    func requestPermission() {
        UserDefaults.standard.set(true, forKey: Keys.askedPermission)
        log("requesting System Audio Recording permission")
        AudioCapturePermission.request { [weak self] granted in
            guard let self else { return }
            log("permission request result: granted=\(granted)")
            self.permissionOverride = granted ? .authorized : nil
            self.permission = granted ? .authorized : AudioCapturePermission.status()
            self.reconcile()
        }
    }

    func openPermissionSettings() { NSWorkspace.shared.open(AudioCapturePermission.settingsURL) }

    /// macOS applies a changed audio-capture permission to new launches, so offer a one-click relaunch.
    func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.7; /usr/bin/open -n \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    // MARK: Login item

    func refreshLoginItem() {
        guard isLive else { return }
        loginItemState = SMAppService.mainApp.status
    }

    var launchAtLogin: Bool { loginItemState == .enabled || loginItemState == .requiresApproval }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
            log("launch at login \(on ? "register" : "unregister") failed: \(error)")
        }
        refreshLoginItem()
        if loginItemState == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    func openLog() { NSWorkspace.shared.open(Log.url) }
}
