# LibraVia

Version **0.3.0** adds private recovery for standalone EPUB, PDF and CBZ files and reading data, plus reader-position and offline-library hardening. See the [release notes](docs/releases/0.3.0.md), [implementation audit](docs/RELEASE_IMPLEMENTATION_AUDIT.md), and [changelog](CHANGELOG.md). The [roadmap to 1.0](docs/ROADMAP.md) tracks later work. Contributors and agents should start with [AGENTS.md](AGENTS.md), [architecture and ADRs](docs/ARCHITECTURE.md), and the [development workflow](docs/DEVELOPMENT.md).

LibraVia is a native SwiftUI reader for DRM-free EPUB, PDF, and CBZ books on iPhone, iPad, and native Mac on Apple OS 27. Connect a Jellyfin 12 server or use a standalone local library. Audiobooks, additional providers, and older-platform compatibility are planned for later milestones.

## Get started

1. Open `JellyfinBooks.xcodeproj` in Xcode 27.
2. Select the shared **LibraVia** scheme and your iPhone, iPad, simulator, or **My Mac** destination.
3. Copy `Configuration/LocalSigning.xcconfig.example` to `Configuration/LocalSigning.xcconfig` and set your Apple development team locally, or pass `DEVELOPMENT_TEAM` to Xcode. The local configuration is ignored by Git. All platforms share the bundle identifier `com.chameleonenterprise.LibraVia`.
4. Run the app and either choose the local library or enter your Jellyfin HTTPS server URL, username, and password. No server or credentials are supplied by the project.

The app identity changed during development. Earlier app containers and saved sessions are not automatically migrated; a new installation requires login. Debug builds provide **Preview a Sample Book** using original CC0 EPUB/PDF/CBZ fixtures. Release builds omit that entry point.

## Features

- Home with Continue Reading, additional in-progress books, server recommendations, collections, and recently added books.
- Library cover grids or compact rows, author/genre/collection browsing, contextual filters, and independent paginated catalog search.
- Device saves, a download queue, local import, a user-selected books folder, and storage controls are included. Device-copy removal preserves source files and reading data.
- EPUB typography, shared app colors, contents, bookmarks, text search, continuous chapter scrolling and layout-based pagination. Adjustable edge taps, genuine adjacent-page previews, interruptible card turns and native iPhone/iPad page curl.
- Separate resizable Mac reader window, native menus/shortcuts, trackpad-driven EPUB turns and an attached inspector with inline appearance sliders.
- PDFKit search and position-preserving navigation; cancellable comic image decoding with distinct zoom/pan and page gestures.
- Editable, edition-aware bookmarks, highlights, notes, annotation search/navigation and Markdown/JSON export with book/source context. Jellyfin progress handling remains separate.
- Opt-in private iCloud recovery for managed standalone originals and reading data, with a separate Jellyfin reading-data recovery flow; retained conflicts, tombstones and account-switch review.
- EPUB scroll-mode visibility/lock-resume hardening and changed-edition saved-position review; CBZ page-loading guards prevent annotations at stale positions.

Books are downloaded locally before reading; this is not progressive network rendering. Cached copies may be evicted; explicitly saved copies use separate storage. The development candidate includes experimental private iCloud recovery for managed standalone books and reading data, plus a separate action for Jellyfin-linked reading data. Both can retry in the foreground after opt-in. Cloud configuration, offline reliability and cross-device recovery still require acceptance; retain original files and do not rely on recovery yet. Signing out warns before removing Jellyfin account data; reading state with pending iCloud recovery changes remains on the device, as can earlier recovery journals. A separately selected book folder remains user-owned. PDF text search requires a text layer; no OCR or DRM support is provided. EPUB page counts describe rendered screens/spreads for the current layout; typography and viewport changes trigger a recount. Counting/unavailable status replaces stale counts. Vertical mode reports percentage progress. Unusual/fixed layouts and large books still require acceptance. Search is capped at 200 results.

## Architecture

| Area | Responsibility |
| --- | --- |
| `App/Core` | Provider-neutral models, app state, reading persistence, managed cache, archive validation |
| `App/Jellyfin` | Adapter over official Jellyfin SDK requests and DTOs |
| `App/Readers` | Native SwiftUI controls, WebKit/EPUB.js, PDFKit, comic image navigation |
| `App/UI` | Login, catalog, details, settings |
| `App/Resources/Reader` | Bundled renderer and local-resource bridge; no runtime CDN |

The single native multiplatform target shares sources and dependencies; platform-specific sandbox and information settings remain conditional. The editable shipping Icon Composer source is `App/Resources/AppIcon.icon`.

## Dependencies and licenses

| Dependency | Pin | Provenance |
| --- | --- | --- |
| JellyfinAPI | 3.1.0 | Official Jellyfin Swift SDK |
| EPUB.js | 0.3.93 | Renderer used by Jellyfin Web 12.0 RC7 |
| JSZip | 3.10.1 | Required by EPUB.js and pinned by Jellyfin Web; used for local archive extraction via JavaScriptCore |

Both `Package.resolved` files pin required Swift transitive dependencies. The SDK requires Get and Apple's SwiftNIO transport services. No additional provider, analytics SDK, archive library, or hosted sync service is included. Bundled dependency notices are in `App/Resources/Licenses` and Settings. Fixture dedication is in `Fixtures/LICENSE.txt`. The project retains all rights under [LICENSE](LICENSE); public source visibility does not grant reuse rights. Third-party licenses and fixture CC0 dedication remain unchanged.

References: [Jellyfin Swift SDK](https://github.com/jellyfin/jellyfin-sdk-swift/tree/3.1.0), [Jellyfin Web pinned dependencies](https://github.com/jellyfin/jellyfin-web/blob/v12.0-rc7/package-lock.json), [Apple PDFKit](https://developer.apple.com/documentation/pdfkit), [Apple WebKit](https://developer.apple.com/documentation/webkit), [Apple Keychain](https://developer.apple.com/documentation/security/keychain-services).

## Build and test

Use the regular Xcode 27 installation and record `xcodebuild -version` for validation:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project JellyfinBooks.xcodeproj -scheme LibraVia -destination 'platform=macOS' -derivedDataPath /tmp/libravia-build CODE_SIGNING_ALLOWED=NO build
xcodebuild -project JellyfinBooks.xcodeproj -scheme LibraVia -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/libravia-build CODE_SIGNING_ALLOWED=NO build
swift test --build-system native --scratch-path /tmp/libravia-tests
node scripts/test_reader.js
node scripts/test_reader_frame.js
python3 -m unittest discover -s scripts/performance -p 'test_*.py'
```

Run Xcode builds sequentially when sharing DerivedData. `scripts/generate_project.py` maintains the project without a third-party generator. Select signing locally rather than checking provisioning profiles, developer credentials, device identifiers, or personal signing settings into source control.

## Release and acceptance status

Version 0.3.0 is an owner-authorized GitHub source release, version 0.3.0/build 59. Version 0.2.5 was promoted unchanged through beta and preview to main before this release. Local core tests, reader probes and Mac/iOS builds pass; security review results and exact source identities are recorded in [VALIDATION.md](VALIDATION.md). A current development build was installed and launched on a physical iPhone 17 Pro; installation does not establish reader acceptance.

Physical iPhone/iPad and sustained Mac reading, accessibility, representative real-book performance, live Jellyfin/iCloud account transitions and two-device/reinstall restoration remain explicit follow-up acceptance. Earlier issues keep their evidence rather than marking unrun criteria as passed. Milestone completion describes the delivered source scope; it does not certify those checks. Keep original books and separate backups until recovery is verified.

The owner handles TestFlight through Xcode Cloud after source publication. This GitHub release includes no IPA/PKG, no new TestFlight upload, no tester activation and no App Store submission. Historical build 58 uploads are separate and superseded by this source. See [PRIVACY.md](PRIVACY.md), [SECURITY.md](SECURITY.md), [TESTFLIGHT.md](TESTFLIGHT.md) and [CONTRIBUTING.md](CONTRIBUTING.md). Final signed-build entitlements, useful aggregate privacy reporting, App Store Connect disclosures, processing and tester availability remain separate distribution checks.
