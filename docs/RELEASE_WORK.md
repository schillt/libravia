# Current release implementation work

Current owner authorization: publish 0.3.0/build 59 source to GitHub, update project/milestone tracking and retain unrun acceptance as follow-up. Version 0.2.5 has first been promoted unchanged to main through #67–#69. The owner handles TestFlight. Earlier restrictions below describe prior checkpoints; no new binary distribution is authorized.

The local implementation audit is complete at `ac173c37b8837fcaeeba35f24c69af9441d213cd`: see [requirement evidence and pending acceptance](RELEASE_IMPLEMENTATION_AUDIT.md). The entries below retain the work history; their earlier next-work suggestions do not represent newly discovered missing implementation. Source is ready for owner review, while #28/#29/#64/#65 remain open for independent acceptance. No distribution is authorized.

Finish local implementation before distribution preparation. No further TestFlight upload, compliance submission or group activation is authorized. Use Xcode Cloud after a separately approved integration when the owner authorizes the finished release. Never upload Codex branches.

Build 58 is a historical preparation/upload checkpoint, not the final release candidate. Later local fixes supersede its source. Production/device checks that cannot run locally remain explicitly pending while other implementation proceeds; they are not a reason to stop the remaining work or repeatedly request distribution permission.

| Issue | Local implementation status | Next work |
| --- | --- | --- |
| #17 exports | Fixed missing author/source metadata and Markdown format; JSON schema 2 adds metadata while preserving reading items. 17 bookmark/export tests pass, including format/Unicode/privacy coverage. | Mac and iOS integration builds pass; native save/share interaction remains separately recorded. |
| #15 bookmarks | Fixed bookmark edition provenance, legacy/changed-edition review, bounds checks and edition-aware deduplication; persistence and recovery-codec tests pass. | Check the native review interaction during the next local reader journey; keep legacy bookmarks intact. |
| #6–#9 offline/import/folder/queue | Existing local implementations and synthetic tests; a catalog-write-failure/retry test now verifies preserved original bytes, honest failed-import visibility and stable recovered identity. Acceptance remains open. | Continue targeted failure-path review and fix demonstrated gaps, including relaunch/account isolation, storage failure, cancellation and preserved source files. |
| #16 annotations | Existing EPUB/PDF highlights and page notes with edition checks; added the missing native bookmark-name search. | Review local create/edit/remove/search/jump/export behavior across EPUB, text/scanned PDF and CBZ. |
| #64 private recovery | Transport, asset/journal/conflict/tombstone/account-review implementation exists; Production schema deployed. Added overflow-safe tick conversion, save/sync validation and restore bounds that keep corrupt page positions/bookmarks staged across journal reopening. The actual Jellyfin sync entry point is tested to make zero requests for a corrupt saved position. | Continue fixes demonstrated locally. Keep live account changes/two-device/reinstall evidence pending for the eventual authorized release test. |
| #65 reader acceptance | EPUB lock/unlock fix has synthetic and bounded earlier-device feedback. | Complete locally available reader/accessibility checks and fix defects. Preserve physical iPhone/iPad/live-server/performance gaps as pending. |

Keep #28 and #29 open. Implementation, automated checks, local UI evidence and eventual live acceptance are separate outcomes.

Latest local verification: 277 core tests pass. Native Mac and iOS Simulator Release builds pass without signing or distribution. These local fixes supersede the uploaded build 58 source and do not designate a finished candidate.

## Edition-safe local restoration completed

Checkpoint `c702b4f697957879584b30a89b82509735797eb8` hashes the actual book before constructing the reader, retains per-record renderer fingerprints, and holds changed/legacy/out-of-range saved places for native review. Choosing a place or beginning preserves the earlier place as a bookmark first. Cancelling retains the position and a persistent edition sync hold; retry cannot bypass it. Stale choices/source changes and failed backup writes cannot overwrite the saved place. Recovery payloads retain renderer fingerprints separately from original-asset edition digests.

Current checks: 277 core tests pass, including nine edition tests and the actual-sync edition-hold regression. Mac and iOS Simulator Release builds pass without signing or distribution. Native interaction and Production/device acceptance are still separately pending.

## Completion audit scope

The [completed audit](RELEASE_IMPLEMENTATION_AUDIT.md) reconciles the remaining 0.3 implementation requirements (#6–#9, #15–#17, #64 and the locally implementable reader work under #65) against source entry points and test coverage. Its discovered CBZ readiness defect is fixed below. TestFlight, physical-device, live-account/server and unavailable native interaction checks remain explicit and pending, without returning to distribution preparation.

Runtime tooling note: the Xcode device-interaction bridge requests an unavailable `device-interaction` skill; the attempted session is no longer live. Native CUA also rejects the Simulator app. No interaction evidence is claimed from those attempts, and no additional simulator was created. Continue core/runtime-independent work; keep the native bookmark review/save/share journey unverified.

## CBZ page-loading annotation safety

The comic surface previously kept `ready` true at the earlier position while decoding the next page. It now clears readiness synchronously when navigation starts and during decoding; only successful decoding publishes the new position and restores readiness. Bookmark creation and page-note actions guard readiness. An unreadable page retains the last readable saved position.

The actual SwiftUI comic surface is exercised in `scripts/test_format_navigation.swift`: initial decode, synchronous readiness retirement, successful next-page publication, damaged image, preserved prior position and return to reading. The probe passes against current source and fails at the expected readiness assertion against the prior surface. The probe's annotation stub was updated to include the existing color field. Native Mac and iOS Simulator Release builds pass without signing. This is native fixture evidence, not physical-device or TestFlight acceptance. The 277 core tests from the preceding checkpoint are unchanged; no core source changed here.
