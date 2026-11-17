// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MenubarMixer",
    platforms: [.macOS("14.4")],
    targets: [
        .executableTarget(
            name: "MenubarMixer",
            path: "Sources/MenubarMixer"
        )
    ]
)
