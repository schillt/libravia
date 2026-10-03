# Validation

This report separates historical development evidence from verification of the exact publication or TestFlight candidate. It contains aggregate results only; local logs, private servers, accounts, device identifiers, reading locations, and screenshots are excluded.

## Development evidence

| Surface | Observed result | Limit |
| --- | --- | --- |
| Core tests | Most recent privacy-pass core suite: 66 passing tests | Rerun if candidate changes after this pass |
| Renderer checks | Navigation, search cancellation/ownership, layout coalescing, page preview commit/cancel, and search keyboard viewport regressions passed | Deterministic bridge checks do not prove all gestures or visual layout |
| Native Mac | Builds and selected catalog/EPUB UI checks passed during development | Latest identity/project change was compile-only |
| iOS Simulator | Builds and selected sample EPUB/PDF/CBZ checks passed during development | Latest identity/project change was compile-only; no complete keyboard/VoiceOver matrix |
| Physical iPhone | Development builds installed; direct finger tests confirmed bidirectional turning, drag-back cancellation, and search open/close preserving location | This evidence predates the unified bundle identity and final privacy pass |
| Physical iPad | No final interactive run recorded | Required coverage remains open |
| Live Jellyfin | Login, catalog, EPUB opening, and controlled API progress round-trip observed | API round-trip is not web-reader/two-installation acceptance; PDF/CBZ integration not established |

Regular Xcode 27.0 was used for the latest recorded builds. The unified **LibraVia** target/scheme built for signed iOS, native macOS, and iOS Simulator. The changed bundle identity requires a fresh login; the unified-identity build had not been installed during that compile-only pass.

## Current publication candidate

Privacy pass removed temporary command tracing, added endpoint-aware state isolation, suppressed raw error detail, and tightened EPUB main-frame bridge/resource handling. The core suite passed 66 tests. Integrated build 53 passed the native Mac and signed iOS builds. Native Mac smoke testing verified EPUB opening under the tightened bridge/CSP, search open/close preserving the displayed page, forward/back navigation, restoration to the starting page, and normal reader close. iOS Simulator compilation also passed. The 72 staged publication files passed a targeted private-context scan, including fixture archive contents; no targeted private patterns or excluded signing/design/diagnostic artifacts were found. Staged whitespace checks passed with original upstream notices retained verbatim. These results cover build 53. No final physical-device run or TestFlight upload was performed. No historical result above establishes that candidate's privacy, distribution signing, runtime behavior, upload, or TestFlight availability. Record the final commit, aggregate test results, destination builds, and archive/upload outcomes here after verification.

## Remaining gates

- Verify login failures, expired tokens, Keychain restoration, sign-out online/offline, cleanup failures, and cancellation/account switching during network activity on the final signed app.
- Inspect iOS and Mac archives, entitlements, transport configuration, aggregated privacy reports, dependency notices, and App Store Connect privacy/export-compliance answers.
- Validate on a non-development iPhone/iPad installation and native Mac; report each separately from simulator and compilation.
- Verify positions between two installations and Jellyfin's web reader, including offline conflicts, completion marking, retries, and deliberate missing-item rematching.
- Exercise authenticated PDF and CBZ delivery/progress against disposable fixtures, EPUB appearance/rotation preservation, image-only PDF search, large documents, and interrupted downloads.
- Complete VoiceOver, hardware-keyboard text entry, window resizing, bookmarks, and gesture-conflict checks.

Internal TestFlight testing does not waive the existing privacy and cross-client synchronization gates for wider release.
