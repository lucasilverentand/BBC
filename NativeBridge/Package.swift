// swift-tools-version: 6.2
import PackageDescription
let package = Package(name:"BBCNativeCore",platforms:[.macOS("26.0")],products:[.library(name:"BBCNativeCore",targets:["BBCNativeCore"])],targets:[
    .target(name:"BBCNativeCore",path:".",exclude:["EmbeddedSession.m","Tests"],sources:["NativeMessaging.m"],publicHeadersPath:"include",cSettings:[.unsafeFlags(["-fobjc-arc"])],linkerSettings:[.linkedFramework("Foundation")]),
    .testTarget(name:"BBCNativeCoreTests",dependencies:["BBCNativeCore"],path:"Tests")
])
