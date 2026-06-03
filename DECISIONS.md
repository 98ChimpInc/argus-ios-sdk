# Decisions Log

## 2026-06-02 — Real-time push implementation notes

**Decision**: Implemented the canonical real-time-push architecture (below) in
the SDK. Key implementation choices:

- **`FlagResolver` is a pure, dependency-free engine.** It takes plain
  `[String: Any]` dictionaries (the shape Firestore hands back from
  `snapshot.data()`) and mirrors the server `resolveFlags` algorithm in
  `functions/index.js` exactly — archived/draft skipping, tenant-override
  priority, priority-sorted version conditions, and FNV-1a rollout
  bucketing. Keeping it free of Firebase types makes resolution fully
  unit-testable without a live backend (`FlagResolverTests`).
- **`StreamClient` owns all Firebase interaction** behind a private named
  `FirebaseApp` (`ArgusSDK-<env>-<tenant>`) so the SDK never clashes with the
  host app's default `FirebaseApp`. `ArgusManager` never imports Firebase.
- **`platformAppId` is passed as `nil` to the on-device resolver.** The
  server fills `platformAppId` from the `config/platform` doc, which the
  scoped stream identity is not authorised to read. Per the shared
  `evaluateCondition` logic, the appId clause only filters when BOTH the
  condition's `appId` and the context's `platformAppId` are present, so
  `nil` skips that clause exactly as the server does when it cannot resolve
  a platform appId — no divergence, just a clause the client can't tighten.
- **Stream beats poll once live.** The HTTP `resolveFlags` fetch + poll
  timer remain as cold-start/fallback only. On the first live snapshot the
  SDK sets a `streamIsLive` flag; thereafter late HTTP responses are dropped
  so the two channels never fight over the cache.
- **`FirebaseConfig` defaults to placeholder Argus prod values** (the
  Firebase apiKey/appId/projectId are public client identifiers, not
  secrets) with an `.emulator()` preset for local/harness testing. These
  placeholders must be swapped for the real Argus prod project values
  before publishing.

**Verified**: `swift build` and all 56 unit tests pass; `xcodebuild` builds
for the iOS Simulator (iPhone 17, iOS 15+ deployment target). Firebase 10.x
resolved via SwiftPM.

## 2026-06-02 — ⭐ CANONICAL: real-time push via Firestore listeners (supersedes the HTTP-poll design)

> **AUTHORITATIVE / owner-approved (shahin@98chimp.com).** Canonical record:
> argus-web-app/DECISIONS.md (2026-06-02, #215).

**Decision**: `ArgusManager` delivers flag changes via **Firestore real-time listeners** (`addSnapshotListener`), not HTTP polling. On start it trades its apiKey for a scoped Firebase custom token (`issueStreamToken` callable), signs in, and listens to its product's flag/env docs; changes push into the existing `configUpdatedPublisher` in ~1s. Per-user/per-device targeting resolves locally via the SDK's existing `FNV1a` (rollout) + version-compare (conditions). The `resolveFlags` HTTP call + `pollTimer` are demoted to a **cold-start / fallback path only** — they are no longer the live update channel.

**This SUPERSEDES** the prior HTTP-poll-only model (the `pollInterval`/`resolveFlags` design carried since the 2026-05-18 Android-side pivot). Real-time push to the client was always the intended design; the poll model dropped it without owner authorization. Do not reintroduce poll-only or SSE as the primary channel.

**Reason / governance**: push-to-client is the core value proposition; reconciling the SDK back to it. No future pivot of the transport/auth/real-time model without explicit owner approval, recorded here as superseding.

## 2026-05-23 — M-1: apiKey identifies a Product, not a Customer

**Decision**: The Argus apiKey now identifies a per-Product credential (was per-Customer). SDK code unchanged — apiKey already drove identity via `Authorization: Bearer`. README + example updated to show multiple `ArgusManager` instances for multi-product apps.

**Reason**: M-1 (argus-web-app#107) introduced Product as a first-class entity. apiKey moved off Customer onto Product so a studio with multiple apps can have disjoint apiKeys per app.

**Alternatives considered**: None — the SDK API is unaffected.
