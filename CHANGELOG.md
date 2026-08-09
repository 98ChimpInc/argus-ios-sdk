# Changelog

All notable changes to the Argus iOS SDK are documented in this file.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project adheres to [Semantic Versioning](https://semver.org/).

## [1.0.3] - 2026-06-09

### Changed

- Widened `firebase-ios-sdk` SPM dependency range to support Firebase 12.x (previously capped at 11.x). Fixes SPM resolution conflicts for host apps already on Firebase 12.

## [1.0.2] - 2026-06-07

### Fixed

- Firebase self-configuration now runs on the main actor and rejects non-iOS `appID` values. Prevents a main-thread assertion crash on apps that initialise Argus before `FirebaseApp.configure()`.

## [1.0.1] - 2026-05-29

### Fixed

- `issueStreamToken` now sends `platform=ios` so the server returns the correct Firebase config for the iOS app. Without this, the SDK received the Android config and the Firestore listener silently failed to connect.

## [1.0.0] - 2026-05-24

### Added

- API-key authentication (replaces prior auth model).
- Auto-detect environment (dev / staging / prod) from the host app's build context.
- Real-time push via Firestore snapshot listeners — flags update live without polling.
- Self-configuring Firebase: the SDK initialises its own `FirebaseApp` from the server response, so the host app's Firebase project is never touched.
- Per-product, per-environment API key support (`argus_<env>_<48-hex>`).

### Known issues

- **v1.0.0 can crash on launch** if the host app calls `FirebaseApp.configure()` after the SDK's self-configuration races on a background thread. Fixed in v1.0.1+. **Pin 1.0.1 or later.**

[1.0.3]: https://github.com/98ChimpInc/argus-ios-sdk/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/98ChimpInc/argus-ios-sdk/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/98ChimpInc/argus-ios-sdk/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/98ChimpInc/argus-ios-sdk/releases/tag/v1.0.0
