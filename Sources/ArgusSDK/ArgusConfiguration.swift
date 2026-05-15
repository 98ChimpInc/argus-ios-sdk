//
//  ArgusConfiguration.swift
//  ArgusSDK
//
//  Configuration struct holding all parameters needed to connect to the
//  Argus resolveFlags endpoint.
//

import Foundation

public struct ArgusConfiguration {

    /// Base URL of the Argus Cloud Function (e.g. "https://us-central1-argus-prod.cloudfunctions.net")
    public let baseURL: String

    /// Tenant identifier (e.g. "acme_ca", "globex_de", "initech_jp")
    public let tenantId: String

    /// Target environment: "dev", "staging", or "prod"
    public let environment: String

    /// Optional user identifier for rollout bucketing
    public let userId: String?

    /// Seconds between automatic fetches. Default: 300 (5 minutes).
    public let pollInterval: TimeInterval

    public init(
        baseURL: String,
        tenantId: String,
        environment: String,
        userId: String? = nil,
        pollInterval: TimeInterval = 300
    ) {
        self.baseURL = baseURL
        self.tenantId = tenantId
        self.environment = environment
        self.userId = userId
        self.pollInterval = pollInterval
    }
}
