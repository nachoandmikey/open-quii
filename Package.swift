// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenQUII",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "OpenQUII", targets: ["OpenQUII"]),
    ],
    targets: [
        .target(name: "OpenQUII"),
        .testTarget(name: "OpenQUIITests", dependencies: ["OpenQUII"]),
    ]
)
