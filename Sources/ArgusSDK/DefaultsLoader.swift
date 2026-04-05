//
//  DefaultsLoader.swift
//  ArgusSDK
//
//  Loads default flag values from RemoteConfigDefaults.plist bundled in
//  the host app's main bundle. This is the same plist that
//  RemoteConfigManager uses via remoteConfig.setDefaults(fromPlist:).
//

import Foundation

public struct DefaultsLoader {

    /// Load key-value pairs from RemoteConfigDefaults.plist in the main bundle.
    ///
    /// Returns an empty dictionary if the plist is not found or cannot be read.
    public static func loadDefaults() -> [String: Any] {
        guard let path = Bundle.main.path(
            forResource: "RemoteConfigDefaults",
            ofType: "plist"
        ) else {
            return [:]
        }
        return NSDictionary(contentsOfFile: path) as? [String: Any] ?? [:]
    }
}
