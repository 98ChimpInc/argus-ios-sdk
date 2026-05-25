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
}
