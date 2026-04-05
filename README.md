# Argus iOS SDK

Drop-in replacement for `RemoteConfigManager` in the SmartHome+ iOS app. Conforms to the `RemoteFlags` protocol, fetches resolved flag values from the Argus HTTP endpoint, and caches them locally for synchronous access.

## Requirements

- iOS 15.0+
- Swift 5.9+
- Firebase Auth (for authenticated requests)

## Installation

Add the package to your `Package.swift` or via Xcode's package manager:

```swift
.package(url: "https://github.com/nickshahin/telus-smarthome-argus-ios-sdk.git", from: "1.0.0")
```

## Usage

```swift
import ArgusSDK

let argus = ArgusManager()
argus.configure(
    baseURL: "https://us-central1-argus-prod.cloudfunctions.net",
    tenantId: "telus_ca",
    environment: "prod"
)

// Synchronous reads from cache
let enabled = argus.bool(forKey: "enable_sweepr")
let version = argus.string(forKey: "app_version")
```

## Architecture

- **ArgusManager** ... `RemoteFlags` conformance, HTTP fetch, thread-safe cache
- **ArgusConfiguration** ... Configuration struct
- **FNV1a** ... Deterministic FNV-1a hash for rollout bucketing (matches JS reference exactly)
- **DefaultsLoader** ... Loads offline defaults from `RemoteConfigDefaults.plist`

## Bootstrap Toggle

The SDK is activated via a Firebase Remote Config flag (`argus_enabled`). See the full spec for integration details.
