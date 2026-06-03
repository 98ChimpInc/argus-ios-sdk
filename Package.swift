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
            // Range spans 10.x + 11.x so the package co-resolves with host
            // apps already on Firebase 11.x (e.g. DK Derby on 11.14.0). SPM
            // `from: "10.0.0"` is up-to-next-major (10.x only), which
            // excluded 11.x and broke transitive resolution in the app.
            "10.0.0" ..< "12.0.0"
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
