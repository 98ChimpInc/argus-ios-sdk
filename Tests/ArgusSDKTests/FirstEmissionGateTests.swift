//
//  FirstEmissionGateTests.swift
//  ArgusSDKTests
//
//  Verifies the #16 gate: the stream's first emission is held until the flags
//  snapshot has arrived AND every flag's env (and tenant, when scoped) listener
//  has delivered once, so the consumer's first snapshot carries real env values
//  instead of defaults. Pure value logic — no live Firebase.
//

import XCTest
@testable import ArgusSDK

final class FirstEmissionGateTests: XCTestCase {

    // The handoff scenario: flags arrive, then env docs arrive separately. The
    // first emission must be held until BOTH env docs land, then release once.
    func testFirstEmissionHeldUntilAllEnvDocsArrive() {
        var gate = FirstEmissionGate()

        // Flags snapshot attaches env listeners for A and B, marks the flags
        // snapshot arrived, then tries to emit.
        gate.expect(flagId: "a", tenantScoped: false)
        gate.expect(flagId: "b", tenantScoped: false)
        gate.flagsSnapshotArrived()
        XCTAssertFalse(gate.shouldEmit(), "must not emit before any env doc arrives")

        // First env doc arrives — still one outstanding.
        gate.envArrived(flagId: "a")
        XCTAssertFalse(gate.shouldEmit(), "must not emit while env b is still pending")

        // Second env doc arrives — now the single first emission is released.
        gate.envArrived(flagId: "b")
        XCTAssertTrue(gate.shouldEmit(), "emits once every env doc has arrived")
        XCTAssertTrue(gate.isOpen)

        // Every later emission passes through unconditionally.
        XCTAssertTrue(gate.shouldEmit())
        XCTAssertTrue(gate.shouldEmit())
    }

    // BLOCKER regression (#16): the conditions listener also drives emission and
    // registers no expectations. Before the flags snapshot arrives, the gate must
    // stay shut even though nothing is pending — otherwise conditions-before-flags
    // opens it on an empty flag set and emits all-defaults.
    func testDoesNotOpenBeforeFlagsSnapshotEvenWithNothingPending() {
        var gate = FirstEmissionGate()
        XCTAssertFalse(gate.shouldEmit(), "a sibling listener must not open the gate before flags arrive")
        XCTAssertFalse(gate.isOpen)

        gate.flagsSnapshotArrived()   // flags arrive (empty product)
        XCTAssertTrue(gate.shouldEmit(), "opens once flags have arrived and nothing is pending")
    }

    // Tenant-scoped flags must wait for the tenant-override listener too, not
    // just the env listener.
    func testTenantScopedWaitsForEnvAndTenant() {
        var gate = FirstEmissionGate()
        gate.expect(flagId: "a", tenantScoped: true)
        gate.flagsSnapshotArrived()

        gate.envArrived(flagId: "a")
        XCTAssertFalse(gate.shouldEmit(), "env alone is not enough when tenant-scoped")

        gate.tenantArrived(flagId: "a")
        XCTAssertTrue(gate.shouldEmit(), "emits once env AND tenant have arrived")
    }

    // A product with no flags: the empty snapshot is a valid first answer and
    // must emit as soon as the flags snapshot arrives.
    func testZeroFlagsEmitsOnceFlagsArrive() {
        var gate = FirstEmissionGate()
        gate.flagsSnapshotArrived()
        XCTAssertTrue(gate.shouldEmit())
        XCTAssertTrue(gate.isOpen)
    }

    // A flag removed before the initial load completes must not hold the gate
    // shut forever on a listener that will never fire again.
    func testFlagDroppedMidLoadDoesNotStall() {
        var gate = FirstEmissionGate()
        gate.expect(flagId: "a", tenantScoped: false)
        gate.expect(flagId: "b", tenantScoped: false)
        gate.flagsSnapshotArrived()

        gate.drop(flagId: "b")           // b removed mid-load
        gate.envArrived(flagId: "a")
        XCTAssertTrue(gate.shouldEmit(), "dropping the removed flag lets the gate open")
    }

    // `drop` on a tenant-scoped flag must clear BOTH the env and tenant slots,
    // otherwise a leftover tenant entry would hold the gate shut.
    func testDropClearsBothEnvAndTenantSlots() {
        var gate = FirstEmissionGate()
        gate.expect(flagId: "a", tenantScoped: true)
        gate.flagsSnapshotArrived()

        gate.drop(flagId: "a")           // only expected flag removed
        XCTAssertTrue(gate.shouldEmit(), "dropping a tenant-scoped flag clears env AND tenant")
    }

    // Once open, a flag first seen AFTER the initial load must not re-gate the
    // stream — its change should flow through as a normal live update.
    func testPostOpenAttachDoesNotRegate() {
        var gate = FirstEmissionGate()
        gate.expect(flagId: "a", tenantScoped: false)
        gate.flagsSnapshotArrived()
        gate.envArrived(flagId: "a")
        XCTAssertTrue(gate.shouldEmit())  // opens

        gate.expect(flagId: "c", tenantScoped: true) // a new flag, post-load
        XCTAssertTrue(gate.shouldEmit(), "a late-added flag must not suppress the stream again")
    }
}
