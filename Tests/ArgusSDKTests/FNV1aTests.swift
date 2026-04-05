//
//  FNV1aTests.swift
//  ArgusSDKTests
//
//  Hash parity tests against the JavaScript reference implementation.
//  Golden values were computed by running the JS fnv1aHash() function.
//

import XCTest
@testable import ArgusSDK

final class FNV1aTests: XCTestCase {

    // MARK: - Hash Parity Tests

    func testEmptyString() {
        XCTAssertEqual(FNV1a.fnv1a(""), 2_166_136_261)
    }

    func testSingleChar() {
        XCTAssertEqual(FNV1a.fnv1a("a"), 3_826_002_220)
    }

    func testHelloWorld() {
        XCTAssertEqual(FNV1a.fnv1a("hello world"), 3_582_672_807)
    }

    func testRolloutSeed() {
        // JS: fnv1aHash("test-seed-abc" + "user-123") === 4113345326
        XCTAssertEqual(FNV1a.fnv1a("test-seed-abcuser-123"), 4_113_345_326)
    }

    func testUnicodeString() {
        // "cafe\u{0301}" is 'e' followed by a combining acute accent (U+0301).
        // JS charCodeAt iterates UTF-16 code units: c, a, f, e, 0x0301.
        // JS: fnv1aHash("cafe\u0301") === 1829333483
        XCTAssertEqual(FNV1a.fnv1a("cafe\u{0301}"), 1_829_333_483)
    }

    // MARK: - Percentage Bucketing Tests

    func testPercentageBucket() {
        // JS: fnv1aHash("rollout-seed-xyzuser-456") % 100 === 55
        let bucket = FNV1a.percentageBucket(seed: "rollout-seed-xyz", userId: "user-456")
        XCTAssertEqual(bucket, 55)
    }

    func testPercentageBucketRange() {
        let bucket = FNV1a.percentageBucket(seed: "rollout-seed-xyz", userId: "user-456")
        XCTAssertTrue((0...99).contains(bucket), "Bucket must be in 0...99")
    }

    func testBucketStability() {
        // Same input called 1000 times must return the same value
        let expected = FNV1a.percentageBucket(seed: "stability-seed", userId: "stable-user")
        for _ in 0..<1000 {
            XCTAssertEqual(
                FNV1a.percentageBucket(seed: "stability-seed", userId: "stable-user"),
                expected
            )
        }
    }

    func testBucketDistribution() {
        // 10000 unique userIds should hit all 100 buckets
        var bucketsSeen = Set<Int>()
        for i in 0..<10_000 {
            let bucket = FNV1a.percentageBucket(seed: "dist-seed", userId: "user-\(i)")
            bucketsSeen.insert(bucket)
        }
        XCTAssertEqual(bucketsSeen.count, 100, "Expected all 100 buckets to be hit with 10000 users")
    }
}
