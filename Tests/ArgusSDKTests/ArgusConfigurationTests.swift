//
//  ArgusConfigurationTests.swift
//  ArgusSDKTests
//
//  Tests for `ArgusConfiguration.autoDetectedEnvironment` and the
//  auto-detecting initialiser.
//

import XCTest
@testable import ArgusSDK

final class ArgusConfigurationTests: XCTestCase {

    // MARK: - DEBUG branch

    /// The SDK's test target is built with DEBUG defined, so the
    /// auto-detected environment must return `"dev"` regardless of
    /// what receipt URL we inject.
    func testAutoDetectedEnvironment_returnsDevInDebugBuild() {
        #if DEBUG
            let sandbox = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/ABC/StoreKit/sandboxReceipt")
            let appStore = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/ABC/StoreKit/receipt")
            XCTAssertEqual(ArgusConfiguration.resolveAutoDetectedEnvironment(receiptURL: nil), "dev")
            XCTAssertEqual(ArgusConfiguration.resolveAutoDetectedEnvironment(receiptURL: sandbox), "dev")
            XCTAssertEqual(ArgusConfiguration.resolveAutoDetectedEnvironment(receiptURL: appStore), "dev")
            // And the public accessor must agree.
            XCTAssertEqual(ArgusConfiguration.autoDetectedEnvironment, "dev")
        #else
            // If the test target is ever flipped to a release build, the
            // DEBUG check would no longer apply ... fail loudly so the
            // discrepancy is investigated rather than silently skipped.
            XCTFail("Test target was built without DEBUG defined; the auto-detect test matrix needs revisiting.")
        #endif
    }

    // MARK: - Release-build runtime logic (receipt-URL inspection)

    /// A TestFlight build's `appStoreReceiptURL` ends in `sandboxReceipt`.
    /// Verify the release-build resolver maps that to `"staging"`.
    func testReleaseEnvironment_sandboxReceiptReturnsStaging() {
        let sandboxURL = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/ABC/StoreKit/sandboxReceipt")
        XCTAssertEqual(
            ArgusConfiguration.resolveReleaseEnvironment(receiptURL: sandboxURL),
            "staging"
        )
    }

    /// An App Store release build has a receipt URL whose last path
    /// component is `receipt` (not `sandboxReceipt`). Verify the
    /// release-build resolver maps that to `"prod"`.
    func testReleaseEnvironment_productionReceiptReturnsProd() {
        let receiptURL = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/ABC/StoreKit/receipt")
        XCTAssertEqual(
            ArgusConfiguration.resolveReleaseEnvironment(receiptURL: receiptURL),
            "prod"
        )
    }

    /// On the first launch of a freshly installed App Store build before
    /// any purchase, `appStoreReceiptURL` may be nil. We treat absence as
    /// production (the safer default ... it matches the App Store build
    /// configuration the user actually shipped).
    func testReleaseEnvironment_nilReceiptReturnsProd() {
        XCTAssertEqual(
            ArgusConfiguration.resolveReleaseEnvironment(receiptURL: nil),
            "prod"
        )
    }

    // MARK: - Initialiser overloads

    func testInit_withExplicitEnvironment_preservesValue() {
        let config = ArgusConfiguration(
            apiKey: "argus_test",
            baseURL: "https://example.com",
            tenantId: "acme_ca",
            environment: "staging"
        )
        XCTAssertEqual(config.environment, "staging")
    }

    func testInit_withoutEnvironment_usesAutoDetected() {
        let config = ArgusConfiguration(
            apiKey: "argus_test",
            baseURL: "https://example.com",
            tenantId: "acme_ca"
        )
        XCTAssertEqual(config.environment, ArgusConfiguration.autoDetectedEnvironment)
    }

    func testInit_withoutEnvironment_preservesOtherDefaults() {
        let config = ArgusConfiguration(
            apiKey: "argus_test",
            baseURL: "https://example.com",
            tenantId: "acme_ca"
        )
        XCTAssertNil(config.userId)
        XCTAssertEqual(config.pollInterval, 300)
    }

    // MARK: - firebaseConfig override

    /// The documented happy path: a consumer supplies only the Argus apiKey
    /// (+ base URL), so `firebaseConfig` is unset and the SDK self-configures
    /// from the server-returned config.
    func testInit_firebaseConfigDefaultsToNil() {
        let config = ArgusConfiguration(
            apiKey: "argus_test",
            baseURL: "https://example.com",
            tenantId: "acme_ca"
        )
        XCTAssertNil(config.firebaseConfig)
    }

    /// The override is honoured when explicitly supplied (e.g. the emulator
    /// preset for local development).
    func testInit_firebaseConfigOverridePreserved() {
        let config = ArgusConfiguration(
            apiKey: "argus_test",
            baseURL: "https://example.com",
            tenantId: "acme_ca",
            environment: "dev",
            firebaseConfig: .emulator()
        )
        XCTAssertNotNil(config.firebaseConfig)
        XCTAssertTrue(config.firebaseConfig?.useEmulator ?? false)
        XCTAssertEqual(config.firebaseConfig?.projectId, "demo-argus")
    }

    // MARK: - Server firebaseConfig parsing (StreamClient.parseFirebaseConfig)

    func testParseFirebaseConfig_fullObject() {
        let raw: [String: Any] = [
            "projectId": "argus-app-f0ff3",
            "apiKey": "AIzaSyD-real-key",
            "appId": "1:123:ios:abc",
            "authDomain": "argus-app-f0ff3.firebaseapp.com",
            "storageBucket": "argus-app-f0ff3.appspot.com",
            "messagingSenderId": "123456789",
            "useEmulator": false,
        ]
        let parsed = StreamClient.parseFirebaseConfig(raw)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.projectId, "argus-app-f0ff3")
        XCTAssertEqual(parsed?.apiKey, "AIzaSyD-real-key")
        XCTAssertEqual(parsed?.appId, "1:123:ios:abc")
        XCTAssertEqual(parsed?.authDomain, "argus-app-f0ff3.firebaseapp.com")
        XCTAssertEqual(parsed?.storageBucket, "argus-app-f0ff3.appspot.com")
        XCTAssertEqual(parsed?.messagingSenderId, "123456789")
        XCTAssertFalse(parsed?.useEmulator ?? true)
    }

    /// The optional fields are genuinely optional, and `useEmulator` defaults
    /// to `false` when the server omits it.
    func testParseFirebaseConfig_minimalObject() {
        let raw: [String: Any] = [
            "projectId": "demo-argus",
            "apiKey": "demo-key",
            "appId": "1:000:ios:demo",
        ]
        let parsed = StreamClient.parseFirebaseConfig(raw)
        XCTAssertNotNil(parsed)
        XCTAssertNil(parsed?.authDomain)
        XCTAssertNil(parsed?.storageBucket)
        XCTAssertNil(parsed?.messagingSenderId)
        XCTAssertFalse(parsed?.useEmulator ?? true)
        // Emulator host/ports fall back to ArgusConfiguration defaults.
        XCTAssertEqual(parsed?.emulatorHost, "127.0.0.1")
        XCTAssertEqual(parsed?.authEmulatorPort, 9099)
        XCTAssertEqual(parsed?.firestoreEmulatorPort, 8080)
    }

    func testParseFirebaseConfig_useEmulatorTrue() {
        let raw: [String: Any] = [
            "projectId": "demo-argus",
            "apiKey": "demo-key",
            "appId": "1:000:ios:demo",
            "useEmulator": true,
        ]
        XCTAssertEqual(StreamClient.parseFirebaseConfig(raw)?.useEmulator, true)
    }

    /// A missing required field (here `appId`) makes the whole object
    /// malformed, so the caller treats the token response as malformed and
    /// demotes to the HTTP fallback.
    func testParseFirebaseConfig_missingRequiredFieldReturnsNil() {
        let raw: [String: Any] = [
            "projectId": "demo-argus",
            "apiKey": "demo-key",
        ]
        XCTAssertNil(StreamClient.parseFirebaseConfig(raw))
    }

    func testParseFirebaseConfig_nonDictionaryReturnsNil() {
        XCTAssertNil(StreamClient.parseFirebaseConfig(nil))
        XCTAssertNil(StreamClient.parseFirebaseConfig("not-a-dict"))
    }
}
