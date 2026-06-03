# Argus iOS SDK

Drop-in feature-flag client for iOS apps. Conforms to the `RemoteFlags` protocol and exposes resolved flag values from a local cache for synchronous access.

Flag changes are delivered to the app **in real time** over Firestore client listeners (`addSnapshotListener`). On start the SDK trades its Argus apiKey for a short-lived, scoped Firebase identity (via the `issueStreamToken` endpoint), signs in, and listens to its Product's flag / environment / tenant / condition documents. When an operator flips a flag in the Argus dashboard, the new value pushes to the device in roughly a second, and `configUpdatedPublisher` emits the changed keys. Per-user and per-version targeting (rollout bucketing + version conditions) is resolved **on-device**, mirroring the server's `resolveFlags` algorithm exactly.

The `resolveFlags` HTTP endpoint and the poll timer are still present, but **demoted to a cold-start / fallback role**: the SDK does one HTTP fetch to paint the cache for the very first frame before the live listener delivers, and the poll loop keeps the app updating if Firebase init or sign-in ever fails. Once the live stream delivers its first snapshot it becomes authoritative, and late HTTP responses are dropped.

## Requirements

- iOS 15.0+
- Swift 5.9+
- One Argus apiKey per environment, per Product (Argus dashboard → **Settings → API keys**)
- The [Firebase iOS SDK](https://github.com/firebase/firebase-ios-sdk) (`FirebaseAuth` + `FirebaseFirestore`), pulled in transitively as a SwiftPM dependency — you do **not** set up your own Firebase project

> **Argus apiKeys are scoped per Product *and* per environment.** Each Product in a workspace has **three** apiKeys — one for `dev`, one for `staging`, one for `prod` — shaped like `argus_dev_…`, `argus_staging_…`, `argus_prod_…`. The environment is baked into the key prefix, and the Argus server reads it directly from the key. You should use a different key per build target (DEBUG → dev key, TestFlight → staging key, App Store → prod key) so each build resolves the flags for its matching environment.
>
> A workspace with multiple Products has multiple apiKey sets — three per Product. If your studio ships both a web app and a mobile app as separate Argus Products, each app has its own three-key set and is configured with its own `ArgusManager` instance.
>
> **Backward compatibility.** Pre-M-2 unprefixed keys (the original `argus_<48-hex>` shape, with no `dev_`/`staging_`/`prod_` segment) continue to resolve as `prod` — no code change needed if you have already shipped against an older key. New integrations should use the env-prefixed keys.

**You provide only the Argus apiKey (and the endpoint base URL).** The SDK authenticates with your Argus apiKey, and the `issueStreamToken` endpoint hands back the Firebase project config alongside the scoped custom token — so the SDK **self-configures** the real-time channel from the server response. It stands up a **private, named `FirebaseApp`** under the hood so it never clashes with your host app's default Firebase configuration. There is no Firebase config to set up, and no `GoogleService-Info.plist` to add for Argus. (Pointing at the local Firebase Emulator Suite for development is the one case where you pass an explicit override — see [Local development](#local-development-against-the-firebase-emulator) below.)

## Installation

Add the package to your `Package.swift` or via Xcode's package manager:

```swift
.package(url: "https://github.com/98ChimpInc/argus-ios-sdk.git", from: "1.0.0")
```

## Usage

### Single-product app

Use the env-matched apiKey for each build target. The simplest pattern is a build-config gate that picks the right key at compile time:

```swift
import ArgusSDK

#if DEBUG
let argusApiKey = "argus_dev_<48-hex>"
#elseif TESTFLIGHT
let argusApiKey = "argus_staging_<48-hex>"
#else
let argusApiKey = "argus_prod_<48-hex>"
#endif

let argus = ArgusManager()
argus.configure(
    apiKey: argusApiKey,
    baseURL: "https://us-central1-argus-app-f0ff3.cloudfunctions.net",
    tenantId: "acme_ca"
)
// The Argus server reads the environment from the key prefix
// (argus_<env>_...), so the real-time channel binds to the right
// environment's docs (and the resolveFlags fallback returns the
// right environment's values). The SDK's `environment:` parameter
// is optional and only affects local display (see "Environment
// auto-detection" below).

// Synchronous reads from cache. Values stay current automatically as
// flags change in the Argus dashboard — observe configUpdatedPublisher
// to react to live updates (see "Real-time updates" below).
let enabled = argus.bool(forKey: "new_checkout_flow")
let version = argus.string(forKey: "app_version")
```

### Real-time updates

Subscribe to `configUpdatedPublisher` to react when flag values change live. It emits `nil` on the first full refresh and a `Set<String>` of changed flag names on subsequent updates:

```swift
import Combine

var cancellables = Set<AnyCancellable>()

argus.configUpdatedPublisher
    .receive(on: DispatchQueue.main)
    .sink { changedKeys in
        // changedKeys == nil  → initial / full refresh
        // changedKeys == {…}  → these flags changed
        refreshUI()
    }
    .store(in: &cancellables)
```

Call `argus.stop()` to detach the listeners and stop the fallback poll timer (for example on sign-out); they are also torn down automatically when the `ArgusManager` is deallocated.

> If your project does not define a `TESTFLIGHT` compile flag, you can swap the middle branch for a runtime check on the App Store receipt URL (the same idiom the SDK uses for environment auto-detection). The key just needs to be the staging one whenever the build is heading to TestFlight.

## Environment auto-detection

> **Heads up.** As of Argus M-2, the **server reads the environment from the apiKey prefix** (`argus_dev_…` → dev, `argus_staging_…` → staging, `argus_prod_…` → prod). The SDK-side environment value described below is a *display-layer* concern — it surfaces in debug overlays, logs, and `ArgusConfiguration.autoDetectedEnvironment` for your own use. It does **not** influence which environment's flags get resolved. **The key wins.** If a DEBUG build is configured with a `argus_prod_…` key, the SDK's `autoDetectedEnvironment` reports `"dev"` but the server still resolves prod flags.
>
> **Recommended.** Use env-matched keys in each build target so the SDK-side display lines up with what the server actually resolves. The build-config pattern in the [Single-product app](#single-product-app) example does this.

`environment:` is optional on `configure(...)`. If you omit it, the SDK resolves it from the build context:

| Build context | Detected environment |
|---|---|
| `#if DEBUG` (Xcode Run, simulator, archive with DEBUG defined) | `"dev"` |
| TestFlight (App Store receipt URL ends in `sandboxReceipt`) | `"staging"` |
| App Store release | `"prod"` |

The receipt-URL check is the standard idiom for distinguishing TestFlight from production builds. It uses no private API and works on first launch regardless of purchase history.

Pass an explicit `environment` argument if you want the display value to differ from the auto-detected one (for example, a DEBUG build that you want logs to label as `"staging"`):

```swift
argus.configure(
    apiKey: "argus_staging_<48-hex>",
    baseURL: "https://us-central1-argus-app-f0ff3.cloudfunctions.net",
    tenantId: "acme_ca",
    environment: "staging" // display-only; server still reads env from the apiKey prefix
)
```

You can read the auto-detected value directly via `ArgusConfiguration.autoDetectedEnvironment` if you need to log it or display it in a debug overlay.

## apiKeys, multi-product workspaces

### Where do apiKeys come from?

Open the Argus dashboard → **Settings → API keys**. Each Product is rendered as a 3-row table — one row per environment — with separate `dev` / `staging` / `prod` keys to copy. Each Product in a workspace has its own disjoint set of three keys.

The shape of each key is:

```
argus_<env>_<48-hex>
```

where `<env>` is `dev`, `staging`, or `prod`. The server reads the environment directly from this prefix, which is why the right key in the right build target is the whole story.

### Multi-product app

If your workspace has multiple Argus Products (for example, a web app and a mobile app under the same Customer), create one `ArgusManager` instance per Product. Each manager gets the **env-matched key for the build target** of its Product:

```swift
import ArgusSDK

#if DEBUG
let webAppKey    = "argus_dev_<web-app-48-hex>"
let mobileAppKey = "argus_dev_<mobile-app-48-hex>"
#elseif TESTFLIGHT
let webAppKey    = "argus_staging_<web-app-48-hex>"
let mobileAppKey = "argus_staging_<mobile-app-48-hex>"
#else
let webAppKey    = "argus_prod_<web-app-48-hex>"
let mobileAppKey = "argus_prod_<mobile-app-48-hex>"
#endif

let webAppFlags = ArgusManager()
webAppFlags.configure(
    apiKey: webAppKey,
    baseURL: "https://us-central1-argus-app-f0ff3.cloudfunctions.net",
    tenantId: "acme_ca"
)

let mobileAppFlags = ArgusManager()
mobileAppFlags.configure(
    apiKey: mobileAppKey,
    baseURL: "https://us-central1-argus-app-f0ff3.cloudfunctions.net",
    tenantId: "acme_ca"
)

// Read flags from the matching Product's cache
let newCheckout = webAppFlags.bool(forKey: "new_checkout_flow")
let onboarding = mobileAppFlags.bool(forKey: "new_onboarding_flow")
```

Each `ArgusManager` maintains its own cache and only resolves flags belonging to the Product *and* environment that its apiKey is bound to.

## Architecture

- **ArgusManager** ... `RemoteFlags` conformance, thread-safe cache, orchestrates the real-time stream (primary) and the HTTP poll (fallback)
- **StreamClient** ... owns all Firebase interaction: `issueStreamToken` bootstrap, the private named `FirebaseApp`, custom-token sign-in, and the Firestore snapshot listeners
- **FlagResolver** ... on-device resolution engine, a 1:1 mirror of the server `resolveFlags` algorithm (archived/draft skipping, tenant overrides, priority-sorted version conditions, rollout bucketing)
- **ArgusConfiguration** ... configuration struct. `firebaseConfig` is an **optional override** that defaults to `nil` — when unset, the SDK self-configures from the `firebaseConfig` returned by `issueStreamToken`; an emulator preset (`.emulator()`) is provided to force the local Firebase Emulator Suite for testing
- **FNV1a** ... deterministic FNV-1a hash for rollout bucketing (matches the JS reference exactly)
- **DefaultsLoader** ... loads offline defaults from `RemoteConfigDefaults.plist`

## Local development against the Firebase Emulator

For local testing (and the convergence harness), point Auth + Firestore at the Firebase Emulator Suite by passing an emulator `FirebaseConfig` override. In normal use `firebaseConfig` is left unset and the SDK self-configures from the server response; to force the emulator, build the `ArgusConfiguration` yourself and set `firebaseConfig: .emulator()` (the override always wins over the server-returned config):

```swift
let config = ArgusConfiguration(
    apiKey: "argus_dev_<48-hex>",
    baseURL: "http://127.0.0.1:5001/demo-argus/us-central1",
    tenantId: "acme_ca",
    environment: "dev",
    firebaseConfig: .emulator() // demo-argus, 127.0.0.1, Auth 9099 / Firestore 8080
)
```

The emulator preset disables on-disk persistence and SSL so it talks to the local emulators cleanly. In production the SDK uses Firestore's default persistent cache, so a cold launch renders the last-known values instantly.
