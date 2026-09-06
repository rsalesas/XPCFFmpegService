// swift-tools-version:5.7

import PackageDescription

let package = Package(
    name: "XPCFFmpeg",
    platforms: [.macOS(.v11)],
    products: [
        .library(name: "XPCFFmpeg", type: .dynamic, targets: ["XPCFFmpeg"]),
    ],
    dependencies: [
        .package(path: "../XPCServiceFramework"),
        .package(path: "../XPCFFmpegServiceFramework"),
    ],
    targets: [
        .target(
            name: "XPCFFmpeg",
            dependencies: ["XPCServiceFramework", "XPCFFmpegServiceFramework"]),
        .testTarget(
            name: "XPCFFmpegTests",
            dependencies: ["XPCFFmpeg"]),
    ]
)
