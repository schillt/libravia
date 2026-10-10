# Validation

This report separates historical development evidence from verification of the exact publication or TestFlight candidate. It contains aggregate results only; local logs, private servers, accounts, device identifiers, reading locations, and screenshots are excluded.

## Revised 0.2.0/build 55 checkpoint

PR #62 runtime candidate is `4259c7604a0d08b2e3af55f04e90719fb5e21a40`; release-documentation changes preserve its runtime tree. The owner authorized integration into alpha and replacement of the v0.2.0 source release. Original build 54 remains historical below.

| Evidence | Result | Limit |
| --- | --- | --- |
| iPhone Release | Signed build, signature verification and selected physical-device installation passed | Development install; no signed distribution archive or upload |
| Owner feedback | Installed build seems to work fine | Scoped feedback; full card/curl gesture matrix remains open |
| iPhone 18 Pro Simulator / iOS 27.0 | arm64 Debug build/launch; portrait/landscape and hidden/revealed-control clearance; next-page navigation and settled rotation reflow | Bundled original EPUB; no physical Dynamic Island performance or gesture certification |
| Automated | Reader/frame checks passed | Does not establish direct-finger behavior |
| Security | Scan `73b3a5ee-d3ae-463c-95df-f395cef2b1c4`: all seven patch files reviewed, no reportable findings or gaps | Static patch review; supplementary release-documentation review recorded in #62 |

The owner will perform TestFlight operations. Gate #28 and incomplete #61 acceptance remain open. No beta/preview/main promotion is part of this patch.

## 0.2 alpha source-release checkpoint

The owner authorized v0.2.0 on 2026-10-08. PR #59 reviewed feature candidate `f62951a6e67778f2ababb641a74c0ab7fbf9e2ea`; alpha squash commit `86b3fd02fb95cfc8f85d02246b61e82e85c1167a` preserves its runtime tree. The final release tag adds documentation and 0.2.0/build 54 metadata. Exact metadata/build checks and the supplementary security review are recorded in that release PR. See [release notes](docs/releases/0.2.0.md) and [handoff](docs/HANDOFF.md).

| Evidence | Result | Limit |
| --- | --- | --- |
| Automated | 70 core tests, reader/frame checks, three report tests and trackpad checks passed | Feature candidate; metadata-only release changes checked separately |
| Native Mac compilation | Final feature candidate build passed | Does not establish distribution entitlements or physical interaction |
| Native WebKit | Consecutive pages, exact scrub, recount, CFI preservation, inspector/turn ordering,30 settings updates and provisional peek cancellation passed | Original synthetic fixture; does not establish the reported real-book crash resolved |
| Security | Scan `95fd6ec3-b117-4aca-936b-eb2400a336a1`: all31 changed files, no reportable vulnerabilities, exclusions or deferred candidates | Static diff review; no adversarial runtime, live-server or signed distribution verification |
| Physical iPhone | Prior install/launch and selected viewport/control checks | Installed candidate `8ce1dc26f714c2eebefeb0bc539b5bb42694a4f6`; final curl/search/haptics acceptance still open |
| Physical iPad/accessibility | Not completed | Gate #28 remains open |

The source-release designation is an owner decision, not evidence that omitted gates passed. No TestFlight/App Store upload, beta/preview/main promotion or new live-server validation is claimed. Remaining real-book, device and distribution gates continue below.

## Historical foundation development evidence

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

## Historical 0.1 publication candidate

Privacy pass removed temporary command tracing, added endpoint-aware state isolation, suppressed raw error detail, and tightened EPUB main-frame bridge/resource handling. The core suite passed 66 tests. Integrated build 53 passed the native Mac and signed iOS builds. Native Mac smoke testing verified EPUB opening under the tightened bridge/CSP, search open/close preserving the displayed page, forward/back navigation, restoration to the starting page, and normal reader close. iOS Simulator compilation also passed. The 72 staged publication files passed a targeted private-context scan, including fixture archive contents; no targeted private patterns or excluded signing/design/diagnostic artifacts were found. Staged whitespace checks passed with original upstream notices retained verbatim. These results cover build 53. No final physical-device run or TestFlight upload was performed. No historical result above establishes that candidate's privacy, distribution signing, runtime behavior, upload, or TestFlight availability. Record the final commit, aggregate test results, destination builds, and archive/upload outcomes here after verification.

## Remaining gates

- Verify login failures, expired tokens, Keychain restoration, sign-out online/offline, cleanup failures, and cancellation/account switching during network activity on the final signed app.
- Inspect iOS and Mac archives, entitlements, transport configuration, aggregated privacy reports, dependency notices, and App Store Connect privacy/export-compliance answers.
- Validate on a non-development iPhone/iPad installation and native Mac; report each separately from simulator and compilation.
- Verify positions between two installations and Jellyfin's web reader, including offline conflicts, completion marking, retries, and deliberate missing-item rematching.
- Exercise authenticated PDF and CBZ delivery/progress against disposable fixtures, EPUB appearance/rotation preservation, image-only PDF search, large documents, and interrupted downloads.
- Complete VoiceOver, hardware-keyboard text entry, window resizing, bookmarks, and gesture-conflict checks.

Internal TestFlight testing does not waive the existing privacy and cross-client synchronization gates for wider release.
