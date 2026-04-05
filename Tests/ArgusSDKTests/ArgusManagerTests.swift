//
//  ArgusManagerTests.swift
//  ArgusSDKTests
//
//  Tests for the full RemoteFlags conformance and cache behaviour.
//

import XCTest
import Combine
@testable import ArgusSDK

final class ArgusManagerTests: XCTestCase {

    private var manager: ArgusManager!
    private var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        manager = ArgusManager()
        cancellables = []
    }

    override func tearDown() {
        cancellables = nil
        manager = nil
        super.tearDown()
    }

    // MARK: - Bool Tests

    func testBoolForKey_returnsTrue() {
        manager.setTestCache(["flag_a": true])
        XCTAssertTrue(manager.bool(forKey: "flag_a"))
    }

    func testBoolForKey_returnsFalse() {
        manager.setTestCache(["flag_a": false])
        XCTAssertFalse(manager.bool(forKey: "flag_a"))
    }

    func testBoolForKey_returnsFalseForMissingKey() {
        manager.setTestCache([:])
        XCTAssertFalse(manager.bool(forKey: "nonexistent"))
    }

    func testBoolForKey_parsesTrueString() {
        manager.setTestCache(["flag_a": "true"])
        XCTAssertTrue(manager.bool(forKey: "flag_a"))
    }

    func testBoolForKey_parsesOneString() {
        manager.setTestCache(["flag_a": "1"])
        XCTAssertTrue(manager.bool(forKey: "flag_a"))
    }

    func testBoolForKey_parsesYesString() {
        manager.setTestCache(["flag_a": "YES"])
        XCTAssertTrue(manager.bool(forKey: "flag_a"))
    }

    func testBoolForKey_returnsFalseForArbitraryString() {
        manager.setTestCache(["flag_a": "random"])
        XCTAssertFalse(manager.bool(forKey: "flag_a"))
    }

    // MARK: - String Tests

    func testStringForKey_returnsValue() {
        manager.setTestCache(["flag_a": "hello"])
        XCTAssertEqual(manager.string(forKey: "flag_a"), "hello")
    }

    func testStringForKey_returnsNilForMissingKey() {
        manager.setTestCache([:])
        XCTAssertNil(manager.string(forKey: "nonexistent"))
    }

    func testStringForKey_returnsBoolStringRepresentation() {
        manager.setTestCache(["flag_a": true])
        XCTAssertEqual(manager.string(forKey: "flag_a"), "true")
    }

    func testStringForKey_returnsNumberStringRepresentation() {
        manager.setTestCache(["flag_a": NSNumber(value: 42)])
        XCTAssertEqual(manager.string(forKey: "flag_a"), "42")
    }

    // MARK: - Int Tests

    func testIntForKey_returnsValue() {
        manager.setTestCache(["flag_a": 42])
        XCTAssertEqual(manager.int(forKey: "flag_a"), 42)
    }

    func testIntForKey_returnsZeroForMissingKey() {
        manager.setTestCache([:])
        XCTAssertEqual(manager.int(forKey: "nonexistent"), 0)
    }

    func testIntForKey_parsesStringValue() {
        manager.setTestCache(["flag_a": "99"])
        XCTAssertEqual(manager.int(forKey: "flag_a"), 99)
    }

    func testIntForKey_returnsZeroForUnparseableString() {
        manager.setTestCache(["flag_a": "not_a_number"])
        XCTAssertEqual(manager.int(forKey: "flag_a"), 0)
    }

    // MARK: - Double Tests

    func testDoubleForKey_returnsValue() {
        manager.setTestCache(["flag_a": 3.14])
        XCTAssertEqual(manager.double(forKey: "flag_a"), 3.14, accuracy: 0.001)
    }

    func testDoubleForKey_returnsZeroForMissingKey() {
        manager.setTestCache([:])
        XCTAssertEqual(manager.double(forKey: "nonexistent"), 0.0)
    }

    func testDoubleForKey_parsesStringValue() {
        manager.setTestCache(["flag_a": "2.718"])
        XCTAssertEqual(manager.double(forKey: "flag_a"), 2.718, accuracy: 0.001)
    }

    // MARK: - JSON Tests

    private struct TestConfig: Decodable, Equatable {
        let interval: Int
        let enabled: Bool
    }

    func testJsonForKey_decodesStruct() {
        let dict: [String: Any] = ["interval": 30, "enabled": true]
        manager.setTestCache(["config": dict])

        let result: TestConfig? = manager.json(forKey: "config")
        XCTAssertEqual(result, TestConfig(interval: 30, enabled: true))
    }

    func testJsonForKey_extractsIosPlatformObject() {
        let dict: [String: Any] = [
            "ios": ["interval": 30, "enabled": true] as [String: Any],
            "android": ["interval": 60, "enabled": false] as [String: Any]
        ]
        manager.setTestCache(["polling_config": dict])

        let result: TestConfig? = manager.json(forKey: "polling_config")
        XCTAssertEqual(result, TestConfig(interval: 30, enabled: true))
    }

    func testJsonForKey_usesFullDictWhenNoIosKey() {
        let dict: [String: Any] = ["interval": 45, "enabled": false]
        manager.setTestCache(["config": dict])

        let result: TestConfig? = manager.json(forKey: "config")
        XCTAssertEqual(result, TestConfig(interval: 45, enabled: false))
    }

    func testJsonForKey_returnsNilForMissingKey() {
        manager.setTestCache([:])
        let result: TestConfig? = manager.json(forKey: "nonexistent")
        XCTAssertNil(result)
    }

    func testJsonForKey_cachesDecodedValue() {
        let dict: [String: Any] = ["interval": 30, "enabled": true]
        manager.setTestCache(["config": dict])

        // First call decodes
        let first: TestConfig? = manager.json(forKey: "config")
        // Second call should return cached decoded value
        let second: TestConfig? = manager.json(forKey: "config")

        XCTAssertEqual(first, second)
        XCTAssertEqual(first, TestConfig(interval: 30, enabled: true))
    }

    // MARK: - configUpdatedPublisher Tests

    func testConfigUpdatedPublisher_exists() {
        // Verify the publisher is accessible (compile-time check, essentially)
        let publisher = manager.configUpdatedPublisher
        XCTAssertNotNil(publisher)
    }

    // MARK: - Thread Safety Tests

    func testCacheIsThreadSafe() {
        // Read and write from multiple concurrent queues, verify no crashes
        let expectation = expectation(description: "Concurrent access completes")
        let iterations = 1000
        let group = DispatchGroup()

        for i in 0..<iterations {
            group.enter()
            DispatchQueue.global().async {
                self.manager.setTestCache(["key_\(i)": i])
                _ = self.manager.bool(forKey: "key_\(i)")
                _ = self.manager.string(forKey: "key_\(i)")
                _ = self.manager.int(forKey: "key_\(i)")
                _ = self.manager.double(forKey: "key_\(i)")
                group.leave()
            }
        }

        group.notify(queue: .main) {
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 10.0)
    }
}
