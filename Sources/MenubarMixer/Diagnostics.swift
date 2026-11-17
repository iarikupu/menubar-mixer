import AppKit
import CoreAudio
import CoreAudio
import Foundation

/// Hidden command-line helpers: `MenubarMixer diag` prints what the app sees.
enum Diagnostics {
    static func run() {
        print("permission: \(AudioCapturePermission.status()) (queryable: \(AudioCapturePermission.isQueryable))")
        let def = Devices.defaultOutput()
        print("outputs:")
        for d in Devices.outputs() {
            let mark = d.id == def ? "*" : " "
            let vol = Devices.volume(d.id).map { String(format: "%.2f", $0) } ?? "n/a"
            print(" \(mark) \(d.id) \(d.name) [\(d.uid)] transport=\(fourCC(OSStatus(bitPattern: d.transport))) vol=\(vol) mute=\(Devices.isMuted(d.id).map(String.init) ?? "n/a")")
        }
        print("audio processes:")
        for p in AudioProcs.list() {
            let host = AudioProcs.hostApp(forPid: p.pid)
            print("  obj=\(p.objectID) pid=\(p.pid) out=\(p.runningOutput) bundle=\(p.bundleID) host=\(host?.name ?? "-")")
        }
        if args().contains("--volume-roundtrip") {
            let id = Devices.defaultOutput()
            if let v = Devices.volume(id) {
                let probe = v > 0.02 ? v - 0.01 : v + 0.01
                Devices.setVolume(id, probe)
                Thread.sleep(forTimeInterval: 0.3)
                print("volume \(v) → set \(probe) → read \(Devices.volume(id).map { "\($0)" } ?? "nil")")
                Devices.setVolume(id, v)
                Thread.sleep(forTimeInterval: 0.3)
                print("restored → \(Devices.volume(id).map { "\($0)" } ?? "nil")")
            } else { print("no volume control") }
        }
        if let i = args().firstIndex(of: "--tap"), i + 1 < args().count, let pid = Int32(args()[i + 1]) {
            tapExperiment(pid: pid)
        }
    }

    private static func args() -> [String] { CommandLine.arguments }

    /// Creates a tap on `pid` for a few seconds and dumps the aggregate device layout.
    static func tapExperiment(pid: pid_t) {
        guard let proc = AudioProcs.list().first(where: { $0.pid == pid }) else { print("pid \(pid) has no audio process object"); return }
        guard let out = Devices.outputs().first(where: { $0.id == Devices.defaultOutput() }) else { return }
        do {
            let tap = try AppTap(processObjects: [proc.objectID], outputUID: out.uid, name: "diag", gain: 1, startIO: args().contains("--start"))
            print("tap created: \(tap.formatSummary)")
            let agg = AppTap.debugAggregateID(tap)
            dumpStreams(agg, label: "aggregate")
            if let dev = AppTap.deviceID(forUID: out.uid) { dumpStreams(dev, label: "sub-device") }
            for _ in 0..<10 {
                Thread.sleep(forTimeInterval: 0.5)
                print(String(format: "peak=%.4f frames=%.0f", tap.takePeak(), tap.framesProcessed))
            }
            tap.stop()
        } catch { print("tap failed: \(error)") }
    }

    private static func dumpStreams(_ dev: AudioObjectID, label: String) {
        for (scope, name) in [(kAudioObjectPropertyScopeInput, "in"), (kAudioObjectPropertyScopeOutput, "out")] {
            let streams: [AudioStreamID] = CA.getArray(dev, CA.address(kAudioDevicePropertyStreams, scope: scope))
            for s in streams {
                let fmt: AudioStreamBasicDescription? = CA.get(s, CA.address(kAudioStreamPropertyVirtualFormat))
                let owner: AudioObjectID? = CA.get(s, CA.address(kAudioObjectPropertyOwner))
                print("  \(label) \(name) stream \(s) owner=\(owner.map(String.init) ?? "?") ch=\(fmt?.mChannelsPerFrame ?? 0) rate=\(fmt?.mSampleRate ?? 0) flags=\(fmt?.mFormatFlags ?? 0) bits=\(fmt?.mBitsPerChannel ?? 0)")
            }
        }
    }

    // MARK: End-to-end self-test

    /// Plays a known tone with afplay, taps it at several gains and measures, with a second silent tap on this
    /// very process, what actually comes out of the mixer. Results go to the log (run via `open --args selftest`
    /// so the audio permission granted to the app applies).
    static func selftest() {
        func say(_ s: String) { log("selftest: \(s)"); print(s) }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mixer-selftest.wav")
        let rate = 44100, secs = 30, amp: Float = 0.5
        var pcm = [Int16](); pcm.reserveCapacity(rate * secs * 2)
        for i in 0..<(rate * secs) {
            let v = Int16(sin(2 * .pi * 440 * Double(i) / Double(rate)) * Double(amp) * 32767)
            pcm.append(v); pcm.append(v)
        }
        var wav = Data()
        func le<T: FixedWidthInteger>(_ v: T) { var x = v.littleEndian; withUnsafeBytes(of: &x) { wav.append(contentsOf: $0) } }
        wav.append("RIFF".data(using: .ascii)!); le(UInt32(36 + pcm.count * 2)); wav.append("WAVEfmt ".data(using: .ascii)!)
        le(UInt32(16)); le(UInt16(1)); le(UInt16(2)); le(UInt32(rate)); le(UInt32(rate * 4)); le(UInt16(4)); le(UInt16(16))
        wav.append("data".data(using: .ascii)!); le(UInt32(pcm.count * 2)); pcm.withUnsafeBytes { wav.append(contentsOf: $0) }
        try? wav.write(to: tmp)

        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = ["-v", "0.5", tmp.path]
        do { try player.run() } catch { say("could not start afplay: \(error)"); return }
        defer { player.terminate(); try? FileManager.default.removeItem(at: tmp) }

        func waitFor<T>(_ what: String, _ f: () -> T?) -> T? {
            for _ in 0..<40 { if let v = f() { return v }; Thread.sleep(forTimeInterval: 0.25) }
            say("timed out waiting for \(what)"); return nil
        }
        say("permission=\(AudioCapturePermission.status()) pid=\(getpid())")
        guard let src = waitFor("afplay audio process", { AudioProcs.list().first { $0.pid == player.processIdentifier && $0.runningOutput } }) else { return }
        guard let out = Devices.outputs().first(where: { $0.id == Devices.defaultOutput() }) else { return }
        say("output=\(out.name); source process object \(src.objectID)")
        do {
            let tap = try AppTap(processObjects: [src.objectID], outputUID: out.uid, name: "selftest", gain: 1)
            say("tap format: \(tap.formatSummary)")
            Thread.sleep(forTimeInterval: 1.0)
            guard let me = waitFor("our own audio process object", { AudioProcs.list().first { $0.pid == getpid() } }) else { tap.stop(); return }
            let monitor = try AppTap(processObjects: [me.objectID], outputUID: out.uid, name: "monitor", gain: 0, monitorOnly: true)
            _ = tap.takeInputPeak(); _ = monitor.takeInputPeak()
            for gain: Float in [1.0, 0.5, 0.25, 0.0, 1.0] {
                tap.setGain(gain)
                Thread.sleep(forTimeInterval: 0.6)
                _ = tap.takeInputPeak(); _ = monitor.takeInputPeak()
                Thread.sleep(forTimeInterval: 1.2)
                let inP = tap.takeInputPeak(), outP = monitor.takeInputPeak()
                let ratio = inP > 0 ? outP / inP : 0
                say(String(format: "gain %.2f → source peak %.3f, mixer output peak %.3f (ratio %.3f) frames=%.0f", gain, inP, outP, ratio, tap.framesProcessed))
            }
            monitor.stop(); tap.stop()
            say("done")
        } catch { say("failed: \(error)") }
    }

    /// Two simultaneous sources (440 Hz and 660 Hz) tapped independently with different gains.
    static func selftestTwo() {
        func say(_ s: String) { log("selftest2: \(s)"); print(s) }
        func makeTone(_ hz: Double, _ name: String) -> URL {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            let rate = 44100, secs = 30
            var pcm = [Int16]()
            for i in 0..<(rate * secs) { let v = Int16(sin(2 * .pi * hz * Double(i) / Double(rate)) * 0.5 * 32767); pcm.append(v); pcm.append(v) }
            var wav = Data()
            func le<T: FixedWidthInteger>(_ v: T) { var x = v.littleEndian; withUnsafeBytes(of: &x) { wav.append(contentsOf: $0) } }
            wav.append("RIFF".data(using: .ascii)!); le(UInt32(36 + pcm.count * 2)); wav.append("WAVEfmt ".data(using: .ascii)!)
            le(UInt32(16)); le(UInt16(1)); le(UInt16(2)); le(UInt32(rate)); le(UInt32(rate * 4)); le(UInt16(4)); le(UInt16(16))
            wav.append("data".data(using: .ascii)!); le(UInt32(pcm.count * 2)); pcm.withUnsafeBytes { wav.append(contentsOf: $0) }
            try? wav.write(to: url)
            return url
        }
        let files = [makeTone(440, "mixer-a.wav"), makeTone(660, "mixer-b.wav")]
        var players: [Process] = []
        for (i, f) in files.enumerated() {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay"); p.arguments = ["-v", i == 0 ? "0.5" : "0.3", f.path]
            try? p.run(); players.append(p)
        }
        defer { players.forEach { $0.terminate() }; files.forEach { try? FileManager.default.removeItem(at: $0) } }
        func waitFor<T>(_ what: String, _ f: () -> T?) -> T? {
            for _ in 0..<40 { if let v = f() { return v }; Thread.sleep(forTimeInterval: 0.25) }
            say("timed out waiting for \(what)"); return nil
        }
        guard let out = Devices.outputs().first(where: { $0.id == Devices.defaultOutput() }) else { return }
        var objs: [AudioObjectID] = []
        for p in players {
            guard let o = waitFor("player \(p.processIdentifier)", { AudioProcs.list().first { $0.pid == p.processIdentifier && $0.runningOutput } }) else { return }
            objs.append(o.objectID)
        }
        do {
            // Route B to a different device than A when there is one, to prove per-app routing.
            let other = Devices.outputs().first { $0.uid != out.uid }
            say("A → \(out.name); B → \((other ?? out).name)")
            let a = try AppTap(processObjects: [objs[0]], outputUID: out.uid, name: "A", gain: 1)
            let b = try AppTap(processObjects: [objs[1]], outputUID: (other ?? out).uid, name: "B", gain: 1)
            Thread.sleep(forTimeInterval: 1)
            guard let me = waitFor("own audio process", { AudioProcs.list().first { $0.pid == getpid() } }) else { return }
            let mon = try AppTap(processObjects: [me.objectID], outputUID: out.uid, name: "monitor", gain: 0, monitorOnly: true)
            for (ga, gb) in [(1, 0), (0, 1), (0.5, 0.25), (0, 0), (1, 1)] as [(Float, Float)] {
                a.setGain(ga); b.setGain(gb)
                Thread.sleep(forTimeInterval: 0.6)
                _ = a.takePeak(); _ = b.takePeak(); _ = mon.takeInputPeak()
                Thread.sleep(forTimeInterval: 1.2)
                say(String(format: "A gain %.2f → A out %.3f | B gain %.2f → B out %.3f | mixer total %.3f", ga, a.takePeak(), gb, b.takePeak(), mon.takeInputPeak()))
            }
            mon.stop(); a.stop(); b.stop()
            say("done")
        } catch { say("failed: \(error)") }
    }

    // MARK: Debug: open the real panel

    /// `open "Menubar Mixer.app" --args --debug-open <out.png>`: clicks the status item, logs what the panel
    /// shows, and saves the panel window's rendering. For checking the real MenuBarExtra without a screenshot.
    static func scheduleDebugOpen(png: String?) {
        func findButton(_ v: NSView) -> NSButton? {
            if let b = v as? NSButton { return b }
            for s in v.subviews { if let b = findButton(s) { return b } }
            return nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard let bar = NSApp.windows.first(where: { String(describing: type(of: $0)).contains("StatusBar") }),
                  let button = bar.contentView.flatMap(findButton) else { log("debug-open: no status button found"); return }
            button.performClick(nil)
            log("debug-open: clicked status item")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                let m = MixerModel.current
                log("debug-open: panelVisible=\(m?.panelVisible ?? false) channels=\(m?.channels.map { "\($0.host.name)=\($0.volume) status=\($0.status) level=\(String(format: "%.2f", $0.meter.level))" } ?? [])")
                for w in NSApp.windows { log("debug-open: window \(type(of: w)) frame=\(NSStringFromRect(w.frame)) visible=\(w.isVisible) key=\(w.isKeyWindow)") }
                if let png, let w = NSApp.windows.filter({ $0.isVisible && !String(describing: type(of: $0)).contains("StatusBar") }).max(by: { $0.frame.height < $1.frame.height }),
                   let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: png))
                    log("debug-open: saved \(png)")
                }
            }
        }
    }
}
