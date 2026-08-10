// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AISessionRemote",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AISessionCore", targets: ["AISessionCore"])
    ],
    targets: [
        .target(name: "AISessionCore"),
        .testTarget(name: "AISessionCoreTests", dependencies: ["AISessionCore"])
    ]
)
