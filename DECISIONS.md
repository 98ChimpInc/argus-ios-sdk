# Decisions Log

## 2026-05-23 — M-1: apiKey identifies a Product, not a Customer

**Decision**: The Argus apiKey now identifies a per-Product credential (was per-Customer). SDK code unchanged — apiKey already drove identity via `Authorization: Bearer`. README + example updated to show multiple `ArgusManager` instances for multi-product apps.

**Reason**: M-1 (argus-web-app#107) introduced Product as a first-class entity. apiKey moved off Customer onto Product so a studio with multiple apps can have disjoint apiKeys per app.

**Alternatives considered**: None — the SDK API is unaffected.
