# Argus iOS SDK

Drop-in feature-flag client for iOS apps. Conforms to the `RemoteFlags` protocol, fetches resolved flag values from the Argus HTTP endpoint, and caches them locally for synchronous access.

## Requirements

- iOS 15.0+
- Swift 5.9+
- An Argus apiKey for each Product you want to read flags for (Argus dashboard → Settings → Products → (Product) → apiKey)

> **Argus apiKeys are scoped per Product, not per Customer.** A workspace with multiple Products has multiple apiKeys — one per Product. If your studio ships both a web app and a mobile app as separate Argus Products, each app gets its own apiKey and is configured with its own `ArgusManager` instance.

No Firebase dependency — the SDK authenticates with your Argus apiKey.

## Installation

Add the package to your `Package.swift` or via Xcode's package manager:

```swift
.package(url: "https://github.com/98ChimpInc/argus-ios-sdk.git", from: "1.0.0")
```

## Usage

### Single-product app

```swift
import ArgusSDK

let argus = ArgusManager()
argus.configure(
    apiKey: "argus_<your-key>",
    baseURL: "https://us-central1-argus-app-f0ff3.cloudfunctions.net",
    tenantId: "acme_ca"
)
// environment auto-resolves from build context ... see "Environment
// auto-detection" below. Pass `environment: "..."` if you ship a
// non-standard mapping.

// Synchronous reads from cache
let enabled = argus.bool(forKey: "new_checkout_flow")
let version = argus.string(forKey: "app_version")
```

## Environment auto-detection

`environment:` is optional. If you omit it, the SDK resolves it from
the build context:

| Build context | Detected environment |
|---|---|
| `#if DEBUG` (Xcode Run, simulator, archive with DEBUG defined) | `"dev"` |
| TestFlight (App Store receipt URL ends in `sandboxReceipt`) | `"staging"` |
| App Store release | `"prod"` |

The receipt-URL check is the standard idiom for distinguishing
TestFlight from production builds. It uses no private API and works on
first launch regardless of purchase history.

Pass an explicit `environment` argument if your team uses a
non-standard mapping (for example, a DEBUG build that talks to a
staging backend, or a TestFlight build that resolves prod flags):

```swift
argus.configure(
    apiKey: "argus_<your-key>",
    baseURL: "https://us-central1-argus-app-f0ff3.cloudfunctions.net",
    tenantId: "acme_ca",
    environment: "staging" // overrides auto-detection
)
```

You can read the auto-detected value directly via
`ArgusConfiguration.autoDetectedEnvironment` if you need to log it or
display it in a debug overlay.

## apiKeys, multi-product workspaces

### Where do apiKeys come from?

Open the Argus dashboard → **Settings → API keys**, pick the Product
you want, and copy its `apiKey`. Each Product in a workspace has its
own disjoint apiKey.

### Multi-product app

If your workspace has multiple Argus Products (for example, a web app
and a mobile app under the same Customer), create one `ArgusManager`
instance per Product and configure each with the matching apiKey:

```swift
import ArgusSDK

let webAppFlags = ArgusManager()
webAppFlags.configure(
    apiKey: "argus_<your-web-app-product-key>",
    baseURL: "https://us-central1-argus-app-f0ff3.cloudfunctions.net",
    tenantId: "acme_ca"
    // environment auto-detects per the section above
)

let mobileAppFlags = ArgusManager()
mobileAppFlags.configure(
    apiKey: "argus_<your-mobile-app-product-key>",
    baseURL: "https://us-central1-argus-app-f0ff3.cloudfunctions.net",
    tenantId: "acme_ca"
)

// Read flags from the matching Product's cache
let newCheckout = webAppFlags.bool(forKey: "new_checkout_flow")
let onboarding = mobileAppFlags.bool(forKey: "new_onboarding_flow")
```

Each `ArgusManager` maintains its own cache and only resolves flags
belonging to the Product that owns its apiKey.

## Architecture

- **ArgusManager** ... `RemoteFlags` conformance, HTTP fetch, thread-safe cache
- **ArgusConfiguration** ... Configuration struct
- **FNV1a** ... Deterministic FNV-1a hash for rollout bucketing (matches JS reference exactly)
- **DefaultsLoader** ... Loads offline defaults from `RemoteConfigDefaults.plist`

## Bootstrap Toggle

The SDK is activated via a Firebase Remote Config flag (`argus_enabled`). See the full spec for integration details.
