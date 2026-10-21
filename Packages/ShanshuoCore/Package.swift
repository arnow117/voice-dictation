// swift-tools-version: 6.0
// Pure domain logic shared by the app and its tests (FEAT-001 ED-017). No AppKit, no I/O.
import PackageDescription

let package = Package(
    name: "ShanshuoCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ShanshuoCore", targets: ["ShanshuoCore"])],
    targets: [
        .target(name: "ShanshuoCore"),
        .testTarget(name: "ShanshuoCoreTests", dependencies: ["ShanshuoCore"]),
    ]
)
