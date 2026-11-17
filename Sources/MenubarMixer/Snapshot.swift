import AppKit
import SwiftUI

/// `MenubarMixer snapshot out.png [--dark] [--denied] [--unknown] [--empty] [--many] [--devices] [--muted]` renders the panel with
/// canned data so layouts can be checked without a display session. (Rendered through an offscreen NSHostingView so real controls draw.)
enum Snapshot {
    @MainActor static func run(_ args: [String]) {
        guard let out = args.first(where: { $0.hasSuffix(".png") }) else { print("usage: snapshot out.png [--dark] [--denied] [--unknown] [--empty] [--many]"); return }
        Theme.snapshotMode = true
        let dark = args.contains("--dark")
        let perm: AudioPermission = args.contains("--denied") ? .denied : (args.contains("--unknown") ? .unknown : .authorized)
        let model = MixerModel.mock(permission: perm)
        if args.contains("--empty") { model.setChannelsForSnapshot([]) }
        if args.contains("--many") { model.setChannelsForSnapshot(MixerModel.mock().channels + MixerModel.mock().channels.map { $0 }) }
        // Device 2 is the MacBook speakers, which Chrome is routed to in the mock.
        if args.contains("--muted") { model.setMutedOutputsForSnapshot([2]) }
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        NSApp.appearance = appearance
        let content = PanelView(model: model, showDevices: args.contains("--devices"))
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: content)
        host.appearance = appearance
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6)) // let animations and layout settle
        // The app list measures itself on the first pass, so size the window again once it has.
        let settled = host.fittingSize
        host.frame = NSRect(origin: .zero, size: settled)
        window.setContentSize(settled)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { print("render failed"); return }
        appearance?.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: rep) }
        guard let png = rep.representation(using: .png, properties: [:]) else { print("render failed"); return }
        try? png.write(to: URL(fileURLWithPath: out))
        print("wrote \(out) (\(Int(settled.width))x\(Int(settled.height)))")
    }
}
