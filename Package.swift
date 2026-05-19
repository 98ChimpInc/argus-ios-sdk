// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ArgusSDK",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "ArgusSDK",
            targets: ["ArgusSDK"]
        ),
    ],
    targets: [
        .target(
            name: "ArgusSDK",
            path: "Sources/ArgusSDK"
        ),
        .testTarget(
            name: "ArgusSDKTests",
            dependencies: ["ArgusSDK"],
            path: "Tests/ArgusSDKTests"
        ),
    ]
)
