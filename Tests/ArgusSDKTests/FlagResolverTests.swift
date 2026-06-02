//
//  FlagResolverTests.swift
//  ArgusSDKTests
//
//  Verifies the client-side resolution engine matches the server
//  `resolveFlags` algorithm. These run without any live Firebase — the
//  engine takes plain dictionaries, the same shape Firestore snapshots
//  hand back.
//

import XCTest
@testable import ArgusSDK

final class FlagResolverTests: XCTestCase {

    private func context(
        platform: String? = "ios",
        version: String? = "1.49.1",
        userId: String? = nil,
        language: String? = nil,
        appId: String? = "1:273554127449:ios:a7b29506b5b4fb55cb0f48",
        tenantId: String? = nil
    ) -> FlagResolutionContext {
        FlagResolutionContext(
            platform: platform,
            version: version,
            userId: userId,
            language: language,
            platformAppId: appId,
            tenantId: tenantId
        )
    }

    // MARK: - Defaults & env value

    func testUsesDefaultWhenNoEnvDoc() {
        let input = FlagInput(
            flag: ["name": "flag_a", "defaultValue": false],
            env: nil,
            tenantOverride: nil
        )
        let out = FlagResolver.resolve(flags: [input], conditionsByName: [:], context: context(version: nil))
        XCTAssertEqual(out["flag_a"] as? Bool, false)
    }

    func testUsesEnvValueOverDefault() {
        let input = FlagInput(
            flag: ["name": "flag_a", "defaultValue": false],
            env: ["value": true],
            tenantOverride: nil
        )
        let out = FlagResolver.resolve(flags: [input], conditionsByName: [:], context: context(version: nil))
        XCTAssertEqual(out["flag_a"] as? Bool, true)
    }

    // MARK: - Archived / draft skipping

    func testSkipsArchivedFlag() {
        let input = FlagInput(
            flag: ["name": "flag_a", "defaultValue": true, "archived": true],
            env: ["value": true],
            tenantOverride: nil
        )
        let out = FlagResolver.resolve(flags: [input], conditionsByName: [:], context: context())
        XCTAssertNil(out["flag_a"])
    }

    func testSkipsDraftFlag() {
        let input = FlagInput(
            flag: ["name": "flag_a", "defaultValue": true, "draft": true],
            env: ["value": true],
            tenantOverride: nil
        )
        let out = FlagResolver.resolve(flags: [input], conditionsByName: [:], context: context())
        XCTAssertNil(out["flag_a"])
    }

    // MARK: - Tenant override

    func testTenantOverrideWins() {
        let input = FlagInput(
            flag: ["name": "flag_a", "defaultValue": false],
            env: ["value": false, "conditionalValues": ["c1": true]],
            tenantOverride: ["value": "tenant_specific"]
        )
        let cond: [String: [String: Any]] = ["c1": ["name": "c1", "priority": 0, "platform": "ios"]]
        let out = FlagResolver.resolve(flags: [input], conditionsByName: cond, context: context(tenantId: "acme"))
        XCTAssertEqual(out["flag_a"] as? String, "tenant_specific")
    }

    func testTenantOverrideIgnoredWhenNoTenantContext() {
        let input = FlagInput(
            flag: ["name": "flag_a", "defaultValue": false],
            env: ["value": true],
            tenantOverride: ["value": "tenant_specific"]
        )
        // No tenantId in context → override must NOT apply.
        let out = FlagResolver.resolve(flags: [input], conditionsByName: [:], context: context(version: nil, tenantId: nil))
        XCTAssertEqual(out["flag_a"] as? Bool, true)
    }

    // MARK: - Conditional values (priority + version constraint)

    func testConditionalValueMatchesByVersion() {
        // Mirrors seed flag enable_energy_dashboard: iOS >= 1.49.1 → true.
        let input = FlagInput(
            flag: ["name": "flag_a", "defaultValue": false],
            env: ["value": false, "conditionalValues": ["iOS EMT 1.49.1 and up": true]],
            tenantOverride: nil
        )
        let cond: [String: [String: Any]] = [
            "iOS EMT 1.49.1 and up": [
                "name": "iOS EMT 1.49.1 and up",
                "platform": "ios",
                "appId": "1:273554127449:ios:a7b29506b5b4fb55cb0f48",
                "versionConstraint": ["operator": ">=", "versions": ["1.49.1"]],
                "priority": 2,
            ],
        ]
        let out = FlagResolver.resolve(flags: [input], conditionsByName: cond, context: context(version: "1.49.1"))
        XCTAssertEqual(out["flag_a"] as? Bool, true)
    }

    func testConditionalValueDoesNotMatchBelowVersion() {
        let input = FlagInput(
            flag: ["name": "flag_a", "defaultValue": false],
            env: ["value": false, "conditionalValues": ["iOS EMT 1.49.1 and up": true]],
            tenantOverride: nil
        )
        let cond: [String: [String: Any]] = [
            "iOS EMT 1.49.1 and up": [
                "name": "iOS EMT 1.49.1 and up",
                "platform": "ios",
                "appId": "1:273554127449:ios:a7b29506b5b4fb55cb0f48",
                "versionConstraint": ["operator": ">=", "versions": ["1.49.1"]],
                "priority": 2,
            ],
        ]
        let out = FlagResolver.resolve(flags: [input], conditionsByName: cond, context: context(version: "1.42.0"))
        XCTAssertEqual(out["flag_a"] as? Bool, false)
    }

    func testConditionalValuesSkippedWithoutVersion() {
        let input = FlagInput(
            flag: ["name": "flag_a", "defaultValue": false],
            env: ["value": false, "conditionalValues": ["iOS EMT 1.49.1 and up": true]],
            tenantOverride: nil
        )
        let cond: [String: [String: Any]] = [
            "iOS EMT 1.49.1 and up": ["name": "iOS EMT 1.49.1 and up", "platform": "ios", "versionConstraint": ["operator": ">=", "versions": ["1.49.1"]], "priority": 2],
        ]
        // version nil → conditionalValues are not evaluated; env value wins.
        let out = FlagResolver.resolve(flags: [input], conditionsByName: cond, context: context(version: nil))
        XCTAssertEqual(out["flag_a"] as? Bool, false)
    }

    func testLowerPriorityConditionWinsFirst() {
        // Two matching conditions; the lower `priority` number wins.
        let input = FlagInput(
            flag: ["name": "flag_a", "defaultValue": "default"],
            env: ["value": "env", "conditionalValues": ["hi": "from_hi", "lo": "from_lo"]],
            tenantOverride: nil
        )
        let cond: [String: [String: Any]] = [
            "lo": ["name": "lo", "platform": "ios", "priority": 0,
                   "versionConstraint": ["operator": ">=", "versions": ["1.0.0"]]],
            "hi": ["name": "hi", "platform": "ios", "priority": 5,
                   "versionConstraint": ["operator": ">=", "versions": ["1.0.0"]]],
        ]
        let out = FlagResolver.resolve(flags: [input], conditionsByName: cond, context: context(version: "2.0.0"))
        XCTAssertEqual(out["flag_a"] as? String, "from_lo")
    }

    func testExactlyMatchesOperator() {
        let input = FlagInput(
            flag: ["name": "flag_a", "defaultValue": false],
            env: ["value": false, "conditionalValues": ["exact": true]],
            tenantOverride: nil
        )
        let cond: [String: [String: Any]] = [
            "exact": ["name": "exact", "platform": "ios", "priority": 0,
                      "versionConstraint": ["operator": "exactlyMatches", "versions": ["1.45.0"]]],
        ]
        XCTAssertEqual(
            FlagResolver.resolve(flags: [input], conditionsByName: cond, context: context(version: "1.45.0"))["flag_a"] as? Bool,
            true
        )
        XCTAssertEqual(
            FlagResolver.resolve(flags: [input], conditionsByName: cond, context: context(version: "1.45.1"))["flag_a"] as? Bool,
            false
        )
    }

    // MARK: - Rollout

    func testRolloutDisabledReturnsDefault() {
        let input = FlagInput(
            flag: ["name": "flag_a", "defaultValue": false],
            env: ["value": true, "rollout": ["enabled": false, "percentage": 100, "seed": "s"]],
            tenantOverride: nil
        )
        let out = FlagResolver.resolve(flags: [input], conditionsByName: [:], context: context(version: nil, userId: "u1"))
        XCTAssertEqual(out["flag_a"] as? Bool, false)
    }

    func testRolloutNoUserIdUsesResolvedValue() {
        let input = FlagInput(
            flag: ["name": "flag_a", "defaultValue": false],
            env: ["value": true, "rollout": ["enabled": true, "percentage": 0, "seed": "s"]],
            tenantOverride: nil
        )
        // No userId → bucketing skipped, resolved (env) value wins even at 0%.
        let out = FlagResolver.resolve(flags: [input], conditionsByName: [:], context: context(version: nil, userId: nil))
        XCTAssertEqual(out["flag_a"] as? Bool, true)
    }

    func testRolloutBucketingMatchesServer() {
        // Find a userId whose bucket is deterministic for seed "rseed".
        let seed = "rseed"
        let userId = "user-123"
        let bucket = FNV1a.percentageBucket(seed: seed, userId: userId)

        // percentage just above the bucket → user IS included → env value.
        let inIn = FlagInput(
            flag: ["name": "flag_a", "defaultValue": false],
            env: ["value": true, "rollout": ["enabled": true, "percentage": bucket + 1, "seed": seed]],
            tenantOverride: nil
        )
        XCTAssertEqual(
            FlagResolver.resolve(flags: [inIn], conditionsByName: [:], context: context(version: nil, userId: userId))["flag_a"] as? Bool,
            true
        )

        // percentage equal to the bucket → bucket >= percentage → excluded → default.
        let inOut = FlagInput(
            flag: ["name": "flag_a", "defaultValue": false],
            env: ["value": true, "rollout": ["enabled": true, "percentage": bucket, "seed": seed]],
            tenantOverride: nil
        )
        XCTAssertEqual(
            FlagResolver.resolve(flags: [inOut], conditionsByName: [:], context: context(version: nil, userId: userId))["flag_a"] as? Bool,
            false
        )
    }

    // MARK: - Version comparison primitives

    func testParseAndCompareVersions() {
        XCTAssertEqual(FlagResolver.compareVersions(FlagResolver.parseVersion("1.49.1"), FlagResolver.parseVersion("1.49")), 1)
        XCTAssertEqual(FlagResolver.compareVersions(FlagResolver.parseVersion("1.2"), FlagResolver.parseVersion("1.2.0")), 0)
        XCTAssertEqual(FlagResolver.compareVersions(FlagResolver.parseVersion("1.0.0"), FlagResolver.parseVersion("2.0.0")), -1)
    }
}
