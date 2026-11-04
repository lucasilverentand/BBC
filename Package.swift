// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BlueBubbleClub",
    platforms: [.macOS("26.0")],
    products: [.library(name: "BBCClient", targets: ["BBCClient"])],
    targets: [
        .systemLibrary(name: "BBCSQLite", pkgConfig: "sqlite3", providers: [.apt(["libsqlite3-dev"]), .brew(["sqlite3"])]),
        .target(name: "BBCClient", dependencies: ["BBCSQLite"]),
        .testTarget(name: "BBCClientTests", dependencies: ["BBCClient"])
    ]
)
