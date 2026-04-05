//
//  FNV1a.swift
//  ArgusSDK
//
//  FNV-1a 32-bit hash for deterministic rollout bucketing.
//  Must produce identical output to the JavaScript reference in
//  functions/index.js.
//

import Foundation

public enum FNV1a {

    /// FNV-1a 32-bit hash.
    ///
    /// Iterates over UTF-16 code units to match JavaScript's `charCodeAt()`.
    /// Uses overflow multiplication (`&*`) to match `Math.imul` behaviour.
    ///
    /// - Parameter string: The input string to hash.
    /// - Returns: An unsigned 32-bit hash value.
    public static func fnv1a(_ string: String) -> UInt32 {
        var hash: UInt32 = 0x811c9dc5 // FNV offset basis
        for codeUnit in string.utf16 {
            hash ^= UInt32(codeUnit)
            hash = hash &* 0x01000193 // FNV prime, overflow wraps (32-bit)
        }
        return hash
    }

    /// Bucket a user into 0...99 based on seed + userId.
    ///
    /// A user is included in a rollout if their bucket value is strictly
    /// less than the rollout percentage.
    ///
    /// - Parameters:
    ///   - seed: The rollout seed string (typically the flag name or rollout ID).
    ///   - userId: The user's unique identifier.
    /// - Returns: A value in 0...99.
    public static func percentageBucket(seed: String, userId: String) -> Int {
        Int(fnv1a(seed + userId) % 100)
    }
}
