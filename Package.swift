// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BlueBubbleClub",
    platforms: [.macOS("26.0")],
    products: [.library(name: "BBCClient", targets: ["BBCClient"])],
    targets: [
        .systemLibrary(name: "BBCSQLite"),
        .target(name: "BBCClient", dependencies: ["BBCSQLite"]),
        .testTarget(name: "BBCClientTests", dependencies: ["BBCClient"])
    ]
)
