// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SendspinInterop",
    platforms: [.macOS(.v26)],
    dependencies: [.package(path: "../.dependencies/SendspinKit")],
    targets: [.executableTarget(
        name: "SendspinInterop",
        dependencies: [.product(name: "SendspinKit", package: "SendspinKit")]
    )]
)
