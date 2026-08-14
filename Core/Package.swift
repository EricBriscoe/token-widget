// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TokenWidgetCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TokenWidgetCore", targets: ["TokenWidgetCore"]),
        .executable(name: "tokenusage", targets: ["tokenusage"])
    ],
    targets: [
        .target(name: "TokenWidgetCore"),
        .executableTarget(name: "tokenusage", dependencies: ["TokenWidgetCore"]),
        .testTarget(name: "TokenWidgetCoreTests", dependencies: ["TokenWidgetCore"])
    ]
)
