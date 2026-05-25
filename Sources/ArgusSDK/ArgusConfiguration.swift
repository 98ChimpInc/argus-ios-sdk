//
//  ArgusConfiguration.swift
//  ArgusSDK
//
//  Configuration struct holding all parameters needed to connect to the
//  Argus resolveFlags endpoint.
//

import Foundation

public struct ArgusConfiguration {

    /// Argus API key for this Customer workspace. Sent as a Bearer token
    /// on every resolveFlags request. Find it in the Argus dashboard
    /// under Settings → API key.
    public let apiKey: String

    /// Base URL of the Argus resolveFlags Cloud Function
    /// (e.g. "https://us-central1-argus-app-f0ff3.cloudfunctions.net")
    public let baseURL: String

    /// Tenant identifier (e.g. "acme_ca", "globex_de", "initech_jp")
    public let tenantId: String

    /// Target environment: "dev", "staging", or "prod"
    public let environment: String

    /// Optional user identifier for rollout bucketing
    public let userId: String?

    /// Seconds between automatic fetches. Default: 300 (5 minutes).
    public let pollInterval: TimeInterval

    /// Auto-detected environment based on build context.
    ///
    /// Priority order:
    /// 1. `#if DEBUG` → `"dev"`
    /// 2. TestFlight (sandbox receipt URL) → `"staging"`
    /// 3. App Store release → `"prod"`
    ///
    /// Customers with non-standard mappings can override by passing
    /// an explicit `environment` argument to `configure(...)`.
    public static var autoDetectedEnvironment: String {
        resolveAutoDetectedEnvironment(receiptURL: Bundle.main.appStoreReceiptURL)
    }

    /// Internal resolver used by `autoDetectedEnvironment` and by tests.
    ///
    /// The receipt URL is injectable so the staging/prod branches can be
    /// exercised under unit tests, where `Bundle.main.appStoreReceiptURL`
    /// is not under our control.
    ///
    /// The DEBUG branch is decided at compile time and always returns
    /// `"dev"` when the SDK (and its tests) are built with DEBUG defined,
    /// which matches the behaviour customers will see when running their
    /// app from Xcode.
    internal static func resolveAutoDetectedEnvironment(receiptURL: URL?) -> String {
        #if DEBUG
            return "dev"
        #else
            // TestFlight builds use a sandbox receipt URL; App Store
            // builds use a regular receipt URL. Standard idiom, no
            // private API. Works on first launch regardless of
            // purchase history.
            if receiptURL?.lastPathComponent == "sandboxReceipt" {
                return "staging"
            }
            return "prod"
        #endif
    }

    /// Internal variant of `resolveAutoDetectedEnvironment` that ignores
    /// the compile-time DEBUG flag. Lets tests exercise the runtime
    /// receipt-URL logic regardless of how the SDK was compiled.
    internal static func resolveReleaseEnvironment(receiptURL: URL?) -> String {
        if receiptURL?.lastPathComponent == "sandboxReceipt" {
            return "staging"
        }
        return "prod"
    }

    /// Initialiser with an explicit environment.
    ///
    /// Use this when you want to override the auto-detected mapping
    /// (e.g. you ship a DEBUG build that talks to a staging backend).
    public init(
        apiKey: String,
        baseURL: String,
        tenantId: String,
        environment: String,
        userId: String? = nil,
        pollInterval: TimeInterval = 300
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.tenantId = tenantId
        self.environment = environment
        self.userId = userId
        self.pollInterval = pollInterval
    }

    /// Initialiser that auto-detects the environment from build context.
    ///
    /// See `autoDetectedEnvironment` for the mapping. Pass the
    /// 6-arg initialiser with an explicit `environment` value if you
    /// need to override.
    public init(
        apiKey: String,
        baseURL: String,
        tenantId: String,
        userId: String? = nil,
        pollInterval: TimeInterval = 300
    ) {
        self.init(
            apiKey: apiKey,
            baseURL: baseURL,
            tenantId: tenantId,
            environment: ArgusConfiguration.autoDetectedEnvironment,
            userId: userId,
            pollInterval: pollInterval
        )
    }
}
