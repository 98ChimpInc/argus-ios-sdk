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
    dependencies: [
        .package(
            url: "https://github.com/firebase/firebase-ios-sdk.git",
            from: "11.0.0"
        ),
    ],
    targets: [
        .target(
            name: "ArgusSDK",
            dependencies: [
                .product(name: "FirebaseAuth", package: "firebase-ios-sdk"),
            ],
            path: "Sources/ArgusSDK"
        ),
        .testTarget(
            name: "ArgusSDKTests",
            dependencies: ["ArgusSDK"],
            path: "Tests/ArgusSDKTests"
        ),
    ]
)
