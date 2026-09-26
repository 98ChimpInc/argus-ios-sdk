//
//  FirstEmissionGate.swift
//  ArgusSDK
//
//  Gates the stream's FIRST consolidated emission (#16).
//
//  The stream attaches a `/flags/{id}/environments/{env}` listener per flag,
//  but those env docs arrive a moment AFTER the flags snapshot. If the first
//  emission goes out in that window, `FlagResolver` maps every not-yet-arrived
//  env doc to the flag's default value, so the consumer's first "answer" is all
//  defaults — then the real values follow a beat later. On Loomi that flashed a
//  whitelisted account as non-premium for ~1s after launch.
//
//  This gate holds the first emission until every flag seen in the initial
//  flags snapshot has had its env listener (and, when the apiKey is
//  tenant-scoped, its tenant listener) deliver at least once — whether or not
//  the doc exists. A missing doc still fires the listener once, so a flag with
//  no env doc does not stall the gate. Once the first complete emission passes,
//  the gate is permanently open: later snapshots emit exactly as before.
//
//  Pure value logic (no Firebase), so the emission rule is unit-testable even
//  though `StreamClient` itself is Firebase-locked.
//

import Foundation

struct FirstEmissionGate {

    /// Flags whose env listener has not yet delivered its first callback.
    private var pendingEnv: Set<String> = []
    /// Flags whose tenant-override listener has not yet delivered its first
    /// callback (only populated when the apiKey is tenant-scoped).
    private var pendingTenant: Set<String> = []

    /// `true` once the first complete emission has been released. From then on
    /// the gate never suppresses again, so post-initial-load changes (a flag
    /// added later, a value change) flow through immediately.
    private(set) var isOpen = false

    /// The flags listener has not yet delivered its first snapshot. Until it
    /// does, no flag has been `expect`ed, so an independent sibling listener
    /// (the conditions query, which also drives emission) must NOT be allowed to
    /// open the gate on an empty pending set and emit an all-defaults snapshot
    /// before flags arrive — a real race on 2nd+ launches with on-disk cache (#16).
    private var awaitingFlagsSnapshot = true

    /// The flags listener delivered its first snapshot: every flag it contains
    /// has now been `expect`ed, so the gate is finally allowed to open.
    mutating func flagsSnapshotArrived() {
        guard !isOpen else { return }
        awaitingFlagsSnapshot = false
    }

    /// Register that a flag's listeners are being attached during the initial
    /// load, so the first emission waits for them. A no-op once the gate is
    /// open — a flag first seen after initial load must not re-gate the stream.
    mutating func expect(flagId: String, tenantScoped: Bool) {
        guard !isOpen else { return }
        pendingEnv.insert(flagId)
        if tenantScoped { pendingTenant.insert(flagId) }
    }

    /// A flag's env listener delivered its first callback.
    mutating func envArrived(flagId: String) {
        pendingEnv.remove(flagId)
    }

    /// A flag's tenant-override listener delivered its first callback.
    mutating func tenantArrived(flagId: String) {
        pendingTenant.remove(flagId)
    }

    /// A flag disappeared before the initial load completed; stop waiting on
    /// it, otherwise its never-cleared entry would hold the gate shut forever.
    mutating func drop(flagId: String) {
        pendingEnv.remove(flagId)
        pendingTenant.remove(flagId)
    }

    /// Whether `emitSnapshot` should deliver now. While the gate is closed it
    /// releases only once nothing is pending; that first release flips `isOpen`,
    /// so every later call returns `true`. Mutating because opening is the
    /// one-way transition the caller relies on.
    mutating func shouldEmit() -> Bool {
        if isOpen { return true }
        // The flags snapshot must arrive first, so a sibling listener can't open
        // the gate on an empty pending set before any flag is even known.
        guard !awaitingFlagsSnapshot else { return false }
        if pendingEnv.isEmpty && pendingTenant.isEmpty {
            isOpen = true
            return true
        }
        return false
    }
}
