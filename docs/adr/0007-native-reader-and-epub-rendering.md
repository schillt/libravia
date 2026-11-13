# ADR 0007: Native reader experience with local WebKit EPUB rendering

Status: Accepted by the owner, 2026-11-01; implementation and acceptance ongoing. This refines [ADR 0001](0001-native-apple-platforms.md) and absorbs the renderer-ownership portion of the withdrawn ADR 0008 draft.

## Context

The owner wants a responsive, native-feeling reader across iPhone, iPad and Mac, including native selection menus, reading tools, page turns and reflow. EPUB publications contain HTML and CSS. LibraVia currently renders locally using a trusted reader shell, EPUB.js and WebKit; it does not stream the reader interface from a website. The WebKit project identifies Apple Books as an application it powers, but Apple's complete Books implementation is not public. See [WebKit documentation](https://docs.webkit.org/) and [Apple's EPUB inspector guidance](https://help.apple.com/itc/booksassetguide/en.lproj/itc5905301b7.html).

## Decision

Continue with local WebKit-based EPUB rendering and native SwiftUI, UIKit and AppKit integration. Treat the native experience as an end-to-end behavior requirement, including system selection menus, accessibility, input, reader chrome, animations and recovery. WebKit is a rendering component, not the owner of app navigation, persistent data, or provider synchronization. Preserve existing publication isolation; do not enable book-provided scripts to implement reader features.

Keep PDFKit and the existing native comic surface for their respective formats. Do not introduce a second EPUB engine or rewrite EPUB layout in TextKit solely to achieve a native appearance. A future engine replacement or significant dependency requires a separate proposal and representative-book comparison across iPhone, iPad and Mac. Readium's Swift navigator is an evaluation option, not an adopted dependency or a demonstrated native Mac solution.

Retain EPUB.js initially. Define a small, validated renderer interface for navigation, selection, search, layout and decorations. Swift owns the reader session and interaction coordination; validate message origin, frame, type and payload bounds. Tag asynchronous work with session, request and layout ownership, rejecting obsolete results when books or layouts change. Keep provider DTOs and synchronization logic outside the renderer.

Use Apple Books as the experience reference for observable behavior, not as evidence of its private implementation. Improve native behavior and the underlying architecture together in focused increments. [ADR 0008](0008-consistent-reading-presentation.md), [ADR 0009](0009-native-selection-and-annotations.md) and [ADR 0010](0010-navigation-and-reflow.md) define the related contracts.

## Alternatives and consequences

A custom TextKit renderer could give greater control over native text layout but would require maintaining EPUB HTML/CSS fidelity, pagination, images, links, accessibility and format compatibility. A mature third-party engine could reduce custom reader code but needs platform, license, migration and compatibility evaluation. Retaining the current engine avoids an immediate migration while leaving us responsible for a well-defined bridge and performance.

## Migration and verification

Preserve existing positions, bookmarks and annotations through reader changes. Compare the same DRM-free EPUB in LibraVia and Apple Books on the same device with comparable font size, theme and layout. Check selection menus, annotation creation/edit/removal/jump, search, links, ordinary/rapid/cancelled turns, typography changes, rotation/resizing and reopening at the saved location. Check VoiceOver, larger text, Reduce Motion and keyboard/pointer input separately. Record performance and animation completion/cancellation on the exact candidate. A compile or synthetic WebKit probe does not establish physical acceptance. See the [reader plan](../READER_ARCHITECTURE_PLAN.md) for delivery and evidence requirements.
