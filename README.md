# LibraVia

The [roadmap to 1.0](docs/ROADMAP.md) defines the next milestones, including native reading, dependable offline books, multiple sources, annotations, and supported-server sync. Version 0.2.0 is the alpha source release for the native reading experience; later milestones remain planned. See [release notes](docs/releases/0.2.0.md), [changelog](CHANGELOG.md) and [current handoff](docs/HANDOFF.md) for shipped scope and remaining acceptance. Contributors and agents should start with [AGENTS.md](AGENTS.md), [architecture and ADRs](docs/ARCHITECTURE.md), and the [development workflow](docs/DEVELOPMENT.md).

LibraVia is a native SwiftUI reader for DRM-free EPUB, PDF, and CBZ books from a user-selected Jellyfin server. It targets iPhone, iPad, and native Mac on Apple OS 27 with Jellyfin 12. Audiobooks, additional providers, and older-platform compatibility are planned after this release.

## Get started

1. Open `JellyfinBooks.xcodeproj` in Xcode 27.
2. Select the shared **LibraVia** scheme and your iPhone, iPad, simulator, or **My Mac** destination.
3. Copy `Configuration/LocalSigning.xcconfig.example` to `Configuration/LocalSigning.xcconfig` and set your Apple development team locally, or pass `DEVELOPMENT_TEAM` to Xcode. The local configuration is ignored by Git. All platforms share the bundle identifier `com.chameleonenterprise.LibraVia`.
4. Run the app and enter your Jellyfin HTTPS server URL, username, and password. No server or credentials are supplied by the project.

The app identity changed during development. Earlier app containers and saved sessions are not automatically migrated; a new installation requires login. Debug builds provide **Preview a Sample Book** using original CC0 EPUB/PDF/CBZ fixtures. Release builds omit that entry point.

## Features

- Home with Continue Reading, additional in-progress books, server recommendations, collections, and recently added books.
- Library cover grids or compact rows, author/genre/collection browsing, contextual filters, and independent paginated catalog search.
- Download-on-open with validation and a managed 1 GB cache. Download and confirmed device-only removal actions retain positions and bookmarks.
- EPUB typography, shared app colors, contents, bookmarks, text search, continuous chapter scrolling and layout-based pagination. Adjustable edge taps, genuine adjacent-page previews, interruptible card turns and native iPhone/iPad page curl.
- Separate resizable Mac reader window, native menus/shortcuts, trackpad-driven EPUB turns and a floating glass inspector with inline appearance sliders.
- PDFKit search and position-preserving navigation; cancellable comic image decoding with distinct zoom/pan and page gestures.
- Exact local EPUB locations, local bookmarks/preferences, coalesced Jellyfin progress writes, retry, conflict selection, and deliberate rematching when a server item disappears.

Books are downloaded locally before reading; this is not progressive network rendering. Cached copies may be evicted. PDF text search requires a text layer; no OCR or DRM support is provided. EPUB page counts describe rendered screens/spreads for the current layout; typography and viewport changes trigger a recount. Counting/unavailable status replaces stale counts. Vertical mode reports percentage progress. Unusual/fixed layouts and large books still require acceptance. Search is capped at 200 results.

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

Version 0.2.0 is an owner-authorized alpha source release. It does not promote beta, preview or main, or establish a TestFlight/App Store distribution. Physical iPad, accessibility, sustained real-book Mac use and final mobile curl/search/haptic acceptance remain open in gate #28. Repository publication, archive validation, upload, processing, and tester distribution are separate steps; source availability does not establish a distributed build. See [VALIDATION.md](VALIDATION.md) for verified evidence and open gates, [PRIVACY.md](PRIVACY.md) for data handling, [SECURITY.md](SECURITY.md) for sensitive reports, [TESTFLIGHT.md](TESTFLIGHT.md) for beta setup, and [CONTRIBUTING.md](CONTRIBUTING.md) for contribution boundaries.

A final signed archive needs its entitlements, privacy report, dependency notices, and App Store Connect answers reviewed. Cross-installation and Jellyfin web-reader synchronization, including offline conflicts and PDF/CBZ fixtures, remain release gates.
