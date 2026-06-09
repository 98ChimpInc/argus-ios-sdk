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
            // NO practical upper cap. ArgusSDK is a leaf dependency consumed
            // inside host apps, and the HOST app owns its firebase-ios-sdk
            // major. A tight cap (e.g. ..<12 or ..<13) causes a hard SPM
            // resolution conflict for any app ahead of the cap — recurring on
            // every Firebase major (this is what blocked Chordy on 12.8 in
            // argus-web-app#272, and DK Derby on 11.x before it). SPM `from:`
            // is up-to-next-major (one major only), so it does NOT mean
            // "any >= 10" — hence the explicit wide range. The SDK only touches
            // stable FirebaseApp / FirebaseAuth (custom token) / FirebaseFirestore
            // (listeners) APIs; if a future major ever breaks that small surface
            // we patch + tag, which is far cheaper than blocking every adopter.
            "10.0.0" ..< "100.0.0"
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
