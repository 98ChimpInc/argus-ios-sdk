# Argus iOS SDK

Drop-in feature-flag client for iOS apps. Conforms to the `RemoteFlags` protocol, fetches resolved flag values from the Argus HTTP endpoint, and caches them locally for synchronous access.

## Requirements

- iOS 15.0+
- Swift 5.9+
- An Argus API key (Argus dashboard → Settings → API key)

No Firebase dependency — the SDK authenticates with your Argus API key.

## Installation

Add the package to your `Package.swift` or via Xcode's package manager:

```swift
.package(url: "https://github.com/98ChimpInc/argus-ios-sdk.git", from: "1.0.0")
```

## Usage

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

## Architecture

- **ArgusManager** ... `RemoteFlags` conformance, HTTP fetch, thread-safe cache
- **ArgusConfiguration** ... Configuration struct
- **FNV1a** ... Deterministic FNV-1a hash for rollout bucketing (matches JS reference exactly)
- **DefaultsLoader** ... Loads offline defaults from `RemoteConfigDefaults.plist`

## Bootstrap Toggle

The SDK is activated via a Firebase Remote Config flag (`argus_enabled`). See the full spec for integration details.
