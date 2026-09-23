// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "Halfwin",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Halfwin", targets: ["Halfwin"])],
    targets: [.executableTarget(name: "Halfwin", path: "Sources/Halfwin")],
    swiftLanguageModes: [.v5]
)
