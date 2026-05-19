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
    tenantId: "acme_ca",
    environment: "prod"
)

// Synchronous reads from cache
let enabled = argus.bool(forKey: "new_checkout_flow")
let version = argus.string(forKey: "app_version")
```

## Architecture

- **ArgusManager** ... `RemoteFlags` conformance, HTTP fetch, thread-safe cache
- **ArgusConfiguration** ... Configuration struct
- **FNV1a** ... Deterministic FNV-1a hash for rollout bucketing (matches JS reference exactly)
- **DefaultsLoader** ... Loads offline defaults from `RemoteConfigDefaults.plist`

## Bootstrap Toggle

The SDK is activated via a Firebase Remote Config flag (`argus_enabled`). See the full spec for integration details.
