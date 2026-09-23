// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "SendspinInterop",
    platforms: [.macOS(.v26)],
    dependencies: [.package(url: "https://github.com/Sendspin/SendspinKit.git", revision: "accbc9ebde17b8af1925fd3f84da2955b801a33e")],
    targets: [.executableTarget(name: "SendspinInterop", dependencies: [.product(name: "SendspinKit", package: "SendspinKit")])]
)
