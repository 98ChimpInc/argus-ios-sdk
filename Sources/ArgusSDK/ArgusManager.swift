//
//  ArgusManager.swift
//  ArgusSDK
//
//  Drop-in replacement for RemoteConfigManager. Conforms to RemoteFlags.
//
//  PRIMARY channel: real-time push (CANONICAL, DECISIONS.md 2026-06-02).
//  On start the manager trades its apiKey for a scoped Firebase custom
//  token (issueStreamToken), signs in, and opens Firestore snapshot
//  listeners on its Product's flag / env / tenant / condition docs. Any
//  change re-resolves all flags client-side (mirroring the server
//  resolveFlags algorithm) and publishes via configUpdatedPublisher.
//
//  FALLBACK channel: the resolveFlags HTTP call + pollTimer remain, but
//  are demoted to a cold-start / fallback role — they paint the cache for
//  the very first frame before the listener delivers, and they keep the
//  app updating if Firebase init / sign-in fails.
//

import Foundation
import Combine
import OSLog

public final class ArgusManager: RemoteFlags {

    // MARK: - RemoteFlags Protocol

    public let configUpdatedPublisher = PassthroughSubject<Set<String>?, Never>()

    // Public no-arg initializer. Without it Swift synthesizes an `internal`
    // init, so `ArgusManager()` is inaccessible to consumer apps (the
    // documented usage). All stored properties below have defaults / are
    // optional, so an empty init is sufficient; `configure(...)` does setup.
    public init() {}

    // MARK: - Internal State

    private var configuration: ArgusConfiguration?
    private var cache: [String: Any] = [:]
    private let cacheLock = NSLock()
    private var defaults: [String: Any] = [:]
    private var pollTimer: Timer?
    private var isInitialFetch = true

    /// Real-time push channel. `nil` until `configure(...)` runs, or when a
    /// stream bootstrap failure has demoted the SDK to HTTP-only.
    private var streamClient: StreamClient?

    /// Set once the live stream has delivered at least one snapshot. While
    /// `true`, the HTTP fallback stops emitting on `configUpdatedPublisher`
    /// so the two channels never fight over the published cache (the stream
    /// is authoritative once live).
    private var streamIsLive = false
    private let streamStateLock = NSLock()

    private let logger = Logger(subsystem: "cloud.projectargus.sdk", category: "ArgusManager")

    // MARK: - Configuration

    /// Configure the SDK and begin fetching flags.
    ///
    /// The happy path is to pass **only the Argus apiKey and the base URL**
    /// (plus a `tenantId`): the SDK trades the apiKey for a scoped Firebase
    /// identity via `issueStreamToken`, and that response also carries the
    /// Firebase project config the SDK uses to self-configure its real-time
    /// channel — so you never set up Firebase yourself. (For local testing
    /// against the emulator, build an `ArgusConfiguration` with an explicit
    /// `firebaseConfig: .emulator()` override; see the README.)
    ///
    /// This method returns immediately. The app is usable with bundled
    /// defaults until the first HTTP response arrives.
    ///
    /// - Parameters:
    ///   - apiKey: Argus API key for your Customer workspace.
    ///   - baseURL: Base URL of the Argus Cloud Function.
    ///   - tenantId: Tenant identifier (e.g. "acme_ca").
    ///   - environment: Target environment: "dev", "staging", or "prod".
    ///   - userId: Optional user identifier for rollout bucketing.
    ///   - pollInterval: Seconds between automatic fetches. Default: 300.
    public func configure(
        apiKey: String,
        baseURL: String,
        tenantId: String,
        environment: String,
        userId: String? = nil,
        pollInterval: TimeInterval = 300
    ) {
        let config = ArgusConfiguration(
            apiKey: apiKey,
            baseURL: baseURL,
            tenantId: tenantId,
            environment: environment,
            userId: userId,
            pollInterval: pollInterval
        )
        applyConfiguration(config)
    }

    /// Configure the SDK with an auto-detected environment.
    ///
    /// Pass **only the Argus apiKey and the base URL** (plus a `tenantId`);
    /// the SDK self-configures Firebase from the `issueStreamToken` response,
    /// so no Firebase setup is required on your side.
    ///
    /// This overload omits the `environment` argument and resolves it
    /// from the build context:
    ///
    /// - `#if DEBUG` → `"dev"`
    /// - TestFlight (sandbox receipt URL) → `"staging"`
    /// - App Store release → `"prod"`
    ///
    /// Use the 4-arg overload with an explicit `environment` if you
    /// ship a non-standard mapping (e.g. a DEBUG build that talks to
    /// a staging backend).
    ///
    /// - Parameters:
    ///   - apiKey: Argus API key for your Customer workspace.
    ///   - baseURL: Base URL of the Argus Cloud Function.
    ///   - tenantId: Tenant identifier (e.g. "acme_ca").
    ///   - userId: Optional user identifier for rollout bucketing.
    ///   - pollInterval: Seconds between automatic fetches. Default: 300.
    public func configure(
        apiKey: String,
        baseURL: String,
        tenantId: String,
        userId: String? = nil,
        pollInterval: TimeInterval = 300
    ) {
        let config = ArgusConfiguration(
            apiKey: apiKey,
            baseURL: baseURL,
            tenantId: tenantId,
            userId: userId,
            pollInterval: pollInterval
        )
        applyConfiguration(config)
    }

    /// Shared post-construction wiring for both `configure(...)` overloads.
    private func applyConfiguration(_ config: ArgusConfiguration) {
        self.configuration = config

        // Load bundled defaults and seed the cache
        defaults = DefaultsLoader.loadDefaults()
        writeCache(defaults)

        // FALLBACK / cold-start: a single HTTP fetch paints the cache for
        // the first frame before the live listener delivers, and the poll
        // timer backstops a stream that never establishes. Once the stream
        // goes live the poll stops emitting (see handleStreamSnapshot).
        refreshConfig()
        startPollTimer(interval: config.pollInterval)

        // PRIMARY: open the real-time push channel.
        startStream(config: config)
    }

    /// Bootstrap the real-time listener channel. On any failure we log and
    /// leave the HTTP fallback running — the app keeps updating, just on
    /// the slower poll cadence.
    private func startStream(config: ArgusConfiguration) {
        let client = StreamClient(
            configuration: config,
            logger: logger,
            onSnapshotChange: { [weak self] snapshot in
                self?.handleStreamSnapshot(snapshot)
            }
        )
        self.streamClient = client

        Task { [weak self] in
            do {
                try await client.start()
            } catch {
                self?.logger.error("ArgusSDK stream bootstrap failed; falling back to HTTP poll: \(error.localizedDescription)")
                // Demote: drop the stream client so deinit/stop is clean and
                // the HTTP fallback remains the live channel.
                self?.streamClient = nil
            }
        }
    }

    /// Re-resolve all flags from a fresh listener snapshot and publish.
    ///
    /// This is the live update path. Resolution mirrors the server
    /// `resolveFlags` algorithm exactly (see `FlagResolver`).
    private func handleStreamSnapshot(_ snapshot: StreamSnapshot) {
        guard let configuration else { return }

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        // `platformAppId` is the Argus platform appId from the server's
        // `config/platform` doc — NOT the Firebase appId. The scoped stream
        // identity is not authorised to read `config/platform`, so we pass
        // `nil`. Per `FlagResolver.evaluateCondition`, the appId clause is
        // only enforced when BOTH the condition's `appId` and the context's
        // `platformAppId` are present, so `nil` skips that clause exactly as
        // the server does when it cannot resolve a platform appId.
        let context = FlagResolutionContext(
            platform: "ios",
            version: appVersion,
            userId: configuration.userId,
            language: Locale.preferredLanguages.first,
            platformAppId: nil,
            tenantId: configuration.tenantId
        )

        let inputs: [FlagInput] = snapshot.flagDocs.map { (flagId, flagData) in
            FlagInput(
                flag: flagData,
                env: snapshot.envDocs[flagId],
                tenantOverride: snapshot.tenantDocs[flagId]
            )
        }

        let resolved = FlagResolver.resolve(
            flags: inputs,
            conditionsByName: snapshot.conditionsByName,
            context: context
        )

        // Strip server-`null`s and parse JSON-string values exactly as the
        // HTTP path does, so both channels produce an identical cache shape.
        let processed = processFlags(resolved)

        // Mark the stream live on first delivery — disables fallback emission.
        let wasLive = markStreamLive()

        let oldCache = snapshotCache()
        let changedKeys = computeDiff(old: oldCache, new: processed)
        writeCache(processed)

        if !wasLive {
            // First live snapshot — treat as a full refresh.
            isInitialFetch = false
            configUpdatedPublisher.send(nil)
        } else if !changedKeys.isEmpty {
            configUpdatedPublisher.send(changedKeys)
        }
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

    // MARK: - Stream-Live State

    /// Whether the real-time stream has delivered at least one snapshot.
    /// Synchronous so it is safe to call from `async` contexts (an inline
    /// `NSLock.unlock()` in an async function is a Swift 6 error).
    private func isStreamLive() -> Bool {
        streamStateLock.lock()
        defer { streamStateLock.unlock() }
        return streamIsLive
    }

    /// Mark the stream live and return the PREVIOUS value, so the first
    /// snapshot can be distinguished from subsequent ones in one atomic step.
    private func markStreamLive() -> Bool {
        streamStateLock.lock()
        defer { streamStateLock.unlock() }
        let previous = streamIsLive
        streamIsLive = true
        return previous
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
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")

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

            // FALLBACK gate: once the live stream has delivered a snapshot
            // it is the authoritative channel. A late HTTP response must not
            // clobber the live cache or double-emit, so we drop it silently.
            if isStreamLive() {
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

    /// Tear down both channels: detach the real-time listeners (signing the
    /// stream identity out) and stop the HTTP poll timer. Safe to call more
    /// than once. The cache is left intact so synchronous accessors keep
    /// returning the last-known values after a stop.
    public func stop() {
        streamClient?.stop()
        streamClient = nil
        pollTimer?.invalidate()
        pollTimer = nil
    }

    deinit {
        streamClient?.stop()
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
