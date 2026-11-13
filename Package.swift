// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BetterRecorder",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "BetterRecorder", targets: ["BetterRecorder"])],
    targets: [.executableTarget(name: "BetterRecorder")],
    swiftLanguageModes: [.v5]
)
