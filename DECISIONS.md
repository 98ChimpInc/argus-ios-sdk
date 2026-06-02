# Decisions Log

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
