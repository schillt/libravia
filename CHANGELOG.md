# Changelog

## 0.3.0 — private recovery, build 59

- Private CloudKit recovery for managed standalone EPUB/PDF/CBZ originals, metadata and precise reading data; separate Jellyfin reading-data recovery.
- Durable outboxes, conditional conflict review, tombstones, account/source/edition guards and interrupted-operation retries.
- EPUB scroll-resume stability, edition-safe saved-position review and CBZ page-loading annotation guards.
- Editable edition-aware bookmarks, annotation search and metadata-rich Markdown/JSON exports.
- Offline/import/storage failure hardening, matched platform cloud configuration and updated privacy/distribution guidance.

Owner-authorized GitHub source release. Live recovery, platform/accessibility/performance and final distribution acceptance remain tracked follow-up; the owner handles TestFlight. See [release notes](docs/releases/0.3.0.md).

## 0.2.5 alpha — build 56

Reader and native UI refinements, with early local reading tools and offline-library features for testing. Reading data and imported books remain local; iCloud sync and restore are not connected. Gates #28 and #29 remain open. See [release notes](docs/releases/0.2.5.md) for scope and limitations.

## Revised 0.2.0 candidate — build 55

- Align iPhone adjacent-page preview and live WebKit inset policies; prevent native bounce of horizontal page information. Production finger acceptance is tracked in #61.

## 0.2.0 — 2026-10-08

Native reading and platform tailoring, released on alpha. See [full release notes](docs/releases/0.2.0.md) for evidence and open acceptance.

- Continuous EPUB scrolling across chapters; layout-dependent page recount and exact scrub targets; publication chapter labels and visible boundaries.
- Adjustable edge taps, responsive card previews/turns, native mobile curl and chapter scrub haptics.
- Immersive page-owned reading information, floating mobile controls and live appearance editing.
- Separate Mac reader window, trackpad page interaction, native commands and a stable glass inspector with inline sliders and serialized reflow.
- Shared browsing/reader colors, consistent cover/title layouts and left-to-right opening dots.
- PDF location preservation, comic decode cancellation and reproducible performance/reader regression tooling.

Physical/device, real-book and distribution acceptance remains explicitly recorded in [VALIDATION.md](VALIDATION.md). For 0.2.0, no new provider, durable offline storage or annotation support was claimed.

## 0.1.0 — Foundation

Shared native Apple OS 27 Jellyfin EPUB/PDF/CBZ reader, account-scoped local positions/bookmarks, managed cache and local-first progress handling. Historical evidence remains in VALIDATION.md.
