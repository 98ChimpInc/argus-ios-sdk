# Argus iOS SDK

Drop-in feature-flag client for iOS apps. Conforms to the `RemoteFlags` protocol, fetches resolved flag values from the Argus HTTP endpoint, and caches them locally for synchronous access.

## Requirements

- iOS 15.0+
- Swift 5.9+
- One Argus apiKey per environment, per Product (Argus dashboard → **Settings → API keys**)

> **Argus apiKeys are scoped per Product *and* per environment.** Each Product in a workspace has **three** apiKeys — one for `dev`, one for `staging`, one for `prod` — shaped like `argus_dev_…`, `argus_staging_…`, `argus_prod_…`. The environment is baked into the key prefix, and the Argus server reads it directly from the key. You should use a different key per build target (DEBUG → dev key, TestFlight → staging key, App Store → prod key) so each build resolves the flags for its matching environment.
>
> A workspace with multiple Products has multiple apiKey sets — three per Product. If your studio ships both a web app and a mobile app as separate Argus Products, each app has its own three-key set and is configured with its own `ArgusManager` instance.
>
> **Backward compatibility.** Pre-M-2 unprefixed keys (the original `argus_<48-hex>` shape, with no `dev_`/`staging_`/`prod_` segment) continue to resolve as `prod` — no code change needed if you have already shipped against an older key. New integrations should use the env-prefixed keys.

No Firebase dependency — the SDK authenticates with your Argus apiKey.

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
// (argus_<env>_...), so resolveFlags always returns the right
// environment's values. The SDK's `environment:` parameter is
// optional and only affects local display (see "Environment
// auto-detection" below).

// Synchronous reads from cache
let enabled = argus.bool(forKey: "new_checkout_flow")
let version = argus.string(forKey: "app_version")
```

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

- **ArgusManager** ... `RemoteFlags` conformance, HTTP fetch, thread-safe cache
- **ArgusConfiguration** ... Configuration struct
- **FNV1a** ... Deterministic FNV-1a hash for rollout bucketing (matches JS reference exactly)
- **DefaultsLoader** ... Loads offline defaults from `RemoteConfigDefaults.plist`

## Bootstrap Toggle

The SDK is activated via a Firebase Remote Config flag (`argus_enabled`). See the full spec for integration details.
