//
//  ArgusManager.swift
//  ArgusSDK
//
//  Drop-in replacement for RemoteConfigManager. Conforms to RemoteFlags,
//  fetches resolved flag values from the Argus HTTP endpoint, and caches
//  them locally for synchronous access.
//

import Foundation
import Combine
import OSLog
import FirebaseAuth

public final class ArgusManager: RemoteFlags {

    // MARK: - RemoteFlags Protocol

    public let configUpdatedPublisher = PassthroughSubject<Set<String>?, Never>()

    // MARK: - Internal State

    private var configuration: ArgusConfiguration?
    private var cache: [String: Any] = [:]
    private let cacheLock = NSLock()
    private var defaults: [String: Any] = [:]
    private var pollTimer: Timer?
    private var isInitialFetch = true

    private let logger = Logger(subsystem: "com.telus.smarthome.argus", category: "ArgusManager")

    // MARK: - Configuration

    /// Configure the SDK and begin fetching flags.
    ///
    /// This method returns immediately. The app is usable with bundled
    /// defaults until the first HTTP response arrives.
    ///
    /// - Parameters:
    ///   - baseURL: Base URL of the Argus Cloud Function.
    ///   - tenantId: Tenant identifier (e.g. "telus_ca").
    ///   - environment: Target environment: "dev", "staging", or "prod".
    ///   - userId: Optional user identifier for rollout bucketing.
    ///   - pollInterval: Seconds between automatic fetches. Default: 300.
    public func configure(
        baseURL: String,
        tenantId: String,
        environment: String,
        userId: String? = nil,
        pollInterval: TimeInterval = 300
    ) {
        let config = ArgusConfiguration(
            baseURL: baseURL,
            tenantId: tenantId,
            environment: environment,
            userId: userId,
            pollInterval: pollInterval
        )
        self.configuration = config

        // Load bundled defaults and seed the cache
        defaults = DefaultsLoader.loadDefaults()
        writeCache(defaults)

        // Trigger initial fetch (non-blocking)
        refreshConfig()

        // Start repeating poll timer on the main run loop
        startPollTimer(interval: config.pollInterval)
    }

    // MARK: - Manual Refresh

    /// Trigger an immediate HTTP fetch, bypassing the poll timer.
    ///
    /// On success, the cache is replaced with new values and
    /// `configUpdatedPublisher` emits the diff (or `nil` on full refresh).
    /// On failure, the cache is unchanged and no emission occurs.
    public func refreshConfig() {
        Task {
            await fetchFlags()
        }
    }

    // MARK: - Synchronous Accessors

    public func bool(forKey key: String) -> Bool {
        let value: Any? = readCache(key)
        if let boolValue = value as? Bool {
            return boolValue
        }
        if let stringValue = value as? String {
            return ["true", "1", "yes"].contains(stringValue.lowercased())
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return false
    }

    public func string(forKey key: String) -> String? {
        let value: Any? = readCache(key)
        if let stringValue = value as? String {
            return stringValue
        }
        if let boolValue = value as? Bool {
            return String(boolValue)
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    public func int(forKey key: String) -> Int {
        let value: Any? = readCache(key)
        if let intValue = value as? Int {
            return intValue
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let stringValue = value as? String, let parsed = Int(stringValue) {
            return parsed
        }
        return 0
    }

    public func double(forKey key: String) -> Double {
        let value: Any? = readCache(key)
        if let doubleValue = value as? Double {
            return doubleValue
        }
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let stringValue = value as? String, let parsed = Double(stringValue) {
            return parsed
        }
        return 0.0
    }

    public func json<T: Decodable>(forKey key: String) -> T? {
        let typeQualifiedKey = "\(key)__decoded__\(String(describing: T.self))"

        // Check for a previously decoded instance
        cacheLock.lock()
        if let cachedDecoded = cache[typeQualifiedKey] as? T {
            cacheLock.unlock()
            return cachedDecoded
        }

        // Retrieve the raw value
        let rawValue = cache[key]
        cacheLock.unlock()

        guard let rawValue else { return nil }

        // Determine the JSON source ... extract "ios" sub-object if present
        var jsonSource: Any = rawValue
        if let dict = rawValue as? [String: Any] {
            if let iosValue = dict["ios"] {
                jsonSource = iosValue
            }
        }

        do {
            let jsonData: Data
            if let dict = jsonSource as? [String: Any] {
                jsonData = try JSONSerialization.data(withJSONObject: dict)
            } else if let array = jsonSource as? [Any] {
                jsonData = try JSONSerialization.data(withJSONObject: array)
            } else {
                // Wrap primitive values for decoding
                let wrapped = ["value": jsonSource]
                jsonData = try JSONSerialization.data(withJSONObject: wrapped)
                // This path is unlikely to decode into T correctly,
                // but we attempt it for completeness
                let decoded = try JSONDecoder().decode(T.self, from: jsonData)
                cacheLock.lock()
                cache[typeQualifiedKey] = decoded
                cacheLock.unlock()
                return decoded
            }

            let decoded = try JSONDecoder().decode(T.self, from: jsonData)

            cacheLock.lock()
            cache[typeQualifiedKey] = decoded
            cacheLock.unlock()

            return decoded
        } catch {
            logger.error("Failed to decode JSON for key '\(key)': \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Thread-Safe Cache

    private func readCache<T>(_ key: String) -> T? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache[key] as? T
    }

    private func writeCache(_ newFlags: [String: Any]) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache = newFlags
    }

    // MARK: - Poll Timer

    private func startPollTimer(interval: TimeInterval) {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(
            withTimeInterval: interval,
            repeats: true
        ) { [weak self] _ in
            self?.refreshConfig()
        }
        RunLoop.main.add(pollTimer!, forMode: .common)
    }

    // MARK: - HTTP Fetch

    private func fetchFlags() async {
        guard let configuration else {
            logger.warning("ArgusManager.fetchFlags called before configure()")
            return
        }

        // Obtain Firebase Auth ID token
        guard let currentUser = Auth.auth().currentUser else {
            logger.debug("No authenticated user ... skipping fetch")
            return
        }

        let idToken: String
        do {
            idToken = try await currentUser.getIDToken()
        } catch {
            logger.error("Failed to get ID token: \(error.localizedDescription)")
            return
        }

        // Build the request URL
        var components = URLComponents(string: configuration.baseURL)
        components?.path += "/resolveFlags"

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"

        var queryItems = [
            URLQueryItem(name: "platform", value: "ios"),
            URLQueryItem(name: "version", value: appVersion),
            URLQueryItem(name: "tenantId", value: configuration.tenantId),
            URLQueryItem(name: "env", value: configuration.environment),
        ]
        if let userId = configuration.userId {
            queryItems.append(URLQueryItem(name: "userId", value: userId))
        }
        components?.queryItems = queryItems

        guard let url = components?.url else {
            logger.error("Failed to construct request URL")
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                logger.error("HTTP error: status \(statusCode)")
                return
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let flags = json["flags"] as? [String: Any] else {
                logger.error("Invalid response shape ... missing 'flags' dictionary")
                return
            }

            // Process flag values: parse JSON strings, handle nulls
            let processedFlags = processFlags(flags)

            // Compute diff before replacing cache
            let oldCache = snapshotCache()
            let changedKeys = computeDiff(old: oldCache, new: processedFlags)

            // Replace cache with new values
            writeCache(processedFlags)

            // Emit on configUpdatedPublisher per the emission rules
            if isInitialFetch {
                isInitialFetch = false
                configUpdatedPublisher.send(nil)
            } else if !changedKeys.isEmpty {
                configUpdatedPublisher.send(changedKeys)
            }
            // If no changes, skip emission entirely

        } catch {
            logger.error("Fetch failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Flag Processing

    /// Process raw flag values from the server response.
    ///
    /// JSON strings are parsed into dictionaries/arrays where possible.
    /// Null values are omitted (they fall through to defaults).
    private func processFlags(_ flags: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in flags {
            if value is NSNull {
                continue
            }
            if let stringValue = value as? String {
                // Attempt to parse JSON strings
                if let data = stringValue.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: data),
                   parsed is [String: Any] || parsed is [Any] {
                    result[key] = parsed
                } else {
                    result[key] = stringValue
                }
            } else {
                result[key] = value
            }
        }
        return result
    }

    /// Snapshot the current cache for diff computation.
    private func snapshotCache() -> [String: Any] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache
    }

    /// Compute the set of keys whose values differ between old and new.
    ///
    /// Uses string representation for equality comparison.
    private func computeDiff(old: [String: Any], new: [String: Any]) -> Set<String> {
        var changedKeys = Set<String>()
        let allKeys = Set(old.keys).union(Set(new.keys))
        for key in allKeys {
            // Skip type-qualified decoded cache keys
            if key.contains("__decoded__") { continue }

            let oldDesc = old[key].map { String(describing: $0) } ?? ""
            let newDesc = new[key].map { String(describing: $0) } ?? ""
            if oldDesc != newDesc {
                changedKeys.insert(key)
            }
        }
        return changedKeys
    }

    deinit {
        pollTimer?.invalidate()
    }

    // MARK: - Testing Support

    /// Allows tests to inject cache values directly without a network fetch.
    internal func setTestCache(_ values: [String: Any]) {
        writeCache(values)
    }

    /// Allows tests to check whether this is still considered the initial fetch.
    internal func setInitialFetchCompleted() {
        isInitialFetch = false
    }
}
