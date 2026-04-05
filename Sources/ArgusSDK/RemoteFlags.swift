//
//  RemoteFlags.swift
//  ArgusSDK
//
//  Protocol definition copied from the SmartHome+ iOS app's DevelopmentFlags
//  package. This allows ArgusSDK to be a standalone package without requiring
//  DevelopmentFlags as a dependency.
//

import Foundation
import Combine

/// A type whose value can be read from a remote flag source.
public protocol RemoteFlagValue {
    static func value(forKey key: String, remoteFlags: RemoteFlags) -> Self
}

extension Bool: RemoteFlagValue {
    public static func value(forKey key: String, remoteFlags: RemoteFlags) -> Bool {
        remoteFlags.bool(forKey: key)
    }
}

extension Int: RemoteFlagValue {
    public static func value(forKey key: String, remoteFlags: RemoteFlags) -> Int {
        remoteFlags.int(forKey: key)
    }
}

extension Optional: RemoteFlagValue where Wrapped: Decodable {
    public static func value(forKey key: String, remoteFlags: RemoteFlags) -> Wrapped? {
        if Wrapped.self == String.self {
            return remoteFlags.string(forKey: key) as? Wrapped
        } else {
            let decodedValue: Wrapped? = remoteFlags.json(forKey: key)
            return decodedValue
        }
    }
}

/// Contract for accessing remotely-configured feature flags.
///
/// The SDK must conform to this protocol without modification. All accessors
/// return cached values synchronously and never perform network I/O.
public protocol RemoteFlags {
    var configUpdatedPublisher: PassthroughSubject<Set<String>?, Never> { get }

    func bool(forKey key: String) -> Bool
    func string(forKey key: String) -> String?
    func int(forKey key: String) -> Int
    func json<T: Decodable>(forKey key: String) -> T?
    func double(forKey key: String) -> Double
}
