// swift-tools-version: 6.0
import PackageDescription
import Foundation

// Distribution must link the SDK's SQLite, not a build machine's package manager.
let sqlitePkgConfig: String? = ProcessInfo.processInfo.environment["BBC_SYSTEM_SQLITE"] == "1" ? nil : "sqlite3"

let package = Package(
    name: "BlueBubbleClub",
    platforms: [.macOS("26.0")],
    products: [.library(name: "BBCClient", targets: ["BBCClient"])],
    targets: [
        .systemLibrary(name: "BBCSQLite", pkgConfig: sqlitePkgConfig, providers: [.apt(["libsqlite3-dev"]), .brew(["sqlite3"])]),
        .target(name: "BBCClient", dependencies: ["BBCSQLite"]),
        .testTarget(name: "BBCClientTests", dependencies: ["BBCClient"])
    ]
)
