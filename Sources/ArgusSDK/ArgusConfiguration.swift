//
//  ArgusConfiguration.swift
//  ArgusSDK
//
//  Configuration struct holding all parameters needed to connect to the
//  Argus resolveFlags endpoint.
//

import Foundation

/// Firebase project parameters the SDK needs to stand up its own named
/// `FirebaseApp` for the real-time listener channel.
///
/// The consumer normally provides nothing here — `issueStreamToken` returns
/// the Firebase project values alongside the scoped custom token, and the
/// SDK self-configures from that server-returned config. So a consumer only
/// ever hands the SDK an Argus apiKey (+ the endpoint base URL).
///
/// This struct is still exposed as an **optional override** on
/// `ArgusConfiguration`: pass one only when you need to point Auth +
/// Firestore at the Firebase Emulator Suite (local development / the
/// convergence harness) or otherwise pin a specific project. When the
/// override is `nil`, the server-returned config wins.
public struct FirebaseConfig: Sendable {

    /// Firebase project ID (`GoogleService-Info.plist` → PROJECT_ID).
    public let projectId: String

    /// Firebase API key (`GoogleService-Info.plist` → API_KEY). This is the
    /// public Firebase Web/iOS API key, NOT the Argus apiKey.
    public let apiKey: String

    /// Firebase iOS app ID (`GoogleService-Info.plist` → GOOGLE_APP_ID).
    public let appId: String

    /// Firebase Auth domain (e.g. `argus-app-f0ff3.firebaseapp.com`).
    /// Optional — Auth + Firestore on the client function without it, but
    /// it is populated on `FirebaseOptions` when the server supplies it.
    public let authDomain: String?

    /// Firebase Cloud Storage bucket. Optional — unused by Auth/Firestore,
    /// carried through for completeness when the server supplies it.
    public let storageBucket: String?

    /// Firebase Cloud Messaging sender ID. Optional — unused by
    /// Auth/Firestore on this channel, carried through when supplied.
    public let messagingSenderId: String?

    /// When `true`, Auth and Firestore are pointed at the local Firebase
    /// Emulator Suite instead of production. Used by local development and
    /// the convergence harness.
    public let useEmulator: Bool

    /// Emulator host (typically `127.0.0.1` — the emulators bind to IPv4).
    public let emulatorHost: String

    /// Auth emulator port (Firebase default: 9099).
    public let authEmulatorPort: Int

    /// Firestore emulator port (Firebase default: 8080).
    public let firestoreEmulatorPort: Int

    public init(
        projectId: String,
        apiKey: String,
        appId: String,
        authDomain: String? = nil,
        storageBucket: String? = nil,
        messagingSenderId: String? = nil,
        useEmulator: Bool = false,
        emulatorHost: String = "127.0.0.1",
        authEmulatorPort: Int = 9099,
        firestoreEmulatorPort: Int = 8080
    ) {
        self.projectId = projectId
        self.apiKey = apiKey
        self.appId = appId
        self.authDomain = authDomain
        self.storageBucket = storageBucket
        self.messagingSenderId = messagingSenderId
        self.useEmulator = useEmulator
        self.emulatorHost = emulatorHost
        self.authEmulatorPort = authEmulatorPort
        self.firestoreEmulatorPort = firestoreEmulatorPort
    }

    /// Convenience override pointing at the local Firebase Emulator Suite,
    /// using the harness project ID `demo-argus`. Pass this as
    /// `ArgusConfiguration.firebaseConfig` to force the emulator path; when
    /// it is omitted, the server-returned config is used instead (and the
    /// server itself decides `useEmulator` via the response).
    public static func emulator(
        projectId: String = "demo-argus",
        host: String = "127.0.0.1",
        authPort: Int = 9099,
        firestorePort: Int = 8080
    ) -> FirebaseConfig {
        FirebaseConfig(
            projectId: projectId,
            // The emulator does not validate the Firebase apiKey/appId, but
            // FirebaseApp requires non-empty values to configure.
            apiKey: "demo-emulator-api-key",
            appId: "1:000000000000:ios:demoemulator",
            useEmulator: true,
            emulatorHost: host,
            authEmulatorPort: authPort,
            firestoreEmulatorPort: firestorePort
        )
    }
}

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
    ///
    /// With real-time push as the primary channel, the poll loop is a
    /// fallback that backstops a dropped or never-established listener.
    public let pollInterval: TimeInterval

    /// Optional Firebase override for the real-time listener channel.
    ///
    /// Leave this `nil` (the default) for normal use — the SDK self-configures
    /// from the `firebaseConfig` returned by `issueStreamToken`, so the
    /// consumer supplies only the Argus apiKey (+ base URL). Set it only to
    /// pin a specific project or to force the Firebase Emulator Suite for
    /// local development (`firebaseConfig: .emulator()`). When non-`nil`, this
    /// override takes precedence over the server-returned config.
    public let firebaseConfig: FirebaseConfig?

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
        pollInterval: TimeInterval = 300,
        firebaseConfig: FirebaseConfig? = nil
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.tenantId = tenantId
        self.environment = environment
        self.userId = userId
        self.pollInterval = pollInterval
        self.firebaseConfig = firebaseConfig
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
        pollInterval: TimeInterval = 300,
        firebaseConfig: FirebaseConfig? = nil
    ) {
        self.init(
            apiKey: apiKey,
            baseURL: baseURL,
            tenantId: tenantId,
            environment: ArgusConfiguration.autoDetectedEnvironment,
            userId: userId,
            pollInterval: pollInterval,
            firebaseConfig: firebaseConfig
        )
    }
}
