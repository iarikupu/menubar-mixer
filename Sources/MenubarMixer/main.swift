import AppKit
import Foundation

let args = CommandLine.arguments
if args.count > 1 && args[1] != "--debug-open" {
    switch args[1] {
    case "diag":
        Diagnostics.run()
    case "selftest":
        Diagnostics.selftest()
    case "selftest2":
        Diagnostics.selftestTwo()
    case "snapshot":
        _ = NSApplication.shared
        MainActor.assumeIsolated { Snapshot.run(Array(args.dropFirst(2))) }
    default:
        print("unknown command \(args[1])")
    }
} else {
    Log.rotateIfNeeded()
    if let i = args.firstIndex(of: "--debug-open") { Diagnostics.scheduleDebugOpen(png: args.indices.contains(i + 1) ? args[i + 1] : nil) }
    NSApplication.shared.setActivationPolicy(.accessory)
    MixerApp.main()
}
