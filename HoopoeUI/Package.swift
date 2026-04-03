// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "HoopoeUI",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "HoopoeUI", targets: ["HoopoeUI"]),
    ],
    dependencies: [
        .package(path: "../HoopoeUtils"),
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", from: "0.9.0"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-markdown", from: "0.4.0"),
    ],
    targets: [
        .target(
            name: "HoopoeUI",
            dependencies: [
                .product(name: "HoopoeUtils", package: "HoopoeUtils"),
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "TreeSitterMarkdown", package: "tree-sitter-markdown"),
            ]
        ),
    ]
)
