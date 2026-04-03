// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "HoopoeUtils",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "HoopoeUtils", targets: ["HoopoeUtils"]),
    ],
    targets: [
        .target(name: "HoopoeUtils"),
    ]
)
