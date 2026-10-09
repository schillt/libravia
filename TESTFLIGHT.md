# Internal TestFlight setup

The public repository is connected to Xcode Cloud. The commands below are documentation, not a claim that archives or uploads were performed.

LibraVia has one shared target, scheme, and bundle identifier. iOS/iPadOS and native macOS still require separate destination archives and uploads. Use one App Store Connect app record with the matching identifier and the required platforms.

## 0.2 source-release status

The v0.2.0 alpha source release uses marketing version 0.2.0 and build 54. This release work does not upload binaries or configure/trigger a Cloud release workflow. See [release notes](docs/releases/0.2.0.md) and [VALIDATION.md](VALIDATION.md). Any future archive/upload must verify its own exact commit, entitlements and platform processing; development builds from build 53 are historical evidence.

## Revised build 55 test focus

The #61 candidate keeps version 0.2.0 and revises build to 55. On iPhone, turn card/curl pages forward and backward, cancel/reverse a drag and repeat rapid turns, with controls hidden and visible. Chapter and progress should retain the same vertical position without compressing or bouncing at the preview/live handoff. Check rotation, text-size recount, search-dismiss navigation and vertical chapter scrolling. This is a candidate test plan, not an upload or acceptance claim.

## Prerequisites

- Active Apple Developer membership and App Store Connect permission to create the app and upload builds.
- Local signing configuration described in README. Keep signing credentials, API private keys, certificates, provisioning profiles, and export logs outside Git.
- Review the exact integrated candidate, dependency notices, entitlements, privacy report, privacy answers, and export-compliance answers before upload. Do not guess legal/compliance answers.
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
