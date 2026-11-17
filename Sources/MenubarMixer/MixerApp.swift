import AppKit
import SwiftUI

struct MixerApp: App {
    @StateObject private var model = MixerModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            Image(nsImage: Self.menuBarIcon(muted: model.masterMuted))
        }
        .menuBarExtraStyle(.window)
    }

    /// Drawn at an explicit point size: a bare SF Symbol in a MenuBarExtra renders a size smaller than the system's own items.
    private static func menuBarIcon(muted: Bool) -> NSImage {
        let name = muted ? "speaker.slash.fill" : "slider.vertical.3"
        let config = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Menubar Mixer")?.withSymbolConfiguration(config)
        image?.isTemplate = true
        return image ?? NSImage()
    }
}
