# LibraVia 0.2.5 alpha candidate validation

The owner authorized the 0.2.5 alpha source prerelease; repository build 56. Exact source is the `v0.2.5` tag once published. This document does not close acceptance gates #28 or #29.

The release-preparation checkout starts from GitHub alpha `48981f802f02ce968514bfe21993deb8d0b8ca9f` and incorporates the verified development runtime snapshot. The protected original checkout remains unchanged. Runtime files were byte-matched to the tested installed development candidate before version metadata changed. Affected release-candidate checks are recorded below; historical results are not substituted for this candidate.

## Candidate checks

- Core: 135 tests passed on the release-preparation source.
- Renderer: JavaScript reader bridge and frame checks passed.
- Performance tooling: three report tests passed.
- Platform Release archives, signing and source metadata: outcomes recorded on the exact candidate PR and GitHub release.
- Pre-publication security diff review: report and coverage recorded on the candidate PR/release before publication.
- Runtime: the accepted development runtime was byte-matched before the metadata change; Mac visual feedback and prior selected physical iPhone annotation checks do not establish complete latest-candidate device acceptance.
- Distribution: no TestFlight upload, Apple processing or tester availability is established by this source document.

## Scope and remaining acceptance

Reader/inspector/resize and library UI refinements are available for alpha testing. The owner accepted the Mac visual pass as good enough for this checkpoint. Native EPUB Highlight and Add Note worked in prior owner-tested Mac and iPhone builds; latest-device coverage remains independent. Local offline/import/folder/download and annotation/export code is included as experimental alpha scope. Private iCloud upload/restore is not wired; do not rely on cloud recovery. Account sign-out warns before deleting account-local unsynced reading data. See [privacy](PRIVACY.md).

0.3 retains offline relaunch, interruption/retry, storage exhaustion, corruption, source/account isolation, device-copy removal without reading-data loss, complete format/annotation/export/migration checks and working private iCloud book/reading-data sync with account-change, two-device and reinstall recovery. Physical iPhone/iPad, native sustained Mac, VoiceOver/larger text/Reduce Motion, live Jellyfin and distribution remain separate gates. Server annotation synchronization remains 0.6.

## Historical validation

The prior 0.2.0 alpha/build 55 source and its recorded checks remain in repository history and [0.2.0 release notes](docs/releases/0.2.0.md). They do not validate this candidate's new local storage, annotations or credential behavior.
