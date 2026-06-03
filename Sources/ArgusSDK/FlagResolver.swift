//
//  FlagResolver.swift
//  ArgusSDK
//
//  Client-side flag resolution. Mirrors the server `resolveFlags`
//  algorithm in functions/index.js EXACTLY so that a value resolved
//  locally from the real-time listener snapshots is identical to one the
//  HTTP endpoint would have returned for the same context.
//
//  Inputs are plain dictionaries (the shape Firestore hands back from a
//  snapshot's `.data()`), which keeps this engine free of any Firebase
//  dependency and fully unit-testable without a live backend.
//

import Foundation

/// The context a resolution is evaluated against — the client identity
/// the server would otherwise receive as query parameters.
struct FlagResolutionContext {
    /// Lowercased platform ("ios"). The SDK always resolves for iOS.
    let platform: String?
    /// Client app version, e.g. "1.49.1". `nil` disables conditional values.
    let version: String?
    /// Stable user identifier for rollout / percentage bucketing.
    let userId: String?
    /// BCP-47 language tag, lowercased downstream.
    let language: String?
    /// The platform's known appId (from `config/platform` → appIds.ios).
    let platformAppId: String?
    /// Tenant the apiKey is scoped to, if any.
    let tenantId: String?
}

/// A single flag's input documents, as read from the live listeners.
struct FlagInput {
    /// The `/flags/{flagId}` document data.
    let flag: [String: Any]
    /// The `/flags/{flagId}/environments/{env}` document data, or `nil`
    /// when the env subdoc does not exist.
    let env: [String: Any]?
    /// The `/flags/{flagId}/environments/{env}/tenants/{tenantId}` document
    /// data, or `nil` when there is no tenant override (or no tenant scope).
    let tenantOverride: [String: Any]?
}

enum FlagResolver {

    /// Resolve every flag to a single value, keyed by flag name.
    ///
    /// - Parameters:
    ///   - flags: per-flag input documents.
    ///   - conditionsByName: `/conditions` docs keyed by their `name`.
    ///   - context: the client evaluation context.
    /// - Returns: a `[flagName: resolvedValue]` map. Values may be `NSNull`
    ///   where the server would emit `null`; the caller strips those so
    ///   they fall through to bundled defaults (matching `processFlags`).
    static func resolve(
        flags: [FlagInput],
        conditionsByName: [String: [String: Any]],
        context: FlagResolutionContext
    ) -> [String: Any] {
        var resolved: [String: Any] = [:]

        for input in flags {
            let flagData = input.flag
            guard let flagName = flagData["name"] as? String else { continue }

            // Skip archived flags (mirrors server `if (flagData.archived) return`).
            if (flagData["archived"] as? Bool) == true { continue }

            // Skip draft flags (#210). Missing `draft` ≡ published.
            if (flagData["draft"] as? Bool) == true { continue }

            let defaultValue = flagData["defaultValue"]

            // No environment doc — use the flag's default value.
            guard let envData = input.env else {
                resolved[flagName] = defaultValue ?? NSNull()
                continue
            }

            var resolvedValue: Any = envData["value"] ?? defaultValue ?? NSNull()

            // ── Tenant override takes priority ──────────────────────
            if context.tenantId != nil, let tenantOverride = input.tenantOverride {
                // The server returns `tenantSnap.data().value` verbatim,
                // even if that is null/absent.
                resolved[flagName] = tenantOverride["value"] ?? NSNull()
                continue
            }

            // ── Conditional values (only when platform AND version supplied) ─
            if let platform = context.platform, !platform.isEmpty,
               let version = context.version, !version.isEmpty,
               let conditionalValues = envData["conditionalValues"] as? [String: Any] {

                // Sort entries by their condition's priority ascending;
                // unknown conditions sort last (Int.max), exactly as the
                // server uses Number.MAX_SAFE_INTEGER.
                let entries = conditionalValues
                    .map { (name, value) -> (name: String, value: Any, priority: Int, definition: [String: Any]?) in
                        let def = conditionsByName[name]
                        let priority = (def?["priority"] as? Int) ?? Int.max
                        return (name, value, priority, def)
                    }
                    .sorted { $0.priority < $1.priority }

                for entry in entries {
                    // Condition not found in /conditions — skip.
                    guard let definition = entry.definition else { continue }
                    if evaluateCondition(definition, context: context) {
                        resolvedValue = entry.value
                        break // first match wins
                    }
                }
            }

            // ── Rollout evaluation ────────────────────────────────
            if let rollout = envData["rollout"] as? [String: Any] {
                let enabled = (rollout["enabled"] as? Bool) ?? false
                if !enabled {
                    // Paused — all users receive the pre-rollout default.
                    resolved[flagName] = defaultValue ?? NSNull()
                    continue
                }
                if let userId = context.userId,
                   let seed = rollout["seed"] as? String,
                   let percentage = intValue(rollout["percentage"]) {
                    let bucket = FNV1a.percentageBucket(seed: seed, userId: userId)
                    if bucket >= percentage {
                        // User NOT in rollout — pre-rollout default.
                        resolved[flagName] = defaultValue ?? NSNull()
                        continue
                    }
                    // User IS in rollout — falls through to resolvedValue.
                }
                // No userId — skip bucketing, use resolvedValue.
            }

            resolved[flagName] = resolvedValue
        }

        return resolved
    }

    // MARK: - Condition Evaluation (mirrors server `evaluateCondition`)

    /// Evaluate whether a single condition matches the context. All present
    /// clauses must match (logical AND).
    static func evaluateCondition(
        _ condition: [String: Any],
        context: FlagResolutionContext
    ) -> Bool {
        // Platform check.
        if let platform = condition["platform"] as? String, platform != "all" {
            if platform != context.platform { return false }
        }

        // App ID check: only enforced when both sides are present.
        if let appId = condition["appId"] as? String, !appId.isEmpty,
           let ctxAppId = context.platformAppId {
            if appId != ctxAppId { return false }
        }

        // Version constraint check.
        if let constraint = condition["versionConstraint"] as? [String: Any] {
            if !evaluateVersionConstraint(context.version, constraint: constraint) {
                return false
            }
        }

        // Percentage range check.
        if let range = condition["percentageRange"] as? [String: Any] {
            guard let userId = context.userId else { return false }
            guard let seed = range["seed"] as? String,
                  let low = intValue(range["low"]),
                  let high = intValue(range["high"]) else { return false }
            let bucket = FNV1a.percentageBucket(seed: seed, userId: userId)
            if bucket < low || bucket >= high { return false }
        }

        // Audience check: without client-side membership data we cannot
        // evaluate, so a non-empty audience never matches (server parity).
        if let audienceIds = condition["audienceIds"] as? [Any], !audienceIds.isEmpty {
            return false
        }

        // Language filter check.
        if let languageFilter = condition["languageFilter"] as? [Any], !languageFilter.isEmpty {
            guard let language = context.language else { return false }
            let clientLang = language.lowercased()
            let matches = languageFilter.contains { entry in
                (entry as? String)?.lowercased() == clientLang
            }
            if !matches { return false }
        }

        return true
    }

    // MARK: - Version Comparison (mirrors server parseVersion/compareVersions)

    /// Split a version string into integer segments. Non-numeric segments
    /// become 0, matching the server's `parseVersion`.
    static func parseVersion(_ versionStr: String?) -> [Int] {
        guard let versionStr, !versionStr.isEmpty else { return [] }
        return versionStr.split(separator: ".", omittingEmptySubsequences: false).map {
            Int($0) ?? 0
        }
    }

    /// Compare two version segment arrays, padding the shorter with zeroes.
    /// Returns -1 if a < b, 0 if equal, 1 if a > b.
    static func compareVersions(_ a: [Int], _ b: [Int]) -> Int {
        let maxLen = max(a.count, b.count)
        for i in 0..<maxLen {
            let segA = i < a.count ? a[i] : 0
            let segB = i < b.count ? b[i] : 0
            if segA < segB { return -1 }
            if segA > segB { return 1 }
        }
        return 0
    }

    /// Evaluate a `{ operator, versions }` constraint against a client
    /// version. Mirrors the server's `evaluateVersionConstraint`.
    static func evaluateVersionConstraint(
        _ clientVersion: String?,
        constraint: [String: Any]
    ) -> Bool {
        guard let op = constraint["operator"] as? String,
              let versions = constraint["versions"] as? [Any], !versions.isEmpty else {
            return true
        }
        let versionStrings = versions.compactMap { $0 as? String }
        let client = parseVersion(clientVersion)

        // List-membership operators.
        if op == "exactlyMatches" || op == "contains" || op == "matches" {
            return versionStrings.contains { compareVersions(client, parseVersion($0)) == 0 }
        }

        // Comparison operators compare against the first listed version.
        guard let first = versionStrings.first else { return false }
        let cmp = compareVersions(client, parseVersion(first))
        switch op {
        case ">=": return cmp >= 0
        case "<=": return cmp <= 0
        case "<":  return cmp < 0
        case "==": return cmp == 0
        default:   return false // unknown operator
        }
    }

    // MARK: - Helpers

    /// Coerce a Firestore numeric (`Int`, `Double`, `NSNumber`) to `Int`.
    /// Firestore returns integer fields as `NSNumber`/`Int64` depending on
    /// path, so normalise defensively.
    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let double = value as? Double { return Int(double) }
        return nil
    }
}
