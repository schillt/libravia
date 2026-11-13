# Internal TestFlight setup

Current owner direction: publish the authorized 0.3.0/build 59 source release to GitHub; the owner will handle TestFlight after it clears. Do not upload an IPA/PKG, submit compliance, activate testers or submit App Store review. Use Xcode Cloud for owner-operated TestFlight builds from the authorized integrated source. Historical build 58 uploads below are superseded and do not validate this source. Never upload a Codex branch.

The public repository is connected to Xcode Cloud. The commands below are documentation, not a claim that archives or uploads were performed.

LibraVia has one shared target, scheme, and bundle identifier. iOS/iPadOS and native macOS still require separate destination archives and uploads. Use one App Store Connect app record with the matching identifier and the required platforms.

## Current recovery release preparation

The owner has directed that Codex local branches must never be uploaded to GitHub. The current recovery work is a local candidate being prepared as 0.3.0/build 58, so the Xcode Cloud workflow below cannot build it as-is. Prepare a reproducible, locally archived candidate after the remaining code and validation work is complete; record its exact source state, marketing version and unique build number before archive. Review the resulting distribution-signed archive, privacy report, entitlements and production CloudKit schema. The owner authorized Production schema promotion on November 12, 2026; the deployed export matches the reviewed schema exactly. TestFlight upload/distribution still requires the owner's separate explicit authorization. This preparation does not grant permission to upload a branch or binary.

## 0.2.5 alpha source-release status

The owner authorized the 0.2.5 alpha source prerelease, with source marketing version 0.2.5 and build 56. The owner intends to trigger Xcode Cloud and internal TestFlight after publication. Source publication does not upload a binary, establish processing, or make a build available to testers. Inspect each actual Cloud archive and processed artifact for its commit, marketing version, build number, signing and entitlements; do not assume Cloud's build number from the source setting. See [release notes](docs/releases/0.2.5.md) and [VALIDATION.md](VALIDATION.md).

## Internal test focus

Exercise reader transitions and controls, search and selection, notes and highlights, import and offline save, and resizing on representative books and devices. Keep the physical iPhone/iPad, accessibility, offline reliability, and data-recovery gaps open until individually verified. In the 0.2.5 alpha source release, local reading data and imported books did not sync or restore via iCloud. The later local development candidate includes experimental recovery, which must pass live two-device and reinstall testing before testers rely on it. Jellyfin sign-out warns about local removal; reading data with pending iCloud recovery changes is retained, and earlier recovery journals can remain. Gates #28 and #29 remain open.

## Prerequisites

- Active Apple Developer membership and App Store Connect permission to create the app and upload builds.
- Local signing configuration described in README. Keep signing credentials, API private keys, certificates, provisioning profiles, and export logs outside Git.
- Review the exact integrated candidate, dependency notices, entitlements, privacy report, privacy answers, and export-compliance answers before upload. Do not guess legal/compliance answers.
- Inspect the existing production CloudKit schema against [the recovery field inventory](docs/CLOUDKIT_SCHEMA.md). Prepare and review any schema diff; production schema promotion requires separate owner authorization and is not established by a development archive.
- Internal testers must be App Store Connect users with app access. Testing on a device does not require developer mode through TestFlight. People who are not internal account users require the external testing workflow and its review requirements.

## Xcode Cloud workflow

After repository publication, open the project in Xcode and configure Xcode Cloud for the shared LibraVia scheme. Connect the authorized GitHub repository, select Xcode 27 or later with the required OS 27 SDKs, and add Release Archive actions for iOS and macOS. Use TestFlight Internal Only post-actions for the intended internal group. Keep this distinct from an App Store release action.

Xcode Cloud manages signing using the team selected for the product. No custom signing hook or stored signing secrets are required. Its `CI_TEAM_ID` must not be copied into `DEVELOPMENT_TEAM`: the observed Cloud value is an App Store Connect UUID, rather than the local signing team identifier. The ignored local signing configuration is only for local builds; the commands below are an optional fallback.

An app record must support both iOS and macOS. After Cloud succeeds, inspect actual archive/upload processing, resolve warnings and declarations, and verify each processed platform build is available to its group. Workflow configuration alone does not distribute a build.

Apple references: [First Xcode Cloud workflow](https://developer.apple.com/documentation/xcode/configuring-your-first-xcode-cloud-workflow), [Distribution workflow](https://developer.apple.com/documentation/xcode/creating-a-workflow-that-builds-your-app-for-distribution), [Environment variables](https://developer.apple.com/documentation/xcode/environment-variable-reference).

## Optional local archive

Run sequentially with regular Xcode 27. The archive output directory is ignored by Git.

```sh
xcodebuild -project JellyfinBooks.xcodeproj -scheme LibraVia -configuration Release -destination 'generic/platform=iOS' -archivePath build/LibraVia-iOS.xcarchive -allowProvisioningUpdates archive
xcodebuild -project JellyfinBooks.xcodeproj -scheme LibraVia -configuration Release -destination 'generic/platform=macOS' -archivePath build/LibraVia-macOS.xcarchive -allowProvisioningUpdates archive
```

Inspect each archive in Xcode Organizer. A development build or successful archive is not proof of distribution eligibility. Ensure the intended marketing/build version, identifier, signature, supported OS, resources, and privacy manifest are present.

## Upload and distribute

The provided export template requests upload with internal-only testing. Review its settings before use; it does not publish to the App Store.

```sh
xcodebuild -exportArchive -archivePath build/LibraVia-iOS.xcarchive -exportOptionsPlist Configuration/ExportOptions-TestFlight.plist -exportPath build/TestFlight-iOS -allowProvisioningUpdates
xcodebuild -exportArchive -archivePath build/LibraVia-macOS.xcarchive -exportOptionsPlist Configuration/ExportOptions-TestFlight.plist -exportPath build/TestFlight-macOS -allowProvisioningUpdates
```

After processing, resolve any App Store Connect warnings or required declarations, create an internal group, add the intended app-access users, select the processed platform builds, and provide concise test notes. Record actual upload, processing, group availability, and installation separately in VALIDATION.md. Do not represent uploaded or processing builds as available to testers.

Install through TestFlight on a non-development iPhone/iPad and Mac and check login, reading, search, cleanup, and progress synchronization. Existing privacy and cross-client synchronization gates remain in effect for wider release.

Apple references: [Create an app record](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app), [Add internal testers](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers/), [Distribution through Xcode](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases).

## November 12, 2026 preparation evidence

Read-only App Store Connect inspection showed version 0.2.5/build 9 in internal Testing on both iOS and macOS. The local candidate uses 0.3.0/build 57, higher than the prior repository build 56. This does not designate the full 0.3 milestone complete or establish an uploaded candidate. A current Apple Development identity is available locally; no Apple Distribution identity was found. Exact archive, distribution export, aggregate privacy review, processing, group availability and production recovery acceptance remain outstanding. No Codex branch or binary was uploaded.

The owner later approved creating Apple Distribution, which succeeded. Organizer produced the local iOS distribution package with Production CloudKit and internal-only testing enabled; no upload occurred. Command-line account discovery remains unreliable. Mac installer signing needs its own Mac Installer Distribution credential; the owner approval is pending. Refer to VALIDATION for artifact identity and remaining gates.

Build 57 is superseded: Xcode's generated archive privacy report flagged the missing `NSPrivacyCollectedDataTypes` key. Build 58 adds the explicit empty collected-data array to the existing no-publisher-collection declaration; archive report regeneration and fresh distribution packages are required. Both Apple Distribution and Mac Installer Distribution certificate creations were explicitly approved and completed in Xcode. No build upload was authorized or performed.

Current prepared candidate: **0.3.0/build 58**, source `13b8d9d3a99c4d44c38cf79a20628a3ab02b72ae`. Both local distribution packages now exist with verified signatures and Production CloudKit entitlements. They are preserved under ignored `build/recovery-0.3.0-58/`; [candidate notes](docs/releases/0.3.0-beta-candidate.md) describe outstanding acceptance and privacy-report limits. Earlier build 57 and pending-certificate statements above are historical. Upload/distribution remains unauthorized.

## Authorized build 58 upload

On November 12, 2026, the owner explicitly authorized uploading 0.3.0/build 58 for iOS and Mac and enabling the existing internal TestFlight group, with documented recovery/privacy-report acceptance gaps still open. This authorizes these binaries only; Codex branches must never be uploaded. Xcode Organizer upload uses the matching verified archive, preserves build 58, includes symbols and limits the build to internal testing. Upload, processing and group availability must be recorded separately as observed.

## Owner direction after build 58 uploads

The owner clarified that implementation must be finished before TestFlight distribution and revoked further distribution work. Both build 58 uploads completed before cancellation was possible. Xcode reported each upload complete; the Mac build processed to Missing Compliance. No encryption declaration was submitted and no internal group was explicitly enabled by this agent. Tester availability is not claimed. Do not resume upload/compliance/group-enablement work under the earlier approval. Finish locally actionable release issues, preserve deferred Production/device checks as pending, and obtain fresh owner permission only after implementation is finished. The intended distribution path is Xcode Cloud following separately approved source integration; Codex branches must never be uploaded.
