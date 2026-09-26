// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "SyncCore", platforms: [.macOS(.v14)], products: [.library(name: "SyncCore", targets: ["SyncCore"])], targets: [.target(name: "SyncCore"), .testTarget(name: "SyncCoreTests", dependencies: ["SyncCore"], resources: [.copy("Fixtures")])])
