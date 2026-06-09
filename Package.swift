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
        // Real-time push (CANONICAL architecture, DECISIONS.md 2026-06-02):
        // FirebaseAuth signs the SDK in with the scoped custom token minted
        // by issueStreamToken; FirebaseFirestore opens the live listeners
        // that push flag changes into configUpdatedPublisher.
        .package(
            url: "https://github.com/firebase/firebase-ios-sdk",
            // Range spans 10.x–12.x so the package co-resolves with host apps
            // on any current Firebase major: 11.x (DK Derby on 11.14.0) and
            // 12.x (Chordy on 12.8.0 — see argus-web-app#272). SPM `from:` is
            // up-to-next-major (one major only); the explicit range avoids the
            // "depends on firebase-ios-sdk 10..<12 and root depends on 12.x"
            // resolution failure. The SDK only uses the stable FirebaseApp /
            // FirebaseAuth (custom token) / FirebaseFirestore (listeners) APIs,
            // which are source-compatible across 10–12.
            "10.0.0" ..< "13.0.0"
        ),
    ],
    targets: [
        .target(
            name: "ArgusSDK",
            dependencies: [
                .product(name: "FirebaseAuth", package: "firebase-ios-sdk"),
                .product(name: "FirebaseFirestore", package: "firebase-ios-sdk"),
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
