// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "BBCMessagesActions", platforms: [.macOS("26.0")],
    products: [.executable(name: "BlueBubbleClub", targets: ["BBCMessagesActions"])],
    dependencies: [.package(name: "BlueBubbleClubSDK", path: ".."), .package(path: "../build/beeper-imessage"),
                   .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7", traits: [])],
    targets: [.executableTarget(name: "BBCMessagesActions", dependencies: [.product(name: "BBCClient", package: "BlueBubbleClubSDK"), .product(name: "IMessage", package: "beeper-imessage"),
                                                                           .product(name: "FluidAudio", package: "FluidAudio")], resources: [.process("Resources")]),
              .testTarget(name: "BBCMessagesActionsTests", dependencies: ["BBCMessagesActions"])])
