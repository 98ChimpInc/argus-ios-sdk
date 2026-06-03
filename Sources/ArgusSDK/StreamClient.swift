//
//  StreamClient.swift
//  ArgusSDK
//
//  Real-time push channel (CANONICAL architecture, DECISIONS.md
//  2026-06-02). Bootstraps a scoped Firebase identity from the Argus
//  apiKey via `issueStreamToken`, stands up a private named FirebaseApp,
//  signs in with the custom token, and opens Firestore snapshot listeners
//  on the SDK's own Product's flag / environment / tenant / condition
//  docs. Any change re-reads the live snapshots and calls back so the
//  owner can re-resolve and publish.
//
//  This file owns ALL Firebase interaction. ArgusManager orchestrates it
//  but never imports Firebase directly, keeping the resolution + cache
//  logic testable without a live backend.
//

import Foundation
import OSLog
import FirebaseCore
import FirebaseAuth
import FirebaseFirestore

/// Claims returned by `issueStreamToken`, mirrored back to the SDK.
struct StreamToken {
    let token: String
    let customerId: String
    let productId: String
    let env: String
    let tenantId: String?
    /// Firebase project config the server hands back so the SDK can
    /// self-configure its private named `FirebaseApp`. Used unless the
    /// consumer supplied an explicit `ArgusConfiguration.firebaseConfig`
    /// override.
    let firebaseConfig: FirebaseConfig
}

/// Errors that demote the SDK to the HTTP fallback path.
enum StreamClientError: Error {
    case tokenRequestFailed(status: Int)
    case malformedTokenResponse
    case invalidBaseURL
}

/// A consolidated snapshot of everything needed to resolve flags locally.
struct StreamSnapshot {
    /// `/flags/{id}` doc data, keyed by flag document ID.
    var flagDocs: [String: [String: Any]]
    /// `/flags/{id}/environments/{env}` doc data, keyed by flag document ID.
    var envDocs: [String: [String: Any]]
    /// Tenant override doc data, keyed by flag document ID (only populated
    /// when the apiKey is tenant-scoped).
    var tenantDocs: [String: [String: Any]]
    /// `/conditions` doc data, keyed by the condition's `name`.
    var conditionsByName: [String: [String: Any]]
}

final class StreamClient {

    // MARK: - Dependencies & State

    private let configuration: ArgusConfiguration
    private let logger: Logger

    private var firebaseApp: FirebaseApp?
    private var firestore: Firestore?
    private var auth: Auth?

    private var token: StreamToken?

    /// Listener registrations, retained so they can be detached.
    private var flagsQueryListener: ListenerRegistration?
    private var conditionsListener: ListenerRegistration?
    private var envListeners: [String: ListenerRegistration] = [:]
    private var tenantListeners: [String: ListenerRegistration] = [:]

    /// Latest known docs, mutated by listener callbacks under `stateLock`.
    private var flagDocs: [String: [String: Any]] = [:]
    private var envDocs: [String: [String: Any]] = [:]
    private var tenantDocs: [String: [String: Any]] = [:]
    private var conditionsByName: [String: [String: Any]] = [:]

    private let stateLock = NSLock()

    /// Invoked on ANY listener change with a fresh consolidated snapshot.
    private let onSnapshotChange: (StreamSnapshot) -> Void

    /// Unique app name so the SDK never clashes with the host app's
    /// default FirebaseApp (or another ArgusManager instance).
    private let appName: String

    init(
        configuration: ArgusConfiguration,
        logger: Logger,
        onSnapshotChange: @escaping (StreamSnapshot) -> Void
    ) {
        self.configuration = configuration
        self.logger = logger
        self.onSnapshotChange = onSnapshotChange
        // Disambiguate per (product/env/tenant) so multiple managers in one
        // process get distinct FirebaseApps.
        let suffix = "\(configuration.environment)-\(configuration.tenantId)"
        self.appName = "ArgusSDK-\(suffix)"
    }

    // MARK: - Lifecycle

    /// Bootstrap the stream: token → FirebaseApp → sign-in → listeners.
    ///
    /// Throws if the token request or sign-in fails, so the caller can fall
    /// back to the HTTP poll channel.
    func start() async throws {
        let token = try await fetchStreamToken()
        self.token = token

        // Self-configure from the server-returned Firebase config unless the
        // consumer supplied an explicit override (e.g. the emulator preset).
        let firebaseConfig = configuration.firebaseConfig ?? token.firebaseConfig
        let (firestore, auth) = configureFirebase(firebaseConfig)
        self.firestore = firestore
        self.auth = auth

        try await signIn(auth: auth, customToken: token.token)
        attachListeners(firestore: firestore, token: token)
        logger.info("ArgusSDK stream established for product \(token.productId) env \(token.env)")
    }

    /// Detach all listeners and sign out. Idempotent.
    func stop() {
        flagsQueryListener?.remove()
        conditionsListener?.remove()
        envListeners.values.forEach { $0.remove() }
        tenantListeners.values.forEach { $0.remove() }
        flagsQueryListener = nil
        conditionsListener = nil
        envListeners.removeAll()
        tenantListeners.removeAll()

        if let auth { try? auth.signOut() }
    }

    deinit {
        stop()
    }

    // MARK: - Token Bootstrap

    private func fetchStreamToken() async throws -> StreamToken {
        guard var components = URLComponents(string: configuration.baseURL) else {
            throw StreamClientError.invalidBaseURL
        }
        components.path += "/issueStreamToken"
        // #221: tell the server we're iOS so it returns the iOS Firebase
        // config (a web appId is rejected by the native SDK with
        // "invalid GOOGLE_APP_ID"). Preserves any existing query items.
        components.queryItems = (components.queryItems ?? []) +
            [URLQueryItem(name: "platform", value: "ios")]
        guard let url = components.url else {
            throw StreamClientError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw StreamClientError.tokenRequestFailed(status: status)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String,
              let customerId = json["customerId"] as? String,
              let productId = json["productId"] as? String,
              let env = json["env"] as? String else {
            throw StreamClientError.malformedTokenResponse
        }
        let tenantId = json["tenantId"] as? String

        guard let firebaseConfig = Self.parseFirebaseConfig(json["firebaseConfig"]) else {
            throw StreamClientError.malformedTokenResponse
        }

        return StreamToken(
            token: token,
            customerId: customerId,
            productId: productId,
            env: env,
            tenantId: tenantId,
            firebaseConfig: firebaseConfig
        )
    }

    /// Parse the `firebaseConfig` object from the `issueStreamToken` response
    /// into a `FirebaseConfig`. Requires `projectId`, `apiKey`, and `appId`;
    /// returns `nil` if any are missing (treated as a malformed response so
    /// the SDK demotes to the HTTP fallback). The emulator host/ports fall
    /// back to `ArgusConfiguration`'s defaults (127.0.0.1 / 9099 / 8080).
    static func parseFirebaseConfig(_ raw: Any?) -> FirebaseConfig? {
        guard let dict = raw as? [String: Any],
              let projectId = dict["projectId"] as? String,
              let apiKey = dict["apiKey"] as? String,
              let appId = dict["appId"] as? String else {
            return nil
        }

        return FirebaseConfig(
            projectId: projectId,
            apiKey: apiKey,
            appId: appId,
            authDomain: dict["authDomain"] as? String,
            storageBucket: dict["storageBucket"] as? String,
            messagingSenderId: dict["messagingSenderId"] as? String,
            useEmulator: (dict["useEmulator"] as? Bool) ?? false
        )
    }

    // MARK: - Firebase Setup

    /// Stand up a private named FirebaseApp and return scoped Auth +
    /// Firestore instances. Reuses the named app if it already exists.
    ///
    /// `fb` is the resolved config: the consumer's explicit override when
    /// set, otherwise the config the server returned from `issueStreamToken`.
    private func configureFirebase(_ fb: FirebaseConfig) -> (Firestore, Auth) {
        let app: FirebaseApp
        if let existing = FirebaseApp.app(name: appName) {
            app = existing
        } else {
            let options = FirebaseOptions(
                googleAppID: fb.appId,
                gcmSenderID: fb.messagingSenderId ?? "" // not used by Auth/Firestore on the client
            )
            options.apiKey = fb.apiKey
            options.projectID = fb.projectId
            // `authDomain` is a Firebase JS-SDK concept; the iOS
            // `FirebaseOptions` has no such field, and Auth + Firestore on
            // the client do not need it, so it is parsed and retained on
            // `FirebaseConfig` for completeness but not applied here.
            if let storageBucket = fb.storageBucket {
                options.storageBucket = storageBucket
            }
            FirebaseApp.configure(name: appName, options: options)
            app = FirebaseApp.app(name: appName)!
        }
        self.firebaseApp = app

        let auth = Auth.auth(app: app)
        let firestore = Firestore.firestore(app: app)

        if fb.useEmulator {
            auth.useEmulator(withHost: fb.emulatorHost, port: fb.authEmulatorPort)
            let settings = firestore.settings
            settings.host = "\(fb.emulatorHost):\(fb.firestoreEmulatorPort)"
            settings.isSSLEnabled = false
            // Memory cache for the emulator — no on-disk persistence between
            // local test runs.
            settings.cacheSettings = MemoryCacheSettings()
            firestore.settings = settings
        }

        return (firestore, auth)
    }

    private func signIn(auth: Auth, customToken: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            auth.signIn(withCustomToken: customToken) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - Listeners

    private func attachListeners(firestore: Firestore, token: StreamToken) {
        // ── Flags query: this Product's flags ───────────────────────
        let flagsQuery = firestore.collection("flags")
            .whereField("customerId", isEqualTo: token.customerId)
            .whereField("productId", isEqualTo: token.productId)

        flagsQueryListener = flagsQuery.addSnapshotListener { [weak self] snapshot, error in
            guard let self else { return }
            if let error {
                self.logger.error("ArgusSDK flags listener error: \(error.localizedDescription)")
                return
            }
            guard let snapshot else { return }
            self.handleFlagsSnapshot(snapshot, firestore: firestore, token: token)
        }

        // ── Conditions query: this Product's conditions ─────────────
        let conditionsQuery = firestore.collection("conditions")
            .whereField("customerId", isEqualTo: token.customerId)
            .whereField("productId", isEqualTo: token.productId)

        conditionsListener = conditionsQuery.addSnapshotListener { [weak self] snapshot, error in
            guard let self else { return }
            if let error {
                self.logger.error("ArgusSDK conditions listener error: \(error.localizedDescription)")
                return
            }
            guard let snapshot else { return }
            var byName: [String: [String: Any]] = [:]
            for doc in snapshot.documents {
                let data = doc.data()
                if let name = data["name"] as? String {
                    byName[name] = data
                }
            }
            self.stateLock.lock()
            self.conditionsByName = byName
            self.stateLock.unlock()
            self.emitSnapshot()
        }
    }

    /// Process a flags-collection snapshot: refresh the cached flag docs and
    /// reconcile the per-flag env (and tenant) listeners so we have a live
    /// listener for exactly the current set of flags.
    private func handleFlagsSnapshot(
        _ snapshot: QuerySnapshot,
        firestore: Firestore,
        token: StreamToken
    ) {
        var newFlagDocs: [String: [String: Any]] = [:]
        for doc in snapshot.documents {
            newFlagDocs[doc.documentID] = doc.data()
        }

        stateLock.lock()
        flagDocs = newFlagDocs
        let knownEnvFlagIds = Set(envListeners.keys)
        stateLock.unlock()

        let currentFlagIds = Set(newFlagDocs.keys)

        // Detach listeners for flags that no longer exist.
        for staleId in knownEnvFlagIds.subtracting(currentFlagIds) {
            envListeners[staleId]?.remove()
            envListeners[staleId] = nil
            tenantListeners[staleId]?.remove()
            tenantListeners[staleId] = nil
            stateLock.lock()
            envDocs[staleId] = nil
            tenantDocs[staleId] = nil
            stateLock.unlock()
        }

        // Attach env (and tenant) listeners for newly-seen flags.
        for flagId in currentFlagIds.subtracting(knownEnvFlagIds) {
            attachEnvListener(flagId: flagId, firestore: firestore, token: token)
        }

        emitSnapshot()
    }

    /// Attach a listener on `/flags/{id}/environments/{env}` and, when the
    /// apiKey is tenant-scoped, on the tenant override doc beneath it.
    private func attachEnvListener(
        flagId: String,
        firestore: Firestore,
        token: StreamToken
    ) {
        let envRef = firestore.collection("flags").document(flagId)
            .collection("environments").document(token.env)

        envListeners[flagId] = envRef.addSnapshotListener { [weak self] snapshot, error in
            guard let self else { return }
            if let error {
                self.logger.error("ArgusSDK env listener error for \(flagId): \(error.localizedDescription)")
                return
            }
            self.stateLock.lock()
            self.envDocs[flagId] = snapshot?.data()
            self.stateLock.unlock()
            self.emitSnapshot()
        }

        guard let tenantId = token.tenantId else { return }

        let tenantRef = envRef.collection("tenants").document(tenantId)
        tenantListeners[flagId] = tenantRef.addSnapshotListener { [weak self] snapshot, error in
            guard let self else { return }
            if let error {
                self.logger.error("ArgusSDK tenant listener error for \(flagId): \(error.localizedDescription)")
                return
            }
            self.stateLock.lock()
            // Store `nil` when the doc does not exist (no override).
            self.tenantDocs[flagId] = (snapshot?.exists == true) ? snapshot?.data() : nil
            self.stateLock.unlock()
            self.emitSnapshot()
        }
    }

    /// Build a consolidated snapshot under the lock and hand it to the owner.
    private func emitSnapshot() {
        stateLock.lock()
        let snapshot = StreamSnapshot(
            flagDocs: flagDocs,
            envDocs: envDocs,
            tenantDocs: tenantDocs,
            conditionsByName: conditionsByName
        )
        stateLock.unlock()
        onSnapshotChange(snapshot)
    }
}
