# Private recovery: live-device validation

This is a test procedure, not evidence that recovery has passed. The owner intends to test iCloud using the production TestFlight build. Use synthetic books and disposable reading data, and an isolated iCloud test account if available. Do not sign out a person's account or remove an existing app installation to prepare the test. Record the exact candidate and the result for each platform separately in `VALIDATION.md`; omit account names, device identifiers, private URLs, screenshots of personal data and credentials.

Jellyfin position deletions require explicit review. Include a staged deletion and a conflict involving a deletion in live acceptance; verify that the open reader and server progress remain unchanged and that changed server progress or unsynced local progress blocks the choice. Local automated tests do not substitute for live Jellyfin and device evidence.

Account-transition release risk: the app checks the active iCloud identity before and after a CloudKit write and cancels manual recovery when its scene becomes inactive. These measures do not prove which account receives a write already in flight or that cancellation prevented a server commit. Recovery zone names currently identify the source, not the iCloud account; both private databases can therefore contain a zone with the same name. Do not treat a post-write account check or a successful normal sync as proof of account isolation. Resolve or obtain an authoritative platform guarantee for this case and test account transitions before declaring private recovery ready.

## Setup

The reviewed Apple references describe [temporary account unavailability](https://developer.apple.com/documentation/cloudkit/ckaccountstatus/temporarilyunavailable), [conditional record saves](https://developer.apple.com/documentation/cloudkit/ckmodifyrecordsoperation/recordsavepolicy/ifserverrecordunchanged), and [operation completion](https://developer.apple.com/documentation/cloudkit/ckmodifyrecordsoperation/modifyrecordsresultblock). They do not establish an account-routing guarantee for a write already in flight. The account-transition risk above remains unresolved by this documentation review.

- Use TestFlight builds from the same exact candidate on both test devices, with the intended production CloudKit container and schema. Verify the actual bundle, signing, provisioning and container environment; a simulator or Debug entitlement alone is not release-distribution evidence. Upload and distribution still require the owner's explicit authorization at the established checkpoints.
- Confirm both devices use the same iCloud account chosen for testing. Confirm an independent original of each fixture remains outside the app. Use `Fixtures/Harbor.epub`, `Harbor.pdf` and `Harbor.cbz`; use a synthetic Jellyfin account and library for server-linked tests.
- Keep automatic recovery off initially so each transfer and interruption can be observed. Use **On My Device → Private Recovery → Check iCloud** for standalone books. If the test account has no area, explicitly choose **Set Up Recovery**; do not treat a removed or reset area as empty. Use the reader's **Private Reading Recovery** for an open Jellyfin book.

## Two-device journey

1. On device A import one fixture of each format. Move to recognizable positions and add named bookmarks, highlights and notes supported by each format. Record the expected values without private data.
2. Go offline, make more changes, close and reopen the books, and verify reading and annotations remain available. Reconnect and run **Sync and Restore**. Resolve any edition or conflict review before declaring the pass complete.
3. On device B, run recovery with the same test account. Verify each original file, format, precise position, bookmark, highlight and note. Include both text and scanned PDF fixtures; the bundled PDF does not by itself establish scanned-PDF coverage.
4. Interrupt an upload and a download, retry, and verify no partial or duplicate books, lost edits or altered source files. Exercise insufficient storage and iCloud unavailable states; restore capacity/connectivity and verify pending work resumes.
5. Make concurrent edits and deletions on the two devices while offline. Reconnect in both orders, inspect the alternatives, choose versions explicitly, and verify an older copy cannot resurrect a deletion.
6. Change the test iCloud account while work is pending. Verify local reading continues, the second account cannot receive the first account's queued work without the reviewed switch, and returning to the first account resumes it. Separately review and exercise both Jellyfin and standalone account-switch flows, including pre-existing destination data and unmatched items.
7. With a disposable installation and synthetic data only, verify a completed backup, remove the app, reinstall the same candidate, and restore. Record deletion/reinstall separately from ordinary two-device recovery. Check the independent source files remain unchanged.

## Separate acceptance evidence

Record physical iPhone, physical iPad, native Mac, accessibility, live Jellyfin, account transitions, signed archive, TestFlight processing and tester availability as distinct results. For EPUB scroll mode, include repeated lock/unlock, a longer lock, status-bar taps, close/reopen, and more than one title. A single successful device gesture or synthetic-cloud test does not close gates #28 or #29.
