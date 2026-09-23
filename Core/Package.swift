// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MusicAssistantCore",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [.library(name: "MusicAssistantCore", targets: ["MusicAssistantCore"])],
    targets: [
        .target(name: "MusicAssistantCore"),
        .testTarget(name: "MusicAssistantCoreTests", dependencies: ["MusicAssistantCore"], resources: [.copy("Fixtures")])
    ]
)
